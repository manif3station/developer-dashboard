use strict;
use warnings;
use utf8;

# Micro-repro v4 for Jenkins build #94: t/05 test 247 stalls on Windows.
#
# Micro v3 (build #97, SUCCESS all four) split the Windows cost in two:
#  - the launcher child lingers 29-36s AFTER the port binds (serve child
#    exit 37.1s vs bind 7.9s; serve-2 44.8s vs 9.0s; restart child exit
#    72.8s, 22.2s after the rebind), and
#  - the port itself is slow to change state (stop death 15.8s, restart
#    death 16.3s, restart rebind 34.3s after death, vs 0.6-4.6s elsewhere).
# Parent Perl load is ruled out (d2 which perl: 1.2s on Windows).
#
# Micro v2 proved netstat is cheap on Windows (0.029s/call) — but the
# product does NOT call netstat first on Windows. _listener_pids_for_port
# (RuntimeManager.pm) shells out to POWERSHELL Get-NetTCPConnection on
# every poll iteration, falling back to netstat only when PowerShell
# fails or returns nothing. Every readiness wait (_start_web_windows_
# background, _web_runtime_ready, _wait_for_port_release at 50 polls)
# pays that PowerShell spawn per iteration. This micro measures the
# PowerShell lookup cost directly (with and without a listener) and
# records a fine-grained serve/restart port timeline, to decide:
#  (a) PowerShell is slow per call and the fix is to use netstat (or
#      cache the lookup) for the listener polls, or
#  (b) the port flaps during serve/restart (appears, disappears,
#      reappears), proving _restart_web_with_retry retries an attempt
#      whose _web_runtime_ready failed even though the server is up.
# All loops are bounded; phases log BEFORE/AFTER with wall-clock times
# plus a heartbeat every ~20s inside long polls, so a stuck phase is
# still named by its BEFORE line and the fail-safe silence window
# (180s) is never approached.

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
my $IS_WINDOWS = $^O eq 'MSWin32';

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

# _port_listening_netstat($port)
# True when netstat shows a LISTENING socket on the port (Windows).
# Mirrors the product's _listener_pids_for_port_via_netstat match.
sub _port_listening_netstat {
    my ($port) = @_;
    my ( $stdout, undef, $exit_code ) = capture {
        system 'netstat', '-ano', '-p', 'tcp';
        return $? >> 8;
    };
    return 0 if $exit_code != 0 || !defined $stdout || $stdout eq '';
    for my $line ( split /\n/, $stdout ) {
        return 1 if $line =~ /^\s*TCP\s+\S+:$port\s+\S+\s+LISTENING\s+\d+\s*$/i;
    }
    return 0;
}

sub _port_state {
    my ($port) = @_;
    return _port_listening_netstat($port) if $IS_WINDOWS;
    return _port_accepting($port);
}

