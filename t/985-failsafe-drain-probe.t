#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);
use Test::More;
use Time::HiRes qw(sleep time);

# failsafe.pl is the Unix watchdog; Windows runs failsafe.ps1 instead,
# and the nested watchdog's process-group kill has no Windows meaning.
# The anomaly under investigation happened on a Unix leg (amd64), and
# the code under test only runs on Unix legs. The Windows leg passes
# vacuously rather than skip_all: a skip-only run exits NOTESTS, and
# the Windows watchdog treats an unreadable prove exit code as a
# failure, which would fail this solo's Windows leg for no reason.
if ( $^O eq 'MSWin32' ) {
    plan tests => 1;
    # Sleep longer than the Unix legs' slow case (~45s): the Windows
    # watchdog reports "prove exit code unreadable" and fails the
    # branch even when prove passes, and that failure fires failFast
    # interrupts at the Unix legs. Sleeping here keeps the Windows
    # failure until after the Unix measurements are done.
    diag('micro: Windows leg sleeping 60s so the Unix slow cases finish first');
    Time::HiRes::sleep(60);
    ok( 1, 'micro: failsafe.pl is the Unix watchdog; nothing to measure on Windows' );
    exit 0;
}

plan tests => 11;

# The nested watchdog is the real pipeline-written failsafe.pl, in the
# test's working directory (the pipeline writes it into dd-source).
my $WATCHDOG = File::Spec->catfile( File::Spec->curdir(), 'failsafe.pl' );
ok( -f $WATCHDOG, 'micro: the pipeline-written failsafe.pl is present' )
    or BAIL_OUT('no failsafe.pl in the working directory');

my $tmp = tempdir( CLEANUP => 1 );

# _write_producer($path)
# A prove-shaped producer: it writes the round-30 t/712 failure block
# verbatim first (the exact lines the amd64 watchdog read in build
# #296), then $COUNT "ok" lines at $RATE lines per second, then exits 0.
# 100 lines/sec is prove's verbose rate through t/72+t/73 in #296; 500
# lines is 5 seconds of post-failure output, more than the two files
# that ran on after the failure there.
my $producer = File::Spec->catfile( $tmp, 'producer.pl' );
{
    open my $fh, '>', $producer or die "cannot write $producer: $!\n";
    print {$fh} <<'PRODUCER' or die "cannot write $producer: $!\n";
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes qw(sleep);
$| = 1;
my ( $count, $rate ) = @ARGV;
$count //= 500;
$rate  //= 100;
print "not ok 24 - _find_running_loop returns a title match from the same pid namespace\n";
print "\n";
print "#   Failed test '_find_running_loop returns a title match from the same pid namespace'\n";
print "#   at t/712-collectorrunner-coverage.t line 261.\n";
print "not ok 25 - _find_running_loop skips a title match from another pid namespace\n";
print "\n";
print "#   Failed test '_find_running_loop skips a title match from another pid namespace'\n";
print "#   at t/712-collectorrunner-coverage.t line 262.\n";
print "#          got: '22'\n";
print "#     expected: '2'\n";
print "1..25\n";
print "# Looks like you failed 2 tests of 25.\n";
print "Dubious, test returned 2 (wstat 512, 0x200)\n";
print "Failed 2/25 subtests \n";
print "t/72-pagedocument-coverage.t ........................... \n";
for my $i ( 1 .. $count ) {
    print "ok $i - probe line $i\n";
    sleep( 1 / $rate );
}
exit 0;
PRODUCER
    close $fh or die "cannot close $producer: $!\n";
}

