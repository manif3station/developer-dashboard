#!/usr/bin/env perl

use strict;
use warnings;

use Config ();
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::XS qw(encode_json);
use Test::More;

use lib 'lib';

use Developer::Dashboard::Pax::CPANMatrix ();
use Developer::Dashboard::Pax::CoreSuite ();
use Developer::Dashboard::Pax::Corpus ();

{
    package Local::RunnerCapture;

    sub new { return bless {}, shift; }

    sub capture {
        my ( $self, $path ) = @_;
        return {
            status => $path eq 'fixture-fail' ? 'error' : $path eq 'fixture-no-status' ? undef : 'ok',
            path => $path,
            compatibility_level => $path eq 'fixture-no-level' ? undef : $path =~ /baseline-(?:mismatch|wrong)/ ? 'partial' : 'safe',
            baseline_match => $path eq 'baseline-mismatch' ? 0 : 1,
        };
    }
}

{
    package Local::RunnerManifest;

    sub new {
        my ( $class, %args ) = @_;
        return bless { capture => $args{capture} }, $class;
    }

    sub to_hash {
        my ($self) = @_;
        return {
            runtime => { baseline_match => $self->{capture}{baseline_match} },
            compatibility => {
                level => $self->{capture}{compatibility_level},
                reason => "fixture $self->{capture}{path}",
                barriers => $self->{capture}{path} eq 'baseline-wrong' ? undef : [],
            },
            diagnostics => $self->{capture}{path} eq 'baseline-wrong' ? undef : [],
        };
    }
}

