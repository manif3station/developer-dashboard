package Developer::Dashboard::Pax::AppServer;

our $VERSION = '5.25';

use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Select;
use IPC::Open3;
use JSON::XS qw(decode_json);
use POSIX qw(setsid);
use Symbol qw(gensym);
use Developer::Dashboard::Pax::AppImage;
use Developer::Dashboard::JSON qw(json_encode_with_options);

sub new {
    my ($class, %args) = @_;
    return bless {
        image => $args{image} // die('image required'),
    }, $class;
}

sub start {
    my ($self, %args) = @_;
    return $self->_daemonize if $args{daemonize};
    return $self->_serve;
}

sub run_client {
    my ($class, %args) = @_;
    my $image = $args{image} // die 'image required';
    my $argv = $args{argv} // [];
    my $cwd = defined $args{cwd} ? $args{cwd} : _cwd();
    my $socket = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $image->{socket_path},
    );
    if (!$socket) {
        return _direct_exec($image, $argv, $cwd);
    }
    my $request = json_encode_with_options( {
        argv => $argv,
        cwd => $cwd,
    }, ascii => 1 );
    print {$socket} "$request\n";
    my $exit = 0;
    while (defined(my $line = <$socket>)) {
        if ($line =~ /^__PAX_EXIT__:(\d+)/) {
            $exit = $1 + 0;
            last;
        }
        print $line;
    }
    close $socket;
    return $exit;
}

sub stop {
    my ($class, %args) = @_;
    my $image = $args{image} // die 'image required';
    my $socket = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $image->{socket_path},
    ) or return 1;
    print {$socket} "{\"control\":\"stop\"}\n";
    $socket->shutdown(1);
    my $response = <$socket>;
    close $socket;
    return defined $response && $response =~ /^__PAX_EXIT__:0\r?\n\z/ ? 0 : 1;
}

sub _serve {
    my ($self) = @_;
    my $image = $self->{image};
    _prepare_runtime($image);
    my $preload = _preload_modules($image);
    unlink $image->{socket_path} if -e $image->{socket_path};
    my $server = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Local => $image->{socket_path},
        Listen => 20,
    ) or die "cannot listen on $image->{socket_path}: $!";
    chmod 0600, $image->{socket_path};
    local $SIG{TERM} = sub { unlink $image->{socket_path}; exit 0 };
    local $SIG{INT} = sub { unlink $image->{socket_path}; exit 0 };

    while (my $client = $server->accept) {
        my $line = <$client>;
        if (!defined $line) {
            close $client;
            next;
        }
        my $request = eval { decode_json($line) } // {};
        if (($request->{control} // '') eq 'stop') {
            print {$client} "__PAX_EXIT__:0\n";
            close $client;
            last;
        }
        _run_request($image, $client, $request);
        close $client;
    }
    close $server;
    unlink $image->{socket_path};
    return 0;
}

sub _daemonize {
    my ($self) = @_;
    my $pid = _fork_process();
    die "fork failed: $!" if !defined $pid;
    return 0 if $pid;
    setsid();
    open STDIN, '<', '/dev/null';
    open STDOUT, '>', "$self->{image}{app_dir}/server.log";
    open STDERR, '>&', \*STDOUT;
    $self->_serve;
    exit 0;
}

sub _run_request {
    # Run one image request and return its Perl exit status to the socket client.
    # Inputs are image metadata, a connected client handle, and request hash; output is no direct return value.
    local $?;    # DD-882: localize the system status while retaining its value for the protocol response.
    my ($image, $client, $request) = @_;
    my $argv = $request->{argv} // [];
    my $cwd = $request->{cwd} // '.';
    my @command = _entrypoint_command( $image, $argv, $cwd );
    my $err = gensym;
    my $pid = open3( my $input, my $output, $err, @command );
    close $input;
    binmode $output;
    binmode $err;
    my $select = IO::Select->new( $output, $err );
    while ( my @ready = $select->can_read ) {
        for my $handle (@ready) {
            my ( $bytes, $chunk ) = _read_output_chunk($handle);
            if ( !$bytes ) {
                $select->remove($handle);
                close $handle;
                next;
            }
            _forward_output( $client, $chunk );
        }
    }
    waitpid( $pid, 0 );
    my $status = $?;
    my $exit = _exit_code($status);
    print {$client} "__PAX_EXIT__:$exit\n";
}