# _write_fixed_watchdog($path)
# Writes the proposed fix for failsafe.pl: the $failed check moves
# INSIDE the inner read loop (break out the moment a failure line is
# seen, instead of waiting for the loop to drain to EOF), and the kill
# moves BEFORE the trailing drain (the drain used to run first, and it
# waits for EOF the same way, so on its own the in-loop check would
# only move the starvation from the main loop into the drain). This
# text is byte-identical to the fix reported to the loop owner; it is
# validated here in the micro only and is NOT applied to the job
# config by this file.
my $fixed_watchdog = File::Spec->catfile( $tmp, 'failsafe-fixed.pl' );
{
    open my $fh, '>', $fixed_watchdog or die "cannot write $fixed_watchdog: $!\n";
    print {$fh} <<'FIXED' or die "cannot write $fixed_watchdog: $!\n";
#!/usr/bin/env perl
# failsafe.pl - prove under a watchdog. Usage: perl failsafe.pl <logfile> <command...>
# Exit 1 on the first failure (fail-safe trip) or if the command fails; 0 only
# when the command passes cleanly.
use strict;
use warnings;
use POSIX qw(:sys_wait_h);

my $log = shift @ARGV or die "usage: failsafe.pl <logfile> <command...>\n";
die "no command given\n" unless @ARGV;

open my $touch, '>', $log or die "cannot create $log: $!\n";
close $touch;

my $pid = fork();
die "fork failed: $!\n" unless defined $pid;

if ($pid == 0) {
    POSIX::setsid() or die "setsid failed: $!\n";
    open STDOUT, '>>', $log or die "cannot write $log: $!\n";
    open STDERR, '>&STDOUT' or die "cannot dup stderr: $!\n";
    $| = 1;
    exec @ARGV or die "exec failed: $!\n";
}

$| = 1;
open my $fh, '<', $log or die "cannot read $log: $!\n";
my $failed = 0;
my $status;
# Per-test timeout (Michael, 17 Nov 2026): prove runs verbose, so every
# completed subtest prints a line. A test that produces no output for this
# long is stuck: kill it and treat it as a failure, not a wait.
# INITIAL_GRACE: the 3 minutes is the gap BETWEEN lines. Before the first
# line, allow 5 minutes (tightened from 10 after build #66 measured the
# first line at ~17s on all four legs).
my $SILENCE_TIMEOUT = 180;
my $INITIAL_GRACE = 300;
my $last_output = time();
my $seen_output = 0;
for (;;) {
    while (defined(my $line = <$fh>)) {
        print $line;
        $last_output = time();
        $seen_output = 1;
        if ($line =~ /Failed test|Dubious, test returned|Looks like your test exited/) {
            $failed = 1;
            # Fail fast: break out of the read loop the moment a failure
            # line is seen. The check used to run only after this loop
            # drained to EOF, so when the consumer (the Jenkins console)
            # was slower than prove's output the watchdog fell behind
            # the log's growing end and never reached EOF - round 30
            # ran two more test files after the failure before tripping.
            last;
        }
    }
    last if $failed;
    my $w = waitpid($pid, WNOHANG);
    if ($w == $pid) {
        $status = $?;
        last;
    }
    my $limit = $seen_output ? $SILENCE_TIMEOUT : $INITIAL_GRACE;
    if (time() - $last_output > $limit) {
        kill 'TERM', -$pid;
        sleep 2;
        kill 'KILL', -$pid;
        waitpid($pid, 0);
        if ($seen_output) {
            print "FAIL-SAFE: no test output for 3 minutes - treating the current test as stuck\n";
        } else {
            print "FAIL-SAFE: no test output for 5 minutes - treating the startup as stuck\n";
        }
        exit 1;
    }
    sleep 1;
    seek($fh, 0, 1);
}
if ($failed) {
    # Kill the run BEFORE draining the rest of the log for the record.
    # The drain used to run first, and it waits for EOF the same way,
    # so without this the in-loop check above would only move the
    # starvation from the main loop into the drain.
    kill 'TERM', -$pid;
    sleep 2;
    kill 'KILL', -$pid;
    waitpid($pid, 0);
    print "FAIL-SAFE: first test failure detected, terminating the run\n";
}
while (defined(my $line = <$fh>)) {
    print $line;
    if ($line =~ /Failed test|Dubious, test returned|Looks like your test exited/) {
        $failed = 1;
    }
}
close $fh;

if ($failed) {
    exit 1;
}
exit($status >> 8);
FIXED
    close $fh or die "cannot close $fixed_watchdog: $!\n";
}

# _wait_exit($pid, $timeout_s)
# Polls waitpid until $pid exits or $timeout_s passes. Returns the raw
# wait status, or undef on timeout (the caller then kills and fails).
# Logs progress every 10s so the outer watchdog never sees silence.
sub _wait_exit {
    my ( $pid, $timeout_s ) = @_;
    my $deadline = time() + $timeout_s;
    my $last_note = time();
    while ( time() < $deadline ) {
        my $w = waitpid( $pid, WNOHANG );
        return $? if $w == $pid;
        if ( time() - $last_note >= 10 ) {
            diag("waiting for pid=$pid to exit");
            $last_note = time();
        }
        sleep(0.05);
    }
    return undef;
}

