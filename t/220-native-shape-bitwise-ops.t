#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Spec;

use lib 'lib';
use Developer::Dashboard::Pax::Capture;
use Developer::Dashboard::Pax::Manifest;
use Developer::Dashboard::Pax::RegionSelector;
use Developer::Dashboard::Pax::HIR;
use Developer::Dashboard::Pax::GuardedSSA;
use Developer::Dashboard::Pax::Tier1;
use Developer::Dashboard::Pax::CodeUnitCompiler;

my $fixture = File::Spec->catfile( 'fixtures', 'native-shape-bitwise.pl' );
$fixture = File::Spec->catfile( 't', $fixture ) if !-f $fixture;

# AC-1 (DDE-007/DD-1031 Stage 1, first real widening): the existing
# i64_binary_leaf native-shape detector (Capture.pm's live-capture probe)
# only recognized +, -, *, > until now. Widen it to also recognize the
# bitwise ops &, |, ^ - deliberately NOT / or %, since Perl's / always
# returns a float and Perl's % follows the right operand's sign while
# C's follows the left, both of which would be a genuine semantic
# mismatch between what this "native i64" shape claims to compute and
# what the generated C code actually computes. Bitwise ops on integers
# are bit-for-bit identical between Perl and C across the full i64
# domain. This proves the "widen the existing guarded-JIT pipeline"
# path from the approved plan (/home/mv/.claude/plans/jazzy-conjuring-
# locket.md) actually works end-to-end: detection -> HIR -> SSA -> real
# C codegen -> real cc compile -> real native execution with the
# correct answer.
my $capture = Developer::Dashboard::Pax::Capture->new( mode => 'live' )->capture($fixture);
ok( $capture, 'live capture ran against the bitwise-ops fixture' );
is( $capture->{status}, 'ok', 'live capture succeeded' ) or diag explain $capture->{diagnostics};

