#!/usr/bin/env perl

use strict;
use warnings;

use File::Find qw(find);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::CodeUnitCompiler;

my @paths;
find(
    {
        wanted => sub {
            return if !-f $_ || $_ !~ /\.pm\z/;
            push @paths, $File::Find::name;
        },
        no_chdir => 1,
    },
    'lib',
);
@paths = sort @paths;

my $source_count = 0;
my $declared_count = 0;
my $recognized_count = 0;
my $native_shape_count = 0;
my @invalid_descriptors;
for my $path (@paths) {
    my $source = Developer::Dashboard::Pax::CodeUnitCompiler::_slurp($path);
    my $package = Developer::Dashboard::Pax::CodeUnitCompiler::_package_name($source);
    next if !$package;
    $source_count++;
    for my $full_name (Developer::Dashboard::Pax::CodeUnitCompiler::_declared_subs($source, $package)) {
        my ($short_name) = $full_name =~ /::([^:]+)\z/;
        next if !$short_name;
        $declared_count++;
        my $result = Developer::Dashboard::Pax::CodeUnitCompiler::_custom_sub_from_source($source, $short_name, $package, $full_name);
        $result ||= Developer::Dashboard::Pax::CodeUnitCompiler::_compile_simple_transform_sub_from_source($source, $short_name, $full_name);
        my $declared = Developer::Dashboard::Pax::CodeUnitCompiler::_compile_declared_sub_from_source($source, $full_name);
        my $native = Developer::Dashboard::Pax::CodeUnitCompiler::_compile_sub(
            { name => $full_name, native_shape => { kind => 'i64_binary_leaf' } },
            $source,
        );
        $native_shape_count++ if $native;
        for my $descriptor (grep { defined } ($result, $declared, $native)) {
            $recognized_count++;
            push @invalid_descriptors, "$path:$short_name expected=$full_name got=" . (ref($descriptor) eq 'HASH' ? ($descriptor->{full_name} // '<missing>') : '<not-hash>')
                if ref($descriptor) ne 'HASH'
                || ($descriptor->{full_name} // '') ne $full_name
                || ($descriptor->{name} // '') ne $short_name;
        }
    }
}

ok( @paths > 0, 'repository library contains Perl source modules for compiler matching' );
ok( $source_count > 0, 'source contract scans modules with package declarations' );
ok( $declared_count > 0, 'source contract scans declared subroutines' );
ok( $recognized_count > 0, 'compiler recognizes at least one repository source transformation' );
ok( $native_shape_count > 0, 'compiler recognizes supported native-shape capture descriptors' );
is_deeply( \@invalid_descriptors, [], 'recognized transformations preserve package and subroutine identity' );

my $work = tempdir( CLEANUP => 1 );
my $compiler = Developer::Dashboard::Pax::CodeUnitCompiler->new();
my $missing_path = eval { $compiler->compile( kind => 'lib', logical_path => 'lib/Missing.pm' ); 1 };
ok( !$missing_path, 'compile requires a source path' );
like( $@, qr/path required/, 'missing source path reports its required argument' );
my $missing_kind = eval { $compiler->compile( path => __FILE__, logical_path => 't/test.pm' ); 1 };
ok( !$missing_kind, 'compile requires a unit kind' );
like( $@, qr/kind required/, 'missing unit kind reports its required argument' );
my $missing_logical = eval { $compiler->compile( path => __FILE__, kind => 'lib' ); 1 };
ok( !$missing_logical, 'compile requires a logical path' );
like( $@, qr/logical_path required/, 'missing logical path reports its required argument' );

my $script_path = File::Spec->catfile( $work, 'main.pl' );
_write(
    $script_path,
    "#!/usr/bin/env perl\nsub main { my (\$left, \$right) = \@_; return \$left + \$right; }\nexit main(\@ARGV) unless caller;\n",
);
my $script_unit = $compiler->compile(
    path => $script_path,
    kind => 'entrypoint',
    logical_path => 'bin/main.pl',
);
is( $script_unit->{packaging}, 'compiled_script_pcu_v1', 'entrypoint compilation creates a script unit for a native-recognizable main' );
like( $script_unit->{logical_path}, qr/main\.script\.json\z/, 'script output logical path uses the script JSON suffix' );

my $service_path = File::Spec->catfile( $work, 'service' );
_write(
    $service_path,
    "sub main { }\nmy \$cmd = shift \@argv || 'version';\nrequire App::Service;\nrequire Web::Runner;\nmy \$APP_VERSION = '1.23';\nApp::Service->build_psgi_app(asset_root => 'public');\n",
);
my $service_unit = $compiler->compile(
    path => $service_path,
    kind => 'entrypoint',
    logical_path => 'bin/service',
);
is( $service_unit->{packaging}, 'compiled_service_dispatch_pcu_v1', 'service dispatcher source is recognized before generic scripts' );
is( $service_unit->{compiled_format}, 'service_dispatch_pcu_v1', 'service dispatcher carries its code-unit format' );

my $dispatch_path = File::Spec->catfile( $work, 'dispatch.pl' );
_write(
    $dispatch_path,
    q{my $cmd = shift @ARGV || 'version';
if ($cmd eq 'version') { print App::Version::show(), "\n"; exit 0; }
print STDERR "Unknown: $cmd"; exit 2;
},
);
my $dispatch_unit = $compiler->compile(
    path => $dispatch_path,
    kind => 'entrypoint',
    logical_path => 'bin/dispatch.pl',
);
is( $dispatch_unit->{packaging}, 'compiled_dispatch_script_pcu_v1', 'dispatch action source is recognized as a dispatch unit' );

my $router_path = File::Spec->catfile( $work, 'router.pl' );
_write(
    $router_path,
    q{my $cmd = shift @ARGV || '';
use Pod::Usage;
pod2usage();
unknown_command_message();
require Developer::Dashboard::Version;
print $Developer::Dashboard::Version::VERSION, "\n"; exit 0;
print STDERR Developer::Dashboard::CLI::Suggest->new()->unknown_command_message($cmd);
sub _prime_command_result_env { }
$ENV{DASHBOARD_ENTRYPOINT} ||= 'dashboard';
},
);
my $router_unit = $compiler->compile(
    path => $router_path,
    kind => 'entrypoint',
    logical_path => 'bin/router.pl',
);
is( $router_unit->{packaging}, 'compiled_cli_router_pcu_v1', 'CLI router source is recognized as a router unit' );

my $module_path = File::Spec->catfile( $work, 'Native.pm' );
_write( $module_path, "package Test::Native;\nsub add { my (\$left, \$right) = \@_; return \$left + \$right; }\n1;\n" );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::CodeUnitCompiler::_capture_with_timeout = sub {
        return {
            status => 'ok',
            capture => {
                sub_optrees => [ {
                    name => 'Test::Native::add',
                    native_shape => { kind => 'i64_binary_leaf', op => 'add' },
                    closure_descriptor => { file => $module_path },
                } ],
            },
        };
    };
    my $unit = $compiler->compile(
        path => $module_path,
        kind => 'lib',
        logical_path => 'lib/Native.pm',
    );
    is( $unit->{packaging}, 'compiled_pcu_v1', 'module compilation consumes matching capture metadata into a compiled unit' );
    is( $unit->{package}, 'Test::Native', 'compiled module preserves its declared package' );
}

my $missing_package_path = File::Spec->catfile( $work, 'NotAModule.pm' );
_write( $missing_package_path, "return 1;\n" );
my $fallback = $compiler->compile(
    path => $missing_package_path,
    kind => 'lib',
    logical_path => 'lib/NotAModule.pm',
);
is( $fallback->{packaging}, 'source_payload_fallback', 'module compilation keeps unrecognized source as a payload' );
is( $fallback->{fallback_reason}, 'missing_package_declaration', 'fallback metadata names the missing package declaration' );

my $empty_module_path = File::Spec->catfile( $work, 'Empty.pm' );
_write( $empty_module_path, "package Test::Empty;\nour \$VERSION = '1.00';\n1;\n" );
my $empty_unit = $compiler->compile( path => $empty_module_path, kind => 'lib', logical_path => 'lib/Empty.pm' );
is( $empty_unit->{packaging}, 'compiled_pcu_v1', 'module without subroutines compiles its package initializers' );

my $bad_initializer_path = File::Spec->catfile( $work, 'BadInitializer.pm' );
_write( $bad_initializer_path, "package Test::BadInitializer;\nuse Test::Import {invalid};\n1;\n" );
my $bad_initializer = $compiler->compile( path => $bad_initializer_path, kind => 'lib', logical_path => 'lib/BadInitializer.pm' );
is( $bad_initializer->{fallback_reason}, 'unsupported_initializer_pattern', 'unsupported use arguments fall back with a specific initializer reason' );

my $exporter_path = File::Spec->catfile( $work, 'Exporter.pm' );
_write( $exporter_path, "package Test::Exporter;\nuse Exporter 'import';\nour \@EXPORT_OK = qw(value);\nsub value { return 1; }\n" );
my $exporter_unit = $compiler->compile( path => $exporter_path, kind => 'lib', logical_path => 'lib/Exporter.pm' );
is( $exporter_unit->{fallback_reason}, 'unsupported_exporter_contract', 'Exporter import contract retains source fallback' );

my $literal_module_path = File::Spec->catfile( $work, 'Literal.pm' );
_write( $literal_module_path, "package Test::Literal;\nsub value { return 42; }\n1;\n" );
my $dependency_unit = $compiler->compile( path => $literal_module_path, kind => 'dependency', logical_path => 'lib/Literal.pm' );
is( $dependency_unit->{packaging}, 'compiled_pcu_v1', 'fully recognized dependency subroutines use compiled packaging' );

my $hybrid_module_path = File::Spec->catfile( $work, 'Hybrid.pm' );
_write( $hybrid_module_path, "package Test::Hybrid;\nsub value { return \$ENV{X}; }\n1;\n" );
my $dependency_hybrid = $compiler->compile( path => $hybrid_module_path, kind => 'dependency', logical_path => 'lib/Hybrid.pm' );
is( $dependency_hybrid->{packaging}, 'hybrid_compiled_pcu_v1', 'dependency with unsupported routine uses hybrid source preservation' );

my $fallback_density_path = File::Spec->catfile( $work, 'FallbackDensity.pm' );
_write( $fallback_density_path, "package Test::FallbackDensity;\n" . join('', map { "sub unsupported_$_ { return \$ENV{X}; }\n" } 1 .. 8) . "1;\n" );
my $density_fallback = $compiler->compile( path => $fallback_density_path, kind => 'dependency', logical_path => 'lib/FallbackDensity.pm' );
is( $density_fallback->{fallback_reason}, 'hybrid_coverage_too_low', 'dependency with eight unsupported subroutines falls back rather than emitting a low-coverage hybrid' );

my $captured_literal_path = File::Spec->catfile( $work, 'CapturedLiteral.pm' );
_write( $captured_literal_path, "package Test::CapturedLiteral;\nsub value { return 7; }\n1;\n" );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::CodeUnitCompiler::_capture_with_timeout = sub { return { status => 'failed' }; };
    my $failed_capture_with_source = $compiler->compile( path => $captured_literal_path, kind => 'lib', logical_path => 'lib/CapturedLiteral.pm' );
    is( $failed_capture_with_source->{packaging}, 'compiled_pcu_v1', 'failed live capture retains fully source-compiled subroutines' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::CodeUnitCompiler::_capture_with_timeout = sub { return { status => 'failed' }; };
    my $failed_capture_hybrid = $compiler->compile( path => $hybrid_module_path, kind => 'lib', logical_path => 'lib/Hybrid.pm' );
    is( $failed_capture_hybrid->{packaging}, 'hybrid_compiled_pcu_v1', 'failed live capture preserves unsupported declared subroutines as hybrid source' );
}
my $pod_sub_path = File::Spec->catfile( $work, 'PodSub.pm' );
_write( $pod_sub_path, "package Test::PodSub;\n=pod\nsub documented_only { }\n=cut\n1;\n" );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::CodeUnitCompiler::_capture_with_timeout = sub { return { status => 'failed' }; };
    my $pod_sub = $compiler->compile( path => $pod_sub_path, kind => 'lib', logical_path => 'lib/PodSub.pm' );
    is( $pod_sub->{fallback_reason}, 'capture_failed', 'failed capture with only POD sub text reports capture failure' );
}

my $uncaptured_path = File::Spec->catfile( $work, 'Uncaptured.pm' );
_write( $uncaptured_path, "package Test::Uncaptured;\nsub value { return 3; }\n1;\n" );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::CodeUnitCompiler::_capture_with_timeout = sub {
        return { status => 'ok', capture => { sub_optrees => [{ name => 'Test::Uncaptured::unknown', closure_descriptor => { file => $uncaptured_path } }] } };
    };
    my $uncaptured = $compiler->compile( path => $uncaptured_path, kind => 'lib', logical_path => 'lib/Uncaptured.pm' );
    is( $uncaptured->{packaging}, 'hybrid_compiled_pcu_v1', 'capture entries for undeclared routines retain them in hybrid metadata' );
}

{
    local $ENV{PAX_CODE_UNIT_MAX_CAPTURE_SUBS} = 0;
    my $lazy_hybrid = $compiler->compile( path => $hybrid_module_path, kind => 'lib', logical_path => 'lib/Hybrid.pm' );
    is( $lazy_hybrid->{packaging}, 'hybrid_compiled_pcu_v1', 'large compiler units take the lazy hybrid path' );
}

ok( Developer::Dashboard::Pax::CodeUnitCompiler::_bootstrap_has_shared_lexicals("my \$state = 1;\n"), 'hybrid bootstrap detects shared lexical state' );
ok( !Developer::Dashboard::Pax::CodeUnitCompiler::_bootstrap_has_shared_lexicals("our \$state = 1;\n"), 'hybrid bootstrap ignores package globals as shared lexicals' );
ok( !Developer::Dashboard::Pax::CodeUnitCompiler::_bootstrap_has_shared_lexicals(undef), 'empty hybrid bootstrap has no shared lexicals' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_calls_class_tail('Thing->new()', 'Thing', 'new'), 1, 'class-call matcher recognizes unqualified class methods' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_calls_class_tail('Other::Thing->new()', 'Thing', 'new'), 1, 'class-call matcher recognizes qualified class methods' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_calls_class_tail('Thing::Other()', 'Thing', undef), 1, 'class matcher recognizes qualified package references without a method' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_calls_class_tail(undef, 'Thing', 'new'), 0, 'class matcher rejects undefined source bodies' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_requires_class_tail("require Thing;\n", 'Thing'), 1, 'require matcher recognizes a local package' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_requires_class_tail("require Foo::Thing;\n", 'Thing'), 1, 'require matcher recognizes a qualified package tail' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_requires_class_tail(undef, 'Thing'), 0, 'require matcher rejects undefined source bodies' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_sibling_class('Foo::Parent', 'Child::Leaf'), 'Foo::Child::Leaf', 'sibling class preserves package root and nested class name' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_sibling_class('Foo::Parent', ''), 'Foo::Parent', 'sibling class falls back when class name is empty' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_related_class_from_source('', 'Foo::Parent', '', 'Child'), 'Foo::Child', 'related class defaults to a sibling when no source reference exists' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_related_class_from_source('', 'Foo::Parent', '', undef), 'Foo::Parent', 'related class handles an absent class reference' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_qualified_class_in_scope('Foo::Child->new()', 'Child', ['new']), 'Foo::Child', 'qualified class matcher prefers requested method references' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_qualified_class_in_scope('Foo::Child()', 'Child', []), 'Foo::Child', 'qualified class matcher accepts package references without methods' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_imported_class_in_scope("use Foo::Child;\n", 'Child'), 'Foo::Child', 'imported class matcher recognizes use declarations' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_imported_class_in_scope("require Foo::Child;\n", 'Child'), 'Foo::Child', 'imported class matcher recognizes require declarations' );
like( Developer::Dashboard::Pax::CodeUnitCompiler::_extract_sub_source("sub with_proto (\$) { return 1; }\n", 'with_proto'), qr/^sub with_proto/, 'sub source extractor retains declaration and body' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_extract_sub_source('sub open {', 'open'), undef, 'sub source extractor rejects an unclosed body' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_parse_array_literal_values('qw(a b), 2 !'), undef, 'array literal parser rejects unsupported punctuation' );
is_deeply( Developer::Dashboard::Pax::CodeUnitCompiler::_parse_array_literal_values("qw(a b), 2, -1.5, 'z'"), ['a', 'b', 2, -1.5, 'z'], 'array literal parser handles qw, numbers, and quoted values' );
is_deeply( Developer::Dashboard::Pax::CodeUnitCompiler::_parse_array_literal_values("map { sprintf 'T%d!', \$_ } 2..0"), ['T2!', 'T1!', 'T0!'], 'array literal parser handles descending generated ranges' );
is_deeply( Developer::Dashboard::Pax::CodeUnitCompiler::_parse_use_args("qw(one two)"), ['one', 'two'], 'use argument parser handles qw parentheses' );
is_deeply( Developer::Dashboard::Pax::CodeUnitCompiler::_parse_use_args("qw/one two/"), ['one', 'two'], 'use argument parser handles qw slashes' );
is_deeply( Developer::Dashboard::Pax::CodeUnitCompiler::_parse_use_args("'one', key => 2, \"three\""), ['one', 'key', 2, 'three'], 'use argument parser handles quoted and bare arguments' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_parse_use_args('one !'), undef, 'use argument parser rejects unsupported punctuation' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_prefer_source_fallback_over_hybrid('source', [], [map { "sub$_" } 1 .. 8]), 1, 'hybrid policy falls back when no subroutine is supported' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_prefer_source_fallback_over_hybrid(('x' x 8192), [1], [1 .. 8]), 1, 'hybrid policy falls back for oversized low-coverage source' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_prefer_source_fallback_over_hybrid('source', [1 .. 8], [1 .. 7]), 0, 'hybrid policy retains sufficiently covered source' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_hybrid_coverage_detail([1, 2], [3]), 'supported=2 unsupported=1', 'hybrid coverage detail reports supported and unsupported counts' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_normalize_lib_path('../lib', '/tmp/bin'), '/tmp/bin/../lib', 'relative parent library path resolves from entrypoint directory' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_normalize_lib_path('lib', '/tmp/bin'), File::Spec->rel2abs('lib', '.'), 'relative library path resolves from current directory' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_normalize_lib_path('', '/tmp/bin'), '', 'empty library paths remain empty' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_native_i64_sum_loop_shape('my ($n) = @_; my $sum = 0; for (my $i = 1; $i <= $n; $i++) { $sum += $i; } return $sum;')->{kind}, 'i64_sum_loop', 'native source recognizer identifies the integer sum loop' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_native_i64_masked_mix_accum_loop_shape('my ($n) = @_; my $sum = 0; for (my $i = 0; $i < $n; $i++) { $sum += (($i * 13) ^ ($i >> 3)) & 0xFFFF; } return $sum;')->{kind}, 'i64_masked_mix_accum_loop', 'native source recognizer identifies masked-mix accumulator loop' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_native_shape_from_source_body('my ($n) = @_; my $sum = 0; for (my $i = 1; $i <= $n; $i++) { $sum += $i; } return $sum;')->{kind}, 'i64_sum_loop', 'native shape dispatcher selects the sum-loop recognizer' );

my $hybrid = Developer::Dashboard::Pax::CodeUnitCompiler::_hybrid_compiled_unit(
    $module_path, 'lib', 'lib/Native.pm', 'Test::Native', [], [], ['Test::Native::other'],
    "package Test::Native;\nmy \$shared = 1;\nsub other { return \$shared; }\n",
);
is( $hybrid->{packaging}, 'hybrid_compiled_pcu_v1', 'hybrid unit contains unsupported source routines' );
is( $hybrid->{hybrid}, JSON::XS::true, 'hybrid unit marks itself as hybrid' );
is( Developer::Dashboard::Pax::CodeUnitCompiler::_require_path_for('ignored', 'Test::Nested::Native'), 'Test/Nested/Native.pm', 'require path maps package separators to path separators' );
ok( Developer::Dashboard::Pax::CodeUnitCompiler::_capture_timeout_supported(), 'capture timeout support is detected on this Perl runtime' );
my $live_capture = Developer::Dashboard::Pax::CodeUnitCompiler::_capture_live_unit($module_path);
is( $live_capture->{status}, 'ok', 'live capture wrapper returns the capture module result' );
{
    local $ENV{PAX_CODE_UNIT_CAPTURE_TIMEOUT} = 0;
    my $unlimited = Developer::Dashboard::Pax::CodeUnitCompiler::_capture_with_timeout($module_path, 'lib');
    is( $unlimited->{status}, 'ok', 'zero timeout delegates directly to the live capture' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::CodeUnitCompiler::_capture_live_unit = sub { CORE::sleep 2; return { status => 'too_late' }; };
    local $ENV{PAX_CODE_UNIT_CAPTURE_TIMEOUT} = 1;
    my $timed_out = Developer::Dashboard::Pax::CodeUnitCompiler::_capture_with_timeout($module_path, 'lib');
    is( $timed_out->{status}, 'capture_timeout', 'capture alarm returns a timeout result instead of a late capture' );
    like( $timed_out->{error}, qr/capture timeout/, 'timeout result preserves its diagnostic' );
}

done_testing();

sub _write {
    # Write deterministic source text for one compiler fixture.
    # Inputs are the destination path and source bytes; output is true after close.
    my ( $path, $source ) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $source or die "cannot write $path: $!";
    close $fh or die "cannot close $path: $!";
    return 1;
}

__END__

=pod

=head1 NAME

t/236-pax-codeunitcompiler-source-contract.t - compiler matcher source contract test

=head1 PURPOSE

This test feeds repository Perl modules through the source-pattern recognizers
in C<Developer::Dashboard::Pax::CodeUnitCompiler>, checks transformation
identity, and verifies public entrypoint/module compilation paths with isolated
temporary sources.

=head1 WHY IT EXISTS

The compiler contains many source-specific transformation rules. Exercising
only the final PAX build subprocess does not instrument those rules in the test
process, leaving matcher regressions and large coverage gaps invisible. This
test invokes pure source recognizers against the real library and uses fixture
capture metadata so module compilation does not launch another process.

=head1 WHEN TO USE

Run after changing PAX source recognition, declared-sub discovery, or transform
descriptor fields. Update the focused expectations if a deliberate compiler
contract changes.

=head1 HOW TO USE

Run from the repository root in the development Docker service. The test scans
Perl modules under C<lib> and creates temporary source fixtures under the
system temporary directory. It checks emitted descriptors and compiler output
metadata; repository sources are read-only.

=head1 WHAT USES IT

The standalone PAX compiler uses these matchers to turn supported Perl source
into code-unit operations. The test suite uses this contract check to exercise
recognizers in-process, under coverage instrumentation.

=head1 EXAMPLES

Example 1:

  prove -lv t/236-pax-codeunitcompiler-source-contract.t

Run the focused repository-source matcher check.

Example 2:

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lv t/236-pax-codeunitcompiler-source-contract.t

Measure the recognizer coverage contribution while running in the development
container.

=cut
