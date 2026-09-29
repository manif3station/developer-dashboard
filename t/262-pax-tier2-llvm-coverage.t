#!/usr/bin/env perl

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Backend::Tier2LLVM ();

my $root = tempdir( CLEANUP => 1 );
my $default = Developer::Dashboard::Pax::Backend::Tier2LLVM->new;
is( $default->{out_dir}, '.pax/native', 'constructor defaults the native output directory' );
is( $default->{enabled}, 1, 'constructor enables the backend by default' );
is( $default->metadata->{status}, 'enabled', 'enabled metadata reports the active backend status' );
my $explicit_enabled = Developer::Dashboard::Pax::Backend::Tier2LLVM->new( enabled => 1, out_dir => $root );
is( $explicit_enabled->{enabled}, 1, 'constructor preserves an explicit enabled setting' );

my $disabled = Developer::Dashboard::Pax::Backend::Tier2LLVM->new( enabled => 0, out_dir => $root );
is( $disabled->{enabled}, 0, 'constructor preserves an explicit disabled setting' );
is( $disabled->{out_dir}, $root, 'constructor preserves an explicit output directory' );
is( $disabled->metadata->{status}, 'disabled_by_configuration', 'disabled metadata identifies configuration as its source' );
is_deeply(
    $disabled->emit_module( {} ),
    { status => 'disabled', reason => 'LLVM backend disabled by configuration' },
    'disabled backend declines emission without inspecting an SSA unit',
);

my $backend = Developer::Dashboard::Pax::Backend::Tier2LLVM->new( out_dir => File::Spec->catdir( $root, 'artifacts' ) );
my %binary_body = (
    add         => qr/add nsw i64 %left, %right/,
    subtract    => qr/sub nsw i64 %left, %right/,
    multiply    => qr/mul nsw i64 %left, %right/,
    greater_than => qr/icmp sgt i64 %left, %right/,
    unsupported => qr/ret i64 0/,
);
for my $op ( sort keys %binary_body ) {
    my $unit = {
        region_id   => "region-$op",
        region_name => "name-$op",
        native_shape => { op => $op },
        typed_ir => { status => 'typed_ir', ops => [ { op => 'typed_i64_binary_leaf' } ] },
    };
    my $module = $backend->module_for($unit);
    is( $module->{status}, 'llvm_ir', "typed binary '$op' shape is lowered to LLVM" );
    like( $module->{ir}, $binary_body{$op}, "typed binary '$op' emits its operation body" );
}

my $sum = $backend->module_for({
    region_id => 'sum-region',
    typed_ir  => { status => 'typed_ir', ops => [ { op => 'typed_i64_sum_loop' } ] },
});
is( $sum->{status}, 'llvm_ir', 'typed sum-loop shape is lowered' );
like( $sum->{ir}, qr/%next_sum = add nsw i64 %sum, %i/, 'sum-loop lowering emits its accumulator update' );
like( $sum->{ir}, qr/label %done_zero/, 'sum-loop lowering emits its non-positive exit' );

my $masked = $backend->module_for({
    region_name => 'masked-region',
    source => { native_shape => { op => 'fallback-shape' } },
    typed_ir => { status => 'typed_ir', ops => [ { op => 'typed_i64_masked_mix_accum_loop' } ] },
});
is( $masked->{status}, 'llvm_ir', 'typed masked-mix loop shape is lowered' );
like( $masked->{ir}, qr/%mix = xor i64 %mul, %shift/, 'masked-mix lowering emits its mixing operations' );
like( $masked->{ir}, qr/%term = and i64 %mix, 65535/, 'masked-mix lowering emits its term mask' );

my $missing_op = $backend->module_for({
    typed_ir => { status => 'typed_ir', ops => [ { op => 'typed_i64_binary_leaf' } ] },
});
is( $missing_op->{status}, 'llvm_ir', 'binary leaf with no source operation still yields valid fallback LLVM' );
like( $missing_op->{ir}, qr/ret i64 0/, 'binary leaf with no source operation emits the zero result body' );

for my $unit (
    {},
    { typed_ir => { status => 'not_typed', ops => [ { op => 'typed_i64_binary_leaf' } ] } },
    { typed_ir => { status => 'typed_ir', ops => [] } },
    { typed_ir => { status => 'typed_ir', ops => [ { op => 'unknown_shape' } ] } },
) {
    is( $backend->module_for($unit)->{status}, 'fallback', 'unsupported or incomplete typed shape reports explicit fallback' );
}

