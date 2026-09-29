#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Config ();
use Capture::Tiny qw(capture);
use Errno qw(EAGAIN);
use IO::Socket::UNIX;
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep);
use Test::More;

use lib 'lib';

use Developer::Dashboard::Pax::AppServer ();

my $root = tempdir( CLEANUP => 1 );
my $app_dir = File::Spec->catdir( $root, 'app' );
make_path($app_dir);
my $entrypoint = File::Spec->catfile( $app_dir, 'entry.pl' );
_write( $entrypoint, 'require Cwd; print "image=$ENV{PAX_APP_IMAGE};argv=@ARGV;cwd=" . Cwd::getcwd();' );
my $socket_path = File::Spec->catfile( $root, 'server.sock' );
my $image = {
    name => 'fixture-image',
    app_dir => $app_dir,
    entrypoint => $entrypoint,
    socket_path => $socket_path,
    lib_dirs => [ $app_dir, File::Spec->catdir( $root, 'missing-lib' ) ],
    preload_modules => [ 'strict', 'Bad::;Module' ],
};

my $missing_image = eval { Developer::Dashboard::Pax::AppServer->new; 1 };
ok( !$missing_image && $@ =~ /image required/, 'constructor requires an image descriptor' );
my $missing_client_image = eval { Developer::Dashboard::Pax::AppServer->run_client; 1 };
ok( !$missing_client_image && $@ =~ /image required/, 'client requires an image descriptor' );
my $missing_stop_image = eval { Developer::Dashboard::Pax::AppServer->stop; 1 };
ok( !$missing_stop_image && $@ =~ /image required/, 'stop requires an image descriptor' );
isa_ok( Developer::Dashboard::Pax::AppServer->new( image => $image ), 'Developer::Dashboard::Pax::AppServer' );
is( Developer::Dashboard::Pax::AppServer->stop( image => { socket_path => $socket_path } ), 1, 'stop reports when no server socket exists' );

for my $stop_response ( "not-an-exit\n", undef ) {
    my $fake_socket = File::Spec->catfile( $root, 'stop-' . ( defined $stop_response ? 'invalid' : 'empty' ) . '.sock' );
    my $listener = IO::Socket::UNIX->new( Type => SOCK_STREAM, Local => $fake_socket, Listen => 1 )
      or die "cannot create fake stop listener: $!";
    my $pid = fork();
    die "cannot fork fake stop listener: $!" if !defined $pid;
    if ( !$pid ) {
        my $client = $listener->accept or die "cannot accept fake stop request: $!";
        <$client>;
        print {$client} $stop_response if defined $stop_response;
        close $client;
        exit 0;
    }
    my $result = Developer::Dashboard::Pax::AppServer->stop( image => { socket_path => $fake_socket } );
    waitpid( $pid, 0 );
    is( $result, 1, 'stop rejects a missing or malformed server acknowledgement' );
}

{
    local @INC = @INC;
    local $ENV{PERL5LIB} = '';
    Developer::Dashboard::Pax::AppServer::_prepare_runtime($image);
    ok( grep( { $_ eq $app_dir } @INC ), 'runtime preparation adds a valid library directory to @INC' );
    like( $ENV{PERL5LIB}, qr/^\Q$app_dir\E(?:\Q$Config::Config{path_sep}\E|$)/, 'runtime preparation prepends library paths to PERL5LIB' );
    Developer::Dashboard::Pax::AppServer::_prepare_runtime({ lib_dirs => [] });
    ok( 1, 'runtime preparation accepts an empty library list' );
}
{
    local @INC = @INC;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    Developer::Dashboard::Pax::AppServer::_prepare_runtime({});
    ok( !defined $ENV{PERL5LIB}, 'runtime preparation leaves PERL5LIB unset without library paths' );
}
{
    local @INC = @INC;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    Developer::Dashboard::Pax::AppServer::_prepare_runtime($image);
    like( $ENV{PERL5LIB}, qr/^\Q$app_dir\E\Q$Config::Config{path_sep}\E/, 'runtime preparation uses the configured path separator and empty environment value' );
}

