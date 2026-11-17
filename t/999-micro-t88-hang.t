# t/999-micro-t88-hang.t — MICRO v6: BISECTION, first half of v5's range.
# Full t/88 lines 1-763 (head + test 1 + all fixture definitions + the test
# blocks from line 276 through the block starting at 708) + done_testing().
# Scratch only, do not merge, do not ship.
#
# Micro v5 REPRODUCED the hang on Windows: the trigger is in the test blocks
# in lines 276-1190 (tests 2-137), after ok 1. v6 bisects that range: first
# half (276-763). If v6 hangs, the trigger is in this half. If v6 passes, v7
# takes the second half (lines 764-1190).
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

sub _log { warn "MICRO6: $_[0]\n"; }
sub _net {
    my ($label) = @_;
    my $n = `netstat -ano | findstr "$$"`;
    warn "MICRO6 net after $label pid $$:\n$n\n";
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

{
    local @Local::ScriptedListener::ACCEPTS = ();
    local $Local::ScriptedListener::FAIL_CLOSE = 1;
    my @stopped;
    no warnings 'redefine';
    local *Developer::Dashboard::Web::Server::_ssl_backend_command = sub { return [ $^X, '-e', 'exit 0' ] };
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 991004 };
    local *IO::Socket::INET::new = sub { return Local::ScriptedListener->new };
    local *Developer::Dashboard::Web::Server::_stop_ssl_backend = sub { push @stopped, $_[0]; return 1 };
    local *Developer::Dashboard::Web::Server::_wait_for_ssl_backend_ready = sub { return 1 };

    my $ok = eval { $ssl_server->_serve_ssl_frontend($ssl_daemon); 1 };
    ok( !$ok, 'SSL frontend reports a listener close failure' );
    like( $@, qr/Unable to close SSL frontend listener/, 'listener close failure is explicit' );
    is_deeply( \@stopped, [991004], 'SSL backend is stopped after listener close failure' );
}

{
    my $closeable = Local::StubSocket->new( closeable => 1 );
    ok( $ssl_server->_close_ssl_frontend_handle($closeable), 'SSL handle close helper returns a successful close' );
    my $uncloseable = Local::StubSocket->new( closeable => 0 );
    ok( !$ssl_server->_close_ssl_frontend_handle($uncloseable), 'SSL handle close helper returns a real close failure' );
}

{
    my $client = Local::StubSocket->new( closeable => 0 );
    local @Local::ScriptedListener::ACCEPTS = (
        sub { return $client },
        sub { $Developer::Dashboard::Web::Server::SSL_SHUTDOWN_REQUESTED = 1; return },
    );
    local $Local::ScriptedListener::FAIL_CLOSE = 1;
    my @stopped;
    no warnings 'redefine';
    local *Developer::Dashboard::Web::Server::_ssl_backend_command = sub { return [ $^X, '-e', 'exit 0' ] };
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 991005 };
    local *Developer::Dashboard::GoRoutine::go = sub { return Local::DelayedRoutine->new };
    local *IO::Socket::INET::new = sub { return Local::ScriptedListener->new };
    my $close_calls = 0;
    local *Developer::Dashboard::Web::Server::_close_ssl_frontend_handle = sub {
        my ( $self, $handle ) = @_;
        if ( !$close_calls++ ) {
            $! = EBADF;
            return;
        }
        return close $handle;
    };
    local *Developer::Dashboard::Web::Server::_stop_ssl_backend = sub { push @stopped, $_[0]; return 1 };
    local *Developer::Dashboard::Web::Server::_wait_for_ssl_backend_ready = sub { return 1 };

    my $ok = eval { $ssl_server->_serve_ssl_frontend($ssl_daemon); 1 };
    ok( !$ok, 'SSL frontend reports a client release close failure' );
    like( $@, qr/Unable to release SSL frontend client/, 'client release close failure is explicit' );
    is_deeply( \@stopped, [991005], 'SSL backend is stopped after client release close failure' );
}