my $root = tempdir( CLEANUP => 1 );
my $corpus_file = File::Spec->catfile( $root, 'corpus.json' );
my $core_file = File::Spec->catfile( $root, 'core.json' );
my $matrix_file = File::Spec->catfile( $root, 'matrix.json' );
_write_json( $corpus_file, {
    cases => [
        { id => 'baseline', path => 'baseline-match', mode => 'live', expected_level => 'safe' },
        { id => 'changed', path => 'baseline-mismatch', expected_level => 'safe', expected_level_when_baseline_mismatch => 'partial' },
        { id => 'failed-capture', path => 'fixture-fail', expected_level => 'safe', expected_level_when_baseline_mismatch => 'other' },
        { id => 'unspecified', path => 'baseline-match' },
        { id => 'wrong-level', path => 'baseline-wrong', expected_level => 'safe' },
        { id => 'mismatch-default', path => 'baseline-mismatch', expected_level => 'safe' },
        { id => 'mismatch-unspecified', path => 'baseline-mismatch' },
    ],
} );
_write_json( $core_file, {
    cases => [
        { id => 'stdout', description => 'emits output', argv => [ '-e', 'print "core-ok"' ] },
        { id => 'stderr', description => 'fails visibly', argv => [ '-e', 'warn "core-error\\n"; exit 7' ] },
        { id => 'default-argv', description => 'defaults to no arguments' },
    ],
} );
_write_json( $matrix_file, {
    distributions => [
        {
            distribution => 'Empty-Distribution',
            modules => [],
            expected_levels => ['safe'],
        },
        {
            distribution => 'Mixed-Distribution',
            source => 'fixture',
            compatibility_class => 'runtime',
            declared_xs => ['Example::XS'],
            modules => ['Local::PaxCoverageVersionless', 'No::Such::PaxCoverageModule'],
            fixtures => [ 'fixture-ok', 'baseline-mismatch', 'fixture-no-status', 'fixture-no-level' ],
            expected_levels => [ 'safe', 'partial', 'impossible' ],
        },
        {
            distribution => 'Failed-Distribution',
            fixtures => ['fixture-fail'],
        },
    ],
} );

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::new = sub { return Local::RunnerCapture->new(@_) };
    local *Developer::Dashboard::Pax::Manifest::new = sub {
        my ( $class, %args ) = @_;
        return Local::RunnerManifest->new(%args);
    };

    my $corpus = Developer::Dashboard::Pax::Corpus->new( manifest_path => $corpus_file )->run;
    is( $corpus->{total}, 7, 'corpus runner processes every declared scenario' );
    is( $corpus->{failed}, 2, 'corpus runner counts mismatches against selected expected levels' );
    ok( !$corpus->{passed}, 'a failed corpus case fails the aggregate result' );
    is( $corpus->{levels}{safe}, 3, 'corpus runner aggregates the safe compatibility level' );
    is( $corpus->{levels}{partial}, 4, 'corpus runner aggregates the partial compatibility level' );
    ok( $corpus->{results}[1]{passed}, 'baseline mismatch uses its alternate expected level' );
    ok( $corpus->{results}[3]{passed}, 'an omitted expected level accepts the measured result' );
    is( $corpus->{results}[0]{reason}, 'fixture baseline-match', 'corpus result carries the compatibility reason' );
    is_deeply( $corpus->{results}[0]{barriers}, [], 'corpus result carries compatibility barriers' );
    is_deeply( $corpus->{results}[0]{diagnostics}, [], 'corpus result carries diagnostics' );
    is_deeply( $corpus->{results}[4]{barriers}, [], 'undefined compatibility barriers become an empty list' );
    is_deeply( $corpus->{results}[4]{diagnostics}, [], 'undefined diagnostics become an empty list' );
    ok( !$corpus->{results}[5]{passed}, 'baseline mismatch without an alternate uses the ordinary expected level' );
    ok( $corpus->{results}[6]{passed}, 'baseline mismatch without either expected level accepts the measured result' );

    my $empty_corpus_file = File::Spec->catfile( $root, 'empty-corpus.json' );
    _write_json( $empty_corpus_file, {} );
    my $empty_corpus = Developer::Dashboard::Pax::Corpus->new( manifest_path => $empty_corpus_file )->run;
    is( $empty_corpus->{total}, 0, 'empty corpus manifest runs zero scenarios' );
    ok( $empty_corpus->{passed}, 'empty corpus passes because it has no failures' );
    is( $empty_corpus->{failed}, 0, 'empty corpus has zero failed cases' );

    my $versionless_dir = File::Spec->catdir( $root, 'Local' );
    make_path($versionless_dir);
    my $versionless_module = File::Spec->catfile( $versionless_dir, 'PaxCoverageVersionless.pm' );
    open my $versionless_fh, '>', $versionless_module or die $!;
    print {$versionless_fh} "package Local::PaxCoverageVersionless;\n1;\n" or die $!;
    close $versionless_fh or die $!;
    local $ENV{PERL5LIB} = defined $ENV{PERL5LIB} && length $ENV{PERL5LIB}
      ? join( $Config::Config{path_sep}, $root, $ENV{PERL5LIB} )
      : $root;
    my $matrix = Developer::Dashboard::Pax::CPANMatrix->new( manifest_path => $matrix_file )->run;
    is( $matrix->{suite}, 'cpan_distribution_matrix', 'matrix runner labels its suite' );
    is( $matrix->{total}, 3, 'matrix runner processes every distribution' );
    is( $matrix->{failed}, 2, 'matrix runner counts the distributions with module, fixture, or expected-level failures' );
    ok( !$matrix->{passed}, 'a failed distribution fails the matrix result' );
    is( $matrix->{results}[0]{source}, 'installed', 'distribution source defaults to installed' );
    is_deeply( $matrix->{results}[0]{modules}, [], 'distribution without modules has an empty module result list' );
    ok( $matrix->{results}[0]{passed}, 'expected levels pass when a distribution has no fixtures' );
    ok( $matrix->{results}[1]{modules}[0]{passed}, 'a loadable module passes its module check' );
    is( $matrix->{results}[1]{modules}[0]{version}, 'unknown', 'module without a version reports unknown' );
    ok( !$matrix->{results}[1]{modules}[1]{passed}, 'an unavailable module fails its module check' );
    is( $matrix->{results}[1]{modules}[1]{version}, undef, 'failed module check has no version' );
    ok( $matrix->{results}[1]{fixtures}[0]{passed}, 'successful fixture capture passes' );
    is( $matrix->{results}[1]{fixtures}[0]{compatibility_level}, 'safe', 'fixture result includes its compatibility level' );
    ok( !$matrix->{results}[1]{fixtures}[2]{passed}, 'missing capture status fails a fixture explicitly' );
    is( $matrix->{results}[1]{fixtures}[3]{compatibility_level}, undef, 'fixture result preserves an undefined compatibility level' );
    ok( !$matrix->{results}[1]{level_checks}[2]{passed}, 'expected level absent from fixtures fails its level check' );
    ok( !$matrix->{results}[2]{passed}, 'failed fixture capture fails its distribution' );

    my $empty_matrix_file = File::Spec->catfile( $root, 'empty-matrix.json' );
    _write_json( $empty_matrix_file, {} );
    my $empty_matrix = Developer::Dashboard::Pax::CPANMatrix->new( manifest_path => $empty_matrix_file )->run;
    is( $empty_matrix->{total}, 0, 'empty CPAN matrix manifest runs zero distributions' );
}

