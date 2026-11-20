use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(getcwd);
use Developer::Dashboard::Collector ();
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Developer::Dashboard::PerlEnv;
use Encode qw(decode encode);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $UNDER_COVER = exists $INC{'Devel/Cover.pm'};
my $repo = getcwd();

local $ENV{HOME} = tempdir( CLEANUP => 1 );
my @built_perl_libs = grep { -d $_ } map { File::Spec->catdir( $repo, 'blib', $_ ) } qw(arch lib);
local $ENV{PERL5LIB} = join Developer::Dashboard::PerlEnv::path_separator(), grep { defined $_ && $_ ne '' } ( @built_perl_libs, $ENV{PERL5LIB} || () );
local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
chdir $ENV{HOME} or die "Unable to chdir to $ENV{HOME}: $!";

my $IS_WINDOWS = $^O eq 'MSWin32';

# Bounds. A healthy `collector output` call is a single perl startup plus a
# few file slurps: well under a second even on the loaded Pi, and the t/05
# loop itself only waits 0.25s between calls. 30s per call is already
# pathological; the 180s watchdog is the hard ceiling, so the micro must
# report a hung call long before the watchdog can fire.
my $CALL_TIMEOUT_SECONDS = 30;
my $LOOP_MAX_ITERATIONS  = 160;    # exact t/05 shape (t/05 lines 788-795)
my $LOOP_SLEEP_SECONDS   = 0.25;   # exact t/05 shape
my $LOOP_BUDGET_SECONDS  = 150;    # stop the loop and report before the watchdog
my $SLOW_CALL_SECONDS    = 2;      # above this, run the control call for comparison

# _one_line($text)
# Truncates text to one short line for a diag, so a huge stdout cannot flood
# the log. Input: text string. Output: single line, at most 200 characters.
sub _one_line {
    my ($text) = @_;
    return '' if !defined $text;
    $text =~ s/\s+/ /g;
    return length($text) > 200 ? substr( $text, 0, 200 ) . '...' : $text;
}

# _slurp_file($path)
# Reads a whole file as bytes, or '' when it is missing. Input: path.
# Output: file contents string.
sub _slurp_file {
    my ($path) = @_;
    return '' if !defined $path || !-f $path;
    open my $fh, '<:raw', $path or return '';
    my $content = do { local $/; <$fh> };
    close $fh;
    return defined $content ? $content : '';
}

# _load_average()
# Returns the 1/5/15-minute load averages as one string, or 'n/a' when the
# platform cannot report them (no /proc/loadavg and no uptime output).
sub _load_average {
    if ( !$IS_WINDOWS && open my $fh, '<', '/proc/loadavg' ) {
        my $line = <$fh>;
        close $fh;
        return $1 if defined $line && $line =~ /\A([\d.]+ [\d.]+ [\d.]+)/;
    }
    if ( !$IS_WINDOWS ) {
        my $uptime = qx(uptime 2>/dev/null);
        return "$1 $2 $3"
          if defined $uptime && $uptime =~ /load averages?:\s*([\d.]+)[, ]+([\d.]+)[, ]+([\d.]+)/;
    }
    return 'n/a';
}

# _orphan_d2_count()
# Counts live processes whose command line looks like a Dashboard
# collector or web process (the same shape the round-45 parent check
# found: 28 on the Pi). Unix only: tasklist has no command lines, so
# Windows reports undef. The count is taken BEFORE this micro's own
# serve starts, so it is the pre-existing orphan load, not our own.
# Output: integer count, or undef when it cannot be measured.
sub _orphan_d2_count {
    return undef if $IS_WINDOWS;
    my $ps = qx(ps -eo args 2>/dev/null);
    return undef if !defined $ps || $ps eq '';
    my $count = 0;
    for my $line ( split /\n/, $ps ) {
        $count++ if $line =~ /d2\s+collector|d2\s+web|bin\/d2/;
    }
    return $count;
}

# _pid_alive($pid)
# Unix kill(0) liveness check. Returns 1/0, or undef on Windows where
# the micro does not probe pids. Input: pid integer.
sub _pid_alive {
    my ($pid) = @_;
    return undef if $IS_WINDOWS || !defined $pid || $pid !~ /^\d+$/;
    return kill( 0, $pid ) ? 1 : 0;
}

