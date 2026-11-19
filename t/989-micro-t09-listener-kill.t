use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes qw(sleep);

use lib 'lib';

use Developer::Dashboard::Config;
use Developer::Dashboard::Collector;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;
use Developer::Dashboard::GoRoutine qw(spawn terminate_process wait_process process_running);

# Micro: reproduce the build #261 t/09 test 348 failure and find out WHY
# the listener child survives stop_web on Windows. Test 348 spawns a
# child that ignores TERM, stubs running_web (first call only),
# _listener_pids_for_port (always returns the child),
# _find_legacy_web_processes (empty) and _pkill_perl, then calls
# stop_web and asserts the child is gone. On Windows the child is
# still running afterwards. The code reading leaves three suspects:
# (a) taskkill never kills it, (b) Perl kill 0 says it is dead while
# GoRoutine process_running says it is alive, so the KILL escalation
# is skipped, (c) the pid stop_web signals is not the child. This
# micro replicates the block exactly and records, after stop_web,
# what process_running, kill 0 and _pid_is_running each say, plus
# whether a post-hoc KILL through GoRoutine finishes it. If (b) is
# true, kill 0 is false while process_running is true.

my $IS_WINDOWS = $^O eq 'MSWin32';
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = File::Spec->catdir( $home, 'state' );
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
my $files = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $runner = bless( {}, 'Local::SignalTestRunner' );
my $manager = Developer::Dashboard::RuntimeManager->new(
    app_builder => sub { die "app builder should not run here\n" },
    config      => $config,
    files       => $files,
    paths       => $paths,
    runner      => $runner,
);

plan tests => 3;

diag 'before - spawning the TERM-ignoring listener child';
my $listener = spawn(
    [ $^X, '-e', q{$SIG{TERM} = 'IGNORE'; sleep 30;} ],
    {},
);
diag "after - spawned listener pid=$listener";
ok( process_running($listener), 'listener child is running before stop_web' );

my $calls = 0;
{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::running_web = sub {
        return $calls++ == 0 ? { pid => $listener, port => 7908 } : undef;
    };
    local *Developer::Dashboard::RuntimeManager::_listener_pids_for_port = sub { return ($listener) };
    local *Developer::Dashboard::RuntimeManager::_find_legacy_web_processes = sub { return () };
    local *Developer::Dashboard::RuntimeManager::_pkill_perl = sub { return 1 };
    diag 'before - calling stop_web';
    my $stopped = $manager->stop_web;
    diag "after - stop_web returned [$stopped]";
    is( $stopped, $listener, 'stop_web returns the recorded pid while it also tracks listener pids on the bound port' );
}
diag 'before - measuring the child three ways after stop_web';
my $by_goroutine = process_running($listener) ? 1 : 0;
my $by_kill0 = kill( 0, $listener ) ? 1 : 0;
my $by_manager = $manager->_pid_is_running($listener) ? 1 : 0;
diag "after - process_running=$by_goroutine kill0=$by_kill0 _pid_is_running=$by_manager";
ok( !$by_goroutine, 'stop_web escalates listener-port pids to KILL when they remain alive after TERM' );
if ($by_goroutine) {
    diag 'before - post-hoc KILL through GoRoutine';
    my $kill_ok = terminate_process( $listener, 'KILL' );
    my $waited = wait_process($listener);
    diag "after - terminate KILL returned $kill_ok wait_process returned $waited";
}

__END__

=head1 NAME

t/989-micro-t09-listener-kill.t - reproduce the build #261 t/09 test 348 failure

=head1 PURPOSE

Find out why the TERM-ignoring listener child survives stop_web on
Windows. Replicates the t/09 test 348 block exactly (same stubs, same
child) and records, after stop_web, what GoRoutine process_running,
Perl kill 0 and RuntimeManager _pid_is_running each say about the
child, plus whether a post-hoc KILL finishes it. The three suspects
are: taskkill never kills it; kill 0 says dead while process_running
says alive so the KILL escalation is skipped; or stop_web signals a
different pid than the child.

=head1 WHY IT EXISTS

Build #261 (t/09 solo at edd1fa2f) failed the Windows leg at test 348
only: stop_web returned the listener pid but the child was still
running afterwards. All three other legs passed all 486 tests. The
mechanism is not readable from the code alone - the Windows branch
sends TERM then KILL to the recorded pid - so it must be measured.

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/989-micro-t09-listener-kill.t)
on the loop branch, or locally with prove after make. Remove the file
in a cleanup commit when the t/09 fix is verified.

=head1 HOW TO USE

Commit it to windows/loop6-combined, push, then trigger a solo with
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined
t/989-micro-t09-listener-kill.t 1. Read the diag lines in the console:
the three liveness readings after stop_web, and the post-hoc KILL
result if the child survived.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a diagnostic micro for
the t/09 test 348 failure in build #261, in the testing-v1 loop.

=head1 EXAMPLES

If kill 0 is false while process_running is true, the KILL escalation
was skipped because stop_web trusts kill 0 - the fix belongs in the
Windows branch's liveness check. If all three readings say alive, the
taskkill itself is not killing this child - the fix belongs in
_send_signal or in how the child is spawned. If all three say dead,
the failure did not reproduce and the cause is timing.

=cut
