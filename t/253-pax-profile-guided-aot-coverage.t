#!/usr/bin/env perl

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use Test::More;

use lib 'lib';
use Developer::Dashboard::JSON qw(json_encode_with_options);
use Developer::Dashboard::Pax::ProfileGuidedAOT;

my $default = Developer::Dashboard::Pax::ProfileGuidedAOT->new;
is( $default->{threshold}, 2, 'constructor defaults the hotness threshold' );

my $custom = Developer::Dashboard::Pax::ProfileGuidedAOT->new(threshold => 3);
is( $custom->{threshold}, 3, 'constructor retains the caller threshold' );

my $empty = $default->plan;
is( $empty->{status}, 'no_hot_native_regions', 'empty plan reports no hot native regions' );
is( $empty->{threshold}, 2, 'empty plan reports the active threshold' );
is_deeply( $empty->{artifacts}, [], 'empty plan has no artifacts' );
like( $empty->{provenance}{capture_manifest_hash}, qr/\A[0-9a-f]{64}\z/, 'empty plan hashes its default manifest' );

my $manifest = {
    runtime => { pax_abi_stamp => 'abi-fixture' },
    source_entrypoint => 'bin/app.pl',
};
my $plan = $default->plan(
    manifest => $manifest,
    ssa_units => [
        { region_name => 'cold', region_id => 'r-cold', native_shape => { kind => 'i64_binary_leaf' } },
        { region_name => 'unprofiled', region_id => 'r-unprofiled', native_shape => { kind => 'i64_binary_leaf' } },
        { region_name => 'hot-no-shape', region_id => 'r-no-shape' },
        { region_name => 'source-shape', source => { native_shape => { kind => 'i64_sum_loop' } } },
        { region_id => 'direct-shape', native_shape => { kind => 'i64_binary_leaf' } },
    ],
    profile => {
        cold => { dispatches => 1 },
        'hot-no-shape' => { dispatches => 2 },
        'source-shape' => { dispatches => 3 },
        'direct-shape' => { dispatches => 2 },
    },
);
is( $plan->{status}, 'planned', 'eligible source and direct native shapes produce a plan' );
is( scalar @{ $plan->{artifacts} }, 2, 'cold, unprofiled, and shapeless regions do not produce artifacts' );
is( $plan->{artifacts}[0]{region_name}, 'source-shape', 'profile mapping accepts a named source-shape region' );
is( $plan->{artifacts}[0]{profile_dispatches}, 3, 'source-shape artifact preserves its dispatch count' );
is( $plan->{artifacts}[0]{cache_key}, sha256_hex(join "\0", 'abi-fixture', 'bin/app.pl', '', 3), 'source-shape cache key uses ABI, entrypoint, empty region id, and count' );
is( $plan->{artifacts}[1]{region_id}, 'direct-shape', 'region id is used as profile name when region name is absent' );
is( $plan->{artifacts}[1]{cache_key}, sha256_hex(join "\0", 'abi-fixture', 'bin/app.pl', 'direct-shape', 2), 'direct-shape cache key includes its region id' );
is( $plan->{provenance}{source_entrypoint}, 'bin/app.pl', 'provenance records the source entrypoint' );
is( $plan->{provenance}{perl_abi_stamp}, 'abi-fixture', 'provenance records the runtime ABI stamp' );
is(
    $plan->{provenance}{capture_manifest_hash},
    sha256_hex(json_encode_with_options($manifest)),
    'provenance hashes the canonical manifest encoding',
);

my $defaults = $custom->plan(
    manifest => {},
    ssa_units => [
        { region_id => 'r-default', native_shape => { kind => 'i64_binary_leaf' } },
    ],
    profile => { 'r-default' => { dispatches => 3 } },
);
is( $defaults->{status}, 'planned', 'region-id lookup at the explicit threshold is planned' );
is( $defaults->{artifacts}[0]{profile_dispatches}, 3, 'explicit threshold includes equality' );
is(
    $defaults->{artifacts}[0]{cache_key},
    sha256_hex(join "\0", '', '', 'r-default', 3),
    'missing ABI and entrypoint metadata use empty cache-key fields',
);
ok( !defined $defaults->{provenance}{source_entrypoint}, 'absent source entrypoint remains absent in provenance' );
ok( !defined $defaults->{provenance}{perl_abi_stamp}, 'absent ABI stamp remains absent in provenance' );

my $zero_threshold = Developer::Dashboard::Pax::ProfileGuidedAOT->new(threshold => 0)->plan(
    ssa_units => [{ region_id => 'r-zero', native_shape => { kind => 'i64_binary_leaf' } }],
    profile => { 'r-zero' => {} },
);
is( $zero_threshold->{status}, 'planned', 'zero threshold permits an artifact without a dispatch count' );
is( $zero_threshold->{artifacts}[0]{profile_dispatches}, undef, 'artifact preserves an absent profile dispatch count' );
like( $zero_threshold->{artifacts}[0]{cache_key}, qr/\A[0-9a-f]{64}\z/, 'absent dispatch count uses its cache-key default' );

my $invalid_region = eval {
    $default->plan(
        ssa_units => [{ native_shape => { kind => 'i64_binary_leaf' } }],
        profile => {},
    );
    1;
};
ok( !$invalid_region, 'planner rejects an SSA unit without a region identity' );
like( $@, qr/SSA unit must provide region_name or region_id/, 'invalid-region error explains the required identity fields' );

done_testing();

__END__

=head1 NAME

t/253-pax-profile-guided-aot-coverage.t - tests profile-guided AOT planning

=head1 PURPOSE

Exercises the constructor and planner in
C<Developer::Dashboard::Pax::ProfileGuidedAOT>, including cold and unprofiled
regions, missing native shapes, direct and source-nested shapes, generated
artifact cache keys, and provenance.

=head1 WHY IT EXISTS

The AOT planner turns dispatch profiles and SSA metadata into reproducible
artifact records. This test verifies each eligibility boundary and checks that
the artifact identity is tied to the manifest and region metadata.

=head1 WHEN TO USE

Run this test when changing AOT thresholds, profile lookup, native-shape
eligibility, cache-key inputs, or provenance output.

=head1 HOW TO USE

Run inside the development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/253-pax-profile-guided-aot-coverage.t

=head1 WHAT USES IT

C<RuntimeDispatcher> uses the planner when preparing AOT decisions; the PAX
profile and runtime-dispatch layers consume its artifact and provenance shape.

=head1 EXAMPLES

Example 1: provide a region profile at or above the configured threshold and
inspect the emitted artifact record.

Example 2: omit ABI and entrypoint metadata to verify that cache-key inputs use
the documented empty-field defaults while provenance retains absent values.

=cut