# _collector_stdout_state()
# Returns "size=<bytes> mtime=<epoch>" for the tick.collector stdout
# file under the current (serve) home, or 'missing' when the file is
# not there yet. Resolves through the product's own Collector API, so
# it sees the same state root the subprocesses see. This is the
# discriminator between "the collector stopped producing" (file frozen)
# and "the collector is alive but the CLI call hangs" (file advancing).
sub _collector_stdout_state {
    my $collector = eval { Developer::Dashboard::Collector->new_from_all_folders() };
    return 'collector API unavailable: ' . ( $@ || 'unknown' ) if !$collector;
    my $paths = eval { $collector->collector_paths('tick.collector') };
    return 'collector paths unavailable: ' . ( $@ || 'unknown' ) if !$paths || !$paths->{stdout};
    my $file = $paths->{stdout};
    my @stat = stat $file;
    return 'missing' if !@stat;
    return "size=$stat[7] mtime=$stat[9]";
}

# _find_free_port()
# Reserves a free local TCP port and releases it. Same shape as t/05.
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

# _run_bounded($home, $cmd, $timeout)
# Runs one d2 CLI command the way t/05's _run_in_home does (cd to $home,
# then the command string), but with a wall-clock bound and per-call
# timing, so a hung call is REPORTED instead of hanging the micro the
# way round 45 hung: t/05's _run only asserts after the call returns,
# so a call that never returns produces no test output at all until the
# watchdog kills the run at 180s.
# On Unix the call runs in a forked child (sh -c, stdout/stderr to temp
# files); the parent polls waitpid and on timeout sends TERM, waits 2s,
# then KILL, and reaps the child, so no hung child is left behind.
# On Windows there is no fork, so the call runs directly the way t/05
# does (Local::NativeCommand) and the pre-call HEARTBEAT diag is the
# pinpoint if it stalls; the stall is a Pi phenomenon and the Windows
# leg is a control that should pass fast.
# Input: home dir, command string, optional timeout in seconds.
# Output: hashref { stdout, exit_code (undef on timeout), timed_out,
# duration_seconds, kill_sequence }.
sub _run_bounded {
    my ( $home, $cmd, $timeout ) = @_;
    $timeout = $CALL_TIMEOUT_SECONDS if !defined $timeout;
    my $shell_cmd = "cd '$home' && $cmd";
    my $started   = time();
    if ($IS_WINDOWS) {
        my %env;
        if ( $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop)\b/ ) {
            $env{PERL5OPT}              = undef;
            $env{HARNESS_PERL_SWITCHES} = undef;
        }
        my ( $stdout, $stderr, $exit_code ) = run_shell_command( $shell_cmd, { env => \%env } );
        return {
            stdout           => decode( 'UTF-8', $stdout . $stderr ),
            exit_code        => $exit_code,
            timed_out        => 0,
            duration_seconds => time() - $started,
            kill_sequence    => 'n/a (direct run on Windows)',
        };
    }
    my ( undef, $out_file ) = tempfile( UNLINK => 0 );
    my ( undef, $err_file ) = tempfile( UNLINK => 0 );
    my $pid = fork();
    die "fork failed for bounded run: $!" if !defined $pid;
    if ( $pid == 0 ) {
        open STDOUT, '>', $out_file or POSIX::_exit(127);
        open STDERR, '>', $err_file or POSIX::_exit(127);
        chdir $home or POSIX::_exit(127);
        if ( $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop)\b/ ) {
            delete $ENV{PERL5OPT};
            delete $ENV{HARNESS_PERL_SWITCHES};
        }
        exec 'sh', '-c', $cmd or POSIX::_exit(127);
    }
    my $timed_out     = 0;
    my $kill_sequence = 'none';
    my $waited;
    while (1) {
        $waited = waitpid( $pid, WNOHANG );
        last if $waited == $pid || $waited == -1;
        if ( time() - $started > $timeout ) {
            $timed_out = 1;
            kill 'TERM', $pid;
            $kill_sequence = 'TERM sent';
            my $term_wait_until = time() + 2;
            while ( time() < $term_wait_until ) {
                $waited = waitpid( $pid, WNOHANG );
                last if $waited == $pid || $waited == -1;
                sleep 0.05;
            }
            if ( $waited != $pid && $waited != -1 ) {
                kill 'KILL', $pid;
                $kill_sequence = 'TERM sent, KILL sent';
                $waited = waitpid( $pid, 0 );
            }
            last;
        }
        sleep 0.05;
    }
    my $status = $?;
    my $stdout = _slurp_file($out_file);
    my $stderr = _slurp_file($err_file);
    unlink $out_file;
    unlink $err_file;
    return {
        stdout           => decode( 'UTF-8', $stdout . $stderr ),
        exit_code        => $timed_out ? undef : ( $status >> 8 ),
        timed_out        => $timed_out,
        duration_seconds => time() - $started,
        kill_sequence    => $kill_sequence,
    };
}

