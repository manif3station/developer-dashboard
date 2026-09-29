#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::HIR;

my $empty = Developer::Dashboard::Pax::HIR->new;
is_deeply( $empty->{regions}, [], 'constructor defaults to an empty region list' );
is_deeply( $empty->lower_all, [], 'empty input lowers to an empty unit list' );

my $shape = { kind => 'i64_binary_leaf', params => [qw($left $right)] };
my $hir = Developer::Dashboard::Pax::HIR->new(
    manifest => { source_entrypoint => 'bin/app.pl' },
    regions => [
        {
            id => 'r-blocked',
            name => 'main::blocked',
            lowering_status => 'blocked',
            reason => 'unsupported operation',
            source => { native_shape => $shape },
            required_epochs => [qw(package_symbols)],
            deopt_anchors => [{ block => 'entry', reason => 'unsupported operation' }],
        },
        {
            id => 'r-native',
            name => 'main::native',
            lowering_status => 'ready',
            source => { native_shape => $shape },
            required_epochs => [qw(package_symbols method_resolution)],
            deopt_anchors => [{ block => 'entry', reason => 'guard_failure' }],
        },
        {
            id => 'r-reference',
            name => 'main::reference',
            lowering_status => 'ready',
            source => {},
        },
        {
            id => 'r-unspecified',
            name => 'main::unspecified',
            source => {},
        },
    ],
);
my $units = $hir->lower_all;
is( scalar @{$units}, 4, 'all supplied regions are lowered' );

my $blocked = $units->[0];
is( $blocked->{status}, 'fallback', 'blocked region lowers to fallback status' );
ok( !defined $blocked->{native_shape}, 'blocked region does not expose a native shape' );
is( $blocked->{graph}{blocks}[0]{ops}[1]{op}, 'fallback_call', 'blocked region uses an interpreter fallback call' );
is( $blocked->{graph}{blocks}[0]{ops}[1]{target}, 'main::blocked', 'fallback call targets the source region' );
is_deeply( $blocked->{diagnostics}, [{ level => 'warning', code => 'hir_fallback_region', message => 'unsupported operation' }], 'blocked region carries its fallback diagnostic' );
is( $blocked->{deopt_anchors}[0]{reason}, 'unsupported operation', 'blocked deopt anchor preserves its reason' );
is_deeply( $blocked->{required_epochs}, ['package_symbols'], 'blocked region retains required epochs' );

my $native = $units->[1];
is( $native->{status}, 'lowered', 'ready region lowers successfully' );
is( $native->{native_shape}, $shape, 'ready region retains its native shape' );
is( $native->{graph}{blocks}[0]{ops}[1]{op}, 'native_candidate', 'native shape creates a native candidate op' );
is( $native->{graph}{blocks}[0]{ops}[1]{shape}, $shape, 'native candidate includes its shape' );
is( $native->{deopt_anchors}[0]{reason}, 'guard_failure', 'ready region uses the standard deopt reason' );
is_deeply( $native->{diagnostics}, [], 'ready region has no fallback diagnostic' );
is_deeply( $native->{required_epochs}, [qw(package_symbols method_resolution)], 'ready region retains epoch requirements' );

my $reference = $units->[2];
is( $reference->{status}, 'lowered', 'ready region without shape remains lowerable' );
ok( !defined $reference->{native_shape}, 'reference-equivalent region keeps native shape undefined' );
is( $reference->{graph}{blocks}[0]{ops}[1]{op}, 'call_reference_equivalent', 'missing native shape uses reference-equivalent call' );
is_deeply( $reference->{required_epochs}, [], 'missing epoch list defaults to empty' );
is_deeply( $reference->{deopt_anchors}[0]{live_values}, [qw(@_ wantarray)], 'deopt anchor lists the live Perl values' );

my $unspecified = $units->[3];
is( $unspecified->{status}, 'lowered', 'region without an explicit lowering status defaults to ready behavior' );
is( $unspecified->{graph}{blocks}[0]{ops}[1]{op}, 'call_reference_equivalent', 'unspecified region without shape uses reference-equivalent lowering' );

done_testing();

__END__

=head1 NAME

t/256-pax-hir-coverage.t - tests high-level IR lowering paths

=head1 PURPOSE

Exercises the constructor, batch lowering, blocked fallback, native-candidate,
and reference-equivalent paths in C<Developer::Dashboard::Pax::HIR>.

=head1 WHY IT EXISTS

HIR translates selected regions into the intermediate form consumed by guarded
SSA. The test checks each emitted op, diagnostic, deoptimization anchor, shape,
and required-epoch list so the runtime contract remains observable.

=head1 WHEN TO USE

Run this test when changing region lowering status, native shape selection,
fallback diagnostics, graph ops, or deoptimization metadata.

=head1 HOW TO USE

Run inside the development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/256-pax-hir-coverage.t

=head1 WHAT USES IT

C<GuardedSSA> consumes HIR units to add epoch guards and lowerable type
metadata; runtime planning reads the resulting region shape and status.

=head1 EXAMPLES

Example 1: lower a supported region carrying a native shape and inspect the
native-candidate operation.

Example 2: mark a region blocked and verify that the graph calls the interpreter
and emits a diagnostic instead of a native candidate.

=cut
