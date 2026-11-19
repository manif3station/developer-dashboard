use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(getcwd);
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Developer::Dashboard::Collector;
use Developer::Dashboard::CollectorRunner;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::IndicatorStore;
use Developer::Dashboard::PathRegistry;
use Local::CollectorFixture qw(wait_for_managed_loop);

my $IS_WINDOWS = $^O eq 'MSWin32';

# Two runtimes, two temp homes, one shared state base: the state root is
# keyed by the runtime root (md5 of its path identity), so each home gets
# its own hashed root under the same base - the production shape, and the
# shape the orphan investigation proved adopts across (a fresh run in a
# new home adopted a loop from a dead run's root). The working directory
# is a neutral tempdir, not either home, so no ancestor layer leaks one
# home's runtime root into the other's resolution.
my $cwd_home = tempdir( CLEANUP => 1 );
chdir $cwd_home or die "Unable to chdir to $cwd_home: $!";

my $home_a = tempdir( CLEANUP => 1 );
my $home_b = tempdir( CLEANUP => 1 );

sub _runner_for {
    my ($home) = @_;
    my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
    return (
        $paths,
        Developer::Dashboard::CollectorRunner->new(
            collectors => Developer::Dashboard::Collector->new( paths => $paths ),
            files      => Developer::Dashboard::FileRegistry->new( paths => $paths ),
            indicators => Developer::Dashboard::IndicatorStore->new( paths => $paths ),
            paths      => $paths,
        )
    );
}

my ( $paths_a, $runner_a ) = _runner_for($home_a);
my ( $paths_b, $runner_b ) = _runner_for($home_b);

# The runtime identity is the state root's key: the basename of the
# hashed state root directory. It is read off the existing state_root
# here (not a new accessor) so this micro runs unchanged before the fix
# lands, when the accessor does not exist yet.
sub _runtime_key {
    my ($paths) = @_;
    my ( undef, $dirs, $name ) = File::Spec->splitpath( $paths->state_root );
    return $name;
}

my $key_a = _runtime_key($paths_a);
my $key_b = _runtime_key($paths_b);

isnt( $key_a, $key_b, 'the two temp homes resolve to different runtime identities' );
like( $key_a, qr/\A[0-9a-f]{32}\z/, 'runtime identity A is the 32-hex state-root key' );
like( $key_b, qr/\A[0-9a-f]{32}\z/, 'runtime identity B is the 32-hex state-root key' );

# Unique per run, so a loop surviving an earlier run of this same file can
# never be mistaken for this run's (DD-518).
my $name = "adoption-scope-$$";
my $job  = { name => $name, interval => 3600, mode => 'singleton', command => 'true' };

my $loop_pid = $runner_a->start_loop($job);
ok( $loop_pid, 'runtime A starts a collector loop' );

my $ready = wait_for_managed_loop( $runner_a, $loop_pid, $name, ready => 1, timeout => 60 );
ok( $ready, 'runtime A loop is recognised and ready before anything else is asserted' );

# Positive control, before the defect: discovery inside one runtime
# works, so a failure below is the scoping and not the setup.
SKIP: {
    skip 'process-table discovery without pidfiles requires Linux procfs', 1 if !-d '/proc';
    is( $runner_a->_find_running_loop($name), $loop_pid,
        'runtime A discovers its own loop in the process table' );
}

# THE DEFECT (round-25 orphan investigation): a fresh runtime adopted a
# loop from a dead run's root and rewrote its pidfile and state into the
# fresh root, so the orphaned loop was never replaced and never died
# across runs. Adoption must only happen inside the runtime that owns
# the loop. This assertion comes before the fix-verification ones below
# because the fail-safe kills the run at the first failure: the observed
# failure must be the defect itself, not a missing identity carrier.
{
    my $adopted_b = $runner_b->_adopt_existing_loop_if_running(
        pidfile       => $runner_b->_pidfile($name),
        name          => $name,
        title         => $runner_b->_process_title($name),
        interval      => 3600,
        schedule_mode => 'interval',
    );
    is( $adopted_b, undef, 'runtime B does NOT adopt runtime A loop' );
    ok( !-f $runner_b->_pidfile($name), 'runtime B wrote no pidfile for the foreign loop' );
    ok( !-f $runner_b->_statefile($name), 'runtime B wrote no loop state for the foreign loop' );
}

# Positive control: adoption inside one runtime still works. The pidfile
# is deleted first, exactly the lost-record state the adoption exists
# for; the loop is the same runtime's, so it must be adopted, not
# duplicated.
{
    my $pidfile_a = $runner_a->_pidfile($name);
    unlink $pidfile_a or die "Unable to remove $pidfile_a: $!";
    my $adopted_a = $runner_a->_adopt_existing_loop_if_running(
        pidfile       => $pidfile_a,
        name          => $name,
        title         => $runner_a->_process_title($name),
        interval      => 3600,
        schedule_mode => 'interval',
    );
    is( $adopted_a, $loop_pid, 'runtime A still adopts its own loop after its pidfile is lost' );
    ok( -f $pidfile_a, 'runtime A repairs the missing pidfile on adoption' );
}

