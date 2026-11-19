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
use Developer::Dashboard::Collector;
use Developer::Dashboard::CollectorRunner;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::GoRoutine ();
use Developer::Dashboard::IndicatorStore;
use Developer::Dashboard::PathRegistry;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use POSIX qw(_exit);
use Test::More;
use Time::HiRes qw(sleep);

# The marker key under test, and the parent sentinel that proves a
# pre-exec /proc environ is the parent's environ, not empty or garbage.
my $MARKER_KEY = 'DEVELOPER_DASHBOARD_LOOP_RUNTIME';
my $SENTINEL   = "micro-parent-$$";

# _child_perl_inc_args()
# Returns explicit include switches for isolated Perl process fixtures.
# Input: none.
# Output: argument list preserving existing string-valued include directories.
sub _child_perl_inc_args {
    return map { ( '-I', File::Spec->rel2abs($_) ) }
      grep { defined($_) && !ref($_) && -d $_ } @INC;
}

# _read_environ_raw($pid)
# Reads one process's initial environ straight from procfs.
# Input: process id integer.
# Output: raw environ string, or undef when it cannot be read.
sub _read_environ_raw {
    my ($pid) = @_;
    my $file = "/proc/$pid/environ";
    return if !-r $file;
    open my $fh, '<', $file or return;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $raw;
}

# _marker_in_environ($raw, $key, $want)
# Checks one raw environ blob for one KEY=VALUE pair.
# Input: raw environ string, env key string, expected value string.
# Output: boolean true when the pair is present with that value.
sub _marker_in_environ {
    my ( $raw, $key, $want ) = @_;
    return 0 if !defined $raw || $raw eq '';
    for my $pair ( split /\0/, $raw ) {
        next if $pair !~ /^([^=]+)=(.*)$/s;
        return 1 if $1 eq $key && $2 eq $want;
    }
    return 0;
}

# _environ_has_sentinel($raw)
# Checks one raw environ blob for this process's parent sentinel.
# Input: raw environ string.
# Output: boolean true when the sentinel pair is present.
sub _environ_has_sentinel {
    my ($raw) = @_;
    return _marker_in_environ( $raw, 'MICRO_PARENT_SENTINEL', $SENTINEL );
}

# _matches_eventually($runner, $pid, $name, $budget)
# THE FIX CANDIDATE: polls _loop_runtime_matches until it accepts the pid
# or the budget runs out. A just-spawned child has not execed yet, so the
# first read sees the spawner's environ; the poll waits for the exec.
# Input: runner, process id, collector name, budget in seconds.
# Output: boolean true when the pid matched within the budget.
sub _matches_eventually {
    my ( $runner, $pid, $name, $budget ) = @_;
    my $deadline = time() + $budget;
    while (1) {
        return 1 if $runner->_loop_runtime_matches( $pid, $name );
        return 0 if time() >= $deadline;
        sleep 0.05;
    }
}

my $home            = tempdir( CLEANUP => 1 );
local $ENV{HOME}   = $home;
my $state_root_base = tempdir( CLEANUP => 1 );
local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = $state_root_base;
local $ENV{MICRO_PARENT_SENTINEL}         = $SENTINEL;
my $original_cwd = getcwd();
chdir $home or die $!;

my $paths = Developer::Dashboard::PathRegistry->new(
    home            => $home,
    app_name        => 'dashboard-test',
    workspace_roots => [$home],
    project_roots   => [$home],
    named_paths     => {},
);
my $runner = Developer::Dashboard::CollectorRunner->new(
    collectors => Developer::Dashboard::Collector->new( paths => $paths ),
    files      => Developer::Dashboard::FileRegistry->new( paths => $paths ),
    indicators => Developer::Dashboard::IndicatorStore->new( paths => $paths ),
    paths      => $paths,
);
my $key = $runner->_runtime_state_key;
diag "runtime key is $key; parent sentinel is $SENTINEL";

my $spawn_fixture = sub {
    my ($runtime_marker) = @_;
    my @argv = (
        $^X, _child_perl_inc_args(), '-MTime::HiRes', '-e',
        'my $t = shift; $0 = $t if defined $t && length $t; Time::HiRes::sleep(30)'
    );
    return Developer::Dashboard::GoRoutine::spawn(
        \@argv,
        defined $runtime_marker ? { env => { DEVELOPER_DASHBOARD_LOOP_RUNTIME => $runtime_marker } } : {},
    );
};
my $reap_fixture = sub {
    my ($pid) = @_;
    Developer::Dashboard::GoRoutine::terminate_process( $pid, 'KILL' );
    Developer::Dashboard::GoRoutine::wait_process($pid);
    return 1;
};

