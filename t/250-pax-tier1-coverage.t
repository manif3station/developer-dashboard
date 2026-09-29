#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Tier1;

my $root = tempdir( CLEANUP => 1 );
my $fake_bin = File::Spec->catdir( $root, 'bin' );
my $empty_bin = File::Spec->catdir( $root, 'empty-bin' );
make_path($fake_bin);
make_path($empty_bin);
my $fake_cc = File::Spec->catfile( $fake_bin, 'fake-cc' );
_write_fake_cc($fake_cc);
my $path_cc = File::Spec->catfile( $fake_bin, 'cc' );
_write_fake_cc($path_cc);
my $gcc_bin = File::Spec->catdir( $root, 'gcc-bin' );
make_path($gcc_bin);
my $path_gcc = File::Spec->catfile( $gcc_bin, 'gcc' );
_write_fake_cc($path_gcc);

my $defaults = Developer::Dashboard::Pax::Tier1->new;
is( $defaults->{backend}, 'portable-fallback', 'constructor defaults the backend label' );
is( $defaults->{out_dir}, '.pax/native', 'constructor defaults the artifact directory' );
my $configured = Developer::Dashboard::Pax::Tier1->new( backend => 'custom', out_dir => $root );
is( $configured->{backend}, 'custom', 'constructor preserves a configured backend label' );
is( $configured->{out_dir}, $root, 'constructor preserves a configured output directory' );

{
    local $ENV{CC};
    local $ENV{PATH} = $empty_bin;
    my $fallback = $configured->compile({ region_id => 'without-compiler' });
    is( $fallback->{status}, 'fallback_artifact', 'unavailable compiler returns a fallback artifact' );
    is( $fallback->{backend}, 'custom', 'unavailable compiler response keeps the configured backend label' );
    is( $fallback->{entry_kind}, 'interpreter_bridge', 'unavailable compiler identifies the interpreter bridge' );
}

my $native = Developer::Dashboard::Pax::Tier1->new( out_dir => File::Spec->catdir( $root, 'native' ) );
my $unknown_unit = { region_id => 'unknown-shape', region_name => 'strange', native_shape => { kind => 'unknown' } };
my $unknown;
{
    local $ENV{CC} = $fake_cc;
    local $ENV{PAX_FAKE_MODE} = 'ok';
    local $ENV{PAX_FAKE_OUTPUT} = '5';
    $unknown = $native->compile($unknown_unit);
}
is( $unknown->{status}, 'native_artifact', 'unknown shape still emits a native trampoline artifact' );
is( $unknown->{entry_kind}, 'native_probe_trampoline', 'unknown shape is marked as a trampoline' );
is( $unknown->{native_test}, undef, 'trampoline has no executable smoke test' );
like( _slurp( $unknown->{source_path} ), qr/return 1;/, 'unknown shape emits the harmless probe body' );
is( $unknown->{tier2_artifact}{status}, 'fallback', 'untyped shape reports the tier-two fallback artifact' );
my $empty_shape = Developer::Dashboard::Pax::Tier1::_c_source_for_region({});
is( $empty_shape->{entry_kind}, 'native_probe_trampoline', 'missing region shape uses the probe trampoline' );
like( $empty_shape->{source}, qr/region_id_len.*strlen\("unknown"\)/s, 'missing region id receives the stable unknown id' );