# Discovery is the unscoped path: the finder asks the process table,
# which is global. From the other runtime it must not find the loop.
SKIP: {
    skip 'process-table discovery without pidfiles requires Linux procfs', 1 if !-d '/proc';
    is( $runner_b->_find_running_loop($name), undef,
        'runtime B does NOT discover runtime A loop in the process table' );
}

# The spawned helper argv must carry the runtime identity: it is the one
# channel visible on every platform (CIM CommandLine on Windows, host
# /proc cmdline under qemu), and the helper-shape branch of the finder
# can only be scoped through it.
my @argv_a = $runner_a->_windows_background_loop_command($name);
my $argv_text = join ' ', @argv_a;
like(
    $argv_text,
    qr/--runtime\s+\Q$key_a\E(?:\s|\z)/,
    'the spawned loop helper argv carries runtime A identity',
);

# The loop's initial environ must carry the same identity: it is the one
# channel visible where the title cannot be observed, and the finder
# scopes its title and marker branches through it. /proc environ is a
# Linux-only read, so this is skipped where it does not exist.
SKIP: {
    skip 'the runtime env marker is only readable where /proc exists', 1 if !-d '/proc';
    my $env = _read_proc_environ($loop_pid);
    my ($runtime_marker) = $env =~ /(?:^|\0)DEVELOPER_DASHBOARD_LOOP_RUNTIME=([^\0]*)/;
    is( $runtime_marker, $key_a, 'the running loop carries runtime A identity in its initial environ' );
}

# Cleanup is this micro's own process hygiene, not orphan cleanup: the
# loop is a child this file spawned, and leaving it alive would point
# the t/994 detector at a dead home with a live loop one run later.
{
    my $stopped = eval { $runner_a->stop_loop($name) };
    my $deadline = time() + 10;
    while ( kill( 0, $loop_pid ) && time() < $deadline ) {
        sleep(0.1);
    }
    if ( kill( 0, $loop_pid ) ) {
        kill 'KILL', $loop_pid;
        waitpid( $loop_pid, 0 );
    }
    else {
        waitpid( $loop_pid, WNOHANG );
    }
    ok( !kill( 0, $loop_pid ), 'the micro loop is dead at the end of the run' );
    ok( !-f $runner_b->_pidfile($name), 'runtime B still has no pidfile at the end of the run' );
}

done_testing();

# _read_proc_environ($pid)
# Reads one process's initial environ block from procfs.
# Input: process id integer.
# Output: raw environ bytes, or '' when unreadable.
sub _read_proc_environ {
    my ($pid) = @_;
    my $file = "/proc/$pid/environ";
    return '' if !-r $file;
    open my $fh, '<', $file or return '';
    local $/;
    my $env = <$fh>;
    close $fh;
    return defined $env ? $env : '';
}

__END__

=head1 NAME

t/990-micro-orphan-adoption-scope.t - a fresh runtime must not adopt another runtime's collector loop

=head1 PURPOSE

Reproduce the cross-runtime adoption the orphan investigation proved:
a fresh supervisor adopted an already-running loop from a dead run's
root (the same micro-tick loop, started 08:43:36, was adopted in four
consecutive solos), rewrote its pidfile and state into the fresh root,
and so the orphaned loop was never replaced and never died across
runs. The micro starts a real loop in runtime A and proves runtime B
neither discovers it in the process table nor adopts it, while runtime
A still adopts its own loop after its pidfile is lost.

=head1 WHY IT EXISTS

Fix C (Michael's call, 19 Nov 2026): scope loop adoption to the
current runtime. Adoption exists to prevent duplicate loops WITHIN a
run when the pidfile is lost; adopting a dead run's loop is wrong on
its face. The runtime identity is the state root's key (md5 of the
runtime root), carried in the loop's initial environ (observable where
the title cannot be) and in its helper argv (observable on Windows and
under qemu, where the environ is not). This micro is the reproduction
for that fix: it fails while B adopts A's loop, and passes once
adoption is scoped.

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/990-micro-orphan-adoption-scope.t)
while iterating on the adoption scoping, and as a regression check after
any change to loop identity resolution, _find_running_loop,
_adopt_existing_loop_if_running, or the loop spawn path. Remove it from
the branch in a cleanup commit once fix C is verified, the way the
t/995 orphan-repro micro was removed after the investigation closed.

=head1 HOW TO USE

No setup: the micro builds two temp homes (two runtimes, two state
roots), starts one real loop in A, and asserts B neither finds nor
adopts it while A still adopts its own. The loop it spawns is stopped
at the end of the run; that cleanup is the micro's own process hygiene,
not orphan cleanup, and the orphans from the investigation are never
touched. The /proc-dependent assertions skip where procfs does not
exist (Windows, macOS); the adoption assertions run everywhere.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a micro-repro for fix C
in the testing-v1 loop, to be removed once the fix is verified.

=head1 EXAMPLES

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/990-micro-orphan-adoption-scope.t 1

Solo the micro on Jenkins; before the fix, runtime B adopts the loop
and the adoption assertions fail; after the fix, all four legs pass.

=cut
