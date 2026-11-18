use strict;
use warnings;
use utf8;

# Micro-repro v3 for Jenkins build #94: t/05 test 247 stalls on Windows.
#
# Micro v1 (build #95, SUCCESS all four) did NOT reproduce the stall:
# Windows serve 49.4s, stop 28.5s, restart-exact 82.8s vs 1-9s elsewhere.
# Micro v2 (build #96, FAILURE on a micro artifact) measured the
# primitives and REFUTED netstat as the dominant cost (Windows netstat
# mean 0.029s/call; 300 polls cost ~9s, not ~50s). It PROVED the
# TCP-connect poll on Windows burns the full timeout while a port is
# closed (2.008s per connect with Timeout 2; the product uses Timeout 1,
# so 1s per failed connect), and that bind itself is only 8.5s on
# Windows (0.9s amd64, 1.4s macOS, 7.7s ARM64). Death is 0.5-0.6s on
# Unix; Windows death was unmeasured (leg fail-fast killed).
#
# Micro v2's test 7 failure was a MICRO artifact, not the product: the
# serve child is a launcher that forks the daemon and returns, so the
# child exits quickly but sits as an unreaped zombie, and
# GoRoutine::process_running (an existence check) reports a zombie as
# running until wait_process reaps it. This micro polls
# GoRoutine::process_exited (the completion-state check) instead.
#
# This micro answers the remaining question: why does `d2 serve` take
# ~49s when the server binds in 8.5s, and why does `d2 stop` take ~28s
# when death is ~0.5s? It measures, per phase, the CHILD exit time
# (when the d2 process itself returns) against the bind/death time,
# plus a trivial `d2 which perl` invocation (parent Perl startup +
# module load, for comparison). If serve-child exit is ~49s while bind
# is ~8.5s, the ~40s sits INSIDE serve_all after bind (start_collectors
# or the runtime-ready wait). If serve-child exit is ~9s, v1's 49s came
# from the _run_logged path, not the product.
# All loops are bounded; every phase logs BEFORE/AFTER with wall-clock
# times, so a stuck phase is still named by its BEFORE line.

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

sub _poll_until_accepting {
    my ( $port, $max_seconds ) = @_;
    my $start = time();
    while ( time() - $start < $max_seconds ) {
        return time() - $start if _port_accepting($port);
        sleep 0.1;
    }
    return undef;
}

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
# Polls GoRoutine::process_exited (completion state) until the child
# has exited. Returns seconds until exit, or undef on timeout.
# NOTE (v2 lesson): do NOT use process_running here — it is an
# existence check, so an unreaped zombie counts as running and the
# poll burns the whole timeout even though the child already exited.
sub _poll_process_exit {
    my ( $pid, $max_seconds ) = @_;
    my $start = time();
    while ( time() - $start < $max_seconds ) {
        return time() - $start if Developer::Dashboard::GoRoutine::process_exited($pid);
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
    if ( $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop|which)\b/ ) {
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

    ok( defined &Developer::Dashboard::GoRoutine::process_exited, 'micro GoRoutine process_exited is available' );

    # Phase 0: parent load. Time a trivial d2 invocation three times.
    # This is the floor every d2 subprocess pays (Perl startup +
    # module load) and the baseline the serve/stop times sit on.
    my ( $out, $rc );
    for my $attempt ( 1 .. 3 ) {
        ( $out, $rc ) = _run_logged( "which-perl-$attempt", "cd '$home' && $perl -I'$lib' '$dashboard' which perl" );
    }
    ok( 1, 'micro trivial d2 invocations timed' );

    # Setup for the serve/stop timing: init + page, as in t/05.
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

    # Phase 1: serve child exit time vs bind time.
    _log('BEFORE serve-spawn: d2 serve --no-indicator (detached)');
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

    # Phase 2: stop child exit time vs death time.
    _log('BEFORE stop-spawn: d2 stop -o json (detached)');
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

    # Phase 3: restart child timing. Serve again first so there is a
    # live server to restart, then spawn `d2 restart` and watch the
    # port close and reopen, plus the child exit.
    _log('BEFORE serve-spawn-2: second serve (detached)');
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
    _log("serve-2 child exit code: $serve2_exit");
    is( $serve2_exit, 0, 'micro second serve child exits 0' );

    _log('BEFORE restart-spawn: d2 restart -o json (detached)');
    my $restart_start = time();
    my $restart_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $perl, "-I$lib", $dashboard, 'restart', '-o', 'json', '--host', '127.0.0.1', '--port', $port ],
        { stdout => $serve_out, stderr => $serve_err },
    );
    ok( $restart_pid, 'micro restart child spawned' );
    my $restart_death = _poll_until_closed( $port, 120 );
    _log( defined $restart_death ? sprintf( 'restart death time (port closes): %.1fs', $restart_death ) : 'restart death time: TIMEOUT after 120s' );
    ok( defined $restart_death, 'micro restart stops the old server' );
    my $restart_rebind = _poll_until_accepting( $port, 120 );
    _log( defined $restart_rebind ? sprintf( 'restart rebind time (port accepts again): %.1fs after spawn', $restart_rebind ) : 'restart rebind time: TIMEOUT after 120s' );
    ok( defined $restart_rebind, 'micro restart rebinds the port' );
    my $restart_exit_time = _poll_process_exit( $restart_pid, 120 );
    _log( defined $restart_exit_time ? sprintf( 'restart child exit time: %.1fs after spawn', $restart_exit_time ) : 'restart child exit time: TIMEOUT after 120s' );
    ok( defined $restart_exit_time, 'micro restart child exits' );
    my $restart_exit = Developer::Dashboard::GoRoutine::wait_process($restart_pid);
    _log("restart child exit code: $restart_exit (total since spawn: " . sprintf( '%.1fs', time() - $restart_start ) . ')');
    is( $restart_exit, 0, 'micro restart child exits 0' );

    # Cleanup: stop everything we started.
    ( $out, $rc ) = _run_logged( 'stop-cleanup', "cd '$home' && $perl -I'$lib' '$dashboard' stop -o json" );
    _log( 'final port accepting: ' . ( _port_accepting($port) ? 'YES' : 'no' ) );
}

done_testing;