my $binary_unit = {
    region_id => 'r-7',
    region_name => 'sum"quoted',
    native_shape => {
        kind => 'i64_binary_leaf',
        op => 'add',
        smoke_left => 2,
        smoke_right => 3,
        smoke_expected => 5,
    },
    typed_ir => { status => 'typed_ir', ops => [{ op => 'typed_i64_binary_leaf' }] },
};
my $binary;
{
    local $ENV{CC} = $fake_cc;
    local $ENV{PAX_FAKE_MODE} = 'ok';
    local $ENV{PAX_FAKE_OUTPUT} = '5';
    $binary = $native->compile($binary_unit);
}
is( $binary->{status}, 'native_artifact', 'supported binary shape compiles as a native artifact' );
is( $binary->{entry_kind}, 'native_i64_leaf', 'binary shape selects the leaf entry kind' );
is( $binary->{native_test}{passed}, JSON::XS::true(), 'matching smoke output passes' );
is( $binary->{native_test}{actual}, '5', 'smoke test captures executable output' );
is( $binary->{backend_tiers}[0]{tier}, 1, 'compile result includes tier-one metadata' );
is( $binary->{backend_tiers}[1]{tier}, 2, 'compile result includes tier-two metadata' );
is( $binary->{tier2_artifact}{status}, 'llvm_ir_artifact', 'typed binary shape emits a tier-two module' );
like( _slurp( $binary->{source_path} ), qr/return left \+ right;/, 'binary emitter selects the add expression' );
like( _slurp( $binary->{tier2_artifact}{path} ), qr/region_name: sum\\"quoted/, 'tier-two module escapes region names' );

my $default_smoke;
{
    local $ENV{CC} = $fake_cc;
    local $ENV{PAX_FAKE_MODE} = 'ok';
    local $ENV{PAX_FAKE_OUTPUT} = '5';
    $default_smoke = Developer::Dashboard::Pax::Tier1->new( out_dir => File::Spec->catdir( $root, 'default-smoke' ) )->_emit_native_artifact({
        region_id => 'default-smoke',
        native_shape => { kind => 'i64_binary_leaf', op => 'add' },
    });
}
is( $default_smoke->{native_test}{expected}, '5', 'missing smoke expected value defaults to five' );
like( $default_smoke->{native_test}{command}, qr/ 2 3\z/, 'missing smoke arguments default to two and three' );

my $mismatch;
{
    local $ENV{CC} = $fake_cc;
    local $ENV{PAX_FAKE_MODE} = 'ok';
    local $ENV{PAX_FAKE_OUTPUT} = '999';
    $mismatch = Developer::Dashboard::Pax::Tier1->new( out_dir => File::Spec->catdir( $root, 'mismatch' ) )->_emit_native_artifact($binary_unit);
}
is( $mismatch->{native_test}{passed}, JSON::XS::false(), 'smoke output mismatch is recorded as a failed check' );

for my $case (
    [ subtract => 'return left - right;' ],
    [ multiply => 'return left * right;' ],
    [ greater_than => 'return left > right ? 1 : 0;' ],
    [ bitwise_and => 'return left & right;' ],
    [ bitwise_or => 'return left | right;' ],
    [ bitwise_xor => 'return left ^ right;' ],
    [ unsupported => 'return 0;' ],
) {
    my ( $op, $expected ) = @{$case};
    is( Developer::Dashboard::Pax::Tier1::_c_binary_expr($op), $expected, "$op maps to its exact C expression" );
}
is( Developer::Dashboard::Pax::Tier1::_c_binary_expr(undef), 'return 0;', 'missing binary operator uses the safe zero expression' );

my $sum = Developer::Dashboard::Pax::Tier1::_c_source_for_region({
    region_id => 'sum-region',
    native_shape => { kind => 'i64_sum_loop', op => 'sum_to_n', smoke_left => 10, smoke_right => 0, smoke_expected => 55 },
});
is( $sum->{entry_kind}, 'native_i64_loop', 'sum loop shape selects loop emitter' );
like( $sum->{source}, qr/for \(int64_t i = 1;/, 'sum loop emits its loop body' );
my $masked = Developer::Dashboard::Pax::Tier1::_c_source_for_region({
    region_id => 'masked-region',
    source => { native_shape => { kind => 'i64_masked_mix_accum_loop', op => 'masked_mix_accumulate' } },
});
like( $masked->{source}, qr/0xFFFFULL/, 'masked-mix source shape can be read from the source record' );
like( Developer::Dashboard::Pax::Tier1::_c_loop_body(), qr/left <= 0/, 'sum loop body handles non-positive limits' );
like( Developer::Dashboard::Pax::Tier1::_c_masked_mix_accum_loop_body(), qr/left <= 0/, 'masked-mix body handles non-positive limits' );
like( Developer::Dashboard::Pax::Tier1::_c_translation_unit( 'back\\slash"quote', 'return 1;' ), qr/back\\\\slash\\"quote/, 'translation unit escapes C string identifiers' );

my $fallback_unit = { region_id => 'compile-failed', native_shape => { kind => 'i64_binary_leaf', op => 'add' } };
for my $mode (qw(shared_fail shared_missing)) {
    my $failed;
    {
        local $ENV{CC} = $fake_cc;
        local $ENV{PAX_FAKE_MODE} = $mode;
        $failed = Developer::Dashboard::Pax::Tier1->new( out_dir => File::Spec->catdir( $root, $mode ) )->_emit_native_artifact($fallback_unit);
    }
    is( $failed->{status}, 'fallback_artifact', "$mode shared-library generation falls back" );
    like( $failed->{reason}, qr/C ABI backend failed/, "$mode reports shared-library generation failure" );
}

for my $mode (qw(exe_fail exe_missing)) {
    my $without_executable;
    {
        local $ENV{CC} = $fake_cc;
        local $ENV{PAX_FAKE_MODE} = $mode;
        local $ENV{PAX_FAKE_OUTPUT} = '5';
        $without_executable = Developer::Dashboard::Pax::Tier1->new( out_dir => File::Spec->catdir( $root, $mode ) )->_emit_native_artifact($fallback_unit);
    }
    is( $without_executable->{status}, 'native_artifact', "$mode preserves the compiled shared library" );
    is( $without_executable->{executable_path}, undef, "$mode leaves executable path absent" );
    is( $without_executable->{native_test}, undef, "$mode skips smoke execution when no executable exists" );
}

my $write_failure_dir = File::Spec->catdir( $root, 'source-open-failure' );
make_path( File::Spec->catdir( $write_failure_dir, 'fixed.c' ) );
my $source_failure;
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Tier1::sha256_hex = sub { return 'fixed' };
    $source_failure = Developer::Dashboard::Pax::Tier1->new( out_dir => $write_failure_dir )->_emit_native_artifact($fallback_unit);
}
is( $source_failure->{status}, 'fallback_artifact', 'unwritable native source returns a fallback artifact' );
like( $source_failure->{reason}, qr/cannot write native source/, 'source write failure explains its cause' );

{
    local $ENV{PATH} = $fake_bin;
    is( Developer::Dashboard::Pax::Tier1::_which('fake-cc'), $fake_cc, 'which resolves an executable through PATH' );
    is( Developer::Dashboard::Pax::Tier1::_which('missing-command'), undef, 'which returns undef when PATH has no matching command' );
}
{
    local $ENV{CC} = $fake_cc;
    is( Developer::Dashboard::Pax::Tier1::_cc(), $fake_cc, 'explicit CC takes precedence over PATH lookup' );
}
{
    local $ENV{CC} = '';
    local $ENV{PATH} = $fake_bin;
    is( Developer::Dashboard::Pax::Tier1::_cc(), $path_cc, 'empty CC falls back to executable discovery' );
}
{
    local $ENV{CC};
    local $ENV{PATH} = $gcc_bin;
    is( Developer::Dashboard::Pax::Tier1::_cc(), $path_gcc, 'compiler discovery tries gcc after cc is absent' );
}
{
    local $ENV{PATH};
    is( Developer::Dashboard::Pax::Tier1::_which('missing-command'), undef, 'which handles an unset PATH as an empty search list' );
}

done_testing();

sub _write_fake_cc {
    my ($path) = @_;
    _write( $path, <<'PERL' );
#!/usr/bin/env perl
use strict;
use warnings;
my @args = @ARGV;
my ($out_index) = grep { $args[$_] eq '-o' } 0 .. $#args;
die "missing -o argument\n" if !defined $out_index || !defined $args[$out_index + 1];
my $output = $args[$out_index + 1];
my $mode = $ENV{PAX_FAKE_MODE} // 'ok';
my $shared = grep { $_ eq '-shared' } @args;
if ($shared) {
    exit 1 if $mode eq 'shared_fail';
    exit 0 if $mode eq 'shared_missing';
    open my $lib, '>', $output or die "cannot create fake library: $!";
    print {$lib} "fake shared library\n" or die "cannot write fake library: $!";
    close $lib or die "cannot close fake library: $!";
    exit 0;
}
exit 1 if $mode eq 'exe_fail';
exit 0 if $mode eq 'exe_missing';
open my $exe, '>', $output or die "cannot create fake executable: $!";
my $printed = $ENV{PAX_FAKE_OUTPUT} // '5';
print {$exe} "#!/usr/bin/env perl\nprint qq($printed\\n);\n" or die "cannot write fake executable: $!";
close $exe or die "cannot close fake executable: $!";
chmod 0700, $output or die "cannot chmod fake executable: $!";
exit 0;
PERL
    chmod 0700, $path or die "Unable to chmod $path: $!";
    return;
}

sub _write {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    return;
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    return <$fh>;
}

__END__

=head1 NAME

t/250-pax-tier1-coverage.t - tests Tier 1 native artifact outcomes

=head1 PURPOSE

This test drives Tier 1 with a deterministic fake C compiler to cover native
shape selection, C generation, shared-library and executable outcomes, smoke
test results, source-write failure, and compiler discovery without depending
on an installed C toolchain.

=head1 WHY IT EXISTS

Tier 1 converts guarded SSA regions to native artifacts and must distinguish
unsupported shapes, unavailable tools, failed compilation, and successful
smoke-tested output. Each outcome is part of the build and runtime contract.

=head1 WHEN TO USE

Run this test when changing C<Tier1>, its source emitters, compiler selection,
or native smoke-test behavior.

=head1 HOW TO USE

Run inside the development container:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/250-pax-tier1-coverage.t

=head1 WHAT USES IT

PAX's CLI, benchmark runner, standalone analysis, and standalone image builder
use C<Developer::Dashboard::Pax::Tier1> to compile eligible regions.

=head1 EXAMPLES

Example 1: run the test alone in Docker to validate fallback and successful
compiler outcomes.

Example 2: include it in C<script/coverage-gate> to measure C<Tier1.pm>'s
statements, branches, conditions, and subroutines.

=cut
