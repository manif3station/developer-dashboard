use strict;
use warnings;
use utf8;

# Micro-repro v2 for Jenkins build #94: t/05 test 247 stalls on Windows.
#
# Micro v1 (build #95, SUCCESS all four) did NOT reproduce the stall, but
# it exposed the slowness that makes the #94 trip plausible. Windows:
# serve-noind 49.4s, stop-alone 28.5s, serve-again 49.2s, restart-exact
# 82.8s, stop-cleanup 29.1s (other legs: 1-9s per phase). The port checks
# were all as expected (pre-stop yes, post-stop no), so the old server
# DOES die on stop — the leading hypothesis from v1 (old server holds
# the port) is REFUTED.
#
# Restart is 82.8s in isolation but tripped the 180s silence limit in
# the full t/05 run. This micro measures the primitives that decide
# where the time goes, so the fix targets the real cost:
#   (a) netstat cost: _listener_pids_for_port_via_netstat shells out to
#       `netstat -ano -p tcp` on EVERY poll. The lifecycle waits poll
#       it hundreds of times per serve/stop/restart (300 polls in
#       _start_web_windows_background and in _web_runtime_ready, 50 in
#       _wait_for_port_release, twice per stop). If one netstat call
#       costs ~0.15-0.25s, serve alone burns ~50s in polling.
#   (b) true bind time: how long from spawning `d2 serve` until the
#       port first accepts (cheap connect polls, no netstat). If the
#       child itself takes ~45s to bind (slow Perl startup), the cost
#       is child startup, not polling.
#   (c) true death time: how long from spawning `d2 stop` until the
#       port stops accepting, and when the stop child itself exits.
# All loops here are bounded; every phase logs BEFORE/AFTER with
# wall-clock times, so a stuck phase is still named by its BEFORE line.

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so
# this process runs the tip's Perl modules exactly like the CLI
# subprocesses already do (same drift fix as t/05, commit cbf9855d).
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Developer::Dashboard::GoRoutine ();
use Developer::Dashboard::JSON qw(json_decode);
use Developer::Dashboard::PerlEnv;
use Encode qw(decode);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use LWP::UserAgent;
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo = getcwd();
my @built_perl_libs = grep { -d $_ } map { File::Spec->catdir( $repo, 'blib', $_ ) } qw(arch lib);
local $ENV{PERL5LIB} = join Developer::Dashboard::PerlEnv::path_separator(), grep { defined && $_ ne '' } ( @built_perl_libs, $ENV{PERL5LIB} || () );
local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

my $T0 = time();

sub _elapsed {
    return sprintf( '%.1fs', time() - $T0 );
}

sub _log {
    my ($msg) = @_;
    diag( '[' . _elapsed() . "] $msg" );
}

# _port_accepting($port)
# True when something answers a TCP connect on the port right now.
# Cheap: one connect attempt, no subprocess.
sub _port_accepting {
    my ($port) = @_;
    my $socket = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    );
    return 0 if !$socket;
    close $socket;
    return 1;
}

# _poll_until_accepting($port, $max_seconds)
# Polls the port with cheap connects every 0.1s. Returns seconds until
# first accept, or undef on timeout.
sub _poll_until_accepting {
    my ( $port, $max_seconds ) = @_;
    my $start = time();
    while ( time() - $start < $max_seconds ) {
        return time() - $start if _port_accepting($port);
        sleep 0.1;
    }
    return undef;
}

# _poll_until_closed($port, $max_seconds)
# Polls until the port stops accepting. Returns seconds until closed,
# or undef on timeout.
sub _poll_until_closed {
    my ( $port, $max_seconds ) = @_;
    my $start = time();
    while ( time() - $start < $max_seconds ) {
        return time() - $start if !_port_accepting($port);
        sleep 0.1;
    }
    return undef;
}

# _poll_process_exit($pid, $max_seconds)
# Polls GoRoutine::process_running until the child exits. Returns
# seconds until exit, or undef on timeout.
sub _poll_process_exit {
    my ( $pid, $max_seconds ) = @_;
    my $start = time();
    while ( time() - $start < $max_seconds ) {
        return time() - $start if !Developer::Dashboard::GoRoutine::process_running($pid);
        sleep 0.1;
    }
    return undef;
}

sub _find_free_port {
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Unable to reserve a free local TCP port: $!";
    my $port = $socket->sockport();
    close $socket or die "Unable to release reserved local TCP port $port: $!";
    return $port;
}

