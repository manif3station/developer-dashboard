#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use JSON::XS ();

use lib 'lib';
use Developer::Dashboard::Pax::HotRegionJIT;

my $default = Developer::Dashboard::Pax::HotRegionJIT->new;
is( $default->{threshold}, 2, 'constructor defaults the promotion threshold' );

my $custom = Developer::Dashboard::Pax::HotRegionJIT->new(threshold => 3);
is( $custom->{threshold}, 3, 'constructor preserves an explicit threshold' );

my $no_shape = $default->decision;
is( $no_shape->{status}, 'barrier', 'missing unit and profile produces a shape barrier' );
is( $no_shape->{reason}, 'region has no native lowering shape', 'barrier explains why promotion cannot proceed' );
ok( JSON::XS::is_bool($no_shape->{hot}) && !$no_shape->{hot}, 'barrier reports a JSON false hot value' );

my $promoted = $default->decision(
    ssa_unit => { native_shape => { kind => 'i64_binary_leaf' } },
    profile => { dispatches => 1 },
);
is( $promoted->{status}, 'promote', 'region at its threshold is promoted' );
is( $promoted->{reason}, 'profile threshold reached', 'promotion reports its threshold reason' );
ok( JSON::XS::is_bool($promoted->{hot}) && $promoted->{hot}, 'promotion reports a JSON true hot value' );
is( $promoted->{tier}, 'tier-1', 'promotion selects tier one' );

my $observed = $default->decision(
    ssa_unit => { native_shape => { kind => 'i64_binary_leaf' } },
    profile => { dispatches => 0 },
);
is( $observed->{status}, 'observe', 'region below threshold remains under observation' );
is( $observed->{reason}, 'profile threshold not reached', 'observation explains that the threshold is unmet' );
ok( JSON::XS::is_bool($observed->{hot}) && !$observed->{hot}, 'observation reports a JSON false hot value' );
is( $observed->{tier}, 'interpreter', 'observation remains on the interpreter tier' );

my $source_shape = $custom->decision(
    ssa_unit => { native_shape => undef, source => { native_shape => { kind => 'i64_sum_loop' } } },
);
is( $source_shape->{status}, 'observe', 'native shape nested in source is accepted' );

my $empty_shape = $default->decision(
    ssa_unit => { native_shape => {}, source => { native_shape => { kind => 'ignored' } } },
);
is( $empty_shape->{status}, 'barrier', 'an explicitly empty native shape is not replaced by a source shape' );

my $default_retirement = $default->retirement;
is( $default_retirement->{reason}, 'native region retired', 'retirement supplies a default reason' );
is( $default_retirement->{status}, 'retire', 'retirement marks the region retired' );
my $explicit_retirement = $default->retirement(
    reason => 'guard epoch changed',
    region_id => 'r1',
    region_name => 'main::add',
);
is( $explicit_retirement->{reason}, 'guard epoch changed', 'retirement preserves an explicit reason' );
is( $explicit_retirement->{region_id}, 'r1', 'retirement preserves the region id' );
is( $explicit_retirement->{region_name}, 'main::add', 'retirement preserves the region name' );

done_testing();

__END__

=head1 NAME

t/252-pax-hot-region-jit-coverage.t - tests the hot-region decision contract

=head1 PURPOSE

Exercises the public constructor, promotion decision, and retirement methods of
C<Developer::Dashboard::Pax::HotRegionJIT>, including barrier, observe,
promotion, default, and explicit-value outcomes.

=head1 WHY IT EXISTS

The module decides whether observed runtime regions have enough dispatches and
a supported native shape to enter tier-one promotion. These tests keep each
reported outcome and its JSON boolean representation explicit.

=head1 WHEN TO USE

Run this test when changing hot-region thresholds, native-shape lookup, result
statuses, or retirement metadata.

=head1 HOW TO USE

Run inside the development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/252-pax-hot-region-jit-coverage.t

=head1 WHAT USES IT

C<RuntimeDispatcher> uses this module to report hot-region promotion decisions;
the PAX profiling and dispatch tests exercise the same result contract.

=head1 EXAMPLES

Example 1: construct the planner with a threshold of three dispatches and call
C<decision> with an SSA unit and profile.

Example 2: pass a unit without a native shape and inspect the returned barrier
status before any tier promotion is attempted.

=cut