sub _prepare_runtime {
    my ($image) = @_;
    my @libs = @{ $image->{lib_dirs} // [] };
    unshift @INC, grep { -d $_ && !_in_inc($_) } @libs;
    if (@libs) {
        require Config;
        my $sep = $Config::Config{path_sep};
        my @existing = grep { length } split /\Q$sep\E/, ($ENV{PERL5LIB} // '');
        $ENV{PERL5LIB} = join $sep, @libs, @existing;
    }
}

sub _preload_modules {
    my ($image) = @_;
    my @loaded;
    for my $module (@{ $image->{preload_modules} // [] }) {
        next if $module !~ /\A[A-Za-z_][A-Za-z0-9_:]*\z/;
        my $ok = eval "require $module; 1";
        push @loaded, $module if $ok;
    }
    return \@loaded;
}

sub _direct_exec {
    # Execute the image directly when no application server is listening.
    # Inputs are image metadata, argv arrayref, and requested cwd; output is child exit status.
    local $?;    # DD-882: localize system status while preserving the caller's prior value.
    my ( $image, $argv, $cwd ) = @_;
    _prepare_runtime($image);
    if ( !-x $^X ) {
        print STDERR "exec failed: Perl interpreter '$^X' is not executable\n";
        return 111;
    }
    my @command = _entrypoint_command( $image, $argv, $cwd );
    system { $command[0] } @command;
    my $status = $?;
    return _exit_code($status);
}

sub _read_output_chunk {
    # Read one bounded block from a child output handle and return its byte count and content.
    # Input is an open readable filehandle; output is (byte count, content), with read failures fatal.
    my ($handle) = @_;
    my $bytes = sysread( $handle, my $chunk, 8192 );
    die "cannot read app-image output: $!" if !defined $bytes;
    return ( $bytes, $chunk );
}

sub _forward_output {
    # Forward one child output block to the connected client and fail on a broken client socket.
    # Inputs are a writable client handle and a byte string; output is true after a successful write.
    my ( $client, $chunk ) = @_;
    print {$client} $chunk or die "cannot forward app-image output: $!";
    return 1;
}

sub _exit_code {
    # Convert wait status to the CLI exit code, using 111 when process execution failed.
    # Input is Perl's wait status; output is a numeric exit code.
    my ($status) = @_;
    return $status == -1 ? 111 : $status >> 8;
}

sub _entrypoint_command {
    # Build a shell-free Perl command preserving do-file behavior and request context.
    # Inputs are image metadata, argv arrayref, and cwd; output is a list-form command.
    my ( $image, $argv, $cwd ) = @_;
    my $wrapper = <<'PERL';
my ( $entrypoint, $cwd, $image_name, @argv ) = @ARGV;
chdir $cwd if defined $cwd && -d $cwd;
@ARGV = @argv;
$0 = $entrypoint;
$ENV{PAX_APP_IMAGE} = $image_name;
my $ok = do $entrypoint;
if (!$ok) {
    print STDERR length($@) ? $@ : "failed to run $entrypoint: $!\n";
    exit 111;
}
exit 0;
PERL
    return ( $^X, '-e', $wrapper, $image->{entrypoint}, (defined $cwd ? $cwd : '.'), $image->{name}, @{$argv} );
}

sub _fork_process {
    # Fork the current process for one app-image worker.
    # Input is none; output is the child PID, zero in the child, or undef on failure.
    return fork();
}

sub _in_inc {
    my ($path) = @_;
    for my $inc (@INC) {
        return 1 if $inc eq $path;
    }
    return 0;
}

sub _cwd {
    require Cwd;
    return Cwd::getcwd();
}

1;

__END__

=pod

=head1 NAME

Developer::Dashboard::Pax::AppServer - fork server and request bridge for packaged app images

=head1 SYNOPSIS

  use Developer::Dashboard::Pax::AppServer;

  my $obj = Developer::Dashboard::Pax::AppServer->new(...);
  my $result = $obj->start(...);

=head1 DESCRIPTION

Runs the prefork application image server that accepts launcher requests, prepares the Perl runtime, and falls back to direct execution when the socket path is unavailable.

=head1 METHODS

=head2 new, start, run_client, stop

These are the public entrypoints exposed by this module's current interface.

=head1 PURPOSE

This module exists to keep the fork server and request bridge for packaged app images logic in one place so the CLI, build
pipeline, and runtime can reuse the same behavior instead of duplicating it.

=head1 WHY IT EXISTS

PAX uses this module when it needs fork server and request bridge for packaged app images. Keeping that behavior isolated here
makes the surrounding compiler and packaging stages easier to reason about and
safer to evolve.

=head1 WHEN TO USE

Edit this file when a change affects fork server and request bridge for packaged app images, the data contract this module
returns, or the conditions under which callers choose this path.

=head1 HOW TO USE

Load the module through the normal PAX call path, pass explicit arguments rather
than ambient global state, and keep project-specific behavior out of this file
so the implementation stays neutral across arbitrary Perl applications.

=head1 WHAT USES IT

This module is used by the PAX CLI, the build pipeline, standalone packaging,
and the test suite paths that cover fork server and request bridge for packaged app images.

=head1 EXAMPLES

Example 1:

  perl -Ilib -MDeveloper::Dashboard::Pax::AppServer -e 1

Confirm that the module loads from a source checkout.

Example 2:

  prove -lr t

Run the repository test suite after changing the behavior this module owns.

=cut
