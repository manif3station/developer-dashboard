use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Spec;
use Test::More;

use lib 'lib';

use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::RuntimeManager;

# Micro: reproduce the round-26 t/09 tests 401-402 failure and prove the
# mechanism before any fix. Round 26 (build #230) failed on Linux amd64:
# _send_signal('TERM', 4002) with a stubbed hard taskkill failure
# (stderr 'taskkill hard failure', exit 5) did NOT die, so tests 401-402
# failed. The restart fix fb4897d5 added a forgive path: on a non-zero
# taskkill exit for TERM/KILL it verifies the targets are gone (bounded
# 2s wait) and returns success when none is still running, dying only
# when a target survives. The code reading says pid 4002 does not exist
# on the amd64 node, so _pid_is_running returns false, the forgive path
# returns 1, and the call never dies - the test never pins whether the
# target is alive, so its outcome depends on the host's pid table.
# Case A measures the liveness and asserts the outcome follows it.
# Case B pins the target alive and proves the die path is intact.
# Case C proves the #220 forgive shape still returns success.

my $home  = tempdir( CLEANUP => 1 );
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
my $files = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $manager = bless { paths => $paths, files => $files }, 'Developer::Dashboard::RuntimeManager';

plan tests => 6;

# Case A: the exact round-26 shape, hard taskkill failure, pid 4002.
{
    diag 'case A: before - stubbing OS_NAME to MSWin32';
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    diag 'case A: after - OS_NAME stubbed';
    no warnings 'redefine';
    diag 'case A: before - stubbing _powershell_command to pwsh';
    local *Developer::Dashboard::RuntimeManager::_powershell_command = sub { return 'pwsh' };
    diag 'case A: after - _powershell_command stubbed';
    diag 'case A: before - stubbing capture to hard taskkill failure';
    local *Developer::Dashboard::RuntimeManager::capture = sub (&) {
        return ( '', 'taskkill hard failure', 5 );
    };
    diag 'case A: after - capture stubbed';
    diag 'case A: before - measuring _pid_is_running(4002)';
    my $alive = $manager->_pid_is_running(4002) ? 1 : 0;
    diag "case A: after - _pid_is_running(4002) = $alive";
    diag 'case A: before - calling _send_signal(TERM, 4002)';
    my $send_ok = eval { $manager->_send_signal( 'TERM', 4002 ); 1 } // 0;
    my $error = $send_ok ? '' : $@;
    diag "case A: after - send_ok=$send_ok error=[$error]";
    if ($alive) {
        ok( !$send_ok, 'case A: hard taskkill failure dies when the target is alive' );
        like( $error, qr/Failed to stop Windows process ids 4002: taskkill hard failure/, 'case A: die names the pid and the taskkill text' );
    }
    else {
        ok( $send_ok, 'case A: hard taskkill failure is forgiven when the target is verifiably gone' );
        is( $error, '', 'case A: no die when the target is gone' );
    }
}

# Case B: same hard failure, but the target is pinned alive.
{
    diag 'case B: before - stubbing OS_NAME to MSWin32';
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    diag 'case B: after - OS_NAME stubbed';
    no warnings 'redefine';
    diag 'case B: before - stubbing _powershell_command to pwsh';
    local *Developer::Dashboard::RuntimeManager::_powershell_command = sub { return 'pwsh' };
    diag 'case B: after - _powershell_command stubbed';
    diag 'case B: before - stubbing capture to hard taskkill failure';
    local *Developer::Dashboard::RuntimeManager::capture = sub (&) {
        return ( '', 'taskkill hard failure', 5 );
    };
    diag 'case B: after - capture stubbed';
    diag 'case B: before - stubbing _pid_is_running to alive';
    local *Developer::Dashboard::RuntimeManager::_pid_is_running = sub { return 1 };
    diag 'case B: after - _pid_is_running stubbed';
    diag 'case B: before - calling _send_signal(TERM, 4002)';
    my $send_ok = eval { $manager->_send_signal( 'TERM', 4002 ); 1 } // 0;
    my $error = $send_ok ? '' : $@;
    diag "case B: after - send_ok=$send_ok error=[$error]";
    ok( !$send_ok, 'case B: hard taskkill failure dies when the target is pinned alive' );
    like( $error, qr/Failed to stop Windows process ids 4002: taskkill hard failure/, 'case B: die names the pid and the taskkill text' );
}