my $core = Developer::Dashboard::Pax::CoreSuite->new( manifest_path => $core_file )->run;
is( $core->{suite}, 'perl_core_regression', 'core-suite result names its suite' );
is( $core->{total}, 3, 'core-suite runs each manifest entry' );
is( $core->{failed}, 1, 'core-suite counts non-zero child exits' );
ok( !$core->{passed}, 'one non-zero child exit fails the core suite' );
is( $core->{results}[0]{stdout}, 'core-ok', 'core-suite captures standard output' );
is( $core->{results}[0]{stderr}, '', 'core-suite returns empty standard error when absent' );
is( $core->{results}[1]{exit}, 7, 'core-suite reports the child exit code' );
like( $core->{results}[1]{stderr}, qr/core-error/, 'core-suite captures standard error' );
is( $core->{results}[2]{exit}, 0, 'core-suite defaults a missing argv list to no arguments' );

my $empty_core_file = File::Spec->catfile( $root, 'empty-core.json' );
_write_json( $empty_core_file, {} );
my $empty_core = Developer::Dashboard::Pax::CoreSuite->new( manifest_path => $empty_core_file, perl => $^X )->run;
is( $empty_core->{total}, 0, 'empty core manifest runs zero commands' );
ok( $empty_core->{passed}, 'empty core suite passes with no failures' );
is( $empty_core->{perl}, $^X, 'core-suite honors an explicit Perl executable' );
is( Developer::Dashboard::Pax::CoreSuite->new( manifest_path => $core_file, perl => '' )->{perl}, '', 'core-suite preserves an explicitly empty Perl executable' );

my $default_matrix = Developer::Dashboard::Pax::CPANMatrix->new( manifest_path => $matrix_file );
is( $default_matrix->{perl}, $^X, 'matrix runner defaults to the current Perl executable' );
is( Developer::Dashboard::Pax::CPANMatrix->new( manifest_path => $matrix_file, perl => $^X )->{perl}, $^X, 'matrix runner accepts an explicit Perl executable' );
is( Developer::Dashboard::Pax::CPANMatrix->new( manifest_path => $matrix_file, perl => '' )->{perl}, '', 'matrix runner preserves an explicitly empty Perl executable' );
is( Developer::Dashboard::Pax::CPANMatrix::_trim("  value \n"), 'value', 'trim removes surrounding whitespace' );
is( Developer::Dashboard::Pax::CPANMatrix::_trim(undef), '', 'trim accepts an undefined version string' );
is( Developer::Dashboard::Pax::CPANMatrix::_stream_text(undef), '', 'matrix runner normalizes an unread stream to empty text' );
is( Developer::Dashboard::Pax::CPANMatrix::_stream_text('captured'), 'captured', 'matrix runner preserves captured stream text' );
is( Developer::Dashboard::Pax::CoreSuite::_stream_text(undef), '', 'core suite normalizes an unread stream to empty text' );
is( Developer::Dashboard::Pax::CoreSuite::_stream_text('captured'), 'captured', 'core suite preserves captured stream text' );
ok( Developer::Dashboard::Pax::CPANMatrix::_level_present( 'safe', [] ), 'expected level passes if there are no fixtures' );
ok( Developer::Dashboard::Pax::CPANMatrix::_level_present( 'safe', [ { compatibility_level => 'safe' } ] ), 'expected level passes when one fixture matches' );
ok( !Developer::Dashboard::Pax::CPANMatrix::_level_present( 'safe', [ { compatibility_level => 'partial' } ] ), 'expected level fails when no fixture matches' );
ok( !Developer::Dashboard::Pax::CPANMatrix::_level_present( 'safe', [ { compatibility_level => undef } ] ), 'undefined fixture compatibility level does not match' );

