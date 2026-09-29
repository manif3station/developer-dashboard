#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::BenchmarkMatrix;

{
    package Local::MatrixCapture;
    sub new { return bless {}, shift }
    sub capture { return { status => 'captured-' . $_[1] } }
}

{
    package Local::MatrixManifest;
    sub new {
        my ($class, %args) = @_;
        return bless { capture => $args{capture} }, $class;
    }
    sub to_hash {
        return { compatibility => { level => 'A', reason => 'fixture-' . $_[0]{capture}{status} } };
    }
}

{
    package Local::MatrixBenchmark;
    sub new {
        my ($class, %args) = @_;
        return bless { args => \%args }, $class;
    }
    sub run_runtime_benchmark { return { fixture => $_[1], iterations => $_[0]{args}{iterations} } }
}

my $matrix = Developer::Dashboard::Pax::BenchmarkMatrix->new();
is( $matrix->{iterations}, 1, 'constructor defaults iterations to one' );
is( $matrix->{manifest_path}, undef, 'constructor keeps a missing manifest path undefined' );
is( $matrix->{pax_bin}, undef, 'constructor keeps a missing executable undefined' );

my $tmp = tempdir( CLEANUP => 1 );
my $manifest_path = File::Spec->catfile( $tmp, 'matrix.json' );
_write( $manifest_path, '{"classes":[{"id":"empty","fixtures":[]}]}' );

my $empty_matrix = Developer::Dashboard::Pax::BenchmarkMatrix->new(
    manifest_path => $manifest_path,
    iterations => 0,
    pax_bin => '/opt/pax',
);
is( $empty_matrix->{iterations}, 0, 'explicit zero iterations are retained' );
my $empty_result = $empty_matrix->run;
is( $empty_result->{manifest_path}, $manifest_path, 'run reports its manifest path' );
is( $empty_result->{iterations}, 0, 'run reports configured iterations' );
is( $empty_result->{passed}, JSON::XS::true(), 'successful manifest processing is marked passed' );
is_deeply(
    $empty_result->{classes},
    [{ id => 'empty', description => undef, metrics => [], fixtures => [] }],
    'class defaults preserve missing description and metrics and empty fixtures',
);

_write(
    $manifest_path,
    '{"classes":[{"id":"populated","description":"demo","metrics":["runtime"],"fixtures":["one.pl","two.pl"]}]}',
);
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::new = sub { return Local::MatrixCapture->new() };
    local *Developer::Dashboard::Pax::Manifest::new = sub {
        my ( $class, %args ) = @_;
        return Local::MatrixManifest->new(%args);
    };
    local *Developer::Dashboard::Pax::Benchmark::new = sub {
        my ( $class, %args ) = @_;
        return Local::MatrixBenchmark->new(%args);
    };
    my $populated = Developer::Dashboard::Pax::BenchmarkMatrix->new(
        manifest_path => $manifest_path,
        iterations => 3,
        pax_bin => '/tmp/pax',
    )->run;
    is( $populated->{classes}[0]{description}, 'demo', 'class description is retained' );
    is_deeply( $populated->{classes}[0]{metrics}, ['runtime'], 'class metrics are retained' );
    is_deeply(
        $populated->{classes}[0]{fixtures},
        [
            {
                path => 'one.pl',
                capture_status => 'captured-one.pl',
                compatibility_level => 'A',
                fallback_reason => 'fixture-captured-one.pl',
                benchmark => { fixture => 'one.pl', iterations => 3 },
            },
            {
                path => 'two.pl',
                capture_status => 'captured-two.pl',
                compatibility_level => 'A',
                fallback_reason => 'fixture-captured-two.pl',
                benchmark => { fixture => 'two.pl', iterations => 3 },
            },
        ],
        'each fixture is captured, classified, benchmarked, and normalized',
    );
}

_write( $manifest_path, '{}' );
is_deeply(
    Developer::Dashboard::Pax::BenchmarkMatrix->new(manifest_path => $manifest_path)->run->{classes},
    [],
    'missing classes default to an empty list',
);

_write( $manifest_path, '{"classes":[{"id":"without-fixtures"}]}' );
is_deeply(
    Developer::Dashboard::Pax::BenchmarkMatrix->new(manifest_path => $manifest_path)->run->{classes}[0]{fixtures},
    [],
    'missing fixture lists default to an empty list',
);

my $missing_path = File::Spec->catfile( $tmp, 'missing.json' );
my $error = eval { Developer::Dashboard::Pax::BenchmarkMatrix->new(manifest_path => $missing_path)->run; 1 };
ok( !$error, 'unreadable manifest is an explicit failure' );
like( $@, qr/cannot read benchmark matrix \Q$missing_path\E:/, 'manifest read error identifies its path and system error' );

done_testing();

sub _write {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content or die "cannot write $path: $!";
    close $fh or die "cannot close $path: $!";
}

__END__

=pod

=head1 NAME

t/239-pax-benchmark-matrix-coverage.t - benchmark matrix behavior and error coverage

=head1 PURPOSE

Exercise constructor defaults, manifest loading, class and fixture defaults,
fixture result normalization, and explicit manifest read failures for
C<Developer::Dashboard::Pax::BenchmarkMatrix>.

=head1 WHY IT EXISTS

The matrix runner combines capture, compatibility classification, and runtime
benchmark results. This test checks that each fixture is represented faithfully
and that malformed runtime setup does not silently pass.

=head1 WHEN TO USE

Run when changing the benchmark matrix schema or the runner's result contract.

=head1 HOW TO USE

Run in the development Docker service with
C<prove -lv t/239-pax-benchmark-matrix-coverage.t>. Temporary manifests are
created under an automatically cleaned directory; integration dependencies are
replaced with deterministic local collaborators.

=head1 WHAT USES IT

The PAX CLI and gatekeeper use this matrix runner to report repeatable fixture
benchmarks. The test suite exercises the same public C<run> entry point.

=head1 EXAMPLES

Example 1 - run an empty matrix and verify defaults:

  my $report = Developer::Dashboard::Pax::BenchmarkMatrix->new(
      manifest_path => $path,
  )->run;

Example 2 - run fixtures with an explicit sample count:

  my $report = Developer::Dashboard::Pax::BenchmarkMatrix->new(
      manifest_path => $path,
      iterations => 3,
  )->run;

=cut
