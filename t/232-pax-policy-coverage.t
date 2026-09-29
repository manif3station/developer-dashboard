#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';

use Developer::Dashboard::Pax::DeoptEngine ();
use Developer::Dashboard::Pax::GuardManager ();
use Developer::Dashboard::Pax::InlineCache ();
use Developer::Dashboard::Pax::Mode ();
use Developer::Dashboard::Pax::OSR ();
use Developer::Dashboard::Pax::TypedIR ();

# Mode maps each explicit mode and the missing or unknown inputs.
is_deeply( Developer::Dashboard::Pax::Mode->policy, Developer::Dashboard::Pax::Mode->policy('dev'), 'mode defaults to dev' );
is( Developer::Dashboard::Pax::Mode->policy('ci')->{undeclared_inputs}, 'fail', 'ci policy rejects undeclared inputs' );
is( Developer::Dashboard::Pax::Mode->policy('prod')->{cache_persistence}, 'persistent', 'prod policy keeps persistent cache state' );
is( Developer::Dashboard::Pax::Mode->policy('unknown')->{telemetry}, 'verbose', 'unknown mode falls back to dev' );
is( Developer::Dashboard::Pax::Mode->policy('')->{telemetry}, 'verbose', 'an empty mode name also falls back to dev' );

# Inline-cache lookup covers absent sites, missing entries, hits, updates, and widening.
my $cache = Developer::Dashboard::Pax::InlineCache->new(max_polymorphic => 2);
is( $cache->lookup->{status}, 'miss', 'lookup misses before a site is populated' );
my $first = $cache->update( site => 'call-a', class_key => 'A', method => 'run', target_region_id => 'r1', target_region_name => 'one' );
is( $first->{status}, 'updated', 'first update adds an inline-cache entry' );
is( $cache->lookup( site => 'call-a', class_key => 'B', method => 'run' )->{status}, 'miss', 'lookup misses for an unknown class key' );
is( $cache->lookup( site => 'call-a', class_key => 'A', method => 'other' )->{status}, 'miss', 'lookup misses for an unknown method' );
my $hit = $cache->lookup( site => 'call-a', class_key => 'A', method => 'run' );
is( $hit->{status}, 'hit', 'lookup hits a matching class and method' );
is( $hit->{hits}, 1, 'lookup increments hit count' );
my $updated = $cache->update( site => 'call-a', class_key => 'A', method => 'run', target_region_id => 'r2', target_region_name => 'two' );
is( $updated->{status}, 'hit', 'updating an existing entry returns its new lookup state' );
is( $cache->lookup( site => 'call-a', class_key => 'A', method => 'run' )->{target_region_id}, 'r2', 'existing cache entries receive the replacement target' );
$cache->update( site => 'call-a', class_key => 'B', method => 'run', target_region_id => 'r3', target_region_name => 'three' );
my $wide = $cache->update( site => 'call-a', class_key => 'C', method => 'run', target_region_id => 'r4', target_region_name => 'four' );
is( $wide->{status}, 'megamorphic', 'exceeding the polymorphic bound widens the site' );
is( $cache->lookup( site => 'call-a', class_key => 'C', method => 'run' )->{status}, 'megamorphic', 'matching lookup reports a megamorphic site' );
is( $cache->lookup( site => 'call-a', class_key => 'D', method => 'run' )->{status}, 'megamorphic', 'missing lookup also reports a megamorphic site' );
is( $cache->report->{max_polymorphic}, 2, 'report returns the configured polymorphic bound' );
is( Developer::Dashboard::Pax::InlineCache->new->report->{max_polymorphic}, 4, 'inline cache defaults to four polymorphic entries' );
my $defaults = Developer::Dashboard::Pax::InlineCache->new;
is( $defaults->update( region_name => 'named-region' )->{method}, 'named-region', 'region_name supplies a default method name' );
is( $defaults->lookup->{class_key}, 'main', 'lookup supplies default site and class key' );
is( $defaults->lookup( region_name => 'named-region' )->{method}, 'named-region', 'lookup accepts region_name as a method alias' );
is( $defaults->update( site => 'empty-method' )->{method}, '', 'update defaults a missing method and region name to an empty string' );
my $comparison_cache = Developer::Dashboard::Pax::InlineCache->new(max_polymorphic => 5);
$comparison_cache->update( site => 'compare', class_key => 'A', method => 'one' );
is(
    $comparison_cache->update( site => 'compare', class_key => 'A', method => 'two' )->{status},
    'updated',
    'update continues after a matching class key has a different method',
);

