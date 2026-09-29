#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Benchmark;

{
    package Local::BenchmarkManifest;
    sub new { return bless {}, shift; }
    sub to_hash { return { packages => {} }; }
}

{
    package Local::BenchmarkRegionSelector;
    sub new { return bless {}, shift; }
    sub select { return { selected => [] }; }
}

{
    package Local::BenchmarkHIR;
    sub new { return bless {}, shift; }
    sub lower_all { return [{ unit => 'lowered' }]; }
}

{
    package Local::BenchmarkSSA;
    sub new { return bless {}, shift; }
    sub build_all { return [{ unit => 'ssa' }]; }
}

{
    package Local::BenchmarkTier1;
    our @ARTIFACTS;
    sub new { return bless {}, shift; }
    sub compile { return shift @ARTIFACTS; }
}

{
    package Local::BenchmarkNativeRunner;
    sub new { return bless {}, shift; }
    sub run_i64_binary {
        my ( $self, %args ) = @_;
        return { exit => 0, result => $args{left} + $args{right} };
    }
}

my $default = Developer::Dashboard::Pax::Benchmark->new();
is( $default->{iterations}, 3, 'benchmark runner defaults to three samples' );
is( $default->{pax_bin}, undef, 'benchmark runner retains an absent optional executable path' );

my $configured = Developer::Dashboard::Pax::Benchmark->new( iterations => 0, pax_bin => '/opt/pax' );
is( $configured->{iterations}, 0, 'benchmark runner preserves a deliberate zero-iteration configuration' );
is( $configured->{pax_bin}, '/opt/pax', 'benchmark runner retains its optional executable path' );

