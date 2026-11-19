#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Capture::Tiny qw(capture);
use Cwd qw(cwd);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX ();
use Test::More;

use lib 'lib';

use Developer::Dashboard::Collector;
use Developer::Dashboard::CollectorRunner;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::IndicatorStore;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::GoRoutine ();

my $repo_root = cwd();

# ---------------------------------------------------------------------------
# Hermetic runtime rooted in a throwaway HOME, mirroring t/115.
# ---------------------------------------------------------------------------
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";

my $paths = Developer::Dashboard::PathRegistry->new(
    home            => $home,
    workspace_roots => [ File::Spec->catdir( $home, 'workspace' ) ],
);
my $runner = Developer::Dashboard::CollectorRunner->new(
    collectors => Developer::Dashboard::Collector->new( paths => $paths ),
    files      => Developer::Dashboard::FileRegistry->new( paths => $paths ),
    indicators => Developer::Dashboard::IndicatorStore->new( paths => $paths ),
    paths      => $paths,
);

plan tests => 8;

# _gone_within($pid, $seconds)
# Polls kill 0 until the pid is gone or the budget runs out.
# Input: process id integer and budget in seconds.
# Output: seconds waited until the pid was gone, or undef when still alive.
sub _gone_within {
    my ( $pid, $budget ) = @_;
    my $step   = 0.1;
    my $waited = 0;
    while ( $waited <= $budget ) {
        return $waited if !kill 0, $pid;
        select undef, undef, undef, $step;
        $waited += $step;
    }
    return undef;
}

# _reaped_within($pid, $seconds)
# Polls GoRoutine::reap_child until it collects the pid or the budget
# runs out. Windows only: on POSIX the spawn registry is always empty
# and reap_child always returns 0.
# Input: process id integer and budget in seconds.
# Output: seconds waited until the pid was reaped, or undef.
sub _reaped_within {
    my ( $pid, $budget ) = @_;
    my $step   = 0.01;
    my $waited = 0;
    while ( $waited <= $budget ) {
        return $waited if Developer::Dashboard::GoRoutine::reap_child($pid);
        select undef, undef, undef, $step;
        $waited += $step;
    }
    return undef;
}

# _force_kill($pid)
# Best-effort cleanup for a child this micro spawned: reap it through
# the registry if it has exited, otherwise KILL it if it is still
# alive. Never dies.
# Input: process id integer.
# Output: nothing.
sub _force_kill {
    my ($pid) = @_;
    return if !defined $pid;
    Developer::Dashboard::GoRoutine::reap_child($pid);
    return if !kill 0, $pid;
    kill 'KILL', $pid;
    select undef, undef, undef, 0.2;
    Developer::Dashboard::GoRoutine::reap_child($pid);
    return;
}

# Scenario A: waitpid observation, first so it prints even if a later
# assertion trips the fail-fast watchdog. Corrected after solo #288:
# waitpid DOES track a GoRoutine-spawned pid on Windows too (it
# returns 0 for a live child there, exactly as on POSIX), so the
# helper's blocking waitpid is not a no-op - the child is reaped by
# it, and what keeps kill 0 reporting the dead child alive must be
# the kept spawn-registry handle.
{
    my $tracked = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'sleep 30;' ], {} );
    die "GoRoutine spawn failed: $!" if !defined $tracked;
    diag("micro: spawned child pid $tracked (test process $$)");
    my $wp = waitpid( $tracked, 1 );
    diag("micro: waitpid WNOHANG on GoRoutine child returned $wp");
    is( $wp, 0, 'micro: waitpid sees a live GoRoutine-spawned child' );
    $runner->_terminate_command_process($tracked);
    _gone_within( $tracked, 5 );
    _force_kill($tracked);
}

# Scenario B: direct taskkill, Windows only. The handle theory predicts
# taskkill succeeds (the tree dies) yet kill 0 still says the pid is
# alive, because GoRoutine keeps a process handle open for it until
# reap_child collects it. If that prediction holds, reap_child is the
# fix and the helper's taskkill was never the problem.
SKIP: {
    skip 'direct taskkill is Windows-only', 4 unless $^O eq 'MSWin32';
    my $direct = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'sleep 30;' ], {} );
    die "GoRoutine spawn failed: $!" if !defined $direct;
    diag("micro: spawned child pid $direct (test process $$)");
    my ( $out, $err ) = capture { system 'taskkill', '/PID', $direct, '/T', '/F' };
    diag("micro: taskkill stdout: $out") if defined $out && $out ne '';
    diag("micro: taskkill stderr: $err") if defined $err && $err ne '';
    like( $out, qr/SUCCESS/, 'micro: direct taskkill reports SUCCESS' );
    my $died_after = _gone_within( $direct, 5 );
    diag( defined $died_after ? "micro: direct-taskkill child gone ${died_after}s after taskkill" : 'micro: direct-taskkill child STILL ALIVE 5s after taskkill (kept handle)' );
    ok( !defined $died_after, 'micro: direct-taskkill child still reports alive after 5s' );
    my $reaped_after = _reaped_within( $direct, 5 );
    diag( defined $reaped_after ? "micro: reap_child collected the child after ${reaped_after}s" : 'micro: reap_child did NOT collect the child within 5s' );
    ok( defined $reaped_after, 'micro: reap_child collects the terminated child within 5s' );
    ok( !kill( 0, $direct ), 'micro: child is gone after reap_child' );
    _force_kill($direct);
}