my $preloaded = Developer::Dashboard::Pax::AppServer::_preload_modules( { %{$image}, preload_modules => [ 'strict', 'Local::PaxAppServerMissing', 'Bad::;Module' ] } );
is_deeply( $preloaded, ['strict'], 'preloader loads valid modules and skips invalid module names' );
is_deeply( Developer::Dashboard::Pax::AppServer::_preload_modules({}), [], 'preloader accepts an empty module list' );
ok( Developer::Dashboard::Pax::AppServer::_in_inc($INC[0]), 'include lookup finds an existing @INC path' );
ok( !Developer::Dashboard::Pax::AppServer::_in_inc(File::Spec->catdir( $root, 'missing' )), 'include lookup rejects an absent @INC path' );

open my $stale, '>', $socket_path or die "cannot create stale socket fixture: $!";
print {$stale} 'stale';
close $stale or die "cannot close stale socket fixture: $!";
my $server = Developer::Dashboard::Pax::AppServer->new( image => $image );
is( $server->start( daemonize => 1 ), 0, 'daemonized server returns success in the parent process' );
my $ready = 0;
for ( 1 .. 100 ) {
    if ( -S $socket_path ) {
        $ready = 1;
        last;
    }
    sleep 0.05;
}
ok( $ready, 'daemonized server replaces the stale path with a UNIX socket' );

if ($ready) {
    my $empty_client = IO::Socket::UNIX->new( Type => SOCK_STREAM, Peer => $socket_path )
      or die "cannot connect empty-client fixture: $!";
    close $empty_client;
    my $output = '';
    {
        local $/;
        my $client = IO::Socket::UNIX->new( Type => SOCK_STREAM, Peer => $socket_path )
          or die "cannot connect malformed-request fixture: $!";
        print {$client} "not-json\n";
        $output = <$client> // '';
        close $client;
    }
    like( $output, qr/image=fixture-image/, 'invalid request JSON falls back to an empty request and runs the entrypoint' );

    my $exit = Developer::Dashboard::Pax::AppServer->run_client(
        image => $image,
        argv => [ 'one', 'two' ],
        cwd => $root,
    );
    is( $exit, 0, 'client returns the server-provided exit code' );

    _write( $entrypoint, 'require Cwd; print "default-cwd=" . Cwd::getcwd();' );
    my $default_cwd_output = '';
    {
        my ( $stdout, undef, $default_exit ) = capture {
            my $status = Developer::Dashboard::Pax::AppServer->run_client( image => $image );
            return $status;
        };
        $default_cwd_output = $stdout;
        is( $default_exit, 0, 'client succeeds with default argv and cwd' );
    }
    like( $default_cwd_output, qr/default-cwd=\Q@{[ Cwd::getcwd() ]}\E/, 'client uses its current directory when cwd is omitted' );

    _write( $entrypoint, 'exit 7;' );
    my ( $nonzero_output, undef, $nonzero_exit ) = capture {
        return Developer::Dashboard::Pax::AppServer->run_client( image => $image );
    };
    is( $nonzero_exit, 7, 'client returns a non-zero application exit code' );

    my $stopped = Developer::Dashboard::Pax::AppServer->stop( image => $image );
    is( $stopped, 0, 'stop sends the server control request' );
    for ( 1 .. 100 ) {
        my $probe = IO::Socket::UNIX->new( Type => SOCK_STREAM, Peer => $socket_path );
        if (!$probe) {
            last;
        }
        close $probe;
        sleep 0.05;
    }
    ok( !-e $socket_path, 'server removes its socket after the stop request' );
}