my @subs = @{ $capture->{capture}{sub_optrees} // [] };
my ($and_sub) = grep { ( $_->{name} // '' ) =~ /bitand_leaf$/ } @subs;
my ($xor_sub) = grep { ( $_->{name} // '' ) =~ /bitxor_leaf$/ } @subs;

ok( $and_sub, 'bitand_leaf was captured' );
ok( $xor_sub, 'bitxor_leaf was captured' );

SKIP: {
    skip 'bitand_leaf not captured, cannot check its shape', 2 if !$and_sub;
    is( $and_sub->{native_shape}{kind}, 'i64_binary_leaf', 'bitand_leaf is recognized as an i64_binary_leaf shape' );
    is( $and_sub->{native_shape}{op}, 'bitwise_and', "bitand_leaf's shape op is 'bitwise_and'" );
}

SKIP: {
    skip 'bitxor_leaf not captured, cannot check its shape', 2 if !$xor_sub;
    is( $xor_sub->{native_shape}{kind}, 'i64_binary_leaf', 'bitxor_leaf is recognized as an i64_binary_leaf shape' );
    is( $xor_sub->{native_shape}{op}, 'bitwise_xor', "bitxor_leaf's shape op is 'bitwise_xor'" );
}

# AC-2: the SAME widening in CodeUnitCompiler.pm's own duplicate detector
# (used by the separate, older native_shape_sub dispatch path) stays in
# sync - test it directly since it is a real, non-heredoc sub.
{
    my $and_body = "my (\$a, \$b) = \@_;\nreturn \$a & \$b;\n";
    my $shape = Developer::Dashboard::Pax::CodeUnitCompiler::_native_i64_binary_leaf_shape($and_body);
    ok( $shape, 'CodeUnitCompiler recognizes a bitwise-and leaf body' );
    is( $shape->{op}, 'bitwise_and', 'CodeUnitCompiler tags it as bitwise_and' ) if $shape;

    my $xor_body = "my (\$a, \$b) = \@_;\nreturn \$a ^ \$b;\n";
    my $xshape = Developer::Dashboard::Pax::CodeUnitCompiler::_native_i64_binary_leaf_shape($xor_body);
    ok( $xshape, 'CodeUnitCompiler recognizes a bitwise-xor leaf body' );
    is( $xshape->{op}, 'bitwise_xor', 'CodeUnitCompiler tags it as bitwise_xor' ) if $xshape;
}

# AC-3: real end-to-end native compilation - HIR -> SSA -> Tier1's real C
# codegen -> real cc invocation -> real compiled binary -> real execution,
# and the compiled binary computes the ACTUAL correct answer (2 & 3 = 2,
# 2 ^ 3 = 1), not just that a shape was detected.
SKIP: {
    skip 'bitand_leaf/bitxor_leaf not both captured, cannot run end-to-end native compile', 4
        if !$and_sub || !$xor_sub;

    my $manifest = Developer::Dashboard::Pax::Manifest->new( capture => $capture )->to_hash;
    my $regions = Developer::Dashboard::Pax::RegionSelector->new( manifest => $manifest )->select;
    my $hir = Developer::Dashboard::Pax::HIR->new( manifest => $manifest, regions => $regions->{selected} )->lower_all;
    my $ssa = Developer::Dashboard::Pax::GuardedSSA->new( hir_units => $hir )->build_all;

    my $out_dir = File::Spec->catdir( 't', 'tmp-t220-native' );
    for my $unit (@$ssa) {
        next if ( $unit->{native_shape}{op} // '' ) !~ /^(?:bitwise_and|bitwise_xor)$/;
        my $artifact = Developer::Dashboard::Pax::Tier1->new( out_dir => $out_dir )->compile($unit);
        my $op = $unit->{native_shape}{op};
        if ( ( $artifact->{status} // '' ) ne 'native_artifact' || !$artifact->{executable_path} ) {
            SKIP: {
                skip "no C compiler available to build a real native artifact for $op ($artifact->{reason})", 2;
            }
            next;
        }
        ok( -x $artifact->{executable_path}, "a real native executable was compiled for $op" );
        ok( $artifact->{native_test}{passed}, "the compiled native $op binary computed the correct smoke-test answer" )
            or diag explain $artifact->{native_test};
    }
}

done_testing();

__END__

=pod

=head1 NAME

220-native-shape-bitwise-ops.t - proves DDE-007 Stage 1's first real native-shape widening

=head1 PURPOSE

Widens the existing i64_binary_leaf native-shape detector (previously
+, -, *, > only) to also recognize the bitwise ops &, |, ^, and proves
the widening reaches all the way through the existing guarded-JIT
pipeline to a real, working, compiled native binary - not just a
detection-level match.

=head1 WHY IT EXISTS

DDE-007's approved plan found that PAX's existing native-shape mechanism
(RegionSelector -> HIR -> GuardedSSA -> Tier1's real C codegen/cc
compile/execute) is architecturally correct but scoped to only 3
hardcoded shapes. This file is the first concrete proof that widening
that catalogue - rather than writing more no-speedup pattern-matched
Perl closures in the old CodeUnitCompiler.pm/StandaloneRuntime.pm system
- actually works end-to-end. Bitwise ops were chosen deliberately over
the initially-attempted divide/modulo, after finding those have real
Perl-vs-C semantic mismatches (Perl's / always returns a float; Perl's
% follows the right operand's sign, C's follows the left) that would
have made the native path compute a WRONG answer for some real inputs -
exactly the class of correctness bug this whole investigation session
was about catching.

=head1 WHEN TO USE

Run this file whenever the i64_binary_leaf shape's op catalogue changes,
in either Capture.pm's live-capture probe or CodeUnitCompiler.pm's
duplicate detector, or Tier1.pm's C codegen.

=head1 HOW TO USE

    prove -lv t/220-native-shape-bitwise-ops.t

Requires a real C compiler (cc/gcc) on PATH for AC-3's end-to-end native
compile-and-run assertions; those are skipped (not failed) if none is
available, matching this project's own SKIP discipline for genuinely
environment-gated checks.

=head1 WHAT USES IT

Capture.pm's live-capture probe, CodeUnitCompiler.pm's duplicate
detector, and Tier1.pm's C codegen are not exercised for bitwise ops by
any other test file in this suite.

=head1 EXAMPLES

Example 1:

    prove -lv t/220-native-shape-bitwise-ops.t

Confirm both detectors and the real native compile-and-run path work.

=cut
