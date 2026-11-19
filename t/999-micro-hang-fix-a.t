# t/999-micro-hang-fix-a.t — MICRO, DO NOT SHIP. Tests candidate fix (a)
# for the t/17 Windows post-plan hang: a watchdog as a separate process.
#
# Shape (extends t/999-micro-hang-repro.t, whose mechanism solo #181
# proved): the frontend spawns the backend with no stdio options AND
# spawns a small watcher perl holding both pids. The watcher polls the
# frontend pid every 0.25s (bounded at 120s); when the frontend is gone
# it kills the backend and exits. The test kills the frontend with
# GoRoutine::terminate_process — SIGTERM on POSIX, TerminateProcess on
# Windows — and measures whether the backend is dead afterwards and
# whether the watcher itself exited (a lingering watcher would hold
# prove's pipes just as the backend did).
#
# Expected outcome, by design: backend dead (alive=0) on ALL legs — on
# POSIX the TERM handler stops it, on Windows the watcher kills it — and
# prove finishes in seconds (read the wallclock from the Jenkins console:
# the repro took 61s on Windows, this must be ~seconds). The watcher
# never dies on the kill: the backend may already be dead (POSIX TERM
# handler got there first), so the kill is eval-wrapped.
use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);

diag '[' . time() . '] micro-hang-fix-a: start';
my $have_xs = eval {
    require Developer::Dashboard::GoRoutine;
    1;
};
# Require-only, on purpose: a runtime no-args import() after File::Temp is
# loaded dies with "Out of memory in perl:util:safesysrealloc" (proven 10/10
# on macOS, and it segfaults non-deterministically on ARM64). t/17 loads
# GoRoutine the same require-only way and is clean.
plan skip_all => 'GoRoutine XS unavailable' if !$have_xs;
diag '[' . time() . '] micro-hang-fix-a: GoRoutine loaded';

my $is_windows = $^O eq 'MSWin32' ? 1 : 0;
my $dir = tempdir( 'micro-hang-fix-a-XXXXXX', TMPDIR => 1, CLEANUP => 0 );
my $log             = File::Spec->catfile( $dir, 'hang.log' );
my $pidfile         = File::Spec->catfile( $dir, 'backend.pid' );
my $watcher_pidfile = File::Spec->catfile( $dir, 'watcher.pid' );
diag "micro-hang-fix-a: log=$log pidfile=$pidfile watcher_pidfile=$watcher_pidfile";
my $backend_sleep = 60;

my $frontend_program = <<'FRONTEND_PERL';
use strict;
use warnings;
use Developer::Dashboard::GoRoutine ();
my ( $pidfile, $watcher_pidfile, $log, $backend_sleep ) = @ARGV;
my $watcher_program = <<'WATCHER_PERL';
use strict;
use warnings;
use Developer::Dashboard::GoRoutine ();
my ( $frontend_pid, $backend_pid, $log ) = @ARGV;
open my $fh, '>>', $log or die "watcher cannot open log: $!";
print {$fh} "watcher started frontend=$frontend_pid backend=$backend_pid " . time() . "\n";
close $fh or die "watcher cannot close log: $!";
# Poll every 0.25s, bounded at 120s: when the frontend is gone, kill the
# backend and exit. Never die on the kill: the backend may already be dead
# (the POSIX TERM handler got there first), so the kill is eval-wrapped.
for ( 1 .. 480 ) {
    if ( !Developer::Dashboard::GoRoutine::process_running($frontend_pid) ) {
        open $fh, '>>', $log or die "watcher cannot reopen log: $!";
        print {$fh} "watcher: frontend gone, killing backend=$backend_pid " . time() . "\n";
        close $fh or die "watcher cannot close log: $!";
        eval { Developer::Dashboard::GoRoutine::terminate_process($backend_pid); };
        for ( 1 .. 40 ) {
            last if !Developer::Dashboard::GoRoutine::process_running($backend_pid);
            select undef, undef, undef, 0.25;
        }
        open $fh, '>>', $log or die "watcher cannot reopen log: $!";
        print {$fh} "watcher exiting backend_alive="
          . ( Developer::Dashboard::GoRoutine::process_running($backend_pid) ? 1 : 0 )
          . " " . time() . "\n";
        close $fh or die "watcher cannot close log: $!";
        exit 0;
    }
    select undef, undef, undef, 0.25;
}
open $fh, '>>', $log or die "watcher cannot reopen log: $!";
print {$fh} "watcher timed out, exiting " . time() . "\n";
close $fh or die "watcher cannot close log: $!";
exit 0;
WATCHER_PERL
my $backend_program = <<'BACKEND_PERL';
use strict;
use warnings;
my ( $log, $sleep ) = @ARGV;
open my $fh, '>>', $log or die "backend cannot open log: $!";
print {$fh} "backend started " . time() . "\n";
close $fh or die "backend cannot close log: $!";
sleep $sleep;
open $fh, '>>', $log or die "backend cannot reopen log: $!";
print {$fh} "backend exiting " . time() . "\n";
close $fh or die "backend cannot close log: $!";
exit 0;
BACKEND_PERL
my @library_args = map { ( '-I', $_ ) } grep { defined && -d $_ } @INC;
my $backend_pid = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, @library_args, '-e', $backend_program, $log, $backend_sleep ],
    {},
);
open my $fh, '>', $pidfile or die "frontend cannot write pidfile: $!";
print {$fh} $backend_pid;
close $fh or die "frontend cannot close pidfile: $!";
my $watcher_pid = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, @library_args, '-e', $watcher_program, $$, $backend_pid, $log ],
    {},
);
open $fh, '>', $watcher_pidfile or die "frontend cannot write watcher pidfile: $!";
print {$fh} $watcher_pid;
close $fh or die "frontend cannot close watcher pidfile: $!";
open $fh, '>>', $log or die "frontend cannot open log: $!";
print {$fh} "frontend started backend=$backend_pid watcher=$watcher_pid " . time() . "\n";
close $fh or die "frontend cannot close log: $!";
$SIG{TERM} = sub {
    Developer::Dashboard::GoRoutine::terminate_process($backend_pid);
    Developer::Dashboard::GoRoutine::wait_process($backend_pid);
    exit 0;
};
for ( 1 .. 300 ) { sleep 1; }
exit 0;
FRONTEND_PERL

