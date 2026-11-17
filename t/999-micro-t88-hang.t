# t/999-micro-t88-hang.t — MICRO v17: PROVE THE FIX in the micro first.
# Full t/88 lines 1-341 + lines 538-571 + the FIXED logic of
# _handle_ssl_frontend_client (Server.pm:455-467) replicated with logs:
# probe the client with getsockopt (SOL_SOCKET/SO_TYPE) before the
# readiness wait; a non-socket skips the wait and goes straight to the
# recv peek; a real socket waits as before (bounded to 5 here so this
# micro cannot hang). Plus a socketpair control + done_testing().
# Scratch only, do not merge, do not ship.
#
# Micro v16 CONFIRMED the root cause: on Windows can_read on a devnull
# handle returns false 5 times in a row (never true), while on Unix it
# returns true at iteration 1, and the socketpair control returns true
# on all four legs. The recv peek fails with ENOTSOCK on all four legs.
# v17 proves the fix logic: getsockopt must say undef for the devnull
# handle and defined for a real socket, on all four legs, and the fixed
# path must return 1 for the non-socket client. If v17 passes, the fix
# goes into Server.pm on the loop branch and the real t/88 solo verifies
# it there.
#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

# Keep signal forwarding injectable for unit coverage without creating a
# process in the test harness.
our $KILL_OVERRIDE;

BEGIN {
    *CORE::GLOBAL::kill = sub {
        return $main::KILL_OVERRIDE->(@_) if $main::KILL_OVERRIDE;
        return CORE::kill(@_);
    };
}

use Capture::Tiny qw(capture);
use Errno qw(EBADF EINTR);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use IO::Select;
use IO::Socket::INET;
use Socket qw(AF_UNIX PF_UNSPEC SOCK_STREAM SOL_SOCKET SO_LINGER);
use Symbol qw(gensym);
use Test::More;

use lib 'lib';

use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::Web::Server;
use Developer::Dashboard::Web::Server::Daemon;

use Socket qw(MSG_PEEK SO_TYPE);  # micro-only: the head imports Socket without MSG_PEEK/SO_TYPE
sub _log { warn "MICRO17: $_[0]\n"; }
sub _net {
    my ($label) = @_;
    return unless $^O eq 'MSWin32';
    my $n = `netstat -ano | findstr "$$"`;
    warn "MICRO17 net after $label pid $$:\n$n\n";
}
_log("use block + definitions compiled, pid $$");
_net("compile");

# Hermetic runtime: every layer lookup resolves from this temp home and cwd.
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";

my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
_log("before ok 1"); _net("before ok 1");
ok( $paths->home_runtime_path, 'hermetic path registry resolves a home runtime path' );
_log("after ok 1"); _net("after ok 1");

{
    package Local::StubApp;

    sub new { return bless {}, shift }

    sub authorize_request { return }
}

# A stub listen socket whose close() succeeds or fails on demand. The failing
# variant is a read pipe from a child that exits non-zero, which is a real
# close failure rather than a faked return value. The child is the running
# perl ($^X), not sh, so the fixture works on Windows where no sh exists.
{
    package Local::StubSocket;

    our $HOST = '127.0.0.1';
    our $PORT = 17901;

    sub new {
        my ( $class, %args ) = @_;
        my $fh;
        if ( $args{closeable} ) {
            open $fh, '<', File::Spec->devnull
              or die "Unable to open closeable stub socket fixture: $!";
        }
        else {
            open $fh, '-|', $^X, '-e', 'exit 3'
              or die "Unable to open uncloseable stub socket fixture: $!";
        }
        return bless $fh, $class;
    }

    sub sockhost { return $HOST }

    sub sockport { return $PORT }
}

{
    package Local::EmptyDaemon;

    # sockhost()
    # Models a daemon descriptor without a reported host.
    # Input: daemon fixture object.
    # Output: undef.
    sub sockhost { return }

    # sockport()
    # Models a daemon descriptor without a reported port.
    # Input: daemon fixture object.
    # Output: undef.
    sub sockport { return }
}