# Deoptimization reconstruction preserves supplied frame state and defaults.
my $deopt = Developer::Dashboard::Pax::DeoptEngine->new;
my $default_frame = $deopt->reconstruct;
is( $default_frame->{status}, 'reconstructed', 'reconstruction reports success' );
is( $default_frame->{reason}, 'guard_failed', 'reconstruction defaults the reason' );
is( $default_frame->{frame}{wantarray}, 0, 'scalar context restores scalar wantarray' );
is_deeply( $default_frame->{frame}{argv}, [], 'missing arguments restore as an empty argv list' );
is_deeply( $default_frame->{materialised}, [], 'missing materialisation state restores as an empty list' );
my $full_frame = $deopt->reconstruct(
    ssa_unit => { region_id => 'r7', region_name => 'sum', deopt => { safepoint => 'sp2', materialise => ['x'] } },
    reason => 'type_guard',
    guard => { guard_id => 'g2', invalidation_key => 'shape:A' },
    interpreter_result => 55,
    args => [ 2, 3 ],
    context => 'list',
    lexicals => { total => 5 },
    closure_environment => { bias => 1 },
    exception_handlers => ['catch'],
    exception_state => 'none',
    caller => 'main',
    debugger_stack => ['frame0'],
);
is( $full_frame->{region_id}, 'r7', 'reconstruction keeps the SSA region identity' );
is( $full_frame->{reason}, 'type_guard', 'reconstruction keeps the invalidation reason' );
is( $full_frame->{guard_id}, 'g2', 'reconstruction keeps the failing guard' );
is( $full_frame->{continuation}, 'sp2', 'reconstruction restores the safepoint' );
is_deeply( $full_frame->{frame}{argv}, [ 2, 3 ], 'reconstruction copies positional arguments' );
is( $full_frame->{frame}{wantarray}, 1, 'list context restores list wantarray' );
is_deeply( $full_frame->{frame}{lexicals}, { total => 5 }, 'reconstruction restores lexicals' );
is_deeply( $full_frame->{materialised}, ['x'], 'reconstruction restores materialised values' );
is( $full_frame->{interpreter_result}, 55, 'reconstruction retains interpreter result' );
ok( !defined Developer::Dashboard::Pax::DeoptEngine::_wantarray_for_context(undef), 'undefined context is void context' );
ok( !defined Developer::Dashboard::Pax::DeoptEngine::_wantarray_for_context('void'), 'explicit void context restores undef wantarray' );
is( Developer::Dashboard::Pax::DeoptEngine::_wantarray_for_context('list'), 1, 'list context restores true wantarray' );
is( Developer::Dashboard::Pax::DeoptEngine::_wantarray_for_context('scalar'), 0, 'other contexts restore false wantarray' );