{
    socketpair( my $client, my $client_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
      or die "Unable to build failing worker-close fixture: $!";
    local @Local::ScriptedListener::ACCEPTS = (
        sub { return $client },
        sub { $Developer::Dashboard::Web::Server::SSL_SHUTDOWN_REQUESTED = 1; return },
    );
    my @stopped;
    no warnings 'redefine';
    local *Developer::Dashboard::Web::Server::_ssl_backend_command = sub { return [ $^X, '-e', 'exit 0' ] };
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 991006 };
    local *Developer::Dashboard::GoRoutine::go = sub {
        my ($callback) = @_;
        $callback->();
        return bless {}, 'Local::CompletedRoutine';
    };
    local *IO::Socket::INET::new = sub { return Local::ScriptedListener->new };
    local *Developer::Dashboard::Web::Server::_handle_ssl_frontend_client = sub { return 1 };
    my $close_calls = 0;
    local *Developer::Dashboard::Web::Server::_close_ssl_frontend_handle = sub {
        my ( $self, $handle ) = @_;
        if ( !$close_calls++ ) {
            $! = EBADF;
            return;
        }
        return close $handle;
    };
    local *Developer::Dashboard::Web::Server::_stop_ssl_backend = sub { push @stopped, $_[0]; return 1 };
    local *Developer::Dashboard::Web::Server::_wait_for_ssl_backend_ready = sub { return 1 };

    my $ok = eval { $ssl_server->_serve_ssl_frontend($ssl_daemon); 1 };
    ok( !$ok, 'SSL frontend reports a client worker close failure' );
    like( $@, qr/Unable to close SSL frontend client/, 'client worker close failure is explicit' );
    is_deeply( \@stopped, [991006], 'SSL backend is stopped after client worker close failure' );
    close $client_peer or die "Unable to close worker-close fixture peer: $!";
}