# A frontend listener whose accept() replays a scripted sequence of results.
{
    package Local::ScriptedListener;

    our @ACCEPTS;
    our $FAIL_CLOSE = 0;

    sub new {
        my ($class) = @_;
        my $fh;
        # $^X, not sh: same Windows-safe failing child as Local::StubSocket.
        if ($FAIL_CLOSE) {
            open $fh, '-|', $^X, '-e', 'exit 3'
              or die "Unable to open failing scripted listener fixture: $!";
        }
        else {
            open $fh, '<', File::Spec->devnull
              or die "Unable to open scripted listener fixture: $!";
        }
        return bless $fh, $class;
    }

    sub accept {
        my $next = shift @ACCEPTS;
        return $next->() if $next;
        $! = 0;
        return;
    }
}

# Tied handles that fail at print time / at close time without leaving a
# half-open filehandle behind for the interpreter to complain about.
{
    package Local::FailingPrintHandle;

    sub TIEHANDLE { return bless {}, shift }

    sub PRINT { return 0 }

    sub CLOSE { return 1 }
}

{
    package Local::FailingCloseHandle;

    sub TIEHANDLE { return bless {}, shift }

    sub PRINT { return 1 }

    sub CLOSE { return 0 }
}

{
    package Local::WorkingHandle;

    sub TIEHANDLE { return bless {}, shift }

    sub PRINT { return 1 }

    sub CLOSE { return 1 }
}

{
    package Local::Runner;

    sub new { return bless { parsed => undef, ran => undef }, shift }

    sub parse_options {
        my ( $self, @options ) = @_;
        $self->{parsed} = \@options;
        return 1;
    }

    sub run {
        my ( $self, $app ) = @_;
        $self->{ran} = $app;
        return 1;
    }
}

# _tied_handle($package)
# Builds an anonymous filehandle backed by one of the tied fixtures above.
sub _tied_handle {
    my ($package) = @_;
    my $fh = gensym();
    tie *{$fh}, $package;
    return $fh;
}

# _write_file($path, $text)
# Writes one fixture file, dying loudly on any failure.
sub _write_file {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $text or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    return 1;
}

# _reset_client_socket()
# Returns a connected loopback client socket whose peer has already sent a TCP
# RST, so the next sysread on it fails with ECONNRESET instead of reading EOF.
sub _reset_client_socket {
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        ReuseAddr => 1,
        Listen    => 5,
    ) or die "Unable to reserve reset-fixture listener: $!";
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $listener->sockport,
        Proto    => 'tcp',
    ) or die "Unable to connect reset-fixture client: $!";
    my $accepted = $listener->accept
      or die "Unable to accept reset-fixture connection: $!";
    setsockopt( $accepted, SOL_SOCKET, SO_LINGER, pack( 'II', 1, 0 ) )
      or die "Unable to force reset-fixture linger: $!";
    close $accepted or die "Unable to reset the fixture peer socket: $!";
    return ( $client, $listener );
}

# _redirect_server(@extra_subject_alt_names)
# Returns a bare Web::Server instance carrying only the fields the redirect
# helpers read, so the authority allowlist can be driven without generating a
# certificate or binding a socket.
sub _redirect_server {
    my (@extra_subject_alt_names) = @_;
    return bless {
        host                  => '0.0.0.0',
        port                  => 7890,
        workers               => 1,
        ssl                   => 1,
        ssl_subject_alt_names => \@extra_subject_alt_names,
    }, 'Developer::Dashboard::Web::Server';
}

# _profile_fixture_cert($cert_file, $key_file, $extensions)
# Generates a self-signed certificate carrying only the requested v3
# extensions, so the profile checker can be driven down each rejection arm.
sub _profile_fixture_cert {
    my ( $cert_file, $key_file, $extensions ) = @_;
    my ( $config_fh, $config_file ) =
      tempfile( 'dd-profile-XXXXXX', SUFFIX => '.cnf', TMPDIR => 1 );
    print {$config_fh} <<"OPENSSL_CONFIG" or die "Unable to write profile fixture config $config_file: $!";
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = fixture_req

[ dn ]
C = US
ST = Local
L = Local
O = Developer Dashboard
CN = localhost

[ fixture_req ]
$extensions
OPENSSL_CONFIG
    close $config_fh or die "Unable to close profile fixture config $config_file: $!";
    my ( $stdout, $stderr, $exit ) = capture {
        system(
            'openssl', 'req', '-new', '-x509', '-days', '365', '-nodes',
            '-config', $config_file,
            '-out',    $cert_file,
            '-keyout', $key_file,
        );
    };
    unlink $config_file or die "Unable to remove profile fixture config $config_file: $!";
    die "Unable to generate profile fixture certificate: $stderr$stdout" if $exit != 0;
    return $cert_file;
}