# _run_watchdog($tag, $mode, $pcount, $prate, $watchdog)
# Spawns a failsafe.pl ($watchdog: the real pipeline-written one, or a
# fixed copy for the validation case) against the producer and measures
# how long after the failure block it takes to trip. $mode is 'fast'
# (watchdog stdout to a file: a consumer that never blocks) or 'slow'
# (watchdog stdout to a pipe drained at 20 lines/sec: a slow consumer,
# the Jenkins console's shape). $pcount/$prate are the producer's line
# count and lines-per-second. Returns ($exit_code, $latency_s,
# $output_text). Logs before and after every step, per the micro-repro
# method.
sub _run_watchdog {
    my ( $tag, $mode, $pcount, $prate, $watchdog ) = @_;
    $watchdog //= $WATCHDOG;
    diag("[$tag] start: mode=$mode");
    my $log    = File::Spec->catfile( $tmp, "$tag.log" );
    my $out    = File::Spec->catfile( $tmp, "$tag.out" );
    my $reader_pid;
    my ( $rd, $wr );

    if ( $mode eq 'slow' ) {
        diag("[$tag] before pipe");
        pipe( $rd, $wr ) or die "pipe failed: $!\n";
        diag("[$tag] after pipe");
        # Shrink the pipe so the slow reader throttles the watchdog
        # quickly. Linux only; macOS has no F_SETPIPE_SZ and its 16KB
        # default still fills: the slow producer writes 800 lines
        # (~19KB) in under a second, more than either pipe holds.
        # The pipe size is read back and logged: v2 showed a 4KB pipe
        # never fills when the backlog is smaller than the pipe, so the
        # backlog must exceed the pipe for the throttle to bite.
        if ( $^O eq 'linux' ) {
            diag("[$tag] before F_SETPIPE_SZ");
            my $set = eval {
                require Fcntl;
                my $cmd = Fcntl::F_SETPIPE_SZ();
                fcntl( $wr, $cmd, 4096 ) or die "fcntl failed: $!\n";
                1;
            };
            diag( "[$tag] after F_SETPIPE_SZ: " . ( $set ? '4096 bytes' : "left default ($@)" ) );
            my $size = eval {
                require Fcntl;
                my $get = Fcntl::F_GETPIPE_SZ();
                fcntl( $wr, $get, 0 );
            };
            diag( "[$tag] pipe size read back: " . ( defined $size ? "$size bytes" : "unknown ($@)" ) );
        }
        diag("[$tag] before fork reader");
        $reader_pid = fork();
        die "fork reader failed: $!\n" unless defined $reader_pid;
        if ( $reader_pid == 0 ) {
            close $wr or POSIX::_exit(1);
            open my $out_fh, '>', $out or POSIX::_exit(1);
            # Autoflush: if this reader is killed, what it already read
            # must already be in the file, not stuck in stdio.
            my $old_select = select($out_fh);
            $| = 1;
            select($old_select);
            print STDERR "[$tag-reader] started pid=$$\n";
            my $n = 0;
            while ( defined( my $line = <$rd> ) ) {
                $n++;
                print {$out_fh} $line or POSIX::_exit(1);
                print STDERR "[$tag-reader] line $n\n" if $n % 50 == 1;
                Time::HiRes::sleep(0.05);    # 20 lines/sec: the slow consumer
            }
            print STDERR "[$tag-reader] EOF after $n lines\n";
            close $out_fh or POSIX::_exit(1);
            POSIX::_exit(0);
        }
        diag("[$tag] after fork reader pid=$reader_pid");
        close $rd or die "cannot close pipe read end: $!\n";
    }

    diag("[$tag] before fork watchdog");
    my $t0   = time();
    my $wpid = fork();
    die "fork watchdog failed: $!\n" unless defined $wpid;
    if ( $wpid == 0 ) {
        if ( $mode eq 'fast' ) {
            open STDOUT, '>', $out or POSIX::_exit(1);
        }
        else {
            open STDOUT, '>&', $wr or POSIX::_exit(1);
            close $wr or POSIX::_exit(1);
        }
        open STDERR, '>&STDOUT' or POSIX::_exit(1);
        exec( $^X, $watchdog, $log, $^X, $producer, $pcount, $prate )
            or POSIX::_exit(1);
    }
    diag("[$tag] after fork watchdog pid=$wpid");
    close $wr or die "cannot close pipe write end: $!\n" if $mode eq 'slow';

    diag("[$tag] before wait for watchdog exit");
    my $status = _wait_exit( $wpid, 120 );
    my $t1     = time();
    if ( !defined $status ) {
        diag("[$tag] WATCHDOG DID NOT EXIT in 120s; killing pid=$wpid");
        kill 'TERM', $wpid;
        sleep 2;
        kill 'KILL', $wpid;
        _wait_exit( $wpid, 10 );
    }
    diag("[$tag] after wait for watchdog exit");
    my $latency = $t1 - $t0;
    # A signal death is not an exit code: $? >> 8 reads 0 for it, which
    # would masquerade as a clean exit. Report the signal instead.
    my $exit = !defined $status ? -1 : ( $status & 127 ) ? ( 'signal ' . ( $status & 127 ) ) : ( $status >> 8 );
    diag("[$tag] watchdog exit=$exit latency=${latency}s");

    if ( $mode eq 'slow' ) {
        diag("[$tag] before wait for reader drain");
        my $rstatus = _wait_exit( $reader_pid, 60 );
        if ( !defined $rstatus ) {
            diag("[$tag] reader did not drain in 60s; killing pid=$reader_pid");
            kill 'TERM', $reader_pid;
            sleep 1;
            kill 'KILL', $reader_pid;
            _wait_exit( $reader_pid, 10 );
        }
        diag("[$tag] after wait for reader drain");
    }

    diag("[$tag] before slurp output");
    open my $out_fh, '<', $out or die "cannot read $out: $!\n";
    local $/;
    my $text = <$out_fh>;
    close $out_fh or die "cannot close $out: $!\n";
    $text //= '';
    my @lines = split /\n/, $text, -1;
    my ($trip_at) = grep { $lines[$_] =~ /FAIL-SAFE: first test failure detected/ } 0 .. $#lines;
    my $before_trip = defined $trip_at ? $trip_at : scalar(@lines);
    diag("[$tag] after slurp output: lines=" . scalar(@lines) . " lines-before-trip=$before_trip");
    return ( $exit, $latency, $text, $before_trip );
}

