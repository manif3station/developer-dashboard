# t/999-micro-hang-fix-b.t — MICRO, DO NOT SHIP. Tests candidate fix (b)
# for the t/17 Windows post-plan hang: redirect the backend stdio at spawn.
#
# Shape (extends t/999-micro-hang-repro.t, whose mechanism solo #181
# proved): identical to the repro except for ONE change — the frontend
# spawns the backend with stdout/stderr redirected to files instead of
# inheriting prove's pipes. The test kills the frontend with
# GoRoutine::terminate_process — SIGTERM on POSIX, TerminateProcess on
# Windows — and measures two things: whether the test itself exits
# promptly (prove sees EOF at once because nothing holds its pipes), and
# whether the backend process is still alive afterwards. The backend
# prints one line to STDOUT at start so the test can prove the redirect
# really captured its output instead of assuming it did.
#
# Expected outcome, by design: the test exits promptly on ALL legs (the
# hang is gone from prove's point of view), BUT on Windows the backend is
# still alive (alive=1) — the redirect frees prove, it does not stop the
# backend. That is the leak, measured: the backend sleeps its bounded
# 60s and then exits on its own. On POSIX the TERM handler stops the
# backend, so alive=0 there.
use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);

diag '[' . time() . '] micro-hang-fix-b: start';
my $have_xs = eval {
    require Developer::Dashboard::GoRoutine;
    1;
};
# Require-only, on purpose: a runtime no-args import() after File::Temp is
# loaded dies with "Out of memory in perl:util:safesysrealloc" (proven 10/10
# on macOS, and it segfaults non-deterministically on ARM64). t/17 loads
# GoRoutine the same require-only way and is clean.
plan skip_all => 'GoRoutine XS unavailable' if !$have_xs;
diag '[' . time() . '] micro-hang-fix-b: GoRoutine loaded';

my $is_windows = $^O eq 'MSWin32' ? 1 : 0;
my $dir = tempdir( 'micro-hang-fix-b-XXXXXX', TMPDIR => 1, CLEANUP => 0 );
my $log         = File::Spec->catfile( $dir, 'hang.log' );
my $pidfile     = File::Spec->catfile( $dir, 'backend.pid' );
my $backend_out = File::Spec->catfile( $dir, 'backend.out' );
my $backend_err = File::Spec->catfile( $dir, 'backend.err' );
diag "micro-hang-fix-b: log=$log pidfile=$pidfile backend_out=$backend_out backend_err=$backend_err";
my $backend_sleep = 60;

my $frontend_program = <<'FRONTEND_PERL';
use strict;
use warnings;
use Developer::Dashboard::GoRoutine ();
my ( $pidfile, $log, $backend_out, $backend_err, $backend_sleep ) = @ARGV;
my $backend_program = <<'BACKEND_PERL';
use strict;
use warnings;
$| = 1;
my ( $log, $sleep ) = @ARGV;
print "backend stdout line\n";
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
# THE FIX UNDER TEST: the backend's stdout/stderr go to files, not to the
# pipes the frontend inherited from prove. Everything else is identical
# to the repro micro.
my $backend_pid = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, @library_args, '-e', $backend_program, $log, $backend_sleep ],
    { stdout => $backend_out, stderr => $backend_err },
);
open my $fh, '>', $pidfile or die "frontend cannot write pidfile: $!";
print {$fh} $backend_pid;
close $fh or die "frontend cannot close pidfile: $!";
open $fh, '>>', $log or die "frontend cannot open log: $!";
print {$fh} "frontend started backend=$backend_pid " . time() . "\n";
close $fh or die "frontend cannot close log: $!";
$SIG{TERM} = sub {
    Developer::Dashboard::GoRoutine::terminate_process($backend_pid);
    Developer::Dashboard::GoRoutine::wait_process($backend_pid);
    exit 0;
};
for ( 1 .. 300 ) { sleep 1; }
exit 0;
FRONTEND_PERL

diag '[' . time() . '] micro-hang-fix-b: spawning frontend';
my @library_args = map { ( '-I', $_ ) } grep { defined && -d $_ } @INC;
my $frontend_pid = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, @library_args, '-e', $frontend_program, $pidfile, $log, $backend_out, $backend_err, $backend_sleep ],
    {},
);
ok( defined $frontend_pid && $frontend_pid > 0, 'frontend spawned' );
diag '[' . time() . "] micro-hang-fix-b: frontend pid=$frontend_pid";

diag '[' . time() . '] micro-hang-fix-b: waiting for backend pid file';
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
diag '[' . time() . "] micro-hang-fix-b: backend pid=$backend_pid";
ok(
    Developer::Dashboard::GoRoutine::process_running($backend_pid),
    'backend running before frontend kill',
);

my $t0 = time();
diag '[' . time() . "] micro-hang-fix-b: terminating frontend pid=$frontend_pid";
Developer::Dashboard::GoRoutine::terminate_process($frontend_pid);
my $status = Developer::Dashboard::GoRoutine::wait_process($frontend_pid);
diag '[' . time() . "] micro-hang-fix-b: frontend reaped status=$status";
ok(
    !Developer::Dashboard::GoRoutine::process_running($frontend_pid),
    'frontend reaped after termination',
);