my $app = Local::StubApp->new;

{
    my $missing = eval { Developer::Dashboard::Web::Server->new(); 1 };
    ok( !$missing, 'server constructor requires an app object' );
    like( $@, qr/Missing web app/, 'server constructor names a missing app object' );

    my $defaults = Developer::Dashboard::Web::Server->new(
        app                   => $app,
        ssl_subject_alt_names => 'not-an-array',
    );
    is( $defaults->{host}, '0.0.0.0', 'server constructor defaults the bind host' );
    is( $defaults->{port}, 7890, 'server constructor defaults the listen port' );
    is( $defaults->{workers}, 1, 'server constructor defaults to one worker' );
    is( $defaults->{ssl}, 0, 'server constructor disables SSL by default' );
    is_deeply( $defaults->{ssl_subject_alt_names}, [], 'server constructor ignores a non-array SAN option' );
    my $with_san = Developer::Dashboard::Web::Server->new(
        app                   => $app,
        ssl_subject_alt_names => ['dashboard.example.test'],
    );
    is_deeply( $with_san->{ssl_subject_alt_names}, ['dashboard.example.test'],
        'server constructor copies an array of configured subject alternative names' );
    is(
        $defaults->listening_url( bless( {}, 'Local::EmptyDaemon' ) ),
        'http://localhost:7890/',
        'listening_url supplies host and port defaults when the daemon omits both',
    );
    is(
        $defaults->listening_url( Developer::Dashboard::Web::Server::Daemon->new( host => 'dashboard.local', port => 8123 ) ),
        'http://dashboard.local:8123/',
        'listening_url preserves host and port reported by the daemon',
    );

    my $running = bless {}, 'Developer::Dashboard::Web::Server';
    my $run_daemon = bless {}, 'Local::RunDaemon';
    my ( $served_daemon, $run_result );
    local *Developer::Dashboard::Web::Server::start_daemon = sub { return $run_daemon };
    local *Developer::Dashboard::Web::Server::listening_url = sub { return 'http://fixture:7890/' };
    local *Developer::Dashboard::Web::Server::serve_daemon = sub { $served_daemon = $_[1]; return 1 };
    my ( $stdout, $stderr ) = capture { $run_result = $running->run };
    is( $run_result, 1, 'run returns the daemon loop result' );
    is( $stdout, "Developer Dashboard listening on http://fixture:7890/\n", 'run prints the resolved server URL' );
    is( $stderr, '', 'run reports no stderr output on a successful daemon loop' );
    is( $served_daemon, $run_daemon, 'run passes its started daemon descriptor to the server loop' );
}

# One shared SSL-enabled server. Building it also exercises the real
# certificate generation path once, which is reused by the SSL frontend tests.
my $ssl_home = tempdir( CLEANUP => 1 );
my $ssl_server = do {
    local $ENV{HOME} = $ssl_home;
    Developer::Dashboard::Web::Server->new(
        app     => $app,
        host    => '127.0.0.1',
        port    => 17902,
        workers => 1,
        ssl     => 1,
    );
};
isa_ok( $ssl_server, 'Developer::Dashboard::Web::Server' );

my $ssl_daemon = Developer::Dashboard::Web::Server::Daemon->new(
    host          => '127.0.0.1',
    port          => 17902,
    internal_host => '127.0.0.1',
    internal_port => 17903,
);

# is_running()
# Reports that the synchronously completed test routine is no longer active.
# Input: routine fixture object.
# Output: false value.
sub Local::CompletedRoutine::is_running { return 0 }

# kill()
# Satisfies the routine lifecycle interface if cleanup attempts cancellation.
# Input: routine fixture object.
# Output: true value.
sub Local::CompletedRoutine::kill { return 1 }

