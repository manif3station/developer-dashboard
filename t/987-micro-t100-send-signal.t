#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;

use lib 'lib';

use Developer::Dashboard::RuntimeManager;

BEGIN {
    # Mirror t/100: make every internal poll loop instant so the
    # _send_signal forgive loop (20 x 0.1s) costs nothing here.
    no warnings qw(redefine prototype);
    *Developer::Dashboard::RuntimeManager::sleep = sub { return 0 };
}

my $RM = 'Developer::Dashboard::RuntimeManager';

# _send_signal needs no object state (it only calls $self->_pid_is_running),
# so a blessed empty hash is the whole harness. No config, files, paths or
# runner is constructed.
my $manager = bless {}, $RM;

# DIAG ONLY, no assertion: whether pid 111 is alive varies by host, and
# that variance is the whole story. Round 27 failed on amd64 because the
# real liveness check said 111 was gone there.
diag "micro-t100: real _pid_is_running(111) = " . ( $manager->_pid_is_running(111) ? 1 : 0 );

# Find a pid the REAL liveness check says is dead, so case A exercises the
# genuine forgive path instead of a stubbed one. Pids at/above 5000000 can
# never exist on macOS (pid_max 99998) or Linux (pid_max 4194304 by
# default); on Windows they are verified dead by the check itself.
my $dead_pid;
for my $cand ( 5000000 .. 5000020 ) {
    if ( !$manager->_pid_is_running($cand) ) {
        $dead_pid = $cand;
        last;
    }
}
diag "micro-t100: dead pid chosen = " . ( defined $dead_pid ? $dead_pid : 'NONE FOUND' );

# --- Case A: target verifiably gone + hard taskkill error ------------------
# This is the round-27 shape (t/100 test 175, fake pid 111, hard error),
# replayed with a pid proven dead by the real liveness check.
SKIP: {
    skip 'no verifiably dead pid found for the forgive-path probe', 2
      if !defined $dead_pid;
    my @cap;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::is_windows = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::capture = sub (&) { return @cap };
    @cap = ( '', 'hard error', 1 );
    my $rc;
    my $err = eval { $rc = $manager->_send_signal( 'TERM', $dead_pid ); 1 } ? '' : $@;
    is( $err, '', 'micro: _send_signal does not die when taskkill hard-fails but the target is verifiably gone' );
    is( $rc, 1, 'micro: _send_signal returns the target count when the target is verifiably gone' );
}

# --- Case B: target pinned alive + hard taskkill error ---------------------
# The t/09 direction (commit cc80fc52): pin the target alive and the die
# fires deterministically. This proves the die path is intact and the fix
# for t/100 test 175 is to pin the target alive, not to change the product.
{
    my @cap;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::is_windows = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::capture = sub (&) { return @cap };
    local *Developer::Dashboard::RuntimeManager::_pid_is_running = sub { return 1 };
    @cap = ( '', 'hard error', 1 );
    my $err = eval { $manager->_send_signal( 'TERM', 111 ); 1 } ? '' : $@;
    like( $err, qr/Failed to stop Windows process ids/, 'micro: _send_signal dies on a hard taskkill failure when the target is pinned alive' );
}

# --- Case C: genuinely live target + hard taskkill error, no liveness stub -
# Same die, but the liveness verdict comes from the real check on the test
# process itself ($$), so no stub stands between the test and the product.
{
    my @cap;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::is_windows = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::capture = sub (&) { return @cap };
    @cap = ( '', 'hard error', 1 );
    my $err = eval { $manager->_send_signal( 'TERM', $$ ); 1 } ? '' : $@;
    like( $err, qr/Failed to stop Windows process ids/, 'micro: _send_signal dies on a hard taskkill failure for a genuinely live target' );
}

# --- Controls: success path and non-terminating signal ----------------------
{
    my @cap;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::is_windows = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::capture = sub (&) { return @cap };
    @cap = ( '', '', 0 );
    is( $manager->_send_signal( 'TERM', 111 ), 1, 'micro: _send_signal returns the target count when taskkill succeeds' );
    @cap = ( '', 'hard error', 1 );
    is( $manager->_send_signal( 'HUP', 111 ), 0, 'micro: _send_signal returns zero for a non-terminating signal failure without dying' );
}

done_testing();

__END__

=head1 NAME

t/987-micro-t100-send-signal.t - MICRO, DO NOT SHIP. Proves which branch of _send_signal round 27 took.

=head1 DESCRIPTION

A minimal reproduction of the round-27 t/100 test 175 failure shape: _send_signal on the Windows path, taskkill stubbed to a hard error, and the target's liveness varied. Nothing more.

=head1 PURPOSE

Decide product vs test for t/100 test 175 ("_send_signal Windows dies on a hard TERM/KILL failure", which failed in Jenkins build #279 because the call returned 1 instead of dying): does _send_signal correctly return success when the target is verifiably gone (the intended fb4897d5 behaviour, so the test must pin its target alive as t/09 did), or does it wrongly swallow a genuine hard failure (so the product must die)?

=head1 WHY IT EXISTS

Round 27 failed on exactly one genuine failure, t/100 test 175. The test stubs capture to return a hard taskkill error for fake pid 111 and expects a die, but fb4897d5 added a forgive path that returns success when every target is verifiably gone. Whether that path is the intended behaviour or a swallowing bug decides whether the fix belongs in the product or in the test, and that must be proven on Jenkins, not assumed from the t/09 case.

=head1 WHEN TO USE

Run it as a Jenkins solo while investigating the t/100 test 175 failure. Remove it in a cleanup commit when the investigation ends; it is not part of the suite.

=head1 HOW TO USE

Trigger a Jenkins solo with TEST_FILE=t/987-micro-t100-send-signal.t on branch windows/loop6-combined. Read the per-leg verdicts: case A must pass (forgive-when-gone is the live behaviour), case B and case C must pass (die-when-alive is intact, stubbed and real), and the diag line shows whether pid 111 is alive on each node.

=head1 WHAT USES IT

Nothing in the product or the suite uses this file. It is a one-off investigation micro for the t/100 applier.

=head1 EXAMPLES

Jenkins solo: python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/987-micro-t100-send-signal.t 1

Local check (main worktree local/ on PERL5LIB): PERL5LIB="$PWD/blib/lib:$PWD/blib/arch:$HOME/workspace/developer-dashboard/local/lib/perl5:$HOME/perl5/lib/perl5" prove -l t/987-micro-t100-send-signal.t

=cut
