package Developer::Dashboard::Pax::TypeAnnotationExtractor;

our $VERSION = '4.32';

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        source_text => $args{source_text},
        native_shape => $args{native_shape} // {},
        region_name => $args{region_name} // 'unknown',
    }, $class;
}

sub extract {
    my ($self) = @_;

    my $explicit = $self->_extract_explicit_annotations;
    return $explicit if $explicit;

    return $self->_infer_from_native_shape;
}

# Parse explicit PAX type hints when the source carries them so later compiler
# stages can work from an operator-authored contract instead of pure inference.
sub _extract_explicit_annotations {
    my ($self) = @_;
    my $text = $self->{source_text};
    return if !defined $text || !length $text;

    my @params;
    my $return;

    while ($text =~ /^\s*#\s*pax-type:\s*(.+?)\s*$/mg) {
        my $payload = $1;
        if ($payload =~ /\bparams\s*=\s*([^\n]+?)(?=\s+\w+\s*=|$)/) {
            my $spec = $1;
            for my $item (split /\s*,\s*/, $spec) {
                next if !length $item;
                my ($name, $type) = split /\s*:\s*/, $item, 2;
                next if !defined $name || !defined $type;
                push @params, {
                    name => $name,
                    type => $type,
                };
            }
        }
        if ($payload =~ /\breturn\s*=\s*([A-Za-z_][A-Za-z0-9_:]*)/) {
            $return = $1;
        }
    }

    return if !@params && !defined $return;

    return {
        source => 'comment',
        confidence => 'explicit',
        region_name => $self->{region_name},
        params => \@params,
        return => $return // 'PerlScalar',
    };
}

# Infer the minimal typed contract PAX can safely promise today for native
# shapes it already understands, so the typed IR stage has a consistent entry
# point even when source annotations are absent.
sub _infer_from_native_shape {
    my ($self) = @_;
    my $shape = $self->{native_shape} // {};
    my $kind = $shape->{kind} // '';

    if ($kind eq 'i64_sum_loop' || $kind eq 'i64_masked_mix_accum_loop') {
        return {
            source => 'native_shape_inference',
            confidence => 'inferred',
            region_name => $self->{region_name},
            params => [
                { name => '$left', type => 'i64' },
            ],
            return => 'i64',
        };
    }

    if ($kind eq 'i64_binary_leaf') {
        return {
            source => 'native_shape_inference',
            confidence => 'inferred',
            region_name => $self->{region_name},
            params => [
                { name => '$left', type => 'i64' },
                { name => '$right', type => 'i64' },
            ],
            return => 'i64',
        };
    }

    return {
        source => 'unknown',
        confidence => 'none',
        region_name => $self->{region_name},
        params => [],
        return => 'PerlScalar',
    };
}

1;

=pod

=head1 NAME

Developer::Dashboard::Pax::TypeAnnotationExtractor - extract or infer typed contracts for native-capable regions

=head1 SYNOPSIS

  use Developer::Dashboard::Pax::TypeAnnotationExtractor;

  my $obj = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(...);
  my $result = $obj->extract(...);

=head1 DESCRIPTION

Extracts explicit C<# pax-type: ...> hints from source when available and falls back to shape-based type inference for native-capable regions.

=head1 METHODS

=head2 new, extract

These are the public entrypoints exposed by this module's current interface.

=head1 PURPOSE

This module exists to keep the typed-contract extraction logic in one place so the CLI, build
pipeline, and runtime can reuse the same behavior instead of duplicating it.

=head1 WHY IT EXISTS

PAX uses this module when it needs typed-contract extraction. Keeping that behavior isolated here
makes the surrounding compiler and packaging stages easier to reason about and
safer to evolve.

=head1 WHEN TO USE

Edit this file when a change affects typed-contract extraction, the data contract this module
returns, or the conditions under which callers choose this path.

=head1 HOW TO USE

Load the module through the normal PAX call path, pass explicit arguments rather
than ambient global state, and keep project-specific behavior out of this file
so the implementation stays neutral across arbitrary Perl applications.

=head1 WHAT USES IT

This module is used by the guarded SSA, LLVM backend planning, and the test
suite paths that cover typed-region extraction.

=head1 EXAMPLES

Example 1:

  perl -Ilib -MDeveloper::Dashboard::Pax::TypeAnnotationExtractor -e 1

Confirm that the module loads from a source checkout.

Example 2:

  prove -lv t/type_annotation_extractor.t

Run the focused extraction regression coverage.

=cut