# _run_control()
# Runs a trivial perl startup with no d2 load, through the same bounded
# runner. This is the control that separates "perl startup itself is
# slow under load" from "d2 collector output specifically hangs": if a
# collector output call is slow or times out but the control right after
# it is fast, the hang is in the d2 command, not in starting perl.
# Output: the _run_bounded result hashref.
sub _run_control {
    my ($home) = @_;
    return _run_bounded( $home, "$perl -e 'print \"control-ok\\n\"'" );
}

# _describe_call($result)
# One-line summary of a bounded call result for a diag. Input: result
# hashref. Output: string.
sub _describe_call {
    my ($result) = @_;
    return 'duration='
      . sprintf( '%.3f', $result->{duration_seconds} )
      . ' timed_out=' . $result->{timed_out}
      . ' exit=' . ( defined $result->{exit_code} ? $result->{exit_code} : 'n/a' )
      . ' kill=' . $result->{kill_sequence};
}

# Phase 0: environment snapshot. The round-45 context says the Pi was
# heavily loaded (15-min load 7.36) with 28 orphaned d2 processes and
# the Jenkins agent flapping ~10 times; record the same numbers here so
# the solo's verdict can be read against them.
diag('HEARTBEAT: phase 0 environment snapshot starting');
my $load_start    = _load_average();
my $orphans_start = _orphan_d2_count();
diag( 'HEARTBEAT: phase 0 load=[' . $load_start . '] orphan_d2=[' . ( defined $orphans_start ? $orphans_start : 'n/a' ) . '] pid=' . $$ );
ok( 1, 'environment snapshot recorded: load=[' . $load_start . '] orphan_d2=[' . ( defined $orphans_start ? $orphans_start : 'n/a' ) . ']' );
diag('HEARTBEAT: phase 0 environment snapshot done');

