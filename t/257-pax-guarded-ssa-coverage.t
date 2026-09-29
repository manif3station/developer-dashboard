#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::GuardedSSA;

my $default = Developer::Dashboard::Pax::GuardedSSA->new;
is_deeply( $default->{hir_units}, [], 'constructor defaults to an empty HIR list' );
is_deeply( $default->build_all, [], 'empty HIR list builds no SSA units' );

my $builder = Developer::Dashboard::Pax::GuardedSSA->new(
    hir_units => [
        {
            region_id => 'r-source-text',
            region_name => 'main::add',
            status => 'ssa',
            source => { source_text => 'sub add { $_[0] + $_[1] }' },
            native_shape => { kind => 'i64_binary_leaf' },
            required_epochs => [qw(package_symbols method_resolution)],
            deopt_anchors => [{ block => 'entry', reason => 'guard_failure' }],
        },
        {
            region_id => 'r-body-source',
            region_name => 'main::fallback',
            status => 'fallback',
            source => { body_source => 'sub fallback { return $_[0] }' },
            required_epochs => [qw(loaded_modules)],
        },
        {
            region_id => 'r-no-source',
            region_name => 'main::unknown',
            source => {},
        },
    ],
);
my $units = $builder->build_all;
is( scalar @{$units}, 3, 'each HIR unit gets an SSA output record' );

my $source_text = $units->[0];
is( $source_text->{status}, 'ssa', 'ordinary HIR status yields SSA status' );
is( $source_text->{region_id}, 'r-source-text', 'SSA record preserves its region id' );
is( $source_text->{region_name}, 'main::add', 'SSA record preserves its region name' );
is( $source_text->{typed_ir}{status}, 'typed_ir', 'supported native shape reaches typed IR' );
is_deeply( [ map { $_->{id} } @{ $source_text->{guards} } ], [qw(guard_package_symbols guard_method_resolution)], 'each required epoch creates a guard' );
is( $source_text->{guards}[0]{compatibility_classification}, 'guarded', 'normal guards are classified as guarded' );
is( $source_text->{guards}[0]{deopt_continuation}, 'r-source-text:entry', 'guard continuation points back to the region entry' );
is( $source_text->{blocks}[0]{terminator}, 'call_lowered_region', 'SSA path calls the lowered region' );
is_deeply( $source_text->{deopt}{anchors}, [{ block => 'entry', reason => 'guard_failure' }], 'SSA deopt anchors are preserved' );

my $fallback = $units->[1];
is( $fallback->{status}, 'fallback', 'fallback HIR status remains fallback' );
is( $fallback->{guards}[0]{compatibility_classification}, 'fallback', 'fallback guards are labeled accordingly' );
is( $fallback->{blocks}[0]{terminator}, 'deopt_to_interpreter', 'fallback SSA terminates in the interpreter' );
is_deeply( [ map { $_->{invalidation_key} } @{ $fallback->{guards} } ], ['loaded_modules'], 'fallback preserves epoch invalidation keys' );
is_deeply( $fallback->{deopt}{anchors}, [], 'missing deopt anchors default to an empty list' );

my $unknown = $units->[2];
is( $unknown->{status}, 'ssa', 'missing HIR status defaults to SSA' );
is_deeply( $unknown->{guards}, [], 'missing required epochs creates no guards' );
is_deeply( $unknown->{type_annotations}{params}, [], 'missing source text produces empty parameter annotations' );

done_testing();

__END__

=head1 NAME

t/257-pax-guarded-ssa-coverage.t - tests guarded SSA construction

=head1 PURPOSE

Exercises the constructor, batch and single-unit SSA construction, fallback
classification, guard generation, deoptimization metadata, and source-text
selection in C<Developer::Dashboard::Pax::GuardedSSA>.

=head1 WHY IT EXISTS

Guarded SSA combines HIR, source-derived type annotations, epoch guards, and
deoptimization records. The test verifies how those inputs become executable
and fallback continuations.

=head1 WHEN TO USE

Run this test when changing source extraction, guard metadata, typed-IR
integration, or fallback status handling.

=head1 HOW TO USE

Run inside the development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/257-pax-guarded-ssa-coverage.t

=head1 WHAT USES IT

C<RuntimeDispatcher> builds guarded SSA from HIR units before validating runtime
epochs and selecting native dispatch candidates.

=head1 EXAMPLES

Example 1: provide a supported HIR unit with two required epochs and inspect the
generated guards and native terminator.

Example 2: provide a fallback HIR unit and verify that its guards route through
the interpreter deoptimization continuation.

=cut