# Guard validation tracks successful assumptions and reconstructs a frame when
# the requested invalidation epoch is missing.
my $guards = Developer::Dashboard::Pax::GuardManager->new( epochs => { 'shape:A' => 3 } );
ok( $guards->validate_region( { region_id => 'empty-guards' } ), 'a region without guards passes validation' );
my $native_allowed = $guards->validate_or_deopt(
    { region_id => 'r-guarded', guards => [ { id => 'g-shape', invalidation_key => 'shape:A' } ] },
);
is( $native_allowed->{status}, 'native_allowed', 'a region passes when each guard has a registered epoch' );
is( $native_allowed->{telemetry}[-1]{status}, 'passed', 'successful guard validation records pass telemetry' );
my $deoptimized = Developer::Dashboard::Pax::GuardManager->new->validate_or_deopt(
    { region_id => 'r-deopt', guards => [ { id => 'g-missing', invalidation_key => 'shape:B' } ], deopt => { safepoint => 'sp-guard' } },
    interpreter_result => 17,
    args => [ 4, 5 ],
    context => 'list',
);
is( $deoptimized->{status}, 'deopt', 'a missing invalidation epoch routes execution through deoptimization' );
is( $deoptimized->{fallback}{reason}, 'missing_epoch', 'deoptimization reports the failed guard reason' );
is( $deoptimized->{fallback}{guard_id}, 'g-missing', 'deoptimization identifies the failed guard' );
is( $deoptimized->{fallback}{continuation}, 'sp-guard', 'deoptimization resumes from the declared safepoint' );
is( $deoptimized->{fallback}{reconstructed_frame}{frame}{wantarray}, 1, 'deoptimization passes list context into frame reconstruction' );
is( $deoptimized->{fallback}{interpreter_result}, 17, 'deoptimization preserves the interpreter result' );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::GuardManager::validate_region = sub { return 0 };
    my $unreported_failure = Developer::Dashboard::Pax::GuardManager->new->validate_or_deopt( { region_id => 'r-custom-failure' } );
    is( $unreported_failure->{fallback}{reason}, 'guard_failed', 'deoptimization supplies a reason if a custom validator fails without telemetry' );
    is_deeply( $unreported_failure->{fallback}{reconstructed_frame}{frame}{argv}, [], 'missing deoptimization arguments default to an empty list' );
    is( $unreported_failure->{fallback}{reconstructed_frame}{frame}{wantarray}, 0, 'missing deoptimization context defaults to scalar' );
}
$guards->invalidate_epoch('shape:A');
ok( !$guards->validate_region( { region_id => 'r-invalidated', guards => [ { id => 'g-shape', invalidation_key => 'shape:A' } ] } ),
    'invalidating an epoch makes future validations fail' );
is( $guards->telemetry->[-1]{reason}, 'missing_epoch', 'invalidated guards append explicit failure telemetry' );

# OSR classifies non-loops, below-threshold loops, promotions, and retirement.
my $osr = Developer::Dashboard::Pax::OSR->new(threshold => 3);
is( Developer::Dashboard::Pax::OSR->new->evaluate->{status}, 'not_applicable', 'OSR defaults an absent SSA unit to an empty record' );
my $not_loop = $osr->evaluate(ssa_unit => { deopt => { safepoint => 'sp1' } });
is( $not_loop->{status}, 'not_applicable', 'OSR ignores a region without a recognized loop shape' );
is( $not_loop->{safepoint}, 'sp1', 'non-applicable OSR result preserves its safepoint' );
my $observed = $osr->evaluate(
    ssa_unit => { source => { native_shape => { kind => 'i64_sum_loop' } }, deopt => { safepoint => 'sp2' } },
    profile => { dispatches => 1 },
);
is( $observed->{status}, 'observe', 'OSR observes a loop below its promotion threshold' );
my $promoted = $osr->evaluate(
    ssa_unit => { native_shape => { kind => 'i64_sum_loop' }, deopt => { safepoint => 'sp3' } },
    profile => { dispatches => 2 },
);
is( $promoted->{status}, 'promote', 'OSR promotes a loop at its dispatch threshold' );
is( $promoted->{osr_event}, 'promote', 'promotion emits an OSR event' );
is( Developer::Dashboard::Pax::OSR->new->evaluate( ssa_unit => { native_shape => { kind => 'i64_sum_loop' } } )->{status}, 'observe', 'OSR defaults to a threshold of two' );
is( $osr->retirement->{reason}, 'guard invalidated promoted OSR region', 'retirement supplies its default reason' );
is( $osr->retirement( reason => 'shape changed', safepoint => 'sp4' )->{safepoint}, 'sp4', 'retirement preserves the provided safepoint' );