my $direct_output = '';
{
    _write( $entrypoint, 'require Cwd; print "image=$ENV{PAX_APP_IMAGE};argv=@ARGV;cwd=" . Cwd::getcwd();' );
    my $direct_image = { %{$image}, socket_path => File::Spec->catfile( $root, 'absent.sock' ) };
    my ( $stdout, undef, $exit ) = capture {
        my $status = Developer::Dashboard::Pax::AppServer->run_client(
            image => $direct_image,
            argv => ['direct'],
            cwd => $root,
        );
        return $status;
    };
    $direct_output = $stdout;
    is( $exit, 0, 'client falls back to direct execution when the socket is unavailable' );
}
like( $direct_output, qr/image=fixture-image;argv=direct;cwd=\Q$root\E/, 'direct execution preserves image environment, arguments, and requested working directory' );
my ( $invalid_cwd_output ) = capture {
    Developer::Dashboard::Pax::AppServer->run_client(
        image => { %{$image}, socket_path => File::Spec->catfile( $root, 'absent-again.sock' ) },
        cwd => File::Spec->catdir( $root, 'missing-cwd' ),
    );
    return 1;
};
like( $invalid_cwd_output, qr/cwd=\Q@{[ Cwd::getcwd() ]}\E/, 'direct execution retains its current directory for an invalid requested cwd' );
my ($undefined_cwd_output) = capture {
    Developer::Dashboard::Pax::AppServer::_direct_exec( $image, [], undef );
    return 1;
};
like( $undefined_cwd_output, qr/cwd=\Q@{[ Cwd::getcwd() ]}\E/, 'direct execution accepts an omitted internal cwd' );
_write( $entrypoint, 'exit 6;' );
my ( undef, undef, $direct_nonzero ) = capture {
    return Developer::Dashboard::Pax::AppServer->run_client(
        image => { %{$image}, socket_path => File::Spec->catfile( $root, 'absent-exit.sock' ) },
        cwd => $root,
    );
};
is( $direct_nonzero, 6, 'direct execution returns a non-zero entrypoint status' );

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::AppServer::_fork_process = sub { $! = EAGAIN; return; };
    my $daemon_error = eval { $server->start( daemonize => 1 ); 1 };
    ok( !$daemon_error && $@ =~ /fork failed/, 'daemon startup reports a fork failure' );
}
{
    local $^X = File::Spec->catfile( $root, 'missing-perl-interpreter' );
    my ( undef, $exec_stderr, $exec_exit ) = capture {
        return Developer::Dashboard::Pax::AppServer->run_client(
            image => { %{$image}, socket_path => File::Spec->catfile( $root, 'absent-exec.sock' ) },
        );
    };
    like( $exec_stderr, qr/exec failed: Perl interpreter .* is not executable/, 'direct execution exposes an invalid interpreter path on stderr' );
    is( $exec_exit, 111, 'direct execution returns its documented exec-failure status' );
}

my $error_entrypoint = File::Spec->catfile( $app_dir, 'error.pl' );
_write( $error_entrypoint, 'this is not valid perl !' );
_write( $entrypoint, 'exit 7;' );
my ( $exit_output, undef, $worker_exit ) = capture {
    Developer::Dashboard::Pax::AppServer::_run_request(
        $image,
        *STDOUT,
        { argv => [], cwd => $root },
    );
    return $? >> 8;
};
like( $exit_output, qr/__PAX_EXIT__:7/, 'request worker propagates a non-zero child exit code' );
is( $worker_exit, 0, 'request parent exit status remains unchanged' );
_write( $entrypoint, 'require Cwd; print "fallback-cwd=" . Cwd::getcwd();' );
my ($fallback_cwd_output) = capture {
    Developer::Dashboard::Pax::AppServer::_run_request(
        $image,
        *STDOUT,
        { cwd => File::Spec->catdir( $root, 'missing-cwd' ) },
    );
    return 1;
};
like( $fallback_cwd_output, qr/fallback-cwd=\Q@{[ Cwd::getcwd() ]}\E/, 'request worker retains its current directory when requested cwd is invalid' );
_write( $entrypoint, '0;' );
my ($false_entrypoint_output) = capture {
    Developer::Dashboard::Pax::AppServer::_run_request( $image, *STDOUT, { argv => [], cwd => $root } );
    return 1;
};
like( $false_entrypoint_output, qr/failed to run .*entry\.pl/, 'request worker reports a false entrypoint result without a compilation error' );
my ( $error_output, undef, $request_exit ) = capture {
    Developer::Dashboard::Pax::AppServer::_run_request(
        { %{$image}, entrypoint => $error_entrypoint },
        *STDOUT,
        { argv => [], cwd => $root },
    );
    return $? >> 8;
};
like( $error_output, qr/syntax error/, 'request worker reports a failed entrypoint to its client' );
is( $request_exit, 0, 'request worker leaves parent exit state unchanged' );

my $listen_error = eval {
    Developer::Dashboard::Pax::AppServer->new(
        image => { %{$image}, socket_path => File::Spec->catfile( $root, 'absent-dir', 'server.sock' ) },
    )->start;
    1;
};
ok( !$listen_error && $@ =~ /cannot listen/, 'foreground server reports a socket bind failure' );