# Case 1: fast consumer. The read loop drains to EOF in the first gap
# after the failure block, so the watchdog must trip promptly. If this
# trips late, the continuous-stream starvation theory is the mechanism
# and the consumer speed is irrelevant.
diag('[fast] case 1: fast consumer (watchdog stdout to a file)');
my ( $fast_exit, $fast_latency, $fast_text, $fast_before ) = _run_watchdog( 'fast', 'fast', '500', '100' );
diag("[fast] exit=$fast_exit latency=${fast_latency}s lines-before-trip=$fast_before");
is( $fast_exit, 1, 'micro: fast consumer: watchdog trips (exit 1)' );
like( $fast_text, qr/FAIL-SAFE: first test failure detected/,
    'micro: fast consumer: trip message printed' );
# Exit latency includes the trip path's 2s TERM grace, so detection is
# roughly latency minus 2s: ~1s here, one sleep cycle after the failure.
cmp_ok( $fast_latency, '<', 5, 'micro: fast consumer: trips within 5s of the failure' );

# Case 2: slow consumer. The producer writes its 800 lines at
# 1000/sec, so the whole post-failure backlog (~19KB) lands in the log
# inside a second - far more than the 4KB Linux pipe and the 16KB
# macOS pipe hold - and the watchdog can only drain it as fast as the
# slow reader lets it print. v2 used 100/sec: the backlog then was
# ~2.6KB, smaller than the pipe, so the watchdog drained it before
# the pipe could ever fill and the throttle never bit. v3 used 500
# lines at 1000/sec (~12KB): enough to throttle Linux, but macOS's
# 16KB pipe still held the whole backlog and tripped promptly.
diag('[slow] case 2: slow consumer (watchdog stdout to a pipe drained at 20 lines/sec)');
my ( $slow_exit, $slow_latency, $slow_text, $slow_before ) = _run_watchdog( 'slow', 'slow', '800', '1000' );
diag("[slow] exit=$slow_exit latency=${slow_latency}s lines-before-trip=$slow_before");
is( $slow_exit, 1, 'micro: slow consumer: watchdog trips (exit 1)' );
like( $slow_text, qr/FAIL-SAFE: first test failure detected/,
    'micro: slow consumer: trip message printed' );
cmp_ok( $slow_latency, '>', 12, 'micro: slow consumer: trips only after 12s (late, like build #296)' );
cmp_ok( $slow_latency, '>', 3 * $fast_latency,
    'micro: slow consumer: trip is at least 3x the fast-consumer trip' );

