use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Spec;
use Test::More;
use Time::HiRes qw(sleep);

use lib 'lib';

use Developer::Dashboard::GoRoutine qw(spawn terminate_process wait_process);

# Micro: reproduce the build #234 t/09 test 92 failure and prove the
# mechanism before any fix. Test 92 expects a GoRoutine-spawned perl
# child that installed a $SIG{TERM} handler to exit 0 after
# terminate_process($pid, 'TERM'). On Windows it exited 143. The code
# reading says GoRoutineProcess.xs maps Windows TERM to
# TerminateProcess(process, 143): an uncatchable kill, so the handler
# can never run and wait_process reports the 143 the terminator set.
# On POSIX, terminate_process sends a real SIGTERM, the handler runs,
# and the child exits 0. This micro spawns a child that installs a TERM
# handler recording its run in a marker file, sends TERM through
# GoRoutine, and records the wait status and whether the marker exists.
# If Windows reports 143 with no marker and Unix reports 0 with a
# marker, the mechanism is proven and the fix is test-only: the t/09
# expectation is Unix-only. If Windows reports 0 with a marker, the
# code reading is wrong and the failure lies elsewhere.

my $IS_WINDOWS = $^O eq 'MSWin32';

my $dir = tempdir( CLEANUP => 1 );
my $child_file = File::Spec->catfile( $dir, 'term-child.pl' );
my $ready_file = File::Spec->catfile( $dir, 'ready.txt' );
my $handled_file = File::Spec->catfile( $dir, 'handled.txt' );

diag 'before - writing the child script';
open my $child_fh, '>', $child_file or die "Unable to write $child_file: $!";
print {$child_fh} <<'CHILD';
use strict;
use warnings;
$SIG{TERM} = sub {
    open my $fh, '>', $ARGV[1] or exit 2;
    print {$fh} "handled\n";
    close $fh;
    exit 0;
};
open my $rfh, '>', $ARGV[0] or die "Unable to write ready file: $!";
print {$rfh} "ready\n";
close $rfh or die "Unable to close ready file: $!";
while (1) { select undef, undef, undef, 0.1; }
CHILD
close $child_fh or die "Unable to close $child_file: $!";
diag 'after - child script written';

plan tests => 4;

diag 'before - spawning the child';
my $pid = spawn( [ $^X, $child_file, $ready_file, $handled_file ], {} );
diag "after - spawned child pid=$pid";

diag 'before - polling for the ready file';
my $ready_seen = 0;
for ( 1 .. 30 ) {
    if ( -f $ready_file ) { $ready_seen = 1; last; }
    sleep 0.1;
}
diag "after - ready_seen=$ready_seen";
ok( $ready_seen, 'child installed its TERM handler and reported ready' );

diag 'before - sending TERM through GoRoutine';
my $term_ok = terminate_process( $pid, 'TERM' );
diag "after - terminate_process returned $term_ok";
ok( $term_ok, 'terminate_process TERM returns true' );

diag 'before - waiting for the child';
my $wait_status = wait_process($pid);
diag "after - wait_process returned $wait_status";
my $expected = $IS_WINDOWS ? 143 : 0;
is( $wait_status, $expected, $IS_WINDOWS ? 'Windows TERM is TerminateProcess(143), not a catchable signal' : 'TERM triggers the handler and the child exits 0' );

diag 'before - checking the handled marker';
my $handled = -f $handled_file ? 1 : 0;
diag "after - handled marker exists=$handled";
if ($IS_WINDOWS) {
    ok( !$handled, 'TERM handler never ran on Windows (TerminateProcess cannot be caught)' );
}
else {
    ok( $handled, 'TERM handler ran and recorded it' );
}

__END__

=head1 NAME

t/992-micro-t09-term-handler.t - reproduce the build #234 t/09 test 92 failure

=head1 PURPOSE

Prove, by measurement, why a GoRoutine-spawned child that installed a
$SIG{TERM} handler exits 143 instead of 0 on Windows after
terminate_process($pid, 'TERM'). The code reading says
GoRoutineProcess.xs maps Windows TERM to TerminateProcess(process,
143), an uncatchable kill, so the handler can never run. On POSIX the
same call sends a real SIGTERM and the handler runs. If the micro
shows 143 with no handled marker on Windows and 0 with a marker on
Unix, the mechanism is proven and the fix is test-only: t/09 test 92
(and its follow-on test 93, which expects the handler to have recorded
stopped status) carry a Unix-only expectation. If Windows shows 0 with
a marker, the code reading is wrong and the failure lies elsewhere.

=head1 WHY IT EXISTS

Build #234 (t/09 solo at cc80fc52) failed on the Windows leg only, at
test 92: got 143, expected 0. The other three legs passed test 92 and
two of them passed all 486 tests. Before any fix is attempted, the
mechanism must be proven: is the Windows TERM uncatchable by design,
or is the handler failing to install?

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/992-micro-t09-term-handler.t)
on the loop branch, or locally with prove after make. Remove the file
in a cleanup commit when the t/09 fix is verified.

=head1 HOW TO USE

Commit it to windows/loop6-combined, push, then trigger a solo with
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined
t/992-micro-t09-term-handler.t 1. Read the diag lines in the console:
the spawned pid, the wait_process return, and whether the handled
marker exists on each leg.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a diagnostic micro for
the t/09 test 92 failure in build #234, in the testing-v1 loop.

=head1 EXAMPLES

If the mechanism is as the code reading says, every leg passes with
diag lines like "wait_process returned 143" and "handled marker
exists=0" on Windows, and "wait_process returned 0" and "handled
marker exists=1" on Unix. If Windows reports 0 with a marker, the
TerminateProcess reading is wrong and the investigation must start
over.

=cut