# Typed IR maps each supported shape and fails closed for absent or unknown kinds.
my $lowerer = Developer::Dashboard::Pax::TypedIR->new;
is( $lowerer->lower_unit({})->{status}, 'untyped', 'lowering without shape data returns untyped' );
is( Developer::Dashboard::Pax::TypedIR::_typed_op_for_shape({}), undef, 'typed-op lookup returns undef when a shape kind is absent' );
is( $lowerer->lower_unit( { source => { native_shape => { kind => 'unknown' } } } )->{status}, 'untyped', 'unsupported shape returns untyped' );
for my $case (
    [ i64_binary_leaf => 'typed_i64_binary_leaf' ],
    [ i64_sum_loop => 'typed_i64_sum_loop' ],
    [ i64_masked_mix_accum_loop => 'typed_i64_masked_mix_accum_loop' ],
  )
{
    my ( $kind, $op ) = @{$case};
    my $ir = $lowerer->lower_unit(
        { region_id => $kind, region_name => 'fixture', native_shape => { kind => $kind } },
        type_annotations => { source => 'fixture', confidence => 'high', params => ['i64'], return => 'i64' },
    );
    is( $ir->{status}, 'typed_ir', "$kind lowers to typed IR" );
    is( $ir->{ops}[0]{op}, $op, "$kind selects its typed op" );
    is( $ir->{source}, 'fixture', "$kind preserves type-annotation source" );
}
my $default_ir = $lowerer->lower_unit( { region_id => 'r-default', native_shape => { kind => 'i64_binary_leaf' } } );
is( $default_ir->{source}, 'unknown', 'typed IR defaults annotation source' );
is( $default_ir->{confidence}, 'none', 'typed IR defaults annotation confidence' );
is( $default_ir->{return}, 'PerlScalar', 'typed IR defaults return type' );
is_deeply( $default_ir->{params}, [], 'typed IR defaults parameter annotations' );

done_testing();

__END__

=pod

=head1 NAME

t/232-pax-policy-coverage.t - PAX mode, cache, deoptimization, OSR, and typed-IR tests

=head1 PURPOSE

This test drives the small PAX policy modules through their success, miss,
fallback, default, and boundary cases. It uses deterministic in-memory records
only; it does not build native binaries or launch external services.

=head1 WHY IT EXISTS

These small policy objects control PAX mode selection, specialization, and
deoptimization decisions. Their boundary behavior is inexpensive to exercise
directly and should remain visible without depending on an end-to-end build.

=head1 WHEN TO USE

Run this test when changing Mode, InlineCache, DeoptEngine, GuardManager, OSR,
or TypedIR.
Add or adjust a focused input case whenever a policy default, transition, or
supported operation changes.

=head1 HOW TO USE

Run the test from the repository root after editing any covered policy module.
For a coverage gap, instrument the test and select the affected source module;
use the report to choose a missing public input or state transition.

=head1 WHAT USES IT

PAX compilation and runtime dispatch use these policy objects to choose
execution modes and manage optimized state. The canonical test suite runs this
file as a regression and four-metric coverage contributor.

=head1 EXAMPLES

Run the focused regressions:

  prove -lv t/232-pax-policy-coverage.t

Instrument the file and inspect the PAX policy report:

  perl -MDevel::Cover=-db,/tmp/pax-policy-cover,-blib,0 t/232-pax-policy-coverage.t
  cover /tmp/pax-policy-cover -report text -select_re '^lib/Developer/Dashboard/Pax/'

=head1 RUNNING

From the repository root:

  prove -lv t/232-pax-policy-coverage.t

For a focused Devel::Cover run, instrument this test and select the relevant
PAX source files in the resulting report.

=head1 COVERAGE INTENT

The scenarios exercise every mode policy, inline-cache miss/hit/update and
megamorphic transition, deoptimization frame default and restoration fields,
guard acceptance, missing-epoch deoptimization, and invalidation, OSR
observation/promotion/retirement, and every typed operation mapping plus the
unsupported-shape fallback. The guard tests also cover a custom validator that
reports failure without telemetry so the public fallback defaults stay live.

=cut