{
    package Local::DelayedRoutine;

    # new()
    # Creates a routine fixture that stays active long enough for one shutdown poll.
    # Input: none.
    # Output: routine fixture with poll and kill counters.
    sub new { return bless { checks => 0, killed => 0 }, shift }

    # is_running()
    # Reports active twice, then reports completion.
    # Input: routine fixture object.
    # Output: true for its first two polls, false after that.
    sub is_running { return ++$_[0]->{checks} <= 2 }

    # kill()
    # Records that the frontend requested routine cancellation.
    # Input: routine fixture object.
    # Output: true value.
    sub kill { $_[0]->{killed}++; return 1 }
}


{
    # v17: prove the FIX in the micro first. Fixed logic: probe the client
    # with getsockopt (SOL_SOCKET/SO_TYPE) before the readiness wait. A
    # non-socket skips the wait and goes straight to the recv peek, which
    # fails with ENOTSOCK and returns 1, as the test expects. A real
    # socket waits as before. The wait here stays bounded to 5 iterations
    # so this micro cannot hang.
    _log("17: before open devnull");
    open my $not_a_socket, '<', File::Spec->devnull
      or die "Unable to open non-socket client fixture: $!";
    _log("17: after open devnull fileno=" . fileno($not_a_socket));

    _log("17: before getsockopt probe on devnull");
    my $socktype = getsockopt( $not_a_socket, SOL_SOCKET, SO_TYPE );
    _log("17: getsockopt on devnull returned " . (defined $socktype ? "defined" : "undef") . " errno=$!");

    my $client_select = IO::Select->new($not_a_socket);
    my $iter  = 0;
    my $ready;
    if ( defined $socktype ) {
        _log("17: socket, entering readiness wait");
        while (1) {
            $iter++;
            $ready = $client_select->can_read(0.25);
            _log("17: can_read iter $iter returned " . ($ready ? "TRUE" : "false"));
            last if $ready;
            if ($iter >= 5) {
                _log("17: bounded wait hit 5, giving up");
                last;
            }
        }
    }
    else {
        _log("17: not a socket, skipping readiness wait");
    }

    _log("17: before recv peek on devnull");
    my $first  = '';
    my $peeked = recv( $not_a_socket, $first, 1, MSG_PEEK );
    _log("17: after recv peek peeked=" . (defined $peeked ? $peeked : "undef")
        . " first=" . (defined $first && $first ne '' ? "defined-nonempty" : "empty")
        . " errno=$!");
    my $fixed_result = ( !defined $peeked || $first eq '' ) ? 1 : 0;
    _log("17: fixed path would return $fixed_result (test expects 1)");

    # Control: a REAL socket — probe defined, wait exits, peek returns the byte.
    _log("17: before socketpair control");
    socketpair( my $ctl_a, my $ctl_b, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
      or die "socketpair control: $!";
    syswrite( $ctl_b, "x" ) or die "socketpair write: $!";
    my $ctl_type = getsockopt( $ctl_a, SOL_SOCKET, SO_TYPE );
    _log("17: getsockopt on socketpair returned " . (defined $ctl_type ? "defined" : "undef") . " errno=$!");
    my $ctl_select = IO::Select->new($ctl_a);
    my $ctl_ready  = $ctl_select->can_read(0.25);
    _log("17: socketpair control can_read returned " . ($ctl_ready ? "TRUE" : "false"));
    my $ctl_first  = '';
    my $ctl_peeked = recv( $ctl_a, $ctl_first, 1, MSG_PEEK );
    _log("17: socketpair recv peek peeked=" . (defined $ctl_peeked ? $ctl_peeked : "undef")
        . " first=" . (defined $ctl_first ? "'$ctl_first'" : "undef"));

    close $not_a_socket;

    ok( !defined $socktype, 'getsockopt probe says the devnull handle is not a socket' );
    ok( $fixed_result == 1, 'fixed path returns 1 for a non-socket client' );
    ok( defined $ctl_type, 'getsockopt probe says a real socket is a socket' );
    ok( $ctl_ready, 'can_read on a real socket with data reports readable' );
    ok( defined $ctl_peeked && $ctl_first eq 'x', 'recv peek on a real socket returns the first byte' );
    _log("17: done");
}

done_testing();
# Compile marker: this BEGIN runs at compile time, after every line above has
# been compiled. If it prints, compilation finished and the hang is runtime.
# If it does NOT print, the hang is during compile (or Perl startup).
BEGIN { warn "MICRO17: compile finished pid $$\n"; }