# Backend readiness is validated without opening a socket or starting a child.
{
    no warnings qw(redefine once);
    local %Developer::Dashboard::Web::Server::SSL_BACKEND_REAPED;
    local *Developer::Dashboard::GoRoutine::process_exited = sub { return 1 };
    local *Developer::Dashboard::GoRoutine::wait_process = sub { return 23 };
    my $ok = eval { $ssl_server->_wait_for_ssl_backend_ready( $ssl_daemon, 93001 ); 1 };
    ok( !$ok, 'SSL readiness fails when the managed backend exits before listening' );
    like( $@, qr/exited before becoming ready \(status 23\)/, 'early backend exit reports its process status' );
    ok( $Developer::Dashboard::Web::Server::SSL_BACKEND_REAPED{93001}, 'early backend exit is recorded as reaped' );

    {
        local %Developer::Dashboard::Web::Server::SSL_BACKEND_REAPED;
        local *Developer::Dashboard::GoRoutine::process_running = sub { die 'readiness must detect an exited, unreaped child' };
        local *Developer::Dashboard::GoRoutine::process_exited = sub { return 1 };
        local *Developer::Dashboard::GoRoutine::wait_process = sub { return 24 };
        my $exited_ok = eval { $ssl_server->_wait_for_ssl_backend_ready( $ssl_daemon, 93005 ); 1 };
        ok( !$exited_ok, 'SSL readiness detects an exited but unreaped backend process' );
        like( $@, qr/exited before becoming ready \(status 24\)/, 'unreaped backend failure reports its exit status immediately' );
        ok( $Developer::Dashboard::Web::Server::SSL_BACKEND_REAPED{93005}, 'unreaped backend is marked reaped after collecting its status' );
    }

    local *Developer::Dashboard::GoRoutine::process_exited = sub { return 0 };
    local *IO::Socket::SSL::new = sub {
        open my $backend, '<', File::Spec->devnull
          or die "Unable to create the SSL readiness socket fixture: $!";
        return $backend;
    };
    is( $ssl_server->_wait_for_ssl_backend_ready( $ssl_daemon, 93002 ), 1,
        'SSL readiness succeeds after a loopback TLS handshake' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::process_exited = sub { return 0 };
    local *IO::Socket::SSL::new = sub { return _tied_handle('Local::FailingCloseHandle') };
    my $ok = eval { $ssl_server->_wait_for_ssl_backend_ready( $ssl_daemon, 93003 ); 1 };
    ok( !$ok, 'SSL readiness reports a backend probe socket close failure' );
    like( $@, qr/Unable to close SSL backend readiness probe/, 'probe close failure remains explicit' );
}

{
    my ( $clock, $probe_count, @stopped ) = ( 0, 0 );
    no warnings 'redefine';
    local *Developer::Dashboard::Web::Server::time = sub { $clock += 20; return $clock };
    local *Developer::Dashboard::Web::Server::sleep = sub { return 1 };
    local *Developer::Dashboard::GoRoutine::process_exited = sub { return 0 };
    local *IO::Socket::SSL::new = sub { $probe_count++; return };
    local *Developer::Dashboard::Web::Server::_stop_ssl_backend = sub {
        push @stopped, $_[0];
        return 1;
    };
    my $ok = eval { $ssl_server->_wait_for_ssl_backend_ready( $ssl_daemon, 93004 ); 1 };
    ok( !$ok, 'SSL readiness fails after the backend startup deadline' );
    like( $@, qr/Timed out waiting for SSL backend listener readiness/, 'backend timeout reports its exact failure' );
    is( $probe_count, 2, 'backend readiness probes are retried until the deadline' );
    is_deeply( \@stopped, [93004], 'backend timeout terminates the managed backend' );
}

# The helper-command contract rejects an absent staged helper and malformed
# command-builder results rather than silently falling back to another path.
{
    local $ENV{DEVELOPER_DASHBOARD_RUNNING_HELPER};
    delete $ENV{DEVELOPER_DASHBOARD_RUNNING_HELPER};
    my $ok = eval { $ssl_server->_ssl_backend_command($ssl_daemon); 1 };
    ok( !$ok, 'SSL backend command refuses to run without the staged helper' );
    like( $@, qr/Missing private Dashboard helper/, 'missing SSL helper has an explicit diagnostic' );

    local $ENV{DEVELOPER_DASHBOARD_RUNNING_HELPER} = '';
    $ok = eval { $ssl_server->_ssl_backend_command($ssl_daemon); 1 };
    ok( !$ok, 'SSL backend command refuses an empty staged helper path' );
    like( $@, qr/Missing private Dashboard helper/, 'empty SSL helper has an explicit diagnostic' );

    for my $bad_command ( 'not an argv array', [] ) {
        local $ssl_server->{ssl_backend_command_builder} = sub { return $bad_command };
        $ok = eval { $ssl_server->_ssl_backend_command($ssl_daemon); 1 };
        ok( !$ok, 'SSL backend command rejects a malformed builder result' );
        like( $@, qr/command builder must return an argv array reference/, 'invalid builder result has an explicit diagnostic' );
    }
}

{
    local $ssl_server->{ssl_backend_command_builder} = sub {
        my ( $host, $port, $workers ) = @_;
        return [ $^X, '-e', 'exit 0', $host, $port, $workers ];
    };
    is_deeply(
        $ssl_server->_ssl_backend_command($ssl_daemon),
        [ $^X, '-e', 'exit 0', '127.0.0.1', 17903, 1 ],
        'SSL backend command accepts a valid custom argv builder result',
    );
}

{
    local $ENV{DEVELOPER_DASHBOARD_RUNNING_HELPER} = '/private/cli/serve';
    local $ssl_server->{ssl_backend_command_builder};
    is_deeply(
        $ssl_server->_ssl_backend_command($ssl_daemon),
        [ $^X, File::Spec->catfile( '/private/cli', '_dashboard-core' ), 'web-ssl-backend-foreground', '--host', '127.0.0.1',
          '--port', 17903, '--workers', 1 ],
        'SSL backend command resolves the core dispatcher beside the running command wrapper',
    );
}

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

# --- new(): worker count validation -----------------------------------------
{
    my $blank = eval {
        Developer::Dashboard::Web::Server->new( app => $app, workers => '' );
        1;
    };
    ok( !$blank, 'constructor rejects an empty worker count' );
    like( $@, qr/Missing worker count/, 'constructor names the missing worker count explicitly' );

    my $word = eval {
        Developer::Dashboard::Web::Server->new( app => $app, workers => 'two' );
        1;
    };
    ok( !$word, 'constructor rejects a non-numeric worker count' );
    like(
        $@,
        qr/Worker count must be a positive integer/,
        'constructor reports non-numeric worker counts as invalid integers',
    );

    my $zero = eval {
        Developer::Dashboard::Web::Server->new( app => $app, workers => 0 );
        1;
    };
    ok( !$zero, 'constructor rejects a zero worker count' );
    like(
        $@,
        qr/Worker count must be a positive integer/,
        'constructor reports a numeric-but-too-small worker count as invalid',
    );
}

# --- start_daemon(): socket reservation and close failures ------------------
{
    my $server = Developer::Dashboard::Web::Server->new( app => $app );
    no warnings 'redefine';
    local *IO::Socket::INET::new = sub { return };
    my $ok = eval { $server->start_daemon; 1 };
    ok( !$ok, 'start_daemon fails when the requested listen address cannot be opened' );
    like( $@, qr/Unable to start server on 0[.]0[.]0[.]0:7890/, 'listen bind failure reports its host and port' );
}

{
    my $server = Developer::Dashboard::Web::Server->new( app => $app );
    no warnings 'redefine';
    local *IO::Socket::INET::new = sub { return Local::StubSocket->new( closeable => 1 ) };
    my $daemon = $server->start_daemon;
    isa_ok( $daemon, 'Developer::Dashboard::Web::Server::Daemon', 'non-SSL start_daemon returns its daemon descriptor' );
    is( $daemon->sockhost, '127.0.0.1', 'non-SSL daemon preserves the reserved host' );
    is( $daemon->sockport, 17901, 'non-SSL daemon preserves the reserved port' );
}

{
    my $server = Developer::Dashboard::Web::Server->new(
        app     => $app,
        host    => '127.0.0.1',
        port    => 17901,
        workers => 1,
    );

    no warnings 'redefine';
    local *IO::Socket::INET::new = sub { return Local::StubSocket->new( closeable => 0 ) };
    my $ok = eval { $server->start_daemon; 1 };
    ok( !$ok, 'start_daemon fails when the reserved listen socket cannot be closed' );
    like(
        $@,
        qr/Unable to close reserved listen socket/,
        'start_daemon reports a failed listen-socket close explicitly',
    );
}

{
    no warnings 'redefine';
    local *IO::Socket::INET::new = sub {
        my ( $class, %args ) = @_;
        return Local::StubSocket->new( closeable => 1 ) if $args{LocalPort};
        return;
    };
    my $ok = eval { $ssl_server->start_daemon; 1 };
    ok( !$ok, 'start_daemon fails when the internal SSL backend port cannot be reserved' );
    like(
        $@,
        qr/Unable to reserve internal SSL backend port/,
        'start_daemon reports a failed internal SSL backend reservation explicitly',
    );
}

{
    no warnings 'redefine';
    local *IO::Socket::INET::new = sub {
        my ( $class, %args ) = @_;
        return Local::StubSocket->new( closeable => 1 ) if $args{LocalPort};
        return Local::StubSocket->new( closeable => 0 );
    };
    my $ok = eval { $ssl_server->start_daemon; 1 };
    ok( !$ok, 'start_daemon fails when the reserved internal SSL backend socket cannot be closed' );
    like(
        $@,
        qr/Unable to close reserved internal SSL backend socket/,
        'start_daemon reports a failed internal SSL backend close explicitly',
    );
}

{
    my @sockets = (
        Local::StubSocket->new( closeable => 1 ),
        Local::StubSocket->new( closeable => 1 ),
    );
    no warnings 'redefine';
    local *IO::Socket::INET::new = sub { return shift @sockets };
    my $daemon = $ssl_server->start_daemon;
    is( $daemon->sockhost, '127.0.0.1', 'SSL daemon retains the public address after successful reservations' );
    is( $daemon->internal_sockhost, '127.0.0.1', 'SSL daemon retains the internal backend address' );
    is( $daemon->internal_sockport, 17901, 'SSL daemon retains the internal backend port after closing its reservation' );
}

# --- listening_url(): missing daemon ----------------------------------------
{
    my $url = $ssl_server->listening_url(undef);
    is( $url, undef, 'listening_url returns nothing when no daemon descriptor is available' );
}

# --- _serve_ssl_frontend(): managed backend and routine lifecycle ------------
{
    no warnings 'redefine';
    local *Developer::Dashboard::Web::Server::_ssl_backend_command = sub { return [ $^X, '-e', 'exit 0' ] };
    local *Developer::Dashboard::GoRoutine::spawn = sub { die "simulated backend process launch failure\n" };
    my $ok = eval { $ssl_server->_serve_ssl_frontend($ssl_daemon); 1 };
    ok( !$ok, 'SSL frontend fails when the backend process cannot be spawned' );
    like(
        $@,
        qr/simulated backend process launch failure/,
        'SSL frontend propagates the GoRoutine process launch error',
    );
}

{
    socketpair( my $client, my $client_peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
      or die "Unable to build frontend client fixture: $!";

    local @Local::ScriptedListener::ACCEPTS = (
        sub {
            $! = EINTR;
            return undef;
        },
        sub {
            $Developer::Dashboard::Web::Server::SSL_SHUTDOWN_REQUESTED = 1;
            return $client;
        },
    );

    my @spawned;
    my ( $handled, @routines ) = (0);
    local *Developer::Dashboard::Web::Server::_ssl_backend_command = sub { return [ $^X, '-e', 'exit 0' ] };
    local *Developer::Dashboard::GoRoutine::spawn = sub {
        @spawned = @_;
        return 991001;
    };

    my @stopped;
    no warnings 'redefine';
    local *IO::Socket::INET::new = sub { return Local::ScriptedListener->new };
    local *Developer::Dashboard::GoRoutine::go = sub {
        my ($callback) = @_;
        $callback->();
        my $routine = Local::DelayedRoutine->new;
        push @routines, $routine;
        return $routine;
    };
    local *Developer::Dashboard::Web::Server::_handle_ssl_frontend_client = sub { $handled++; return 1 };
    local *Developer::Dashboard::Web::Server::_stop_ssl_backend = sub {
        push @stopped, $_[0];
        return 1;
    };
    local *Developer::Dashboard::Web::Server::_wait_for_ssl_backend_ready = sub { return 1 };
    local $ssl_server->{ssl_subject_alt_names} = undef;

    is(
        $ssl_server->_serve_ssl_frontend($ssl_daemon),
        1,
        'SSL frontend retries an interrupted accept and then exits once shutdown is requested',
    );
    is_deeply( \@spawned, [ [ $^X, '-e', 'exit 0' ], { process_group => 1, env => { DEVELOPER_DASHBOARD_SSL_FRONTEND_PID => $$ } } ],
        'SSL frontend starts its backend with the managed process-group option' );
    is( $handled, 1, 'accepted client is handled by one GoRoutine worker' );
    is( $routines[0]{killed}, 1, 'SSL frontend cancels a client routine during shutdown' );
    is( $routines[0]{checks}, 3, 'SSL frontend waits for a running client routine to finish' );
    is_deeply( \@stopped, [991001], 'SSL frontend stops the internal backend before returning' );

    close $client_peer or die "Unable to close frontend client fixture peer: $!";
}


_log("done");
done_testing();