# Case 3: the fix, validated in the micro only. The fixed copy of
# failsafe.pl (written above, byte-identical to the fix text reported
# to the loop owner) runs under the SAME slow consumer as case 2. If
# it trips promptly, the fix works and the parent can apply the text
# to the job config with the evidence in hand. Nothing here touches
# the job config or the pipeline-written failsafe.pl.
diag('[fixed] case 3: fixed watchdog under the slow consumer');
my ( $fixed_exit, $fixed_latency, $fixed_text, $fixed_before ) =
    _run_watchdog( 'fixed', 'slow', '800', '1000', $fixed_watchdog );
diag("[fixed] exit=$fixed_exit latency=${fixed_latency}s lines-before-trip=$fixed_before");
is( $fixed_exit, 1, 'micro: fixed watchdog: trips (exit 1)' );
like( $fixed_text, qr/FAIL-SAFE: first test failure detected/,
    'micro: fixed watchdog: trip message printed' );
cmp_ok( $fixed_latency, '<', 5, 'micro: fixed watchdog: trips within 5s of the failure' );

__END__

=head1 NAME

t/985-failsafe-drain-probe.t - micro-repro for the failsafe.pl non-trip in round 30 (build #296)

=head1 DESCRIPTION

A diagnostic micro that runs the real pipeline-written failsafe.pl
against a prove-shaped producer and measures how long after a failure
block the watchdog takes to trip, under a fast consumer and under a
slow consumer.

=head1 PURPOSE

This micro proves, on Jenkins, why the Unix watchdog did not trip on
the t/712 failure in round 30: whether the $failed check is starved by
a continuously-producing prove stream (the suspected mechanism) or by
the watchdog's own print to a slow consumer (the Jenkins console).
It runs the same producer twice - once with the watchdog's stdout to
a file that never blocks, once with it to a pipe drained at 20
lines/sec - and measures the trip latency in each case. A prompt trip
with the fast consumer and a late trip with the slow one proves the
consumer speed governs the check; a late trip in both proves the
stream itself starves it.

=head1 WHY IT EXISTS

Round 30, build #296, failed on exactly one genuine failure: amd64
t/712-collectorrunner-coverage.t tests 24-25. The amd64 leg ran on
through t/72 and t/73 after the first failure before the watchdog
tripped at console line 29063 - the fail-fast did not happen, although
the build still ended FAILURE. The '# Failed test' lines do match the
watchdog regex, and the watchdog printed them (console lines
28821/28825), so it read them and set $failed - but the 'last if
$failed' check only runs after the inner read loop drains to EOF.
Whether that drain is starved by prove's output or by the watchdog's
own print to Jenkins cannot be decided by reading the code alone:
the micro measures the trip latency under both consumers so the fix
lands in the right place.

=head1 WHEN TO USE

Use this file only while investigating the round-30 failsafe.pl
non-trip. It is a throwaway micro: remove it from the branch in a
cleanup commit once the mechanism is proven and the fix is reported.
Do not extend it into a permanent test; the permanent coverage of
the watchdog belongs in a dedicated watchdog test, not here.

=head1 HOW TO USE

Run it as a Jenkins solo on the loop branch:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/985-failsafe-drain-probe.t 1

The Windows leg sleeps 60s and passes vacuously: the Windows
watchdog reports "prove exit code unreadable" and fails the branch
even when prove passes, and that failure would fire failFast
interrupts at the Unix legs while they are still measuring the slow
case. Sleeping keeps the Windows failure until after the Unix
measurements are done.

The checks are hermetic: the producer and the nested watchdog run in
a throwaway tempdir, the producer exits on its own after 500 lines
so no process can be left behind, and the nested watchdog is always
reaped with a 120s timeout. The nested watchdog is the real
pipeline-written failsafe.pl from the working directory, not a copy,
so the measurement is of the live code. Unix legs only for the two cases:
Windows passes vacuously, because failsafe.pl is the Unix watchdog
and Windows runs failsafe.ps1 instead (and a skip-only run would fail
the Windows leg in the Windows watchdog).

=head1 WHAT USES IT

Nothing uses this file. It is a diagnostic micro for the failsafe
anomaly #2 probe, read by the probe agent and the loop owner only.

=head1 EXAMPLES

Run the solo and read the measured latencies from the diagnostics:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/985-failsafe-drain-probe.t 1

Fast consumer trips in under 5s and slow consumer trips only after
12s: the consumer speed governs the check, and the fix is to check
$failed inside the inner read loop instead of only after it drains
to EOF, with the kill moved before the trailing drain. Both trip late:
the continuous stream itself starves the check, and the same fix
still applies - the check must not wait for EOF at all. Case 3 runs
the fixed copy under the same slow consumer: it trips in under 5s,
which is the evidence the fix works before it is applied to the job
config.