# Case C: the #220 shape - a tree child refused, target gone.
{
    diag 'case C: before - stubbing OS_NAME to MSWin32';
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    diag 'case C: after - OS_NAME stubbed';
    no warnings 'redefine';
    diag 'case C: before - stubbing _powershell_command to pwsh';
    local *Developer::Dashboard::RuntimeManager::_powershell_command = sub { return 'pwsh' };
    diag 'case C: after - _powershell_command stubbed';
    diag 'case C: before - stubbing capture to tree-child refusal';
    local *Developer::Dashboard::RuntimeManager::capture = sub (&) {
        return ( '', 'ERROR: The operation attempted is not supported', 1 );
    };
    diag 'case C: after - capture stubbed';
    diag 'case C: before - measuring _pid_is_running(4003)';
    my $alive = $manager->_pid_is_running(4003) ? 1 : 0;
    diag "case C: after - _pid_is_running(4003) = $alive";
    diag 'case C: before - calling _send_signal(TERM, 4003)';
    my $send_ok = eval { $manager->_send_signal( 'TERM', 4003 ); 1 } // 0;
    my $error = $send_ok ? '' : $@;
    diag "case C: after - send_ok=$send_ok error=[$error]";
    if ($alive) {
        ok( !$send_ok, 'case C: tree failure dies when the target is alive' );
        like( $error, qr/Failed to stop Windows process ids 4003: ERROR: The operation attempted is not supported/, 'case C: die names the pid and the taskkill text' );
    }
    else {
        ok( $send_ok, 'case C: tree failure is forgiven when the target is verifiably gone' );
        is( $error, '', 'case C: no die when the target is gone' );
    }
}

__END__

=head1 NAME

t/993-micro-t09-send-signal.t - reproduce the round-26 t/09 tests 401-402 failure

=head1 PURPOSE

Prove, by measurement, why _send_signal('TERM', 4002) with a stubbed hard
taskkill failure does not die on the amd64 leg in round 26. The code
reading says the restart fix fb4897d5 added a forgive path that returns
success when every target is verifiably gone, and pid 4002 does not exist
on the amd64 node, so the call returns 1 instead of dying. The test
never pins whether the target is alive, so its outcome depends on the
host's pid table. Case A measures the liveness and asserts the outcome
follows it; case B pins the target alive and proves the die path is
intact; case C proves the #220 tree-failure forgive shape still returns
success. If case B fails, the die path itself is broken and the fix
belongs in the product. If case B passes, the fix is test-only: pin the
liveness in t/09 tests 401-402.

=head1 WHY IT EXISTS

Round 26 (build #230) failed on Linux amd64 t/09 tests 401-402 only:
the call did not die on an unexpected Windows taskkill failure. Before
any fix is attempted, the mechanism must be proven: is the forgive path
engaging because the target is gone, or is the die path itself broken?

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/993-micro-t09-send-signal.t) on
the loop branch, or locally with prove after make. Remove the file in a
cleanup commit when the t/09 fix is verified.

=head1 HOW TO USE

Commit it to windows/loop6-combined, push, then trigger a solo with
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined
t/993-micro-t09-send-signal.t 1. Read the diag lines in the console:
the measured _pid_is_running values for 4002 and 4003, and the
send_ok/error after each _send_signal call.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a diagnostic micro for the
t/09 tests 401-402 failure in round 26, in the testing-v1 loop.

=head1 EXAMPLES

If the mechanism is as the code reading says, every leg passes with
diag lines like "_pid_is_running(4002) = 0" and "send_ok=1 error=[]"
in case A, "send_ok= error=[Failed to stop Windows process ids 4002:
taskkill hard failure ...]" in case B, and "send_ok=1 error=[]" in
case C. If case B does not die, the die path is broken and the fix
belongs in RuntimeManager.pm, not in the test.

=cut