sub _run_logged {
    my ( $label, $cmd ) = @_;
    _log("BEFORE $label: $cmd");
    my $start = time();
    my %env;
    if ( $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop)\b/ ) {
        $env{PERL5OPT}              = undef;
        $env{HARNESS_PERL_SWITCHES} = undef;
    }
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => \%env } );
    _log( sprintf( 'AFTER %s: exit=%d in %.1fs', $label, $exit_code, time() - $start ) );
    return ( decode( 'UTF-8', $stdout . $stderr ), $exit_code );
}

{
    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

    ok( defined &Developer::Dashboard::GoRoutine::spawn, 'micro GoRoutine spawn is available' );

    # Phase 1: netstat primitive cost (the exact call the product makes
    # on every listener poll on Windows).
    _log('BEFORE netstat-cost: 20 x netstat -ano -p tcp');
    my $netstat_start = time();
    my $netstat_calls = 0;
    my $netstat_min;
    my $netstat_max = 0;
    for ( 1 .. 20 ) {
        my $call_start = time();
        my ( $stdout, undef, $rc ) = capture { system 'netstat', '-ano', '-p', 'tcp'; };
        my $call_elapsed = time() - $call_start;
        $netstat_calls++;
        $netstat_min = $call_elapsed if !defined $netstat_min || $call_elapsed < $netstat_min;
        $netstat_max = $call_elapsed if $call_elapsed > $netstat_max;
    }
    my $netstat_total = time() - $netstat_start;
    _log( sprintf( 'AFTER netstat-cost: %d calls in %.1fs, mean %.3fs, min %.3fs, max %.3fs',
            $netstat_calls, $netstat_total, $netstat_total / $netstat_calls, $netstat_min, $netstat_max ) );
    ok( $netstat_calls == 20, 'micro netstat cost measured' );

    # Phase 2: connect primitive cost (the cheap check).
    _log('BEFORE connect-cost: 20 x TCP connect to a free port');
    my $free_port = _find_free_port();
    my $connect_start = time();
    for ( 1 .. 20 ) {
        _port_accepting($free_port);
    }
    my $connect_total = time() - $connect_start;
    _log( sprintf( 'AFTER connect-cost: 20 connects in %.3fs, mean %.4fs', $connect_total, $connect_total / 20 ) );
    ok( 1, 'micro connect cost measured' );

    # Setup for the serve/stop timing: init + page, as in t/05.
    my ( $out, $rc );
    ( $out, $rc ) = _run_logged( 'init', "cd '$home' && $perl -I'$lib' '$dashboard' init" );
    like( $out, qr/runtime_root/, 'micro init initializes a runtime' );
    ( $out, $rc ) = _run_logged( 'page-new', "cd '$home' && $perl -I'$lib' '$dashboard' page new noind 'No Indicators'" );
    my $source_file = File::Spec->catfile( $home, 'noind.page' );
    open my $source_fh, '>:raw', $source_file or die "Unable to write $source_file: $!";
    print {$source_fh} $out;
    close $source_fh;
    ( $out, $rc ) = _run_logged( 'page-save', "cd '$home' && $perl -I'$lib' '$dashboard' page save noind < '$source_file'" );

    my $port = _find_free_port();
    _log("using port $port");
    my $serve_out = File::Spec->catfile( $home, 'serve.out' );
    my $serve_err = File::Spec->catfile( $home, 'serve.err' );
    my $stop_out  = File::Spec->catfile( $home, 'stop.out' );
    my $stop_err  = File::Spec->catfile( $home, 'stop.err' );

    # Phase 3: true bind time. Spawn `d2 serve` detached and poll the
    # port with cheap connects until it first accepts. Then wait for
    # the serve child itself to exit and collect its exit code.
    _log('BEFORE serve-spawn: d2 serve --no-indicator (detached, cheap port polls)');
    my $spawn_start = time();
    my $serve_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $perl, "-I$lib", $dashboard, 'serve', '--host', '127.0.0.1', '--port', $port, '--no-indicator' ],
        { stdout => $serve_out, stderr => $serve_err },
    );
    ok( $serve_pid, 'micro serve child spawned' );
    my $bind_time = _poll_until_accepting( $port, 120 );
    _log( defined $bind_time ? sprintf( 'serve bind time (port first accepts): %.1fs', $bind_time ) : 'serve bind time: TIMEOUT after 120s' );
    ok( defined $bind_time, 'micro server binds the port' );
    my $serve_exit_time = _poll_process_exit( $serve_pid, 120 );
    _log( defined $serve_exit_time ? sprintf( 'serve child exit time: %.1fs after spawn', $serve_exit_time ) : 'serve child exit time: TIMEOUT after 120s' );
    ok( defined $serve_exit_time, 'micro serve child exits' );
    my $serve_exit = Developer::Dashboard::GoRoutine::wait_process($serve_pid);
    _log("serve child exit code: $serve_exit (total since spawn: " . sprintf( '%.1fs', time() - $spawn_start ) . ')');
    is( $serve_exit, 0, 'micro serve child exits 0' );

    # Phase 4: true death time. Spawn `d2 stop` detached and poll the
    # port until it stops accepting. Then wait for the stop child.
    _log('BEFORE stop-spawn: d2 stop -o json (detached, cheap port polls)');
    my $stop_spawn_start = time();
    my $stop_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $perl, "-I$lib", $dashboard, 'stop', '-o', 'json' ],
        { stdout => $stop_out, stderr => $stop_err },
    );
    ok( $stop_pid, 'micro stop child spawned' );
    my $death_time = _poll_until_closed( $port, 120 );
    _log( defined $death_time ? sprintf( 'stop death time (port stops accepting): %.1fs', $death_time ) : 'stop death time: TIMEOUT after 120s' );
    ok( defined $death_time, 'micro server stops listening' );
    my $stop_exit_time = _poll_process_exit( $stop_pid, 120 );
    _log( defined $stop_exit_time ? sprintf( 'stop child exit time: %.1fs after spawn', $stop_exit_time ) : 'stop child exit time: TIMEOUT after 120s' );
    ok( defined $stop_exit_time, 'micro stop child exits' );
    my $stop_exit = Developer::Dashboard::GoRoutine::wait_process($stop_pid);
    _log("stop child exit code: $stop_exit (total since spawn: " . sprintf( '%.1fs', time() - $stop_spawn_start ) . ')');
    is( $stop_exit, 0, 'micro stop child exits 0' );
    _log( 'post-stop port accepting: ' . ( _port_accepting($port) ? 'YES' : 'no' ) );

    # Phase 5: repeat serve+stop once, to check the timings are stable
    # rather than one-off variance.
    _log('BEFORE serve-spawn-2: second serve (detached, cheap port polls)');
    my $spawn2_start = time();
    my $serve2_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $perl, "-I$lib", $dashboard, 'serve', '--host', '127.0.0.1', '--port', $port, '--no-indicator' ],
        { stdout => $serve_out, stderr => $serve_err },
    );
    ok( $serve2_pid, 'micro second serve child spawned' );
    my $bind2_time = _poll_until_accepting( $port, 120 );
    _log( defined $bind2_time ? sprintf( 'serve-2 bind time: %.1fs', $bind2_time ) : 'serve-2 bind time: TIMEOUT after 120s' );
    ok( defined $bind2_time, 'micro second server binds' );
    my $serve2_exit_time = _poll_process_exit( $serve2_pid, 120 );
    _log( defined $serve2_exit_time ? sprintf( 'serve-2 child exit time: %.1fs after spawn', $serve2_exit_time ) : 'serve-2 child exit time: TIMEOUT after 120s' );
    my $serve2_exit = Developer::Dashboard::GoRoutine::wait_process($serve2_pid);
    _log("serve-2 child exit code: $serve2_exit (total since spawn: " . sprintf( '%.1fs', time() - $spawn2_start ) . ')');

    _log('BEFORE stop-spawn-2: second stop (detached, cheap port polls)');
    my $stop2_start = time();
    my $stop2_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $perl, "-I$lib", $dashboard, 'stop', '-o', 'json' ],
        { stdout => $stop_out, stderr => $stop_err },
    );
    ok( $stop2_pid, 'micro second stop child spawned' );
    my $death2_time = _poll_until_closed( $port, 120 );
    _log( defined $death2_time ? sprintf( 'stop-2 death time: %.1fs', $death2_time ) : 'stop-2 death time: TIMEOUT after 120s' );
    ok( defined $death2_time, 'micro second server stops listening' );
    my $stop2_exit_time = _poll_process_exit( $stop2_pid, 120 );
    _log( defined $stop2_exit_time ? sprintf( 'stop-2 child exit time: %.1fs after spawn', $stop2_exit_time ) : 'stop-2 child exit time: TIMEOUT after 120s' );
    my $stop2_exit = Developer::Dashboard::GoRoutine::wait_process($stop2_pid);
    _log("stop-2 child exit code: $stop2_exit (total since spawn: " . sprintf( '%.1fs', time() - $stop2_start ) . ')');
    _log( 'final port accepting: ' . ( _port_accepting($port) ? 'YES' : 'no' ) );
}

done_testing;
