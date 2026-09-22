package Fixture::NativeShapeBitwise;

sub bitand_leaf {
    my ($a, $b) = @_;
    return $a & $b;
}

sub bitxor_leaf {
    my ($a, $b) = @_;
    return $a ^ $b;
}

1;

__END__

=pod

=head1 NAME

t/fixtures/native-shape-bitwise.pl - fixture: two leaf subs for the i64_binary_leaf bitwise-op native shape

=head1 PURPOSE

Defines C<bitand_leaf> and C<bitxor_leaf>, two small pure two-argument
leaf functions using the bitwise C<&> and C<^> operators - the shape
C<Developer::Dashboard::Pax>'s native-shape JIT should recognize and
compile to real machine code (DD-1032).

=head1 WHY IT EXISTS

Proves the C<i64_binary_leaf> native shape's op catalogue was genuinely
widened to include bitwise operators, chosen deliberately over
divide/modulo after finding those have real Perl-vs-C semantic
mismatches that would make a native-compiled version compute a wrong
answer for some inputs (see this subsystem's own vault documentation
page on the native-shape JIT).

=head1 WHEN TO USE

Change this file only when the specific bitwise-op shapes it captures
need to change. Add a new, separate fixture for a different op or shape
rather than widening this one's scope.

=head1 HOW TO USE

Captured live via C<Developer::Dashboard::Pax::Capture>'s
C<mode =E<gt> 'live'> probe, driven from
t/220-native-shape-bitwise-ops.t.

=head1 WHAT USES IT

t/220-native-shape-bitwise-ops.t, exercising the widened native-shape
detector (Capture.pm/CodeUnitCompiler.pm) and the real C codegen/compile
path (Tier1.pm) against both subs.

=head1 EXAMPLES

Running it interpreted, the baseline behavior a compiled version must
match:

    perl -e 'require "t/fixtures/native-shape-bitwise.pl"; print Fixture::NativeShapeBitwise::bitand_leaf(2,3), "\n";'

=cut
