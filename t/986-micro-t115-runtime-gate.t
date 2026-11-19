#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

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

plan tests => 10;

my $key = $runner->_runtime_state_key;

# The t/115 test-28 fixture verbatim: fake proc entries, stubbed readers.
# The only live pid in the set is the test process itself.
{
    require File::Path;
    my $root = File::Spec->catdir( $home, 'fake-collector-proc' );
    my $self_pid = POSIX::getpid();
    my @pids = map { $self_pid + $_ } ( 10000, 10001, 10002, 10003 );
    File::Path::make_path( $root, map { File::Spec->catdir( $root, $_ ) } ( $self_pid, @pids ) );
    no warnings 'redefine';
    local $Developer::Dashboard::CollectorRunner::PROCFS_ROOT = $root;
    local *Developer::Dashboard::CollectorRunner::_process_title = sub { 'collector-fixture' };
    local *Developer::Dashboard::CollectorRunner::_read_proc_file = sub {
        my ( undef, $path ) = @_;
        return '' if $path =~ m{/\Q$pids[0]\E/cmdline\z};
        return 'command line' if $path =~ m{/\Q$pids[1]\E/cmdline\z};
        return undef;
    };
    local *Developer::Dashboard::CollectorRunner::_read_process_title = sub {
        my ( undef, $pid ) = @_;
        return 'other-title' if $pid == $pids[1];
        return 'collector-fixture';
    };
    local *Developer::Dashboard::CollectorRunner::_same_pid_namespace = sub {
        my ( undef, $pid ) = @_;
        return $pid == $pids[3] ? 1 : 0;
    };

    # 1. Reproduction of the round-28 failure, fixture as-is.
    is( $runner->_find_running_loop('fixture'), undef,
        'micro: fixture as-is finds no loop (round-28 repro)' );

    # 2-3. The gate is the cause, and its first guard is liveness.
    is( $runner->_loop_runtime_matches( $pids[3], 'fixture' ), 0,
        'micro: runtime gate rejects the fake positive candidate' );
    ok( !kill( 0, $pids[3] ),
        'micro: the fake positive candidate is not a live process' );

    # 4. No identity channel can help a fake pid: even with the env marker
    # stubbed to this runtime's key AND the title carrying the --runtime
    # token, the gate still returns 0, because its kill-0 guard runs first.
    {
        local *Developer::Dashboard::CollectorRunner::_read_process_env_marker = sub {
            my ( undef, undef, $wanted ) = @_;
            return $key if $wanted eq 'DEVELOPER_DASHBOARD_LOOP_RUNTIME';
            return undef;
        };
        local *Developer::Dashboard::CollectorRunner::_read_process_title = sub {
            return "collector-fixture --runtime $key";
        };
        is( $runner->_loop_runtime_matches( $pids[3], 'fixture' ), 0,
            'micro: marker plus token still cannot match a fake pid' );
    }

    # 7. The fix: hold the gate at yes for the positive candidate only.
    # The stub is behaviour-identical to the real gate for every other pid
    # (a fake pid fails the real gate on liveness), so only the one bit
    # the fixture cannot provide changes.
    {
        local *Developer::Dashboard::CollectorRunner::_loop_runtime_matches = sub {
            my ( undef, $pid ) = @_;
            return $pid == $pids[3] ? 1 : 0;
        };
        is( $runner->_find_running_loop('fixture'), $pids[3],
            'micro: with the gate held at yes, the fixture finds its loop' );
        is( $runner->_find_running_loop(''), undef,
            'micro: fix keeps the empty-name rejection' );
        {
            local *Developer::Dashboard::CollectorRunner::_read_process_title = sub { return undef };
            is( $runner->_find_running_loop('fixture'), undef,
                'micro: fix keeps the unavailable-title rejection' );
        }
        {
            local *Developer::Dashboard::CollectorRunner::_same_pid_namespace = sub { return 0 };
            is( $runner->_find_running_loop('fixture'), undef,
                'micro: fix keeps the foreign-namespace rejection' );
        }
    }
}

# 5. The token channel works for a live pid: this test process, alive,
# with a stubbed title carrying this runtime's token, matches the gate.
{
    no warnings 'redefine';
    local *Developer::Dashboard::CollectorRunner::_read_process_title = sub {
        return "d2 collector: fixture --runtime $key";
    };
    is( $runner->_loop_runtime_matches( $$, 'fixture' ), 1,
        'micro: a live pid carrying the runtime token matches the gate' );
}

# 6. The gate still fails closed for a live pid with no identity: this
# test process, no stubs, carries no marker, no token and no loop state.
is( $runner->_loop_runtime_matches( $$, 'fixture' ), 0,
    'micro: a live pid with no runtime identity does not match the gate' );

__END__

=head1 NAME

t/986-micro-t115-runtime-gate.t - micro-repro for the round-28 t/115 test-28 failure

=head1 PURPOSE

This micro proves, on Jenkins, whether the round-28 failure of
t/115-collectorrunner-coverage-2.t test 28 is a product defect in the
fix-C runtime gate or a stale test fixture: it reproduces the failure
with the fixture as-is, shows the gate rejects the fixture's positive
candidate because the candidate pid is not alive, shows no identity
channel can help a fake pid, shows the gate still matches a live pid
that carries identity and still refuses a live pid that does not, and
shows the test-side fix (holding the gate at yes for the positive
candidate) restores the find.

=head1 WHY IT EXISTS

Round 28 failed on exactly one genuine failure: amd64 t/115 test 28,
which expects C<_find_running_loop('fixture')> to return the only
same-namespace candidate from a fake proc directory. Fix C scoped
every branch of C<_find_running_loop> through
C<_loop_runtime_matches>, which fails closed when a candidate carries
no runtime identity. The fixture's candidate pids are synthetic, so
they cannot be alive and cannot carry identity, and the gate's first
guard (C<kill 0>) rejects them before any identity channel is even
consulted. Whether that is a product defect or a stale fixture cannot
be decided by reading the code alone: the micro measures each step so
the fix lands in the right layer.

=head1 WHEN TO USE

Use this file only while investigating the round-28 t/115 test-28
failure. It is a throwaway micro: remove it from the branch in a
cleanup commit once the fix is verified and t/115 is green on all four
legs. Do not extend it into a permanent test; the permanent coverage
of the runtime gate lives in the t/07 unit tests added by fix C.

=head1 HOW TO USE

Run it as a Jenkins solo on the loop branch:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/986-micro-t115-runtime-gate.t 1

The checks are hermetic: every path lives under a throwaway HOME that
the test chdirs into first, and the fake proc directory is built under
that HOME. The positive candidate pids are synthetic (the test pid
plus an offset), so no real process is ever signalled; the only live
pid the micro touches is its own (C<kill 0> reads, never a signal).
The C<local> stubs are scoped to their blocks and die with them.

=head1 WHAT USES IT

Nothing uses this file. It is a diagnostic micro for the t/115
applier, read by the applier and the loop owner only.

=head1 EXAMPLES

Reproduce the round-28 failure (test 1 fails before the fix, passes
after the t/115 fix is applied):

  prove -l t/986-micro-t115-runtime-gate.t

The interesting assertions are 4 and 5: 4 shows that provisioning
both identity channels still cannot match a fake pid, and 5 shows the
same token matches as soon as the pid is alive. Together they are the
whole product-vs-test verdict.
