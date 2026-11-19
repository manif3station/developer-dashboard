#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Capture::Tiny qw(capture);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX ();
use Test::More;
use Time::HiRes qw(sleep time);

use lib 'lib';

use Developer::Dashboard::CommandRunner ();
use Developer::Dashboard::GoRoutine ();

# Hermetic runtime rooted in a throwaway HOME, mirroring t/122.
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";

# Stand-in for the Windows tree killer, mirroring t/122. Real Windows
# uses the real taskkill; the POSIX legs need the fake so the Windows
# branch of terminate_command_process can run here at all.
my $fake_bin;
if ( $^O ne 'MSWin32' ) {
    $fake_bin = File::Spec->catdir( $home, 'fake-windows-bin' );
    make_path($fake_bin);
    my $taskkill = File::Spec->catfile( $fake_bin, 'taskkill' );
    open my $fh, '>', $taskkill or die "Unable to write $taskkill: $!";
    print {$fh} <<'SH';
#!/bin/sh
# Emulate `taskkill /PID <pid> /T /F`: kill the whole subtree, then the process.
kill -9 -"$2" 2>/dev/null
kill -9 "$2" 2>/dev/null
exit 0
SH
    close $fh or die "Unable to close $taskkill: $!";
    chmod 0755, $taskkill or die "Unable to chmod $taskkill: $!";
}
local $ENV{PATH} = "$fake_bin:$ENV{PATH}" if defined $fake_bin;

plan tests => 6;

# _spawn_unregistered_sleeper()
# Spawns a 30s sleeper through a path GoRoutine never sees, so the pid
# is absent from the spawn registry on every platform: fork+exec on
# POSIX, the asynchronous form of system() on Windows (the same spawn
# CommandRunner::spawn_windows_command uses in production).
# Input: none.
# Output: the sleeper pid.
sub _spawn_unregistered_sleeper {
    if ( $^O eq 'MSWin32' ) {
        my $pid = system 1, $^X, '-e', 'sleep 30';
        die "micro: async system spawn failed: $!" if !$pid;
        return $pid;
    }
    my $pid = fork();
    die "micro: fork failed: $!" if !defined $pid;
    if ( $pid == 0 ) {
        exec 'sleep', '30' or POSIX::_exit(127);
    }
    return $pid;
}

# _force_kill($pid)
# Best-effort cleanup for a sleeper this micro spawned: reap it through
# the registry if it has exited, otherwise KILL it if it is still alive.
# Never dies.
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
    waitpid( $pid, 1 );
    return;
}

# Scenario A: the t/122 shape - an unregistered sleeper terminated
# through the Windows branch. The 72f55cf8 poll exists only to collect
# the kept spawn-registry handle, so for a pid the registry never saw
# reap_child can never return 1 and the poll can only burn its whole
# 500 x 10ms bound. The elapsed time is the discriminator: before a
# fix this takes ~5s (the t/122 failure was 5s timeout + 5s poll =
# 10.067s against a < 10 assertion); after a fix it must be instant.
{
    my $sleeper = _spawn_unregistered_sleeper();
    diag("micro: unregistered sleeper pid $sleeper (test process $$)");
    my $reaped = Developer::Dashboard::GoRoutine::reap_child($sleeper);
    diag("micro: reap_child(unregistered pid) = $reaped");
    is( $reaped, 0, 'micro: reap_child returns 0 for a pid the spawn registry never saw' );

    no warnings 'redefine';
    local *Developer::Dashboard::CommandRunner::is_windows = sub { return 1 };
    use warnings 'redefine';

    my $started = time();
    my $rc = Developer::Dashboard::CommandRunner::terminate_command_process($sleeper);
    my $elapsed = time() - $started;
    diag("micro: terminate_command_process(unregistered) took ${elapsed}s, returned $rc");
    ok( $rc, 'micro: terminate_command_process returns true for an unregistered sleeper' );
    cmp_ok( $elapsed, '<', 2, 'micro: terminating an unregistered sleeper does not burn the 5s reap-poll bound' );
    ok( !kill( 0, $sleeper ), 'micro: the unregistered sleeper is gone after terminate_command_process' );
    _force_kill($sleeper);
}

# Scenario B: the t/115 shape - a GoRoutine-spawned sleeper, which IS
# in the registry on real Windows and therefore the one case the poll
# can ever collect. On POSIX the registry is Windows-only and stays
# empty by design, so this scenario burns the same 5s there before a
# fix; on Windows the reap is immediate and it is fast before and
# after. Either way the fix must keep it fast: the poll may only run
# where a handle exists to collect.
{
    my $tracked = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'sleep 30;' ], {} );
    die "micro: GoRoutine spawn failed: $!" if !defined $tracked;
    diag("micro: GoRoutine-spawned sleeper pid $tracked (test process $$)");

    no warnings 'redefine';
    local *Developer::Dashboard::CommandRunner::is_windows = sub { return 1 };
    use warnings 'redefine';

    my $started = time();
    my $rc = Developer::Dashboard::CommandRunner::terminate_command_process($tracked);
    my $elapsed = time() - $started;
    diag("micro: terminate_command_process(GoRoutine-spawned) took ${elapsed}s, returned $rc");
    ok( $rc, 'micro: terminate_command_process returns true for a GoRoutine-spawned sleeper' );
    cmp_ok( $elapsed, '<', 2, 'micro: terminating a GoRoutine-spawned sleeper does not burn the 5s reap-poll bound' );
    _force_kill($tracked);
}

__END__

=head1 NAME

t/983-micro-t122-reap-poll.t - micro-repro for the t/122 reap-poll knock-on

=head1 PURPOSE

Prove whether the bounded reap poll that 72f55cf8 added to
C<terminate_command_process> is the cause of the round-29 t/122 failure,
and whether the product or the test must change.

=head1 WHY IT EXISTS

Round 29 failed on amd64 t/122 test 1 with elapsed 10.067s against a
C<< < 10 >> assertion: a 5s command timeout plus a 5s reap poll. The
poll exists only to collect the kept GoRoutine spawn-registry handle,
but the t/122 command tree is never in that registry on a POSIX host
(the registry is Windows-only), so the poll can never succeed there.
This micro isolates that question at the unit level before any fix.

=head1 WHEN TO USE

Run it as a Jenkins solo while investigating the t/122 failure. It is
a diagnostic micro: remove it in a cleanup commit once the fix is
solo-verified, exactly as the t/115 micros were removed.

=head1 HOW TO USE

Trigger it as a Jenkins solo on the loop branch and read the elapsed
diag lines: an unregistered sleeper taking ~5s proves the poll burns
its whole bound for pids the registry never saw. A GoRoutine-spawned
sleeper is the control: fast on Windows (the reap is immediate),
slow on POSIX before a fix (the registry stays empty there).

=head1 WHAT USES IT

Nothing in the suite uses this file. The t/122 applier runs it by
hand as a Jenkins solo, then deletes it.

=head1 EXAMPLES

Example 1:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/983-micro-t122-reap-poll.t 1

Run the micro on all four legs and read the elapsed diag lines.

Example 2:

  prove -lv t/983-micro-t122-reap-poll.t

Run it locally (POSIX legs only) for a quick read of the poll cost.

=cut
