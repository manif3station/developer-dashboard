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

plan tests => 6;

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

# _force_kill($pid)
# Best-effort cleanup for a child this micro spawned: KILL it if it is
# still alive, then give it a moment to go. Never dies.
# Input: process id integer.
# Output: nothing.
sub _force_kill {
    my ($pid) = @_;
    return if !defined $pid;
    return if !kill 0, $pid;
    kill 'KILL', $pid;
    select undef, undef, undef, 0.2;
    return;
}

# Scenario A: the t/115 test-16 shape, exactly. Spawn an obedient sleep
# child, terminate it through the helper, and watch when (or whether)
# the pid stops existing.
my $obedient = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'sleep 30;' ], {} );
ok( defined $obedient, 'micro: spawn obedient child' );
ok( $runner->_terminate_command_process($obedient),
    'micro: terminate_command_process returns true' );
my $died_after = _gone_within( $obedient, 10 );
diag( defined $died_after ? "micro: child gone ${died_after}s after terminate" : 'micro: child STILL ALIVE 10s after terminate' );
ok( defined $died_after, 'micro: child is gone within 10s of terminate' );
_force_kill($obedient);

# Scenario B: direct taskkill, Windows only. Same question asked of the
# tool itself, without the helper in between.
SKIP: {
    skip 'direct taskkill is Windows-only', 2 unless $^O eq 'MSWin32';
    my $direct = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'sleep 30;' ], {} );
    die "GoRoutine spawn failed: $!" if !defined $direct;
    my ( $out, $err ) = capture { system 'taskkill', '/PID', $direct, '/T', '/F' };
    diag("micro: taskkill stdout: $out") if defined $out && $out ne '';
    diag("micro: taskkill stderr: $err") if defined $err && $err ne '';
    like( $out, qr/SUCCESS/, 'micro: direct taskkill reports SUCCESS' );
    my $direct_died = _gone_within( $direct, 5 );
    diag( defined $direct_died ? "micro: direct-taskkill child gone ${direct_died}s after taskkill" : 'micro: direct-taskkill child STILL ALIVE 5s after taskkill' );
    ok( defined $direct_died, 'micro: direct-taskkill child is gone within 5s' );
    _force_kill($direct);
}

# Scenario C: is the helper's waitpid even able to reap a
# GoRoutine-spawned pid? WNOHANG never blocks, so this only observes.
{
    my $tracked = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'sleep 30;' ], {} );
    die "GoRoutine spawn failed: $!" if !defined $tracked;
    my $wp = waitpid( $tracked, 1 );
    diag("micro: waitpid WNOHANG on GoRoutine child returned $wp");
    if ( $^O eq 'MSWin32' ) {
        is( $wp, -1, 'micro: waitpid does not track GoRoutine-spawned pids on Windows' );
    }
    else {
        is( $wp, 0, 'micro: waitpid sees a live GoRoutine-spawned child on POSIX' );
    }
    $runner->_terminate_command_process($tracked);
    _gone_within( $tracked, 5 );
    _force_kill($tracked);
}

__END__

=head1 NAME

t/985-micro-t115-terminate-race.t - micro-repro for the t/115 test-16 Windows failure

=head1 PURPOSE

This micro diagnoses why t/115 test 16 ("_terminate_command_process
leaves no owned command child behind") fails on Windows only: it
spawns an obedient sleep child exactly as the test does, terminates it
through the helper, and measures when (or whether) the pid stops
existing; it then asks the same question of taskkill directly, and
checks whether Perl's waitpid can even track a GoRoutine-spawned pid
on each platform.

=head1 WHY IT EXISTS

Solo #286 showed test 16 failing only on Windows while test 15 (the
helper returns true) passes everywhere and test 28 (the fix-C gate)
now passes 4/4. The helper's Windows branch runs taskkill and then a
blocking waitpid before returning true, so the test's immediate kill-0
check should find the pid gone - unless taskkill is asynchronous, the
waitpid is a no-op for a CreateProcess pid, or taskkill never kills
this child at all. Guessing between those three wastes a solo each;
the micro measures all three in one run.

=head1 WHEN TO USE

Use this file only while investigating the t/115 test-16 Windows
failure. It is a throwaway micro: remove it from the branch in a
cleanup commit once the fix is verified and t/115 is green on all four
legs. Do not extend it into a permanent test.

=head1 HOW TO USE

Run it as a Jenkins solo on the loop branch:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/985-micro-t115-terminate-race.t 1

The checks are hermetic: every path lives under a throwaway HOME that
the test chdirs into first. The children are bare 30-second sleeps
spawned through the project's own GoRoutine API; each scenario
force-kills its child if it is still alive at the end, so no child
outlives the run by more than its own 30-second sleep. The only
signals the micro sends are to pids it spawned itself.

=head1 WHAT USES IT

Nothing uses this file. It is a diagnostic micro for the t/115
applier, read by the applier and the loop owner only.

=head1 EXAMPLES

Run the micro and read the diag lines: "child gone Xs after
terminate" names the race window if there is one, and "STILL ALIVE"
names a permanent failure instead:

  prove -l t/985-micro-t115-terminate-race.t

If scenario A shows the child gone after a short delay, the fix is a
bounded wait for death in the helper (or in the test). If it shows
the child still alive after 10 seconds, taskkill is not killing this
child and the fix is elsewhere.