SKIP: {
    skip 'the runtime env marker is only readable where /proc exists', 10 if !-d '/proc';

    # Part A - deterministic pre-exec proof. The child stops itself before
    # exec, so the parent's read cannot race the exec: the environ it sees
    # is definitionally the pre-exec one.
    my $stopped = fork();
    die "fork failed: $!" if !defined $stopped;
    if ( $stopped == 0 ) {
        kill 'STOP', $$;
        local $ENV{$MARKER_KEY} = $key;
        exec $^X, _child_perl_inc_args(), '-MTime::HiRes', '-e', 'Time::HiRes::sleep(30)'
          or _exit(127);
    }
    diag "part A: stopped child pid is $stopped (pre-exec, self-STOPped)";
    my $pre = _read_environ_raw($stopped);
    diag "part A: pre-exec environ length is " . ( defined $pre ? length $pre : 'undef' );
    ok( !_marker_in_environ( $pre, $MARKER_KEY, $key ), 'pre-exec environ carries no runtime marker' );
    ok( _environ_has_sentinel($pre), 'pre-exec environ is the parent environ (sentinel present)' );
    kill 'CONT', $stopped;
    my $post;
    my $found = 0;
    for ( 1 .. 100 ) {
        $post  = _read_environ_raw($stopped);
        $found = _marker_in_environ( $post, $MARKER_KEY, $key );
        last if $found;
        sleep 0.05;
    }
    diag "part A: post-exec marker found after CONT is " . ( $found ? 'yes' : 'no' );
    ok( $found, 'same pid gains the runtime marker after exec' );
    ok( $runner->_loop_runtime_matches( $stopped, 'fixture.marker' ), '_loop_runtime_matches accepts the pid once it has execed' );
    kill 'KILL', $stopped;
    waitpid( $stopped, 0 );

    # Part B - the real fixture path, five trials. The immediate read is
    # logged only (timing-dependent); the polled fix-candidate call is
    # asserted. If any trial's immediate read misses while the poll finds
    # it, the race bit live on this leg.
    my $immediate_misses = 0;
    for my $trial ( 1 .. 5 ) {
        my $child = $spawn_fixture->($key);
        diag "part B trial $trial: spawned child pid is $child";
        my $immediate_raw   = _read_environ_raw($child);
        my $immediate_match = $runner->_loop_runtime_matches( $child, 'fixture.marker' );
        my $immediate_seen  = _marker_in_environ( $immediate_raw, $MARKER_KEY, $key );
        diag "part B trial $trial: immediate match=$immediate_match marker-seen=$immediate_seen environ-len="
          . ( defined $immediate_raw ? length $immediate_raw : 'undef' );
        $immediate_misses++ if !$immediate_match;
        my $eventual = _matches_eventually( $runner, $child, 'fixture.marker', 2 );
        ok( $eventual, "trial $trial: polled _loop_runtime_matches accepts the spawned child" );
        $reap_fixture->($child);
    }
    diag "part B: immediate reads missed $immediate_misses of 5 trials on this leg";
    ok( $immediate_misses >= 0, 'immediate-miss count logged (diagnostic only)' );
}

chdir $original_cwd or die $!;

=pod

=head1 NAME

t/995-micro-t07-environ-race.t - Micro-probe for the t/07 test 652 ARM64-only failure

=head1 DESCRIPTION

Round 32 (build #334) failed on ARM64 only at t/07 test 652:
C<_loop_runtime_matches> rejects a process that carries this runtime's
marker in its initial environ, even though the identical test passed on
amd64 in the same round. This micro decides whether the cause is a
read-vs-exec race (the parent reads F</proc/PID/environ> before the
just-spawned child has execed, so it sees the spawner's environ) or a
spawn-path defect (the env never reaches the child), and proves the
bounded-poll fix in the micro first.

=head1 PURPOSE

Pin down the exact mechanism behind the ARM64-only test 652 failure so
the fix lands in the right place (test-side poll vs product-side change)
instead of being guessed.

=head1 WHY IT EXISTS

A test that spawns a child and reads its environ in the next statement
has an inherent race on a slow node: fork returns before the child
execs, and the pre-exec environ is the parent's. The failure is
ARM64-only and the sibling argv-token test passes, which points at
timing rather than at the spawn layer, but that must be proven, not
assumed.

=head1 WHEN TO USE

Run as a Jenkins solo while investigating the round 32 t/07 test 652
failure. Remove in a cleanup commit when the investigation ends, like
every other micro.

=head1 HOW TO USE

Trigger as a Jenkins solo: TEST_FILE=t/995-micro-t07-environ-race.t on
branch windows/loop6-combined. Never run by hand against the nodes.

=head1 WHAT USES IT

Nothing in production uses this file. It is a throwaway investigation
micro for the testing-v1 loop.

=head1 EXAMPLES

A solo run proves the mechanism when part A shows the stopped,
pre-exec child has no marker but carries the parent sentinel, and the
same pid gains the marker after CONT and exec; part B then shows the
polled match accepting all five spawned children on every leg.

=cut