for my $case (
    [ Developer::Dashboard::Pax::Corpus->new( manifest_path => File::Spec->catfile( $root, 'missing.json' ) ), qr/cannot read corpus manifest/ ],
    [ Developer::Dashboard::Pax::CoreSuite->new( manifest_path => File::Spec->catfile( $root, 'missing.json' ) ), qr/cannot read core suite manifest/ ],
    [ Developer::Dashboard::Pax::CPANMatrix->new( manifest_path => File::Spec->catfile( $root, 'missing.json' ) ), qr/cannot read CPAN matrix manifest/ ],
  )
{
    my ( $runner, $error ) = @{$case};
    my $ok = eval { $runner->_load_manifest; 1 };
    ok( !$ok && $@ =~ $error, 'manifest load reports its source path on open failure' );
}

done_testing();

sub _write_json {
    my ( $path, $data ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} encode_json($data) or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    return;
}

__END__

=pod

=head1 NAME

t/233-pax-validation-runners-coverage.t - PAX corpus, core-suite, and CPAN matrix tests

=head1 PURPOSE

This test verifies the manifest-driven PAX validation runners without depending
on network downloads or third-party package state. Fixture capture and
compatibility results are deterministic test doubles; CoreSuite uses the
configured Perl executable for real child-process exit and stream handling.

=head1 WHY IT EXISTS

These runners turn compatibility manifests into deterministic result records.
Tests protect their aggregation and failure contracts without downloading
third-party distributions or relying on network state.

=head1 WHEN TO USE

Run this file after changes to Corpus, CoreSuite, or CPANMatrix. Add a manifest
fixture for every newly supported default or failure mode before altering the
runner implementation.

=head1 HOW TO USE

Run this test from the repository root for a quick regression check. To inspect
coverage, instrument the test, then select the three runner modules and add
input cases for every condition reported below 100 percent.

=head1 WHAT USES IT

The PAX CLI uses these runners for corpus, Perl-core, and CPAN compatibility
checks. The canonical repository test and coverage gates also execute this
file.

=head1 EXAMPLES

Run the focused regression suite:

  prove -lv t/233-pax-validation-runners-coverage.t

Collect and inspect focused runner coverage:

  perl -MDevel::Cover=-db,/tmp/pax-runners-cover,-blib,0 t/233-pax-validation-runners-coverage.t
  cover /tmp/pax-runners-cover -report text -select_re '^lib/Developer/Dashboard/Pax/(Corpus|CoreSuite|CPANMatrix)\.pm$'

=head1 RUNNING

Run from the repository root:

  prove -lv t/233-pax-validation-runners-coverage.t

Use Devel::Cover against this test to inspect coverage in the corpus, core-suite,
and CPAN matrix runner modules.

=head1 COVERAGE INTENT

Scenarios include empty manifests, successful and failed observations,
baseline-mismatch expected-level selection, missing modules, expected levels
present or absent, and real child commands that produce stdout, stderr, zero,
and non-zero exit statuses.

=cut