diag '[' . time() . '] micro-hang-fix-a: spawning frontend';
my @library_args = map { ( '-I', $_ ) } grep { defined && -d $_ } @INC;
my $frontend_pid = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, @library_args, '-e', $frontend_program, $pidfile, $watcher_pidfile, $log, $backend_sleep ],
    {},
);
ok( defined $frontend_pid && $frontend_pid > 0, 'frontend spawned' );
diag '[' . time() . "] micro-hang-fix-a: frontend pid=$frontend_pid";

diag '[' . time() . '] micro-hang-fix-a: waiting for backend pid file';
my $backend_pid;
for ( 1 .. 30 ) {
    if ( -e $pidfile ) {
        open my $fh, '<', $pidfile or die "cannot read pidfile: $!";
        $backend_pid = <$fh>;
        close $fh or die "cannot close pidfile: $!";
        chomp $backend_pid if defined $backend_pid;
        last;
    }
    sleep 1;
}
ok( defined $backend_pid && $backend_pid > 0, 'backend pid file appeared' );
diag '[' . time() . "] micro-hang-fix-a: backend pid=$backend_pid";
ok(
    Developer::Dashboard::GoRoutine::process_running($backend_pid),
    'backend running before frontend kill',
);

diag '[' . time() . '] micro-hang-fix-a: waiting for watcher pid file';
my $watcher_pid;
for ( 1 .. 30 ) {
    if ( -e $watcher_pidfile ) {
        open my $fh, '<', $watcher_pidfile or die "cannot read watcher pidfile: $!";
        $watcher_pid = <$fh>;
        close $fh or die "cannot close watcher pidfile: $!";
        chomp $watcher_pid if defined $watcher_pid;
        last;
    }
    sleep 1;
}
ok( defined $watcher_pid && $watcher_pid > 0, 'watcher pid file appeared' );
diag '[' . time() . "] micro-hang-fix-a: watcher pid=$watcher_pid";
ok(
    Developer::Dashboard::GoRoutine::process_running($watcher_pid),
    'watcher running before frontend kill',
);

my $t0 = time();
diag '[' . time() . "] micro-hang-fix-a: terminating frontend pid=$frontend_pid";
Developer::Dashboard::GoRoutine::terminate_process($frontend_pid);
my $status = Developer::Dashboard::GoRoutine::wait_process($frontend_pid);
diag '[' . time() . "] micro-hang-fix-a: frontend reaped status=$status";
ok(
    !Developer::Dashboard::GoRoutine::process_running($frontend_pid),
    'frontend reaped after termination',
);