# Scenario C: the exact t/115 test-16 shape plus the fix prototype -
# terminate through the helper, then reap, then check.
{
    my $obedient = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'sleep 30;' ], {} );
    die "GoRoutine spawn failed: $!" if !defined $obedient;
    diag("micro: spawned child pid $obedient (test process $$)");
    ok( $runner->_terminate_command_process($obedient),
        'micro: terminate_command_process returns true' );
    # After the helper, did its blocking waitpid reap the child? -1 says
    # yes (already reaped), 0 says no (still tracked). Either way the
    # reap below is the fix prototype; this line only names which.
    my $wp_after = waitpid( $obedient, 1 );
    diag("micro: waitpid WNOHANG after helper returned $wp_after");
    SKIP: {
        skip 'reap_child is Windows-only', 1 unless $^O eq 'MSWin32';
        my $reaped_after = _reaped_within( $obedient, 5 );
        diag( defined $reaped_after ? "micro: reap_child collected the helper-terminated child after ${reaped_after}s" : 'micro: reap_child did NOT collect the helper-terminated child within 5s' );
        ok( defined $reaped_after, 'micro: reap_child collects the helper-terminated child within 5s' );
    }
    ok( !kill( 0, $obedient ), 'micro: child is gone after helper plus reap' );
    _force_kill($obedient);
}

__END__

=head1 NAME

t/984-micro-t115-reap-prototype.t - micro-repro for the t/115 test-16 Windows fix

=head1 PURPOSE

This micro tests the mechanism behind the t/115 test-16 Windows
failure and prototypes its fix. Micro t/985 showed the helper's
taskkill is not the problem: a directly taskkilled child reports
SUCCESS for its whole tree, yet the helper-terminated child still
reports alive per kill 0 after 10 seconds. The candidate mechanism is
the GoRoutine spawn registry: GoRoutine.pm keeps one Win32::Process
handle open per spawned child until wait_process or reap_child
collects it, and that handle is what makes a completed child still
"exist" until it is reaped. Solo #288 corrected one premise on the
way: waitpid DOES track a GoRoutine-spawned pid on Windows (WNOHANG
returns 0 for a live child), so the helper's blocking waitpid is not
a no-op - the child is reaped by it, and only the kept handle keeps
kill 0 reporting the dead child alive. The helper's Windows branch
never reaps that handle, so kill 0 keeps reporting the dead child
alive.

=head1 WHY IT EXISTS

Solo #287 (micro t/985) left two questions unanswered because the
Windows leg was killed by fail-fast after its third test failed: does
kill 0 stay true after a direct taskkill too (which would convict the
kept handle and exonerate taskkill), and does reap_child make kill 0
go false (which would name the fix). This micro asserts the handle
theory's predictions directly, so a green run confirms the mechanism
and prototypes the fix in one solo, and a red run names which
prediction was wrong.

=head1 WHEN TO USE

Use this file only while investigating the t/115 test-16 Windows
failure. It is a throwaway micro: remove it from the branch in a
cleanup commit once the fix is verified and t/115 is green on all four
legs. Do not extend it into a permanent test.

=head1 HOW TO USE

Run it as a Jenkins solo on the loop branch:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/984-micro-t115-reap-prototype.t 1

The checks are hermetic: every path lives under a throwaway HOME that
the test chdirs into first. The children are bare 30-second sleeps
spawned through the project's own GoRoutine API; each scenario reaps
or force-kills its child if it is still alive at the end, so no child
outlives the run by more than its own 30-second sleep. The only
signals the micro sends are to pids it spawned itself.

=head1 WHAT USES IT

Nothing uses this file. It is a diagnostic micro for the t/115
applier, read by the applier and the loop owner only.

=head1 EXAMPLES

Run the micro and read the diag lines: "STILL ALIVE 5s after
taskkill" plus "reap_child collected the child after Xs" is the
handle mechanism confirmed, and the final "child is gone after helper
plus reap" is the fix prototype passing:

  prove -l t/984-micro-t115-reap-prototype.t

If the "still reports alive" test goes red, the handle theory is
wrong and the helper's taskkill differs from a direct one. If the
reap tests go red, reap_child does not collect this child and the fix
is elsewhere.
