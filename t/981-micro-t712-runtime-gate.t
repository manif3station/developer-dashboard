#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use Developer::Dashboard::Collector;
use Developer::Dashboard::CollectorRunner;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::IndicatorStore;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::GoRoutine ();

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

my $key = $runner->_runtime_state_key;

plan tests => 10;

SKIP: {
    skip '/proc is not listable here', 7 if !-d '/proc';
    no warnings 'redefine';
    my $calls = 0;
    my @seen;
    local *Developer::Dashboard::CollectorRunner::_read_proc_file = sub { return 'x' };
    local *Developer::Dashboard::CollectorRunner::_read_process_title = sub { return 'd2 collector: s8-ns' };
    local *Developer::Dashboard::CollectorRunner::_same_pid_namespace = sub {
        my ( undef, $pid ) = @_;
        push @seen, $pid;
        return ++$calls >= 2 ? 1 : 0;
    };

    # 1-2. Reproduction of the round-30 failure, t/712 fixture verbatim.
    my $found = $runner->_find_running_loop('s8-ns');
    is( $found, undef, 'micro: fixture as-is finds no loop (round-30 repro)' );
    ok( $calls > 2, 'micro: fixture as-is scans past the second candidate (round-30 repro)' );

    # 3-5. The gate is the cause: the positive candidate is alive but
    # carries no runtime identity through any of the three channels.
    my $positive = $seen[1];
    is( $runner->_loop_runtime_matches( $positive, 's8-ns' ), 0,
        'micro: runtime gate rejects the positive candidate' );
    my $marker = $runner->_read_process_env_marker( $positive, 'DEVELOPER_DASHBOARD_LOOP_RUNTIME' );
    isnt( $marker, $key, 'micro: positive candidate carries no marker for this runtime' );
    is( $runner->_state_confirms_managed_loop( 's8-ns', $positive ), 0,
        'micro: positive candidate has no loop state for this runtime' );

    # 6-7. The fix: hold the gate at yes for the positive candidate only.
    # The stub is behaviour-identical to the real gate for every other pid
    # (tests 3-5: the real gate returns 0 for them), so only the one bit
    # the fixture cannot provide changes. The positive pid is taken from
    # the scan itself, so no second /proc read can race the find.
    {
        $calls = 0;
        @seen  = ();
        local *Developer::Dashboard::CollectorRunner::_loop_runtime_matches = sub {
            my ( undef, $pid ) = @_;
            return $pid == $seen[1] ? 1 : 0;
        };
        my $found2 = $runner->_find_running_loop('s8-ns');
        is( $found2, $seen[1], 'micro: with the gate held at yes, the fixture finds its loop' );
        is( $calls, 2, 'micro: with the gate held at yes, the scan stops at the second candidate' );
    }
}

# 8. The state channel works for a live pid: a loop state record naming
# this process matches the gate, so the product can adopt a real loop
# that carries identity - the fixture just provides none.
{
    $runner->_write_loop_state( 's8-state',
        { pid => $$, name => 's8-state', process_name => 'd2 collector: s8-state' } );
    is( $runner->_loop_runtime_matches( $$, 's8-state' ), 1,
        'micro: a live pid with loop state matches the gate' );
}

# 9. The gate still fails closed for a live pid with no identity: this
# test process, no stubs, carries no marker, no token and no loop state
# for this name.
is( $runner->_loop_runtime_matches( $$, 's8-ns' ), 0,
    'micro: a live pid with no runtime identity does not match the gate' );

# 10. The token channel works for a live pid: a title carrying this
# runtime's token matches the gate.
{
    no warnings 'redefine';
    local *Developer::Dashboard::CollectorRunner::_read_process_title = sub {
        return "d2 collector: s8-ns --runtime $key";
    };
    is( $runner->_loop_runtime_matches( $$, 's8-ns' ), 1,
        'micro: a live pid carrying the runtime token matches the gate' );
}

__END__

=head1 NAME

t/981-micro-t712-runtime-gate.t - micro-repro for the round-30 t/712 tests 24-25 failure

=head1 PURPOSE

This micro proves, on Jenkins, whether the round-30 failure of
t/712-collectorrunner-coverage.t tests 24-25 is a product defect in the
fix-C runtime gate or a stale test fixture: it reproduces the failure
with the fixture as-is, shows the gate rejects the fixture's positive
candidate because the candidate carries no runtime identity through any
of the three channels, shows the product gate still matches a live pid
that carries identity (loop state, or the --runtime token) and still
refuses a live pid that does not, and shows the test-side fix (holding
the gate at yes for the positive candidate only) restores the find.

=head1 WHY IT EXISTS

Round 30 failed on exactly one genuine failure: amd64 t/712 tests
24-25, which expect C<_find_running_loop('s8-ns')> to return the
second same-namespace candidate from the real process table. Fix C
scoped every branch of C<_find_running_loop> through
C<_loop_runtime_matches>, which fails closed when a candidate carries
no runtime identity. The fixture stubs the title and namespace readers
but provides no identity at all, so the gate rejects every candidate
and the scan runs to the end of /proc. Whether that is a product
defect or a stale fixture cannot be decided by reading the code alone:
the micro measures each step so the fix lands in the right layer.

=head1 WHEN TO USE

Use this file only while investigating the round-30 t/712 tests 24-25
failure. It is a throwaway micro: remove it from the branch in a
cleanup commit once the fix is verified and t/712 is green on all four
legs. Do not extend it into a permanent test; the permanent coverage
of the runtime gate lives in the t/07 unit tests added by fix C.

=head1 HOW TO USE

Run it as a Jenkins solo on the loop branch:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/981-micro-t712-runtime-gate.t 1

The checks are hermetic: every path lives under a throwaway HOME that
the test chdirs into first. The positive candidate pids come from the
real process table, so the scan touches real pids, but only through
read-only queries (C<kill 0> reads, environ and title reads, never a
signal); the only pid the micro writes state for is its own. The
C<local> stubs are scoped to their blocks and die with them.

=head1 WHAT USES IT

Nothing uses this file. It is a diagnostic micro for the t/712
applier, read by the applier and the loop owner only.

=head1 EXAMPLES

Reproduce the round-30 failure (tests 1-2 fail before the fix, pass
after the t/712 fix is applied):

  prove -l t/981-micro-t712-runtime-gate.t

The interesting assertions are 6 and 8: 6 shows that holding the gate
at yes for the positive candidate restores the find with the scan
stopping at the second candidate, and 8 shows the same gate matches a
live pid the moment it carries loop state. Together they are the whole
product-vs-test verdict.