diag('HEARTBEAT: phase 1 serve-home setup starting');
my $serve_home = tempdir( CLEANUP => 1 );
{
    local $ENV{HOME} = $serve_home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

    diag('HEARTBEAT: phase 1 init starting');
    my $init = _run_bounded( $serve_home, "$perl -I'$lib' '$dashboard' init" );
    diag( 'HEARTBEAT: phase 1 init done ' . _describe_call($init) );
    BAIL_OUT('d2 init failed, cannot probe the poll loop') if $init->{timed_out} || !defined $init->{exit_code} || $init->{exit_code} != 0;
    like( $init->{stdout}, qr/runtime_root/, 'isolated serve home initializes a runtime for the poll-loop probe' );

    diag('HEARTBEAT: phase 1 config write starting');
    my $serve_config_file = File::Spec->catfile( $serve_home, '.developer-dashboard', 'config', 'config.json' );
    open my $serve_config_fh, '>:raw', $serve_config_file or die "Unable to write $serve_config_file: $!";
    my $serve_config_json = json_encode(
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
    $serve_config_json = encode( 'UTF-8', $serve_config_json ) if utf8::is_utf8($serve_config_json);
    print {$serve_config_fh} $serve_config_json;
    close $serve_config_fh or die "Unable to close $serve_config_file: $!";
    diag('HEARTBEAT: phase 1 config written');

    my $serve_port = _find_free_port();
    diag( 'HEARTBEAT: phase 2 serve starting port=' . $serve_port );
    my $serve = _run_bounded( $serve_home, "$perl -I'$lib' '$dashboard' serve --host 127.0.0.1 --port $serve_port" );
    diag( 'HEARTBEAT: phase 2 serve done ' . _describe_call($serve) );
    my $serve_json = eval { json_decode( $serve->{stdout} ) };
    BAIL_OUT('d2 serve returned no pid, cannot probe the poll loop') if !$serve_json || !$serve_json->{pid};
    my $web_pid = $serve_json->{pid};
    ok( 1, 'd2 serve returns a managed web pid for the poll-loop probe' );
    diag( 'HEARTBEAT: phase 2 web pid=' . $web_pid . ' alive=' . ( defined _pid_alive($web_pid) ? _pid_alive($web_pid) : 'n/a' ) );

    diag('HEARTBEAT: phase 3 baseline control starting');
    my $baseline = _run_control($serve_home);
    diag( 'HEARTBEAT: phase 3 baseline control done ' . _describe_call($baseline) . ' stdout=[' . _one_line( $baseline->{stdout} ) . ']' );
    ok( !$baseline->{timed_out} && defined $baseline->{exit_code} && $baseline->{exit_code} == 0, 'baseline perl startup completes (control for the poll loop)' );

    # Phase 4: the exact call that was t/05 test 200 in round 45, the
    # last call that returned before the leg went silent.
    diag('HEARTBEAT: phase 4 first collector output starting');
    my $first_call = _run_bounded( $serve_home, "$perl -I'$lib' '$dashboard' collector output tick.collector" );
    diag( 'HEARTBEAT: phase 4 first collector output done ' . _describe_call($first_call) . ' stdout=[' . _one_line( $first_call->{stdout} ) . ']' );
    my $stall_before_loop = '';
    if ( $first_call->{timed_out} ) {
        $stall_before_loop
          = 'first collector output call timed out after ' . sprintf( '%.3f', $first_call->{duration_seconds} ) . 's'
          . ' kill=' . $first_call->{kill_sequence}
          . ' web_alive=' . ( defined _pid_alive($web_pid) ? _pid_alive($web_pid) : 'n/a' )
          . ' stdout_file=[' . _collector_stdout_state() . ']'
          . ' load=[' . _load_average() . ']';
        diag( 'HEARTBEAT: phase 4 STALL ' . $stall_before_loop );
        diag('HEARTBEAT: phase 4 control call after stall starting');
        my $control = _run_control($serve_home);
        diag( 'HEARTBEAT: phase 4 control after stall done ' . _describe_call($control) . ' stdout=[' . _one_line( $control->{stdout} ) . ']' );
    }
    ok( !$first_call->{timed_out} && defined $first_call->{exit_code} && $first_call->{exit_code} == 0,
        'first collector output call returns (t/05 test 200 in round 45)' );

    # Phase 5: the poll loop, exact t/05 shape (lines 788-795): up to 160
    # iterations of `collector output`, 0.25s between, exit when stdout
    # matches a changing timestamp. Every iteration logs before and after
    # the call, with the call duration and the collector stdout file
    # state on both sides, so the log shows exactly which call stalls
    # and whether the collector was still producing while it did.
    my $first_stdout      = '';
    my $loop_started      = time();
    my $iterations_run    = 0;
    my $timed_out_calls   = 0;
    my $slow_calls        = 0;
    my $max_call_seconds  = 0;
    my $stall_iteration   = 0;
    my $stall_detail      = $stall_before_loop;
    my $loop_budget_hit   = 0;
    diag( 'HEARTBEAT: phase 5 poll loop starting stdout file before loop: [' . _collector_stdout_state() . ']' );
    if ( $stall_before_loop eq '' ) {
        for my $iteration ( 1 .. $LOOP_MAX_ITERATIONS ) {
            $iterations_run = $iteration;
            diag( 'HEARTBEAT: phase 5 iteration=' . $iteration . ' loop_elapsed=' . sprintf( '%.2f', time() - $loop_started ) . ' load=[' . _load_average() . ']' );
            my $file_before = _collector_stdout_state();
            diag( 'HEARTBEAT: phase 5 iteration=' . $iteration . ' stdout file before call: [' . $file_before . ']' );
            diag( 'HEARTBEAT: phase 5 iteration=' . $iteration . ' collector output call starting' );
            my $call = _run_bounded( $serve_home, "$perl -I'$lib' '$dashboard' collector output tick.collector" );
            my $file_after = _collector_stdout_state();
            diag( 'HEARTBEAT: phase 5 iteration=' . $iteration . ' call done ' . _describe_call($call) . ' stdout file after call: [' . $file_after . ']' );
            $max_call_seconds = $call->{duration_seconds} if $call->{duration_seconds} > $max_call_seconds;
            if ( $call->{timed_out} ) {
                $timed_out_calls++;
                $stall_iteration = $iteration;
                $stall_detail
                  = 'iteration=' . $iteration
                  . ' duration=' . sprintf( '%.3f', $call->{duration_seconds} ) . 's'
                  . ' kill=' . $call->{kill_sequence}
                  . ' web_alive=' . ( defined _pid_alive($web_pid) ? _pid_alive($web_pid) : 'n/a' )
                  . ' file_before=[' . $file_before . '] file_after=[' . $file_after . ']'
                  . ' load=[' . _load_average() . ']'
                  . ' orphan_d2=[' . ( defined _orphan_d2_count() ? _orphan_d2_count() : 'n/a' ) . ']';
                diag( 'HEARTBEAT: phase 5 STALL ' . $stall_detail );
                diag('HEARTBEAT: phase 5 control call after stall starting');
                my $control = _run_control($serve_home);
                diag( 'HEARTBEAT: phase 5 control after stall done ' . _describe_call($control) . ' stdout=[' . _one_line( $control->{stdout} ) . ']' );
                last;
            }
            if ( $call->{duration_seconds} > $SLOW_CALL_SECONDS ) {
                $slow_calls++;
                diag( 'HEARTBEAT: phase 5 slow call iteration=' . $iteration . ', running control for comparison' );
                my $control = _run_control($serve_home);
                diag( 'HEARTBEAT: phase 5 control after slow call done ' . _describe_call($control) . ' stdout=[' . _one_line( $control->{stdout} ) . ']' );
            }
            my $output = eval { json_decode( $call->{stdout} ) };
            if ( !$output ) {
                diag( 'HEARTBEAT: phase 5 iteration=' . $iteration . ' collector output was not JSON: [' . _one_line( $call->{stdout} ) . ']' );
                $first_stdout = '';
            }
            else {
                $first_stdout = $output->{stdout} || '';
            }
            diag( 'HEARTBEAT: phase 5 iteration=' . $iteration . ' stdout matches=' . ( $first_stdout =~ /^\d+\.\d+\n$/ ? 'yes' : 'no' ) );
            last if $first_stdout =~ /^\d+\.\d+\n$/;
            if ( time() - $loop_started > $LOOP_BUDGET_SECONDS ) {
                $loop_budget_hit = 1;
                diag('HEARTBEAT: phase 5 loop budget reached, stopping');
                last;
            }
            sleep $LOOP_SLEEP_SECONDS;
        }
    }
    diag( 'HEARTBEAT: phase 5 poll loop done iterations=' . $iterations_run . ' timed_out_calls=' . $timed_out_calls . ' slow_calls=' . $slow_calls . ' max_call_seconds=' . sprintf( '%.3f', $max_call_seconds ) . ' budget_hit=' . $loop_budget_hit );
    my $loop_matched = $first_stdout =~ /^\d+\.\d+\n$/ ? 1 : 0;
    ok( $loop_matched && $timed_out_calls == 0,
        'collector output poll loop reaches a changing timestamp with no call timing out'
          . ( $timed_out_calls ? ' (STALL REPRODUCED: ' . $stall_detail . ')' : '' )
          . ( !$loop_matched && !$timed_out_calls ? ' (output never appeared within ' . $iterations_run . ' iterations; max call ' . sprintf( '%.3f', $max_call_seconds ) . 's)' : '' ) );

    # Phase 6: stop the serve this probe started, so the micro leaves no
    # new orphan behind on the Pi. A stop that itself times out is more
    # evidence, recorded in the diag, not hidden.
    diag('HEARTBEAT: phase 6 serve stop starting');
    my $stop = _run_bounded( $serve_home, "$perl -I'$lib' '$dashboard' stop -o json" );
    diag( 'HEARTBEAT: phase 6 serve stop done ' . _describe_call($stop) . ' web_alive_after=' . ( defined _pid_alive($web_pid) ? _pid_alive($web_pid) : 'n/a' ) );
    ok( !$stop->{timed_out} && defined $stop->{exit_code} && $stop->{exit_code} == 0, 'probe serve stops cleanly (no new orphan left behind)' );
    diag('HEARTBEAT: phase 6 done');
}

done_testing();

__END__

=head1 NAME

t/997-micro-t05-collector-output-poll-stall.t - probe the ARM64 t/05 poll-loop stall behind the round-45 silence trip

=head1 DESCRIPTION

A minimal reproduction of the serve/collector lifecycle smoke section of
t/05 (lines 756-795): init a home, configure one interval collector
(tick.collector, 1s), start d2 serve, then run the exact poll loop that
waits for the collector output to start changing. Every collector
output call runs through a wall-clock-bounded runner (30s) with a
HEARTBEAT diag before and after it, plus the collector stdout file
state on both sides and a bare-perl control call whenever a call is
slow or times out, so the log shows exactly which call stalls and
whether the collector was still producing while it did.

=head1 PURPOSE

Round 45 failed on an ARM64 watchdog silence trip: no test output for
3 minutes in t/05, zero not-ok lines. The ARM64 leg's own prove-out.log
ends at t/05 test 200 (the first `collector output` call returning);
the stall is inside the first poll loop (t/05 lines 788-795), where a
later `collector output` subprocess produced nothing for 3+ minutes.
t/05's _run only asserts after the call returns, so a call that never
returns produces no test output at all until the watchdog kills the
run, and the merged console even points at the wrong file (the t/21
lines just before the trip are the macOS leg's). This micro must pin
down, before any fix is chosen: does a `collector output` call hang
(the round-45 silence-trip signature), does it return promptly while
the output never changes (the round-25 signature, same loop, "output
never appeared within 160 polls"), or does the loop pass (the stall
was load or agent flapping, not the code)? It must also separate "perl
startup itself is slow under load" from "d2 collector output
specifically hangs", and "the collector stopped producing" from "the
collector is alive but the CLI call hangs".

=head1 WHY IT EXISTS

A hand probe cannot answer this: the stall needs the serve running,
the supervisor ticking, and the Pi under the same load, all at once,
and the evidence has to come from the same run on all four legs. The
round-45 monitor read the ARM64 prove-out.log by SSH and the Pi's load
(15-min 7.36) and orphan count (28 d2 processes) after the fact, but
none of that says which call hung, how long each call took, whether
the collector kept writing while the call hung, or whether a bare perl
startup was equally slow at the same moment. Without those numbers the
fix choice (bound the call, fix the supervisor, or treat it as a
loaded-Pi flake and re-run) would be a guess, and the same test area
has already produced two different signatures (round 25 assertion,
round 45 silence trip).

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/997-micro-t05-collector-output-poll-stall.t)
to prove the stall mechanism on all four legs. Remove it in a cleanup
commit once the investigation ends, like every other micro. Never run
it by hand against a live box for a verdict: the solo is the evidence.

=head1 HOW TO USE

No setup: the micro snapshots the load and the pre-existing orphan d2
process count, builds an isolated serve home with one 1s interval
collector, starts serve, runs a baseline bare-perl control, runs the
first collector output call, then runs the exact t/05 poll loop with
per-call timing. The OUTCOME is in the HEARTBEAT diag lines: the
duration of every call, the collector stdout file size/mtime before
and after each call, the control-call comparison after any slow or
timed-out call, and the load and orphan count at any stall. The
assertions are the verdict: the loop must reach a changing timestamp
with no call timing out. A timeout is a FAILING micro with the stall
evidence in the log (the round-45 signature reproduced); a loop that
runs all 160 iterations without a match is a FAILING micro with the
round-25 signature; a pass means the stall did not reproduce under
these conditions. The micro stops its own serve at the end so it
leaves no new orphan behind; it never touches the pre-existing
orphans.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a probe for the testing-v1
loop, written for round 45, and is removed once the stall is understood.
The Jenkins solo runner is the only caller.

=head1 EXAMPLES

On a leg where the loop is healthy the file passes with seven
assertions and the HEARTBEAT lines show sub-second calls, for example
"phase 5 iteration=3 call done duration=0.214 timed_out=0 exit=0
kill=none stdout file after call: [size=27 mtime=1795179000]". On a
reproduced stall it fails the loop verdict with the stall in the test
name, for example "STALL REPRODUCED: iteration=2 duration=30.000s
kill=TERM sent, KILL sent web_alive=1 file_before=[size=27
mtime=1795179000] file_after=[size=27 mtime=1795179000]
load=[1.10 3.65 7.36] orphan_d2=[28]", plus a control call right
after it: if the control is fast while collector output hung, the
hang is in the d2 command, not in starting perl; if the stdout file
is frozen too, the collector itself stopped producing.

=cut
