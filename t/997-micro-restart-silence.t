use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, 'lib' );

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Developer::Dashboard::GoRoutine qw(process_exited spawn terminate_process wait_process);
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Encode qw(decode encode);
use File::Spec;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use LWP::UserAgent;
use Local::NativeCommand qw(run_shell_command);
use Test::More;
use Time::HiRes qw(sleep time);

# Micro-probe: is the Windows `d2 restart` silence trip in round 35 a hang
# or a slow restart, and which phase eats the time?
#
# Round 35 (build #349) tripped the 180 s watchdog silence branch on the
# Windows leg right after t/05 test 203 printed (the serve-starts-collectors
# check); the next step is `d2 restart -o json` at t/05 line 797. The same
# restart completed on Windows in solo #348, so this is intermittent or
# load-dependent, not a hard hang - but the console cannot distinguish a
# genuinely hung restart from a legitimate-but-slow one that overran 180 s.
#
# This micro reproduces the exact t/05 serve/restart lifecycle sequence
# three times (fresh serve home and fresh port each time), with a timestamp
# + elapsed time on every log line, and runs each restart as a GoRoutine
# child polled once a second with a heartbeat diag every 15 s - so a slow
# restart stays visible past the 180 s watchdog silence threshold instead
# of killing the run mute, and the true elapsed time is recorded either
# way. The restart child is the identical command line t/05 runs; only the
# parent's wait differs (polling with a heartbeat instead of blocking).
# Each round also times the two listener-query primitives the Windows
# readiness wait pays per poll: `netstat -ano -p tcp` (fast path, ~0.03 s)
# and the PowerShell Get-NetTCPConnection fallback (~4 s per call when no
# listener exists yet, per the comment in RuntimeManager.pm
# _listener_pids_for_port). The ready wait runs up to 300 polls in each of
# _start_web_windows_background and _web_runtime_ready, so the fallback
# cost is what turns a slow-to-bind web child into a silence trip.
#
# Expected solo result: Unix legs fast everywhere (restart well under 10 s
# each round). On Windows, if the restart is merely slow under load, all
# three restarts return with elapsed times printed and the heartbeat lines
# show the run alive throughout; if it hangs, the 420 s cap fires instead
# and the log shows exactly how long it ran before being killed. Either
# outcome is a finding. The micro asserts the control half (serve starts
# the tick collector) and the restart outcome per round; it fixes nothing.

plan tests => 12;

my $repo = getcwd();
my $perl = $^X;
my $lib  = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

my $T0 = time();

# _log($message)
# Prints one timestamped probe line: wall-clock seconds since the micro
# started, so every phase boundary is readable off the console.
# Input: message string.
# Output: nothing (diag output).
sub _log {
    my ($message) = @_;
    diag sprintf( '[T+%7.2fs] %s', time() - $T0, $message );
}

# _run($command)
# Runs one shell command exactly the way t/05 does (Local::NativeCommand
# on Windows, sh -c on Unix) and returns its captured output - but unlike
# t/05's _run it does NOT assert the exit code, so a slow or failing
# lifecycle step is logged and reported instead of dying mid-probe.
# Input: command string.
# Output: list of (stdout, stderr, exit code).
sub _run {
    my ($cmd) = @_;
    my $child_perl5opt = join ' ', grep { defined $_ && $_ ne '' } ( $ENV{PERL5OPT}, $ENV{HARNESS_PERL_SWITCHES} );
    my $runtime_command = $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop)\b/;
    my %env;
    if ($runtime_command) {
        $env{PERL5OPT}              = undef;
        $env{HARNESS_PERL_SWITCHES} = undef;
    }
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => \%env } );
    return ( decode( 'UTF-8', $stdout ), decode( 'UTF-8', $stderr ), $exit_code );
}

# _run_in_home($home, $command)
# Runs one command with its working directory inside the given home, the
# way t/05's _run_in_home does.
# Input: home directory and command string.
# Output: list of (stdout, stderr, exit code).
sub _run_in_home {
    my ( $home, $cmd ) = @_;
    return _run("cd '$home' && $cmd");
}

# _find_free_port()
# Reserves one free local TCP port and releases it, the way t/05 does.
# Input: none.
# Output: free port integer.
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