is( Developer::Dashboard::Pax::AppServer::_exit_code(-1), 111, 'process wait failure maps to the server error status' );
is( Developer::Dashboard::Pax::AppServer::_exit_code( 7 << 8 ), 7, 'process wait status maps to its child exit code' );
{
    open my $closed, '>', File::Spec->devnull() or die "cannot open closed-handle fixture: $!";
    close $closed or die "cannot close handle fixture: $!";
    my @warnings;
    my $read_ok;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $read_ok = eval { Developer::Dashboard::Pax::AppServer::_read_output_chunk($closed); 1 };
    }
    ok( !$read_ok && $@ =~ /cannot read app-image output/, 'output reader reports a stream read failure' );
    like( join( '', @warnings ), qr/closed filehandle/, 'stream read warning remains observable to the caller' );
}
{
    open my $closed, '>', File::Spec->devnull() or die "cannot open closed-client fixture: $!";
    close $closed or die "cannot close client fixture: $!";
    my @warnings;
    my $write_ok;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $write_ok = eval { Developer::Dashboard::Pax::AppServer::_forward_output( $closed, 'payload' ); 1 };
    }
    ok( !$write_ok && $@ =~ /cannot forward app-image output/, 'output forwarder reports a disconnected client' );
    like( join( '', @warnings ), qr/closed filehandle/, 'client write warning remains observable to the caller' );
}

for my $signal (qw(TERM INT)) {
    my $signal_socket = File::Spec->catfile( $root, "signal-$signal.sock" );
    my $signal_server = Developer::Dashboard::Pax::AppServer->new( image => { %{$image}, socket_path => $signal_socket } );
    my $pid = fork();
    die "cannot fork signal fixture: $!" if !defined $pid;
    if ( !$pid ) {
        $signal_server->start;
        POSIX::_exit(0);
    }
    my $signal_ready = 0;
    for ( 1 .. 100 ) {
        if ( -S $signal_socket ) {
            $signal_ready = 1;
            last;
        }
        sleep 0.05;
    }
    ok( $signal_ready, "foreground server starts for $signal handling" );
    if ($signal_ready) {
        kill $signal, $pid;
        waitpid( $pid, 0 );
        is( $? >> 8, 0, "SIG$signal shuts down the foreground server cleanly" );
        ok( !-e $signal_socket, "SIG$signal removes the foreground socket" );
    }
    else {
        kill 'KILL', $pid;
        waitpid( $pid, 0 );
        fail( "SIG$signal fixture could not start" );
    }
}

done_testing();

sub _write {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content or die "cannot write $path: $!";
    close $fh or die "cannot close $path: $!";
    return;
}

__END__

=pod

=head1 NAME

t/234-pax-appserver-coverage.t - PAX application-image server regression tests

=head1 PURPOSE

This file verifies AppServer client, daemon, request-worker, and direct-execution
behavior using temporary local fixtures. No network service or third-party
application is required.

=head1 WHY IT EXISTS

AppServer crosses process and filesystem boundaries while serving a packaged
application. Its socket protocol, fallback execution, and cleanup behavior must
remain verifiable independently of the broader standalone-image build tests.

=head1 WHEN TO USE

Run this test when changing C<Developer::Dashboard::Pax::AppServer>, its socket
protocol, child lifecycle, runtime preparation, or preload behavior. Extend the
fixture assertions to represent each new request or failure contract.

=head1 HOW TO USE

Run from the repository root inside the project's development container. The
test creates and removes a temporary app tree, launches a daemon child, sends
local UNIX-socket requests, and verifies that the child cleans up its socket.

=head1 WHAT USES IT

The PAX launcher and application-image runtime use AppServer to dispatch local
requests and execute application entrypoints. The canonical unit and coverage
gates run this test to protect those runtime paths.

=head1 EXAMPLES

Run the focused test:

  prove -lv t/234-pax-appserver-coverage.t

Collect focused coverage for the server module:

  perl -MDevel::Cover=-db,/tmp/pax-appserver-cover,-blib,0 t/234-pax-appserver-coverage.t
  cover /tmp/pax-appserver-cover -report text -select_re '^lib/Developer/Dashboard/Pax/AppServer.pm$'

=cut
