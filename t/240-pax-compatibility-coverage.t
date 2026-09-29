#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Compatibility;

my $default = Developer::Dashboard::Pax::Compatibility->new();
is_deeply(
    $default->report,
    {
        level => 'D',
        reason => 'reference capture failed',
        acceleration_supported => JSON::XS::false(),
        barriers => [],
    },
    'missing capture defaults to a failed reference capture',
);

my $failed_capture = Developer::Dashboard::Pax::Compatibility->new(
    capture => { status => 'error', source_features => { tie => 1 } },
    baseline_match => 1,
)->report;
is( $failed_capture->{level}, 'D', 'failed capture has level D regardless of baseline match' );
is( $failed_capture->{reason}, 'reference capture failed', 'failed capture explains the compatibility decision' );
is( $failed_capture->{acceleration_supported}, JSON::XS::false(), 'failed capture does not support acceleration' );
is_deeply(
    $failed_capture->{barriers},
    [{ feature => 'tie', policy => 'barrier', reason => 'tied variables are semantic barriers by default' }],
    'feature barriers are reported even when reference capture fails',
);

my $nonbaseline = Developer::Dashboard::Pax::Compatibility->new(
    capture => { status => 'ok' },
)->report;
is( $nonbaseline->{level}, 'C', 'capturable non-baseline runtime has level C' );
is( $nonbaseline->{reason}, 'runtime is capturable but does not match Perl 5.42.x baseline', 'level C explains the baseline mismatch' );
is( $nonbaseline->{acceleration_supported}, JSON::XS::false(), 'level C does not support acceleration' );
is_deeply( $nonbaseline->{barriers}, [], 'featureless capture has no barriers' );

my $all_features = Developer::Dashboard::Pax::Compatibility->new(
    capture => {
        status => 'ok',
        source_features => {
            string_eval => 1,
            autoload => 1,
            tie => 1,
            overload => 1,
            typeglob => 1,
            xs_loader => 1,
            local_dynamic => 1,
            unrecognized_feature => 1,
            disabled_feature => 0,
        },
    },
    baseline_match => 'yes',
)->report;
is( $all_features->{level}, 'B', 'baseline with active feature barriers has level B' );
is( $all_features->{reason}, 'capturable baseline with dynamic feature barriers', 'level B explains dynamic feature barriers' );
is( $all_features->{acceleration_supported}, JSON::XS::true(), 'level B supports guarded acceleration' );
is_deeply(
    $all_features->{barriers},
    [
        { feature => 'autoload', policy => 'guarded_barrier', reason => 'AUTOLOAD requires guarded method resolution' },
        { feature => 'local_dynamic', policy => 'guarded_barrier', reason => 'local dynamic scoping requires deopt state' },
        { feature => 'overload', policy => 'guarded_barrier', reason => 'overload tables require epoch guards' },
        { feature => 'string_eval', policy => 'fallback', reason => 'string eval is a runtime compilation boundary' },
        { feature => 'tie', policy => 'barrier', reason => 'tied variables are semantic barriers by default' },
        { feature => 'typeglob', policy => 'guarded_barrier', reason => 'typeglob access requires package shape guards' },
        { feature => 'unrecognized_feature', policy => 'unknown', reason => 'unknown dynamic feature' },
        { feature => 'xs_loader', policy => 'barrier', reason => 'XS is barrier mode unless declared safe' },
    ],
    'all named feature policies and unknown features are normalized in sorted order',
);

my $clean_baseline = Developer::Dashboard::Pax::Compatibility->new(
    capture => { status => 'ok', source_features => { tie => 0, string_eval => '' } },
    baseline_match => 1,
)->report;
is( $clean_baseline->{level}, 'A', 'baseline without active barriers has level A' );
is( $clean_baseline->{reason}, 'capturable baseline with no detected dynamic barriers in source scan', 'level A explains the clean result' );
is( $clean_baseline->{acceleration_supported}, JSON::XS::true(), 'level A supports acceleration' );
is_deeply( $clean_baseline->{barriers}, [], 'false feature flags do not create barriers' );

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Compatibility::_feature_policy = sub {
        return { policy => 'allowed', reason => 'feature has no barrier', barrier => 0 };
    };
    my $permitted_feature = Developer::Dashboard::Pax::Compatibility->new(
        capture => { status => 'ok', source_features => { permitted_feature => 1 } },
        baseline_match => 1,
    )->report;
    is( $permitted_feature->{level}, 'A', 'feature policies may explicitly permit a feature without a barrier' );
    is_deeply( $permitted_feature->{barriers}, [], 'non-barrier policy results are not emitted as barriers' );
}

done_testing();

__END__

=pod

=head1 NAME

t/240-pax-compatibility-coverage.t - compatibility policy result coverage

=head1 PURPOSE

Verify compatibility levels A through D, acceleration support, feature
barriers, known policies, disabled flags, and unknown feature handling for
C<Developer::Dashboard::Pax::Compatibility>.

=head1 WHY IT EXISTS

Compatibility reports decide whether a captured program is eligible for
acceleration or must remain on a guarded or fallback path. Every policy and
decision boundary needs a regression assertion because a false clean report
could select unsafe execution.

=head1 WHEN TO USE

Run when changing the compatibility baseline, levels, source feature names, or
per-feature policies.

=head1 HOW TO USE

Run in the development Docker service with
C<prove -lv t/240-pax-compatibility-coverage.t>. The test uses only in-memory
capture records and does not invoke the compiler or modify project files.

=head1 WHAT USES IT

The PAX manifest and execution planning paths consume compatibility reports;
this test covers the exact report contract those callers receive.

=head1 EXAMPLES

Example 1 - a failed capture remains on the non-accelerated level:

  my $report = Developer::Dashboard::Pax::Compatibility->new(
      capture => { status => 'error' },
  )->report;

Example 2 - a baseline capture with barriers exposes each policy:

  my $report = Developer::Dashboard::Pax::Compatibility->new(
      capture => { status => 'ok', source_features => { tie => 1 } },
      baseline_match => 1,
  )->report;

=cut