# _time_netstat_listener_query($port)
# Times the exact listener query RuntimeManager.pm
# _listener_pids_for_port_via_netstat runs (`netstat -ano -p tcp`) and
# reports whether it found a LISTENING pid for the port. Windows only:
# the netstat path is the fast path the readiness wait prefers.
# Input: port integer.
# Output: elapsed seconds (also logged with the found pid, if any).
sub _time_netstat_listener_query {
    my ($port) = @_;
    return if $^O ne 'MSWin32';
    my $start = time();
    my ( $stdout, undef, $exit_code ) = capture {
        system 'netstat', '-ano', '-p', 'tcp';
        return $? >> 8;
    };
    my $elapsed = time() - $start;
    my ($found) = defined $stdout ? ( $stdout =~ /^\s*TCP\s+\S+:$port\s+\S+\s+LISTENING\s+(\d+)\s*$/im ) : ();
    _log(
        sprintf(
            'primitive netstat -ano -p tcp for port %d: %.2fs exit=%s listener_pid=%s',
            $port, $elapsed, $exit_code, defined $found ? $found : 'none',
        )
    );
    return $elapsed;
}

# _time_powershell_no_listener_query($port)
# Times the exact PowerShell fallback query _listener_pids_for_port runs
# when netstat finds no listener (Get-NetTCPConnection for a port with
# nothing listening). Windows only: this is the ~4 s per-poll cost the
# readiness wait pays before the web child binds.
# Input: port integer with no listener.
# Output: elapsed seconds (also logged with the exit code and output).
sub _time_powershell_no_listener_query {
    my ($port) = @_;
    return if $^O ne 'MSWin32';
    my $powershell = 'powershell.exe';
    if ( !-f $powershell ) {
        my $system_root = $ENV{SystemRoot} || 'C:\\Windows';
        my $fallback = File::Spec->catfile( $system_root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe' );
        $powershell = $fallback if -f $fallback;
    }
    my $start = time();
    my ( $stdout, undef, $exit_code ) = capture {
        system(
            $powershell,
            '-NoLogo',
            '-NoProfile',
            '-Command',
            qq{\$ErrorActionPreference = 'Stop'; Get-NetTCPConnection -LocalPort $port -State Listen | Select-Object -ExpandProperty OwningProcess},
        );
        return $? >> 8;
    };
    my $elapsed = time() - $start;
    my $out = defined $stdout ? $stdout : '';
    $out =~ s/\s+\z//;
    _log(
        sprintf(
            'primitive PowerShell Get-NetTCPConnection for unbound port %d: %.2fs exit=%s output=[%s]',
            $port, $elapsed, $exit_code, $out,
        )
    );
    return $elapsed;
}

# _restart_with_heartbeat($home, $port)
# Runs `d2 restart -o json` for one serve home as a GoRoutine child and
# polls it once a second, printing a heartbeat diag every 15 s so the run
# stays visible past the 180 s watchdog silence threshold and the true
# elapsed time is recorded even if the restart is slow. The child is the
# identical command line t/05 runs; only the parent's wait differs.
# Input: serve home directory and port integer.
# Output: hash reference with elapsed, exit, timed_out flag, decoded JSON
# (if any), and raw stdout/stderr strings.
sub _restart_with_heartbeat {
    my ( $home, $port ) = @_;
    my $out_file = File::Spec->catfile( $home, 'restart-stdout.txt' );
    my $err_file = File::Spec->catfile( $home, 'restart-stderr.txt' );
    my @argv = ( $perl, '-I' . $lib, $dashboard, 'restart', '-o', 'json', '--host', '127.0.0.1', '--port', $port );
    my $cap        = 420;
    my $start      = time();
    my $last_beat  = $start;
    my $old_cwd    = getcwd();
    my $pid;
    {
        local $ENV{HOME} = $home;
        local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
        local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
        local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
        local $ENV{PERL5OPT};
        local $ENV{HARNESS_PERL_SWITCHES};
        chdir $home or die "Unable to chdir to $home: $!";
        $pid = spawn(
            \@argv,
            {
                stdin  => File::Spec->devnull(),
                stdout => $out_file,
                stderr => $err_file,
            },
        );
        chdir $old_cwd or die "Unable to chdir back to $old_cwd: $!";
    }
    _log("restart child spawned pid=$pid (cap ${cap}s)");
    my $timed_out = 0;
    while ( time() - $start < $cap ) {
        last if process_exited($pid);
        if ( time() - $last_beat >= 15 ) {
            _log( sprintf( 'restart still running at T+%.2fs (elapsed %.2fs)', time() - $T0, time() - $start ) );
            $last_beat = time();
        }
        sleep 1;
    }
    my $elapsed = time() - $start;
    my $exit;
    if ( process_exited($pid) ) {
        $exit = wait_process($pid);
    }
    else {
        $timed_out = 1;
        _log( sprintf( 'restart did NOT return within %.2fs - killing child pid=%d', $elapsed, $pid ) );
        terminate_process( $pid, 'KILL' );
        $exit = wait_process($pid);
    }
    my $stdout = '';
    my $stderr = '';
    if ( open my $out_fh, '<', $out_file ) {
        local $/;
        $stdout = <$out_fh> // '';
        close $out_fh;
    }
    if ( open my $err_fh, '<', $err_file ) {
        local $/;
        $stderr = <$err_fh> // '';
        close $err_fh;
    }
    my $json;
    if ( !$timed_out && defined $stdout && $stdout ne '' ) {
        $json = eval { json_decode($stdout) };
        _log("restart stdout did not decode as JSON: $@") if !$json && $@;
    }
    return {
        elapsed   => $elapsed,
        exit      => $exit,
        timed_out => $timed_out,
        json      => $json,
        stdout    => $stdout,
        stderr    => $stderr,
    };
}

my @restart_elapsed;

for my $round ( 1 .. 3 ) {
    _log("=== round $round: fresh serve home ===");
    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

    # Setup: identical to the t/05 lifecycle block - init, then a 1 s
    # tick.collector that prints a HiRes timestamp per run.
    my $t = time();
    my ( $init_out, undef, $init_exit ) = _run_in_home( $home, "$perl -I'$lib' '$dashboard' init" );
    _log( sprintf( 'round %d init: %.2fs exit=%s runtime_root=%s', $round, time() - $t, $init_exit, $init_out =~ /runtime_root/ ? 'yes' : 'no' ) );
    my $config_file = File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' );
    open my $config_fh, '>:raw', $config_file or die "Unable to write $config_file: $!";
    my $config_json = json_encode(
        {
            collectors => [
                {
                    name     => 'tick.collector',
                    command  => q{perl -MTime::HiRes=time -e 'printf qq{%.6f\n}, time'},
                    cwd      => 'home',
                    interval => 1,
                },
            ],
        }
    );
    $config_json = encode( 'UTF-8', $config_json ) if utf8::is_utf8($config_json);
    print {$config_fh} $config_json;
    close $config_fh;

    my $port = _find_free_port();
    $t = time();
    my ( $serve_out, undef, $serve_exit ) = _run_in_home( $home, "$perl -I'$lib' '$dashboard' serve --host 127.0.0.1 --port $port" );
    my $serve_json = $serve_exit == 0 ? eval { json_decode($serve_out) } : undef;
    _log( sprintf( 'round %d serve: %.2fs exit=%s pid=%s', $round, time() - $t, $serve_exit, $serve_json && $serve_json->{pid} ? $serve_json->{pid} : 'none' ) );

    # Control half: poll collector output until it changes, exactly as
    # t/05 does. If this fails the setup is at fault, not the restart.
    my $first_stdout = '';
    my $polls_used   = 0;
    $t = time();
    for ( 1 .. 160 ) {
        $polls_used = $_;
        my ( $output_out, undef, $output_exit ) = _run_in_home( $home, "$perl -I'$lib' '$dashboard' collector output tick.collector" );
        if ( $output_exit == 0 ) {
            my $output = eval { json_decode($output_out) };
            $first_stdout = $output->{stdout} || '' if $output;
        }
        last if $first_stdout =~ /^\d+\.\d+\n$/;
        sleep 0.25;
    }
    _log( sprintf( 'round %d collector output poll: %d polls %.2fs first_stdout=[%s]', $round, $polls_used, time() - $t, $first_stdout ) );
    like( $first_stdout, qr/^\d+\.\d+\n$/, "round $round control: serve starts the tick collector so output appears" );

    # Price the two listener-query primitives the Windows readiness wait
    # pays per poll, before the restart runs.
    _time_netstat_listener_query($port);
    _time_powershell_no_listener_query( _find_free_port() );

    # The restart under test, with a heartbeat so a slow one stays
    # visible instead of tripping the watchdog mute.
    _log("round $round restart starting (t/05 line 797 equivalent)");
    my $restart = _restart_with_heartbeat( $home, $port );
    push @restart_elapsed, $restart->{elapsed};
    _log(
        sprintf(
            'round %d restart: %.2fs exit=%s timed_out=%s web_pid=%s stderr=[%s]',
            $round,
            $restart->{elapsed},
            defined $restart->{exit} ? $restart->{exit} : 'undef',
            $restart->{timed_out} ? 'yes' : 'no',
            $restart->{json} && $restart->{json}->{web_pid} ? $restart->{json}->{web_pid} : 'none',
            $restart->{stderr},
        )
    );
    ok( !$restart->{timed_out}, "round $round: restart returns within the 420 s cap" );
    my $web_pid = $restart->{json} ? $restart->{json}->{web_pid} : undef;
    ok( $web_pid && kill( 0, $web_pid ), "round $round: restart reports a live managed web pid" );
    my $ua       = LWP::UserAgent->new( timeout => 5 );
    my $response;
    $t = time();
    for ( 1 .. 160 ) {
        $response = $ua->get("http://127.0.0.1:$port/");
        last if $response->code;
        sleep 0.25;
    }
    _log( sprintf( 'round %d health probe: %.2fs code=%s', $round, time() - $t, $response ? $response->code : 'none' ) );
    ok( $response && $response->code, "round $round: restarted web listener is reachable on the port" );

    # Cleanup: stop the round's runtime so nothing lingers into the next round.
    $t = time();
    my ( undef, undef, $stop_exit ) = _run_in_home( $home, "$perl -I'$lib' '$dashboard' stop -o json" );
    _log( sprintf( 'round %d stop: %.2fs exit=%s', $round, time() - $t, $stop_exit ) );
}

_log( sprintf( 'summary: restart elapsed per round = %s', join( ', ', map { sprintf( '%.2fs', $_ ) } @restart_elapsed ) ) );

1;

__END__

=pod

=head1 NAME

t/997-micro-restart-silence.t - micro-probe for the Windows d2 restart silence trip in round 35

=head1 DESCRIPTION

Reproduces the exact t/05 serve/restart lifecycle sequence three times
(fresh serve home and fresh port each time) with a timestamp and elapsed
time on every log line, to prove whether the Windows `d2 restart` step
hangs or merely runs slow, and where the time goes.

=head1 PURPOSE

Round 35 (build #349) tripped the 180 s watchdog silence branch on the
Windows leg right after t/05 test 203 printed; the next step is
`d2 restart -o json` at t/05 line 797. The same restart completed on
Windows in solo #348, so the failure is intermittent or load-dependent,
and the console cannot distinguish a genuinely hung restart from a
legitimate-but-slow one that overran 180 s. This micro measures the
restart directly: three timed runs, a heartbeat every 15 s while each
restart is in flight, and timings for the two listener-query primitives
the Windows readiness wait pays per poll.

=head1 WHY IT EXISTS

A silence trip says only "nothing printed for 180 s". Without timing
evidence the parent cannot tell a hang (the web child never binds, the
ready wait burns its full 300-poll budget at ~4 s a poll through the
PowerShell fallback, the retry loop repeats it 20 times) from a slow
restart (a loaded box makes the web child bind late, so the ready wait
legitimately takes minutes). The fix differs completely between the two,
so the mechanism must be proven first, by the micro-repro method.

=head1 WHEN TO USE

Use this file only as a probe for the round 35 restart silence trip. It
is not a regression test: once the solo reports the three restart elapsed
times and the primitive costs, the parent decides the fix, and this file
is removed in the fix's cleanup commit.

=head1 HOW TO USE

Run it as a Jenkins solo (TEST_FILE=t/997-micro-restart-silence.t) on the
loop branch. Read the diag lines: each round logs init, serve, the
collector-output control poll, the netstat and PowerShell primitive
costs, the restart elapsed time with heartbeat lines while it runs, the
health probe, and stop. The summary line at the end lists the three
restart elapsed times. A restart that does not return within the 420 s
cap is killed and reported as timed out.

=head1 WHAT USES IT

Nothing in the product uses it. The Jenkins solo run uses it to produce
the timing evidence for the round 35 restart investigation.

=head1 EXAMPLES

  prove -lv t/997-micro-restart-silence.t

Run it locally (all three restarts should return in seconds on Unix).

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/997-micro-restart-silence.t 1

Run it as a Jenkins solo on all four platforms.

=cut