my $escaped = $backend->module_for({
    region_id   => 'id\\"quoted',
    region_name => 'name\\"quoted',
    native_shape => { op => 'add' },
    typed_ir => { status => 'typed_ir', ops => [ { op => 'typed_i64_binary_leaf' } ] },
});
like( $escaped->{ir}, qr/region_id: id\\\\\\"quoted/, 'module metadata escapes backslashes and quotes in region ids' );
like( $escaped->{ir}, qr/region_name: name\\\\\\"quoted/, 'module metadata escapes backslashes and quotes in region names' );
like( $escaped->{ir}, qr/target triple = "unknown-unknown-unknown"/, 'module declares the target triple' );
like( $escaped->{ir}, qr/define i64 \@pax_region_probe/, 'module emits its probe function' );

my $artifact_unit = {
    native_shape => { op => 'add' },
    typed_ir => { status => 'typed_ir', ops => [ { op => 'typed_i64_binary_leaf' } ] },
};
my $artifact = $backend->emit_module($artifact_unit);
is( $artifact->{status}, 'llvm_ir_artifact', 'supported shape writes an LLVM IR artifact' );
is( $artifact->{entry_symbol}, 'pax_region_i64', 'artifact identifies its native entry symbol' );
is( $artifact->{module_id}, sha256_hex( join "\n", '', '', $backend->module_for($artifact_unit)->{ir} ), 'artifact id hashes empty region identity fields and IR text when identity is absent' );
like( do { open my $fh, '<', $artifact->{path} or die "Unable to read $artifact->{path}: $!"; local $/; <$fh> }, qr/region_id: unknown\n; region_name: unknown/, 'missing region identity is represented by the module defaults' );
ok( -f $artifact->{path}, 'artifact file exists at its reported path' );
open my $artifact_fh, '<', $artifact->{path} or die "Unable to read $artifact->{path}: $!";
is( do { local $/; <$artifact_fh> }, $backend->module_for($artifact_unit)->{ir}, 'artifact file contains the generated LLVM IR' );
close $artifact_fh or die "Unable to close $artifact->{path}: $!";

my $unsupported_artifact = $backend->emit_module({});
is( $unsupported_artifact->{status}, 'fallback', 'artifact emission passes through unsupported-shape fallback' );

{
    package Local::Tier2MissingStatus;
    our @ISA = ('Developer::Dashboard::Pax::Backend::Tier2LLVM');
    sub module_for { return {} }
}
my $overridden_backend = Local::Tier2MissingStatus->new( out_dir => File::Spec->catdir( $root, 'override' ) );
is_deeply( $overridden_backend->emit_module({}), {}, 'status-less module metadata from an override passes through unchanged' );

my $failure_dir = File::Spec->catdir( $root, 'blocked-output' );
my $failure_backend = Developer::Dashboard::Pax::Backend::Tier2LLVM->new( out_dir => $failure_dir );
my $failure_unit = {
    region_id   => 'blocked-region',
    region_name => 'blocked-name',
    native_shape => { op => 'subtract' },
    typed_ir => { status => 'typed_ir', ops => [ { op => 'typed_i64_binary_leaf' } ] },
};
my $failure_module = $failure_backend->module_for($failure_unit);
my $failure_id = sha256_hex( join "\n", $failure_unit->{region_id}, $failure_unit->{region_name}, $failure_module->{ir} );
make_path( $failure_dir, File::Spec->catdir( $failure_dir, "$failure_id.ll" ) );
my $write_failure = $failure_backend->emit_module($failure_unit);
is( $write_failure->{status}, 'fallback', 'filesystem open failure returns a fallback result' );
like( $write_failure->{reason}, qr/^cannot write LLVM IR module:/, 'filesystem fallback explains the failed write' );

done_testing();

__END__

=head1 NAME

t/262-pax-tier2-llvm-coverage.t - exercises the Tier 2 LLVM backend contract

=head1 PURPOSE

This test covers construction, metadata, typed-shape lowering, fallback paths,
LLVM text escaping, and filesystem artifact emission for
C<Developer::Dashboard::Pax::Backend::Tier2LLVM>.

=head1 WHY IT EXISTS

Tier 2 translates supported typed SSA shapes into LLVM IR and writes artifacts
for later native compilation. Direct contract tests cover operation choices and
write failures without requiring an installed LLVM toolchain.

=head1 WHEN TO USE

Run this test when changing Tier 2 configuration, metadata, supported IR shapes,
the emitted LLVM syntax, or artifact persistence.

=head1 HOW TO USE

Run C<prove -lv t/262-pax-tier2-llvm-coverage.t> through the repository's
Docker development service.

=head1 WHAT USES IT

C<Developer::Dashboard::Pax::Tier1> and C<Developer::Dashboard::Pax::Gatekeeper>
use this backend's metadata and module-emission contract.

=head1 EXAMPLES

Example 1: the test verifies that an enabled typed add region creates a readable
C<.ll> artifact.

Example 2: the test verifies that unknown shapes and unwriteable artifact paths
return explicit fallback results.

=cut
