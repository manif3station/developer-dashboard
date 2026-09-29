#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::TypeAnnotationExtractor;

my $defaults = Developer::Dashboard::Pax::TypeAnnotationExtractor->new();
is( $defaults->{source_text}, undef, 'source text defaults to undefined' );
is_deeply( $defaults->{native_shape}, {}, 'native shape defaults to an empty hash' );
is( $defaults->{region_name}, 'unknown', 'region name defaults to unknown' );
is_deeply(
    $defaults->extract,
    { source => 'unknown', confidence => 'none', region_name => 'unknown', params => [], return => 'PerlScalar' },
    'missing annotations and shapes return an untyped contract',
);

for my $kind ( qw(i64_sum_loop i64_masked_mix_accum_loop) ) {
    my $inferred = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
        native_shape => { kind => $kind }, region_name => "region-$kind",
    )->extract;
    is( $inferred->{source}, 'native_shape_inference', "$kind uses shape inference" );
    is( $inferred->{confidence}, 'inferred', "$kind is marked inferred" );
    is( $inferred->{region_name}, "region-$kind", "$kind inference preserves region name" );
    is_deeply( $inferred->{params}, [{ name => '$left', type => 'i64' }], "$kind infers its left parameter" );
    is( $inferred->{return}, 'i64', "$kind infers i64 return" );
}

my $binary = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
    native_shape => { kind => 'i64_binary_leaf' },
)->extract;
is_deeply( $binary->{params}, [ { name => '$left', type => 'i64' }, { name => '$right', type => 'i64' } ], 'binary leaf infers both operands' );
is( $binary->{return}, 'i64', 'binary leaf infers i64 return' );

my $unknown_shape = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
    source_text => '',
    native_shape => { kind => 'unrecognized' },
    region_name => 'unknown-region',
)->extract;
is( $unknown_shape->{confidence}, 'none', 'unrecognized shape remains untyped' );
is( $unknown_shape->{region_name}, 'unknown-region', 'unknown result retains its region name' );

my $full_annotation = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
    source_text => <<'SOURCE',
# pax-type: params=$left:i64,$right:Num return=My::Result
SOURCE
    native_shape => { kind => 'i64_binary_leaf' },
    region_name => 'explicit-region',
)->extract;
is( $full_annotation->{source}, 'comment', 'source annotation takes precedence over inferred shape' );
is( $full_annotation->{confidence}, 'explicit', 'source annotation has explicit confidence' );
is( $full_annotation->{region_name}, 'explicit-region', 'explicit result retains region name' );
is_deeply( $full_annotation->{params}, [ { name => '$left', type => 'i64' }, { name => '$right', type => 'Num' } ], 'annotation parses comma-separated parameter types' );
is( $full_annotation->{return}, 'My::Result', 'annotation parses qualified return type' );

my $params_without_return = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
    source_text => "# pax-type: params=\$value:Str\n",
)->extract;
is_deeply( $params_without_return->{params}, [{ name => '$value', type => 'Str' }], 'parameter-only annotation is retained' );
is( $params_without_return->{return}, 'PerlScalar', 'parameter-only annotation defaults return type' );

my $return_without_params = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
    source_text => "# pax-type: return=Bool\n",
)->extract;
is_deeply( $return_without_params->{params}, [], 'return-only annotation has no parameters' );
is( $return_without_params->{return}, 'Bool', 'return-only annotation is retained' );

my $partial_params = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
    source_text => "# pax-type: params=missing,\$good:i64,,also_missing return=\n",
)->extract;
is_deeply( $partial_params->{params}, [{ name => '$good', type => 'i64' }], 'malformed and empty parameter fragments are skipped' );
is( $partial_params->{return}, 'PerlScalar', 'invalid return annotation defaults to PerlScalar' );

my $annotation_without_payload = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
    source_text => "# pax-type:\n",
    native_shape => { kind => 'i64_binary_leaf' },
)->extract;
is( $annotation_without_payload->{confidence}, 'inferred', 'annotation marker without recognized values falls back to inference' );

my $falsey_extractor = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
    source_text => undef,
    native_shape => undef,
);
is_deeply( $falsey_extractor->{native_shape}, {}, 'constructor normalizes undefined shape to an empty hash' );
my $falsey_shape = $falsey_extractor->extract;
is( $falsey_shape->{confidence}, 'none', 'undefined source and shape use safe defaults' );

done_testing();

__END__

=pod

=head1 NAME

t/241-pax-type-annotation-extractor-coverage.t - explicit and inferred type contract coverage

=head1 PURPOSE

Test defaults, supported inferred shapes, explicit type comments, partial or
malformed annotations, and the conservative untyped fallback of
C<Developer::Dashboard::Pax::TypeAnnotationExtractor>.

=head1 WHY IT EXISTS

The extractor is the typed-IR pipeline's contract boundary. Explicit type
comments must take priority, recognized native shapes may infer only known
types, and incomplete information must never be upgraded into a guessed type.

=head1 WHEN TO USE

Run when changing the C<# pax-type:> syntax, inferred shape table, or returned
confidence contract.

=head1 HOW TO USE

Run in the development Docker service with
C<prove -lv t/241-pax-type-annotation-extractor-coverage.t>. All inputs are
in-memory source strings and shape hashes.

=head1 WHAT USES IT

PAX's typed IR and native compiler planning paths use this result to decide
whether a region has explicit, inferred, or no usable type information.

=head1 EXAMPLES

Example 1 - parse an explicit return type:

  my $contract = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
      source_text => "# pax-type: return=Bool\n",
  )->extract;

Example 2 - infer the known binary-leaf contract:

  my $contract = Developer::Dashboard::Pax::TypeAnnotationExtractor->new(
      native_shape => { kind => 'i64_binary_leaf' },
  )->extract;

=cut
