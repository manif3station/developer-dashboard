#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use JSON::XS ();

use lib 'lib';
use Developer::Dashboard::Pax::ProfileStore;

my $default = Developer::Dashboard::Pax::ProfileStore->new;
is( $default->{threshold}, 2, 'profile store defaults its hotness threshold' );
is_deeply( $default->{regions}, {}, 'profile store starts without region records' );

my $store = Developer::Dashboard::Pax::ProfileStore->new(threshold => 3);
is( $store->{threshold}, 3, 'profile store retains an explicit threshold' );

my $native = $store->record_dispatch({
    region_name => 'main::add',
    status => 'native',
    osr_event => 'promote',
});
is_deeply(
    $native,
    {
        dispatches => 1,
        native => 1,
        fallback => 0,
        deopt => 0,
        osr_promotions => 1,
        osr_retirements => 0,
    },
    'first native event initializes and increments its profile slot',
);
my $merged = $store->record_dispatch({
    region_name => 'main::add',
    status => 'native',
});
is( $merged, $native, 'subsequent event updates the existing region slot' );
is( $merged->{dispatches}, 2, 'merged native event increments dispatch count' );
is( $merged->{native}, 2, 'merged native event increments native count' );
is( $merged->{osr_promotions}, 1, 'missing OSR event does not change promotion count' );

my $deopt = $store->record_dispatch({
    region_id => 'r-deopt',
    status => 'deopt',
    osr_event => 'retire',
});
is( $deopt->{deopt}, 1, 'deopt event increments deopt count' );
is( $deopt->{fallback}, 1, 'deopt event is also counted as a fallback' );
is( $deopt->{osr_retirements}, 1, 'retire OSR event increments retirement count' );

my $fallback = $store->record_dispatch({
    region_id => 'r-fallback',
    status => 'fallback',
    osr_event => 'other',
});
is( $fallback->{fallback}, 1, 'ordinary non-native status increments fallback count' );
is( $fallback->{deopt}, 0, 'ordinary fallback does not increment deopt count' );
is( $fallback->{osr_promotions}, 0, 'non-promote OSR event does not increment promotions' );
is( $fallback->{osr_retirements}, 0, 'non-retire OSR event does not increment retirements' );

my $missing_status = $store->record_dispatch({ region_id => 'r-missing-status' });
is( $missing_status->{fallback}, 1, 'event with absent status safely defaults to fallback' );

my $unknown = $store->record_dispatch({ status => 'native' });
is( $unknown->{dispatches}, 1, 'event without either identity is recorded under unknown' );

my $report = $store->report;
is( $report->{threshold}, 3, 'report includes its configured threshold' );
is_deeply(
    [ map { $_->{region} } @{ $report->{regions} } ],
    [ 'main::add', 'r-deopt', 'r-fallback', 'r-missing-status', 'unknown' ],
    'report returns regions in lexical order',
);
ok( JSON::XS::is_bool($report->{regions}[0]{hot}) && !$report->{regions}[0]{hot}, 'two dispatches below threshold are cold' );
ok( JSON::XS::is_bool($report->{regions}[1]{hot}) && !$report->{regions}[1]{hot}, 'single dispatch is cold' );

my $hot_store = Developer::Dashboard::Pax::ProfileStore->new(threshold => 2);
$hot_store->record_dispatch({ region_name => 'main::hot', status => 'native' });
$hot_store->record_dispatch({ region_name => 'main::hot', status => 'native' });
my $hot = $hot_store->report->{regions}[0]{hot};
ok( JSON::XS::is_bool($hot) && $hot, 'region reaching threshold is a JSON true hot value' );

done_testing();

__END__

=head1 NAME

t/255-pax-profile-store-coverage.t - tests region profile aggregation

=head1 PURPOSE

Tests the constructor, event aggregation, and sorted report returned by
C<Developer::Dashboard::Pax::ProfileStore>, including native, deopt, fallback,
OSR promotion, OSR retirement, unknown identity, and hot/cold outcomes.

=head1 WHY IT EXISTS

Runtime planning depends on accurate per-region dispatch and OSR counts. This
test verifies the aggregation semantics and the JSON booleans consumed by later
promotion decisions.

=head1 WHEN TO USE

Run this test when changing profile event fields, region identity fallback,
counter updates, threshold handling, or report ordering.

=head1 HOW TO USE

Run inside the development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/255-pax-profile-store-coverage.t

=head1 WHAT USES IT

C<RuntimeDispatcher> records dispatch outcomes here; profile-guided JIT and AOT
planning reads the resulting counts.

=head1 EXAMPLES

Example 1: record repeated native events under one region name and inspect the
merged counters.

Example 2: record a deoptimization with an OSR retirement and verify that the
event contributes to both deopt and fallback totals.

=cut