# Short bound on purpose: on Windows the backend is NOT expected to die,
# so a long poll would only burn the wallclock the test is measuring.
my $backend_alive = 1;
for ( 1 .. 20 ) {
    if ( !Developer::Dashboard::GoRoutine::process_running($backend_pid) ) {
        $backend_alive = 0;
        last;
    }
    select undef, undef, undef, 0.25;
}
my $elapsed = time() - $t0;
diag '[' . time() . "] micro-hang-fix-b: backend alive after frontend kill: $backend_alive (is_windows=$is_windows) elapsed=${elapsed}s";
ok(
    $elapsed <= 10,
    'test exits promptly after frontend kill',
);
is(
    $backend_alive,
    $is_windows ? 1 : 0,
    'backend survives frontend kill on Windows (leaked); POSIX TERM handler stops it',
);

# Prove the redirect really captured the backend's stdout: the line must
# be in the redirect file, not in prove's output. Poll briefly: the
# backend prints it at start, but the pidfile can appear first.
my $redirect_ok = 0;
for ( 1 .. 20 ) {
    if ( -e $backend_out ) {
        open my $fh, '<', $backend_out or die "cannot read backend stdout file: $!";
        local $/;
        my $content = <$fh>;
        close $fh or die "cannot close backend stdout file: $!";
        if ( defined $content && $content =~ /backend stdout line/ ) {
            $redirect_ok = 1;
            last;
        }
    }
    select undef, undef, undef, 0.25;
}
ok( $redirect_ok, 'backend stdout went to the redirect file' );

open my $lfh, '>>', $log or die "test cannot open log: $!";
print {$lfh} "test exiting " . time() . " backend_alive=$backend_alive elapsed=${elapsed}s\n";
close $lfh or die "test cannot close log: $!";
diag '[' . time() . "] micro-hang-fix-b: test exiting; log=$log";
done_testing();

__END__

=head1 NAME

t/999-micro-hang-fix-b.t - Micro test of candidate fix (b): stdio redirect

=head1 PURPOSE

Test whether redirecting the backend's stdout and stderr to files at
spawn time ends the t/17 Windows post-plan hang. The frontend spawns the
backend exactly as the repro micro does, except the spawn passes stdout
and stderr file paths, so the backend no longer inherits prove's pipes.
The micro measures two things after the frontend is killed: whether the
test itself exits promptly, and whether the backend process is still
alive afterwards — the redirect can free prove without stopping the
backend, and this micro tells those two outcomes apart.

=head1 WHY IT EXISTS

Solo #181 proved the hang mechanism: on Windows the backend survives the
frontend's TerminateProcess and holds prove's pipes, so prove finishes
only when the backend exits on its own. Two candidate fixes were put to
Michael and neither was chosen yet. This micro proves candidate (b) in
miniature before any product code changes, so the decision can rest on
measured behaviour: a fast prove with a leaked backend is a mask, not a
fix, and only this measurement shows which one it is.

=head1 WHEN TO USE

Use this file only while testing candidate fix (b) for the GoRoutine
shutdown hang on the redesign branch. Run it as a Jenkins solo against
the redesign branch, never by hand and never as part of a release check.
It is a throwaway diagnostic: remove it from the branch in a cleanup
commit as soon as the investigation reports back, and never ship it.

=head1 HOW TO USE

Trigger it as a Jenkins solo on branch goroutine-c-async with the test
file set to t/999-micro-hang-fix-b.t, then read the per-leg verdicts from
the saved console and compare the prove wallclock against the repro
micro's 61 seconds on Windows. The test prints the frontend and backend
pids, the backend-alive reading after the frontend is killed, and the
elapsed seconds from kill to test exit, and it writes a hang log whose
path is printed in a diag. On every leg the test must exit promptly; on
Windows the backend must read alive (leaked) and the redirect file must
hold the backend's stdout line, proving the redirect is real. The backend
sleep is bounded at 60 seconds and the frontend block at 300 seconds, so
the micro itself can never hang forever. The leaked backend exits on its
own when its 60 second sleep ends. Do not run it on a machine where stray
perl processes would matter: a crashed run can orphan a frontend and
backend, so check the node is clean afterwards.

=head1 WHAT USES IT

Nothing in the product uses this file. It is run only by the Jenkins solo
trigger during the shutdown-hang investigation, and its verdicts are read
by the investigating agent from the saved build console. The full test
suite does not depend on it, and no other test file loads it.

=head1 EXAMPLES

Run it as a Jenkins solo on the redesign branch:

  TEST_FILE=t/999-micro-hang-fix-b.t, branch goroutine-c-async

Read the measured outcome from the hang log after a run:

  frontend started backend=1234 1795047000
  backend started 1795047000
  test exiting 1795047001 backend_alive=1 elapsed=5s

On Windows the test exits in seconds with the backend still alive: the
redirect frees prove but leaks the backend on every run.

=cut
