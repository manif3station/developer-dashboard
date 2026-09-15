package Developer::Dashboard::Pax::TypedIR;

our $VERSION = '4.32';

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {}, $class;
}

sub lower_unit {
    my ($self, $ssa_unit, %args) = @_;
    my $annotations = $args{type_annotations} || {};
    my $shape = $ssa_unit->{native_shape} // $ssa_unit->{source}{native_shape} // {};
    my $kind = $shape->{kind} // '';

    return {
        status => 'untyped',
        reason => 'no native shape available for typed lowering',
    } if !$kind;

    my $op = _typed_op_for_shape($shape);
    return {
        status => 'untyped',
        reason => 'native shape has no typed IR lowering',
    } if !$op;

    return {
        status => 'typed_ir',
        region_id => $ssa_unit->{region_id},
        region_name => $ssa_unit->{region_name},
        source => $annotations->{source} // 'unknown',
        confidence => $annotations->{confidence} // 'none',
        params => $annotations->{params} || [],
        return => $annotations->{return} // 'PerlScalar',
        ops => [
            {
                op => $op,
                shape_kind => $kind,
            },
        ],
    };
}

sub _typed_op_for_shape {
    my ($shape) = @_;
    my $kind = $shape->{kind} // '';
    return 'typed_i64_binary_leaf' if $kind eq 'i64_binary_leaf';
    return 'typed_i64_sum_loop' if $kind eq 'i64_sum_loop';
    return 'typed_i64_masked_mix_accum_loop' if $kind eq 'i64_masked_mix_accum_loop';
    return;
}

1;

=pod

=head1 NAME

Developer::Dashboard::Pax::TypedIR - lower native-capable SSA units into a typed intermediate form

=head1 SYNOPSIS

  use Developer::Dashboard::Pax::TypedIR;

  my $obj = Developer::Dashboard::Pax::TypedIR->new(...);
  my $result = $obj->lower_unit(...);

=head1 DESCRIPTION

Bridges guarded SSA and LLVM planning by expressing supported native shapes as a typed intermediate form with explicit parameter and return contracts.

=head1 METHODS

=head2 new, lower_unit

These are the public entrypoints exposed by this module's current interface.

=head1 PURPOSE

This module exists to keep the typed intermediate representation logic in one place so the CLI, build
pipeline, and runtime can reuse the same behavior instead of duplicating it.

=head1 WHY IT EXISTS

PAX uses this module when it needs typed intermediate representation lowering. Keeping that behavior isolated here
makes the surrounding compiler and packaging stages easier to reason about and
safer to evolve.

=head1 WHEN TO USE

Edit this file when a change affects typed intermediate representation lowering, the data contract this module
returns, or the conditions under which callers choose this path.

=head1 HOW TO USE

Load the module through the normal PAX call path, pass explicit arguments rather
than ambient global state, and keep project-specific behavior out of this file
so the implementation stays neutral across arbitrary Perl applications.

=head1 WHAT USES IT

This module is used by guarded SSA, LLVM backend planning, and the test suite
paths that cover typed native lowering.

=head1 EXAMPLES

Example 1:

  perl -Ilib -MDeveloper::Dashboard::Pax::TypedIR -e 1

Confirm that the module loads from a source checkout.

Example 2:

  prove -lv t/typed_ir.t

Run the focused typed IR regression coverage.

=cut
