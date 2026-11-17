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
    print STDERR "MICRO-COLL: before run_command $label\n";
    my ( $stdout, $stderr, $exit, $timed_out ) = Developer::Dashboard::CommandRunner::run_command(
        source     => $cmd,
        cwd        => $cwd,
        env        => {},
        timeout_ms => 30_000,
    );
    $stdout = defined $stdout ? $stdout : '<undef>';
    $stderr = defined $stderr ? $stderr : '<undef>';
    print STDERR "MICRO-COLL: after run_command $label stdout=[$stdout] stderr=[$stderr] exit=$exit timed_out=$timed_out\n";
}

# The dump above goes to STDERR, which prove passes through even for a
# passing test (plain STDOUT is swallowed without -v, and a deliberate
# fail is self-defeating under fail-fast: the fastest leg fails first
# and kills the other three before they run). So this probe PASSES by
# design; the dumped lines are the result.
pass('micro collector probe ran');
done_testing;