# _poll_process_exit($pid, $max_seconds)
# Polls GoRoutine::process_exited (completion state) until the child
# has exited. Returns seconds until exit, or undef on timeout.
# (v2 lesson: process_running reports an unreaped zombie as running.)
sub _poll_process_exit {
    my ( $pid, $max_seconds ) = @_;
    my $start = time();
    while ( time() - $start < $max_seconds ) {
        return time() - $start if Developer::Dashboard::GoRoutine::process_exited($pid);
        sleep 0.1;
    }
    return undef;
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

# _timeline_poll($label, $port, $max_seconds, $pid)
# Polls the port state every 0.25s and logs every transition with its
# elapsed time, plus a heartbeat every ~20s. Stops early once the
# watched child pid has exited (the phase is over then). Returns a
# list of [elapsed, new_state] transitions (state 1 =
# listening/accepting). A port that appears, disappears and reappears
# proves a retry: the first attempt's server was started then stopped.
sub _timeline_poll {
    my ( $label, $port, $max_seconds, $pid ) = @_;
    my $start = time();
    my $last_state = _port_state($port) ? 1 : 0;
    my @transitions = ( [ 0, $last_state ] );
    _log("$label timeline start: port state is " . ( $last_state ? 'LISTENING' : 'absent' ));
    my $last_heartbeat = 0;
    while ( time() - $start < $max_seconds ) {
        sleep 0.25;
        my $state = _port_state($port) ? 1 : 0;
        if ( $state != $last_state ) {
            my $at = time() - $start;
            _log( sprintf( '%s timeline: port %s at %.1fs', $label, $state ? 'LISTENING' : 'absent', $at ) );
            push @transitions, [ $at, $state ];
            $last_state = $state;
        }
        if ( defined $pid && Developer::Dashboard::GoRoutine::process_exited($pid) ) {
            _log( sprintf( '%s timeline: watched child exited at %.1fs, stopping poll', $label, time() - $start ) );
            last;
        }
        my $elapsed = time() - $start;
        if ( $elapsed - $last_heartbeat >= 20 ) {
            _log( sprintf( '%s timeline heartbeat: %.1fs elapsed, port %s', $label, $elapsed, $last_state ? 'LISTENING' : 'absent' ) );
            $last_heartbeat = $elapsed;
        }
    }
    return @transitions;
}

# _time_lookup($label, $code, $count)
# Times $count calls of the lookup coderef; logs mean/min/max.
# Returns the mean seconds per call.
sub _time_lookup {
    my ( $label, $code, $count ) = @_;
    my @times;
    for my $i ( 1 .. $count ) {
        my $start = time();
        $code->();
        push @times, time() - $start;
        _log("$label call $i of $count done") if $i % 5 == 0;
    }
    my $total = 0;
    $total += $_ for @times;
    my $mean = $total / @times;
    my $min = ( sort { $a <=> $b } @times )[0];
    my $max = ( sort { $a <=> $b } @times )[-1];
    _log( sprintf( '%s: %d calls in %.1fs, mean %.3fs, min %.3fs, max %.3fs', $label, $count, $total, $mean, $min, $max ) );
    return $mean;
}

sub _powershell_listener_lookup {
    my ($port) = @_;
    my ( undef, undef, undef ) = capture {
        system(
            'powershell', '-NoLogo', '-NoProfile', '-Command',
            qq{\$ErrorActionPreference = 'Stop'; Get-NetTCPConnection -LocalPort $port -State Listen | Select-Object -ExpandProperty OwningProcess},
        );
        return $? >> 8;
    };
    return;
}

sub _netstat_lookup {
    my ($port) = @_;
    my ( undef, undef, undef ) = capture {
        system 'netstat', '-ano', '-p', 'tcp';
        return $? >> 8;
    };
    return;
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

    # Phase A (Windows only): PowerShell listener-lookup cost with NO
    # listener on the port, vs netstat. This is the per-call cost the
    # product pays on EVERY readiness-poll iteration.
    my ( $ps_mean_free, $ns_mean_free );
    if ($IS_WINDOWS) {
        $ps_mean_free = _time_lookup( 'powershell-lookup-no-listener', sub { _powershell_listener_lookup($port) }, 20 );
        $ns_mean_free = _time_lookup( 'netstat-lookup-no-listener', sub { _netstat_lookup($port) }, 20 );
        ok( $ps_mean_free > 0, 'micro powershell lookup (no listener) timed' );
        ok( $ns_mean_free > 0, 'micro netstat lookup (no listener) timed' );
    }
    else {
        _log('skipping powershell phase: not Windows');
        ok( 1, 'micro powershell phase skipped on non-Windows' );
        ok( 1, 'micro netstat phase skipped on non-Windows' );
    }

    # Phase B: serve timeline. Spawn serve detached, poll the port
    # state every 0.25s, log every transition. A flap (LISTENING then
    # absent then LISTENING) proves a retry inside serve_all.
    _log('BEFORE serve-spawn: d2 serve --no-indicator (detached)');
    my $spawn_start = time();
    my $serve_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $perl, "-I$lib", $dashboard, 'serve', '--host', '127.0.0.1', '--port', $port, '--no-indicator' ],
        { stdout => $serve_out, stderr => $serve_err },
    );
    ok( $serve_pid, 'micro serve child spawned' );
    my @serve_transitions = _timeline_poll( 'serve', $port, 120, $serve_pid );
    my $serve_exit_time = _poll_process_exit( $serve_pid, 60 );
    _log( defined $serve_exit_time ? sprintf( 'serve child exit time: %.1fs after spawn', $serve_exit_time ) : 'serve child exit time: TIMEOUT after 60s' );
    ok( defined $serve_exit_time, 'micro serve child exits' );
    my $serve_exit = Developer::Dashboard::GoRoutine::wait_process($serve_pid);
    _log("serve child exit code: $serve_exit (total since spawn: " . sprintf( '%.1fs', time() - $spawn_start ) . ')');
    is( $serve_exit, 0, 'micro serve child exits 0' );
    my $serve_flaps = 0;
    $serve_flaps++ for grep { $_->[1] == 0 } @serve_transitions[ 1 .. $#serve_transitions ];
    _log("serve timeline transitions: " . scalar(@serve_transitions) . " (flaps to absent after first LISTENING: $serve_flaps)");
    ok( $serve_flaps == 0, 'micro serve port does not flap (no retry)' );

    # Phase C (Windows only): PowerShell listener-lookup cost WITH a
    # listener present (the server from phase B is still running), vs
    # netstat. Then stop it and log the stop time.
    if ($IS_WINDOWS) {
        my $ps_mean_live = _time_lookup( 'powershell-lookup-with-listener', sub { _powershell_listener_lookup($port) }, 20 );
        my $ns_mean_live = _time_lookup( 'netstat-lookup-with-listener', sub { _netstat_lookup($port) }, 20 );
        ok( $ps_mean_live > 0, 'micro powershell lookup (with listener) timed' );
        ok( $ns_mean_live > 0, 'micro netstat lookup (with listener) timed' );
    }
    else {
        ok( 1, 'micro powershell-with-listener phase skipped on non-Windows' );
        ok( 1, 'micro netstat-with-listener phase skipped on non-Windows' );
    }
    ( $out, $rc ) = _run_logged( 'stop-after-serve', "cd '$home' && $perl -I'$lib' '$dashboard' stop -o json" );
    _log( 'post-stop port accepting: ' . ( _port_accepting($port) ? 'YES' : 'no' ) );

    # Phase D: restart timeline. Serve again (bind only, do not wait
    # for the launcher to exit), then spawn restart detached and poll
    # the port state every 0.25s, logging every transition. The gap
    # between the port closing and reopening is the rebind cost; a
    # flap inside it (reopen then close then reopen) proves a retry.
    _log('BEFORE serve-spawn-2: second serve (detached, bind only)');
    my $serve2_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $perl, "-I$lib", $dashboard, 'serve', '--host', '127.0.0.1', '--port', $port, '--no-indicator' ],
        { stdout => $serve_out, stderr => $serve_err },
    );
    ok( $serve2_pid, 'micro second serve child spawned' );
    my $bind2_time = _poll_until_accepting( $port, 120 );
    _log( defined $bind2_time ? sprintf( 'serve-2 bind time: %.1fs', $bind2_time ) : 'serve-2 bind time: TIMEOUT after 120s' );
    ok( defined $bind2_time, 'micro second server binds' );

    _log('BEFORE restart-spawn: d2 restart -o json (detached)');
    my $restart_start = time();
    my $restart_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $perl, "-I$lib", $dashboard, 'restart', '-o', 'json', '--host', '127.0.0.1', '--port', $port ],
        { stdout => $serve_out, stderr => $serve_err },
    );
    ok( $restart_pid, 'micro restart child spawned' );
    my @restart_transitions = _timeline_poll( 'restart', $port, 180, $restart_pid );
    my $restart_exit_time = _poll_process_exit( $restart_pid, 60 );
    _log( defined $restart_exit_time ? sprintf( 'restart child exit time: %.1fs after spawn', $restart_exit_time ) : 'restart child exit time: TIMEOUT after 60s' );
    ok( defined $restart_exit_time, 'micro restart child exits' );
    my $restart_exit = Developer::Dashboard::GoRoutine::wait_process($restart_pid);
    _log("restart child exit code: $restart_exit (total since spawn: " . sprintf( '%.1fs', time() - $restart_start ) . ')');
    is( $restart_exit, 0, 'micro restart child exits 0' );
    my $restart_flaps = 0;
    $restart_flaps++ for grep { $_->[1] == 0 } @restart_transitions[ 1 .. $#restart_transitions ];
    _log("restart timeline transitions: " . scalar(@restart_transitions) . " (flaps to absent after first state: $restart_flaps)");
    ok( $restart_flaps <= 1, 'micro restart port flaps at most once (the expected stop)' );

    # Cleanup: stop everything we started.
    ( $out, $rc ) = _run_logged( 'stop-cleanup', "cd '$home' && $perl -I'$lib' '$dashboard' stop -o json" );
    _log( 'final port accepting: ' . ( _port_accepting($port) ? 'YES' : 'no' ) );
}

done_testing;
