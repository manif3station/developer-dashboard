use strict;
use warnings;

# MICRO PROBE — NEVER MERGE. Diagnoses the Windows t/05 collector failures
# (lines 805/824): `collector output tick.collector` stays empty after
# `d2 serve` and after `d2 restart`. Runs the exact tick command through
# CommandRunner::run_command (the path the loop worker uses) in both its
# single-quote form (as written in t/05) and its double-quote form, and
# prints stdout/stderr/exit_code for each, on all four legs.
# Run as a Jenkins solo: TEST_FILE=t/999-micro-t05-collector.t

use Test::More;
use Cwd qw(getcwd);
use Developer::Dashboard::CommandRunner ();

my $cwd         = getcwd();
my $tick_single = q{perl -MTime::HiRes=time -e 'printf qq{%.6f\n}, time'};
my $tick_double = q{perl -MTime::HiRes=time -e "printf qq{%.6f\n}, time"};

for my $case ( [ 'single-quote', $tick_single ], [ 'double-quote', $tick_double ] ) {
    my ( $label, $cmd ) = @{$case};
    print "MICRO-COLL: before run_command $label\n";
    my ( $stdout, $stderr, $exit, $timed_out ) = Developer::Dashboard::CommandRunner::run_command(
        source     => $cmd,
        cwd        => $cwd,
        env        => {},
        timeout_ms => 30_000,
    );
    $stdout = defined $stdout ? $stdout : '<undef>';
    $stderr = defined $stderr ? $stderr : '<undef>';
    print "MICRO-COLL: after run_command $label stdout=[$stdout] stderr=[$stderr] exit=$exit timed_out=$timed_out\n";
}

# prove without -v swallows a passing test's STDOUT, so a probe that
# always passes prints nothing anywhere. Fail deliberately at the end so
# the harness shows the dump above; the build verdict is meaningless
# for this probe — the dumped lines are the result.
fail('micro collector probe dump complete — deliberate fail so prove shows the dump');
done_testing;