{
    no warnings 'redefine';
    my @captures = (
        { status => 'ok' },
        { status => 'error', diagnostics => ['compiler unavailable'] },
        sub { die "capture exploded\n" },
    );
    my @rss = ( 100, 101, 102, 103, 104 );
    local *Developer::Dashboard::Pax::Capture::capture = sub {
        my $next = shift @captures;
        return $next->() if ref($next) eq 'CODE';
        return $next;
    };
    local *Developer::Dashboard::Pax::Benchmark::_current_rss_kb = sub { return shift @rss };

    my $result = $default->run_capture_benchmark('app.pl');
    is( $result->{benchmark_class}, 'capture_overhead', 'capture benchmark identifies its benchmark kind' );
    is( $result->{iterations}, 3, 'capture benchmark uses the configured sample count' );
    is_deeply( [ map { $_->{exit} } @{ $result->{samples} } ], [ 0, 1, 1 ], 'capture status and exceptions are recorded as successful or failed samples' );
    is_deeply( [ map { $_->{iteration} } @{ $result->{samples} } ], [ 1, 2, 3 ], 'capture samples carry one-based iteration numbers' );
    is( $result->{memory_impact}{delta_rss_kb}, 4, 'capture benchmark reports RSS change across its run' );
    ok( $result->{mean_seconds} >= 0, 'capture benchmark computes a non-negative mean' );
    ok( $result->{warm_up_seconds} >= 0, 'capture benchmark records the first-sample warm-up time' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Benchmark::_current_rss_kb = sub { return undef };
    my $result = $configured->run_capture_benchmark('empty.pl');
    is_deeply( $result->{samples}, [], 'zero-iteration capture produces no samples' );
    is( $result->{mean_seconds}, 0, 'zero-iteration capture mean is zero' );
    is( $result->{warm_up_seconds}, 0, 'zero-iteration capture has no warm-up duration' );
    is( $result->{memory_impact}{measured}, JSON::XS::false(), 'unavailable RSS measurements are explicitly marked unavailable' );
    is( $result->{memory_impact}{delta_rss_kb}, undef, 'unavailable RSS measurements have no fabricated delta' );
}

my $memory = Developer::Dashboard::Pax::Benchmark::_memory_impact( 8, 11 );
is( $memory->{measured}, JSON::XS::true(), 'memory accounting marks two measured RSS values as available' );
is( $memory->{delta_rss_kb}, 3, 'memory accounting subtracts before from after' );
is( $memory->{unit}, 'KiB', 'memory accounting labels its unit' );
my $memory_before_missing = Developer::Dashboard::Pax::Benchmark::_memory_impact( undef, 11 );
is( $memory_before_missing->{measured}, JSON::XS::false(), 'memory accounting handles a missing starting measurement' );
is( $memory_before_missing->{delta_rss_kb}, undef, 'missing starting RSS does not produce a delta' );
my $memory_after_missing = Developer::Dashboard::Pax::Benchmark::_memory_impact( 8, undef );
is( $memory_after_missing->{measured}, JSON::XS::false(), 'memory accounting handles a missing ending measurement' );
is( $memory_after_missing->{delta_rss_kb}, undef, 'missing ending RSS does not produce a delta' );

is( Developer::Dashboard::Pax::Benchmark::_summarise([])->{mean_seconds}, 0, 'empty timing summaries use zero mean' );
is( Developer::Dashboard::Pax::Benchmark::_summarise([])->{warm_up_seconds}, 0, 'empty timing summaries use zero warm-up' );
my $summary = Developer::Dashboard::Pax::Benchmark::_summarise([
    { elapsed_seconds => 2 },
    { elapsed_seconds => 4 },
]);
is( $summary->{mean_seconds}, 3, 'timing summaries compute the arithmetic mean' );
is( $summary->{warm_up_seconds}, 2, 'timing summaries use the first sample as warm-up' );

my $work = tempdir( CLEANUP => 1 );
my $empty_status_path = File::Spec->catfile( $work, 'status-without-rss' );
_write( $empty_status_path, "Name:\ttest\n" );
is( Developer::Dashboard::Pax::Benchmark::_current_rss_kb($empty_status_path), undef, 'RSS parser returns unavailable when a status file has no VmRSS record' );
is( Developer::Dashboard::Pax::Benchmark::_current_rss_kb( File::Spec->catfile( $work, 'missing-status' ) ), undef, 'RSS reader returns unavailable when its status file cannot be opened' );
my $rss_status_path = File::Spec->catfile( $work, 'status-with-rss' );
_write( $rss_status_path, "Name:\ttest\nVmRSS:\t321 kB\n" );
is( Developer::Dashboard::Pax::Benchmark::_current_rss_kb($rss_status_path), 321, 'RSS parser returns the VmRSS value in KiB' );
ok( defined Developer::Dashboard::Pax::Benchmark::_current_rss_kb(), 'RSS reader defaults to the current process status file' );
ok( defined Developer::Dashboard::Pax::Benchmark::_current_rss_kb(''), 'RSS reader treats an empty path as the current process status file' );

my $entrypoint = File::Spec->catfile( $work, 'exit.pl' );
_write( $entrypoint, "exit 0;\n" );
my $command_bench = Developer::Dashboard::Pax::Benchmark->new( iterations => 1 );
my $command_result = $command_bench->_time_command( [ $^X, $entrypoint ] );
is( $command_result->{samples}[0]{exit}, 0, 'reference timing records a successful Perl subprocess' );
_write( $entrypoint, "exit 7;\n" );
my $failed_command_result = $command_bench->_time_command( [ $^X, $entrypoint ] );
is( $failed_command_result->{samples}[0]{exit}, 7, 'reference timing records a non-zero Perl subprocess status' );

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Benchmark::_time_command = sub { return { mean_seconds => 2 }; };
    local *Developer::Dashboard::Pax::Benchmark::run_capture_benchmark = sub {
        return { mean_seconds => 1, warm_up_seconds => 0.5 };
    };
    local *Developer::Dashboard::Pax::Benchmark::_time_native = sub {
        return { available => JSON::XS::false(), mean_seconds => undef, result => undef };
    };
    my $runtime = $command_bench->run_runtime_benchmark('app.pl');
    is( $runtime->{benchmark_class}, 'runtime', 'runtime benchmark identifies its benchmark kind' );
    is( $runtime->{reference_mean_seconds}, 2, 'runtime benchmark includes reference timing' );
    is( $runtime->{capture_mean_seconds}, 1, 'runtime benchmark includes capture timing' );
    is( $runtime->{fallback_share}, 1, 'runtime benchmark marks all-fallback execution when native code is unavailable' );
    is( $runtime->{native_mean_seconds}, undef, 'runtime benchmark does not invent an unavailable native timing' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Benchmark::_time_command = sub { return { mean_seconds => 2 }; };
    local *Developer::Dashboard::Pax::Benchmark::run_capture_benchmark = sub {
        return { mean_seconds => 1, warm_up_seconds => 0.5 };
    };
    local *Developer::Dashboard::Pax::Benchmark::_time_native = sub {
        return { available => JSON::XS::true(), mean_seconds => 0.25, result => { exit => 0 } };
    };
    my $runtime = $command_bench->run_runtime_benchmark('app.pl');
    is( $runtime->{fallback_share}, 0, 'runtime benchmark marks no fallback when native code is available' );
    is( $runtime->{native_result}{exit}, 0, 'runtime benchmark preserves the native execution result' );
}

{
    no warnings 'redefine';
    @Local::BenchmarkTier1::ARTIFACTS = ( { entry_kind => 'perl_fallback', executable_path => undef } );
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    local *Developer::Dashboard::Pax::Manifest::new = sub { return Local::BenchmarkManifest->new(); };
    local *Developer::Dashboard::Pax::RegionSelector::new = sub { return Local::BenchmarkRegionSelector->new(); };
    local *Developer::Dashboard::Pax::HIR::new = sub { return Local::BenchmarkHIR->new(); };
    local *Developer::Dashboard::Pax::GuardedSSA::new = sub { return Local::BenchmarkSSA->new(); };
    local *Developer::Dashboard::Pax::Tier1::new = sub { return Local::BenchmarkTier1->new(); };
    local *Developer::Dashboard::Pax::Benchmark::_current_rss_kb = sub { return 10; };

    my $unavailable = $command_bench->_time_native('app.pl');
    is( $unavailable->{available}, JSON::XS::false(), 'native timing reports unavailable when no compiled i64 leaf exists' );
    is( $unavailable->{mean_seconds}, undef, 'unavailable native timing has no mean' );
    is( $unavailable->{result}, undef, 'unavailable native timing has no result' );

    @Local::BenchmarkTier1::ARTIFACTS = ({ entry_kind => 'native_i64_leaf', executable_path => undef });
    my $not_executable = $command_bench->_time_native('app.pl');
    is( $not_executable->{available}, JSON::XS::false(), 'native leaf metadata without an executable is not timed as native' );

    @Local::BenchmarkTier1::ARTIFACTS = ({ executable_path => '/tmp/not-a-native-leaf' });
    my $untyped_artifact = $command_bench->_time_native('app.pl');
    is( $untyped_artifact->{available}, JSON::XS::false(), 'artifacts without an entry kind are not mistaken for native leaves' );

    @Local::BenchmarkTier1::ARTIFACTS = ({ entry_kind => 'native_i64_leaf', executable_path => '/tmp/native-leaf' });
    local *Developer::Dashboard::Pax::NativeRunner::new = sub { return Local::BenchmarkNativeRunner->new(); };
    my $available = Developer::Dashboard::Pax::Benchmark->new(iterations => 2)->_time_native('app.pl');
    is( $available->{available}, JSON::XS::true(), 'native timing runs when a compiled i64 leaf is available' );
    is( $available->{result}{result}, 42, 'native timing preserves the last measured execution result' );
    is( $available->{samples}[1]{iteration}, 2, 'native timing records every configured sample' );
}

done_testing();

sub _write {
    # Write a small executable fixture for the reference-runtime subprocess.
    # Inputs are the file path and Perl source text; output is true after close.
    my ( $path, $source ) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $source or die "cannot write $path: $!";
    close $fh or die "cannot close $path: $!";
    return 1;
}

__END__

=head1 NAME

t/237-pax-benchmark-coverage.t - benchmark result and runtime-path coverage

=head1 PURPOSE

Exercise the benchmark result contracts for capture-only, reference-runtime,
native-runtime, timing-summary, and memory-accounting paths.

=head1 WHY IT EXISTS

Benchmarks have meaningful failure and unavailable-runtime results as well as
successful timings. This test keeps their public result shapes and zero-sample,
capture-error, subprocess-error, native-available, and memory-unavailable
behavior covered in the same Perl process where Devel::Cover can observe it.

=head1 WHEN TO USE

Run when changing C<Developer::Dashboard::Pax::Benchmark>, its result fields,
or the way capture, reference, and native measurements are combined.

=head1 HOW TO USE

From the repository root, run the test in the development Docker service:

  d2 docker compose --project-name problem20 \
    -f .developer-dashboard/config/docker/d2/compose.yml \
    -f .developer-dashboard/config/docker/d2/development.compose.yml \
    exec -T dev prove -lv t/237-pax-benchmark-coverage.t

The test uses short temporary Perl entrypoints for subprocess exit statuses and
stubs the PAX pipeline when asserting the benchmark's result-combination logic.

=head1 WHAT USES IT

The focused regression suite protects the internal PAX benchmark module; the
full instrumented suite also executes it through release and validation tests.

=head1 EXAMPLES

Example 1 - capture samples retain a failed capture:

  my $result = Developer::Dashboard::Pax::Benchmark->new(iterations => 3)
    ->run_capture_benchmark('app.pl');
  # A capture failure is represented by sample exit => 1.

Example 2 - a reference command's real exit status is retained:

  my $result = $benchmark->_time_command([$^X, 'app.pl']);
  # Each sample includes its iteration number, exit status, duration, and RSS.

Example 3 - native absence is explicit:

  my $result = $benchmark->run_runtime_benchmark('app.pl');
  # Check native_available before consuming native_mean_seconds.

=cut