my $backend_alive = 1;
for ( 1 .. 40 ) {
    if ( !Developer::Dashboard::GoRoutine::process_running($backend_pid) ) {
        $backend_alive = 0;
        last;
    }
    select undef, undef, undef, 0.25;
}
my $t1 = time();
diag '[' . time() . "] micro-hang-fix-a: backend alive after frontend kill: $backend_alive (is_windows=$is_windows) after " . ( $t1 - $t0 ) . "s";
is(
    $backend_alive,
    0,
    'watchdog killed the backend after the frontend died',
);

my $watcher_alive = 1;
for ( 1 .. 40 ) {
    if ( !Developer::Dashboard::GoRoutine::process_running($watcher_pid) ) {
        $watcher_alive = 0;
        last;
    }
    select undef, undef, undef, 0.25;
}
diag '[' . time() . "] micro-hang-fix-a: watcher alive after frontend kill: $watcher_alive";
is(
    $watcher_alive,
    0,
    'watchdog exited after killing the backend',
);

open my $lfh, '>>', $log or die "test cannot open log: $!";
print {$lfh} "test exiting " . time() . " backend_alive=$backend_alive watcher_alive=$watcher_alive\n";
close $lfh or die "test cannot close log: $!";
diag '[' . time() . "] micro-hang-fix-a: test exiting; log=$log";
done_testing();

__END__

=head1 NAME

t/999-micro-hang-fix-a.t - Micro test of candidate fix (a): watchdog process

=head1 PURPOSE

Test whether a watchdog as a separate operating-system process ends the
t/17 Windows post-plan hang. The frontend spawns a small watcher holding
the frontend and backend pids; when the frontend disappears the watcher
kills the backend and exits. The micro measures two things after the
frontend is killed: whether the backend is actually dead, and whether the
watcher itself exited instead of lingering and holding prove's pipes the
way the backend did.

=head1 WHY IT EXISTS

Solo #181 proved the hang mechanism: on Windows the backend survives the
frontend's TerminateProcess and holds prove's pipes, so prove finishes
only when the backend exits on its own. Two candidate fixes were put to
Michael and neither was chosen yet. This micro proves candidate (a) in
miniature before any product code changes, so the decision can rest on
measured behaviour instead of reasoning about the design.

=head1 WHEN TO USE

Use this file only while testing candidate fix (a) for the GoRoutine
shutdown hang on the redesign branch. Run it as a Jenkins solo against
the redesign branch, never by hand and never as part of a release check.
It is a throwaway diagnostic: remove it from the branch in a cleanup
commit as soon as the investigation reports back, and never ship it.

=head1 HOW TO USE

Trigger it as a Jenkins solo on branch goroutine-c-async with the test
file set to t/999-micro-hang-fix-a.t, then read the per-leg verdicts from
the saved console and compare the prove wallclock against the repro
micro's 61 seconds on Windows. The test prints the frontend, backend and
watcher pids, the backend-alive reading after the frontend is killed, and
the watcher-alive reading, and it writes a hang log whose path is printed
in a diag. On every leg the backend must read dead and the watcher must
read exited; the wallclock must be seconds, not a minute. The backend
sleep is bounded at 60 seconds, the frontend block at 300 seconds and the
watcher poll at 120 seconds, so the micro itself can never hang forever.
Do not run it on a machine where stray perl processes would matter: a
crashed run can orphan a frontend, backend and watcher, so check the node
is clean afterwards.

=head1 WHAT USES IT

Nothing in the product uses this file. It is run only by the Jenkins solo
trigger during the shutdown-hang investigation, and its verdicts are read
by the investigating agent from the saved build console. The full test
suite does not depend on it, and no other test file loads it.

=head1 EXAMPLES

Run it as a Jenkins solo on the redesign branch:

  TEST_FILE=t/999-micro-hang-fix-a.t, branch goroutine-c-async

Read the measured outcome from the hang log after a run:

  frontend started backend=1234 watcher=1235 1795047000
  watcher started frontend=1233 backend=1234 1795047000
  watcher: frontend gone, killing backend=1234 1795047001
  watcher exiting backend_alive=0 1795047001
  test exiting 1795047001 backend_alive=0 watcher_alive=0

On every leg the backend must be dead and the watcher exited when the
test exits; on Windows that is the proof the watchdog ends the hang.

=cut
