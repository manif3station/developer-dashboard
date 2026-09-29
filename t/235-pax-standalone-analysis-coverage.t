#!/usr/bin/env perl

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use JSON::XS ();

use lib 'lib';

use Developer::Dashboard::Pax::StandaloneAnalysis;

my $root = tempdir( CLEANUP => 1 );
my $lib = File::Spec->catdir( $root, 'lib' );
my $app = File::Spec->catdir( $root, 'app' );
make_path( $lib, $app );
my $entrypoint = File::Spec->catfile( $app, 'main.pl' );
my $local_module = File::Spec->catfile( $lib, 'App', 'Local.pm' );
my $nested_module = File::Spec->catfile( $lib, 'Foo', 'Nested.pm' );
my $pure_module = File::Spec->catfile( $lib, 'Pure.pm' );
my $xs_module = File::Spec->catfile( $lib, 'WithXS.pm' );
make_path( File::Spec->catdir( $lib, 'App' ), File::Spec->catdir( $lib, 'Foo' ) );
_write( $entrypoint, "use App::Local;\nuse App::Local;\nuse strict;\nuse WithXS;\nrequire Foo::Nested;\nrequire lib;\n" );
_write( $local_module, "package App::Local;\nuse Pure;\n1;\n" );
_write( $nested_module, "package Foo::Nested; 1;\n" );
_write( $pure_module, "package Pure; 1;\n" );
_write( $xs_module, "package WithXS; use XSLoader; 1;\n" );
my $cpanfile = File::Spec->catfile( $root, 'cpanfile' );
_write( $cpanfile, "requires 'Foo::Nested';\nrecommends \"Missing::Module\";\nrequires 'bad-name!';\n" );

my $analysis = Developer::Dashboard::Pax::StandaloneAnalysis->new( ignored => 1 );
isa_ok( $analysis, 'Developer::Dashboard::Pax::StandaloneAnalysis' );

my $missing_entrypoint = eval { $analysis->dependencies(); 1 };
ok( !$missing_entrypoint, 'dependency analysis requires an entrypoint' );
like( $@, qr/entrypoint required/, 'missing entrypoint reports the argument requirement' );
my $defaulted_dependencies = $analysis->dependencies( entrypoint => $entrypoint );
is_deeply( $defaulted_dependencies, { items => [], summary => {
    packaged_app => 0,
    compiled_dependency => 0,
    bundled_pure_perl => 0,
    bundled_xs => 0,
    missing => 0,
    unsupported => 0,
} }, 'dependency analysis defaults omitted code units and cpanfiles to empty collections' );
is( Developer::Dashboard::Pax::StandaloneAnalysis::_analysis_source(undef), '', 'source analysis accepts undefined source as empty text' );
ok( !Developer::Dashboard::Pax::StandaloneAnalysis::_is_dependency_candidate('A'), 'single-character package names are not dependency candidates' );
ok( !Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path(undef), 'undefined module paths have no package name' );
is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path('/tmp/project/lib/.pm'), '', 'empty package names fall through after a terminal lib segment' );

my $dependency_result;
{
    local @INC = ( $lib, @INC );
    $dependency_result = $analysis->dependencies(
        entrypoint => $entrypoint,
        code_units => [
            { unit_kind => 'entrypoint', source_path => $entrypoint },
            { unit_kind => 'lib', source_path => $local_module, packaging => 'compiled_pcu_v1' },
            { unit_kind => 'dependency', source_path => $nested_module, packaging => 'compiled_pcu_v1' },
            {},
            { unit_kind => 'lib', source_path => File::Spec->catfile( $root, 'lib', 'NoExtension' ) },
        ],
        cpanfiles => [ $cpanfile, File::Spec->catfile( $root, 'missing-cpanfile' ) ],
    );
}
my %dependency = map { $_->{module} => $_ } @{ $dependency_result->{items} };
is( $dependency{ 'App::Local' }{class}, 'packaged_app', 'classifies an application library unit as packaged app code' );
is( $dependency{ 'Foo::Nested' }{class}, 'compiled_dependency', 'classifies a packaged dependency unit as compiler-provided' );
is( $dependency{Pure}{class}, 'bundled_pure_perl', 'dependency closure scans source for bundled child modules' );
ok( $dependency{ 'Missing::Module' }{class} eq 'missing', 'reports declared but unavailable modules as missing' );
is_deeply(
    $dependency{ 'Foo::Nested' }{declared_in_cpanfile},
    [ { type => 'requires', path => $cpanfile } ],
    'cpanfile requirements retain their source path and declaration type',
);
ok( !exists $dependency{strict} && !exists $dependency{lib}, 'core pragmas are excluded from dependency candidates' );
is( $dependency_result->{summary}{packaged_app}, 1, 'dependency summary counts packaged app libraries' );
is( $dependency_result->{summary}{compiled_dependency}, 1, 'dependency summary counts compiler dependencies' );
is( $dependency_result->{summary}{bundled_xs}, 1, 'dependency summary counts modules using XS' );
is( $dependency_result->{summary}{bundled_pure_perl}, 1, 'dependency summary counts bundled pure Perl modules' );
is( $dependency_result->{summary}{missing}, 1, 'dependency summary counts unresolved declarations' );

is( Developer::Dashboard::Pax::StandaloneAnalysis::_analysis_source("use Foo;\n__DATA__\nnot perl\n"), "use Foo;\n", 'source analysis strips a DATA section' );
is( Developer::Dashboard::Pax::StandaloneAnalysis::_analysis_source("use Foo;\n=head1 PRIVATE\nnot perl\n=cut\nuse Bar;\n"), "use Foo;\nuse Bar;\n", 'source analysis strips POD while retaining later code' );
is_deeply(
    [ Developer::Dashboard::Pax::StandaloneAnalysis::_source_module_refs("use strict; use Foo::Bar;\nrequire Baz::Qux;\nuse Foo::Bar;\nuse warnings;\n") ],
    [ 'Foo::Bar', 'Baz::Qux' ],
    'source references exclude core modules and return distinct use/require dependencies in encounter order',
);
is_deeply(
    [ Developer::Dashboard::Pax::StandaloneAnalysis::_source_module_refs("use lowercase::Module;\nuse strict;\nrequire lib;\n") ],
    [ 'lowercase::Module' ],
    'source reference parsing supports lowercase package names and filters lowercase core modules',
);
is_deeply(
    [ Developer::Dashboard::Pax::StandaloneAnalysis::_source_module_refs("use strict;\nrequire lib;\n") ],
    [],
    'source reference parsing rejects core modules from both use and require declarations',
);
ok( !Developer::Dashboard::Pax::StandaloneAnalysis::_is_dependency_candidate('x'), 'single-character package names are not dependency candidates' );
ok( !Developer::Dashboard::Pax::StandaloneAnalysis::_is_dependency_candidate(undef), 'undefined package names are not dependency candidates' );
ok( !Developer::Dashboard::Pax::StandaloneAnalysis::_is_dependency_candidate('base'), 'core base pragma is not a dependency candidate' );
ok( Developer::Dashboard::Pax::StandaloneAnalysis::_is_dependency_candidate('A::Module'), 'ordinary package names are dependency candidates' );

{
    local @INC = ( $lib, @INC );
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path($nested_module), 'Foo::Nested', 'module path under @INC maps to a Perl package name' );
    {
        local @INC = ( sub { }, $lib );
        is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path($nested_module), 'Foo::Nested', 'module path conversion skips reference entries in @INC' );
    }
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path('/tmp/project/lib/Other/Unit.pm'), 'Other::Unit', 'module path falls back to its lib-relative name outside @INC' );
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path('/tmp/project/Single.pm'), 'Single', 'module path falls back to its basename when no lib segment exists' );
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path('/tmp/project/Single.pl'), undef, 'non-module source paths have no package name' );
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path('/tmp/missing/Single.pm'), 'Single', 'unresolvable absolute module paths fall back to their filename' );
    {
        local @INC = ( '/tmp/missing-root' );
        is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path('/tmp/missing-root/Foo.pm'), 'Foo', 'module-name lookup uses unresolved include roots as textual path prefixes' );
    }
    {
        no warnings 'redefine';
        local @INC = ( '/missing-include-root' );
        local *Developer::Dashboard::Pax::StandaloneAnalysis::abs_path = sub { return undef };
        is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path('/elsewhere/lib/Foo.pm'), 'Foo', 'module-name lookup falls back to input paths when absolute resolution fails' );
    }
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_locate_module('Foo::Nested'), abs_path($nested_module), 'module lookup returns a resolved @INC path' );
    {
        no warnings 'redefine';
        local @INC = ('lib');
        local *Developer::Dashboard::Pax::StandaloneAnalysis::abs_path = sub { return undef };
        my $original_cwd = Cwd::getcwd();
        chdir $root or die "cannot chdir to fixture root: $!";
        is( Developer::Dashboard::Pax::StandaloneAnalysis::_locate_module('Foo::Nested'), File::Spec->catfile('lib', 'Foo', 'Nested.pm'), 'module lookup retains a relative candidate when absolute resolution fails' );
        chdir $original_cwd or die "cannot restore working directory: $!";
    }
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_locate_module('Missing::Module'), undef, 'module lookup returns undef when no @INC path exists' );
    {
        local @INC = ( sub { }, '/tmp/missing-include', $lib );
        is( Developer::Dashboard::Pax::StandaloneAnalysis::_locate_module('Foo::Nested'), abs_path($nested_module), 'module lookup skips reference and missing @INC roots before finding a module' );
    }
    ok( Developer::Dashboard::Pax::StandaloneAnalysis::_module_uses_xs($xs_module), 'module analysis detects XS loader use in source' );
    ok( !Developer::Dashboard::Pax::StandaloneAnalysis::_module_uses_xs($pure_module), 'module analysis recognizes pure Perl source' );
    my $shared_object = File::Spec->catfile( $lib, 'Native' );
    _write( "$shared_object.so", '' );
    _write( "$shared_object.pm", 'package Native; 1;' );
    ok( Developer::Dashboard::Pax::StandaloneAnalysis::_module_uses_xs("$shared_object.pm"), 'module analysis detects a sibling shared object' );
}
{
    local @INC = ( '/tmp/project' );
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_module_name_from_path('/tmp/project/.pm'), '', 'module name conversion handles an empty relative package name' );
}
is( Developer::Dashboard::Pax::StandaloneAnalysis::_slurp( File::Spec->catfile( $root, 'missing' ) ), '', 'source reader returns an empty string when a file is unavailable' );
my @slurp_warnings;
{
    local $SIG{__WARN__} = sub { push @slurp_warnings, @_ };
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_slurp(undef), '', 'source reader returns empty text for an undefined path' );
}
is_deeply( \@slurp_warnings, [], 'undefined source paths do not emit warnings' );
my $empty_source = File::Spec->catfile( $root, 'empty-source' );
_write( $empty_source, '' );
is( Developer::Dashboard::Pax::StandaloneAnalysis::_slurp($empty_source), '', 'source reader returns empty text for an empty file' );
is( Developer::Dashboard::Pax::StandaloneAnalysis::_slurp(''), '', 'source reader returns empty text for an empty path' );
my @directory_warnings;
{
    local $SIG{__WARN__} = sub { push @directory_warnings, @_ };
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_slurp($root), '', 'source reader treats a readable directory as empty input' );
}
is_deeply( \@directory_warnings, [], 'directory input does not emit Perl warnings' );

my $static_artifacts;
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Tier1::new = sub { return bless {}, $_[0] };
    local *Developer::Dashboard::Pax::Tier1::compile = sub {
        my ( $self, $unit ) = @_;
        return $unit->{native_shape}{test_ready}
          ? { status => 'compiled', entry_kind => 'native_i64_leaf', reason => 'ok', executable_path => '/tmp/native', library_path => '/tmp/native.so', tier2_artifact => undef }
          : $unit->{native_shape}{test_missing_path}
          ? { status => 'compiled', entry_kind => 'native_i64_loop', reason => 'missing path', tier2_artifact => undef }
          : $unit->{native_shape}{test_missing_kind}
          ? {}
          : { status => 'fallback', entry_kind => 'perl_fallback', reason => 'unsupported', tier2_artifact => undef };
    };
    my $record = JSON::XS::encode_json({
        package => 'App::Math',
        subs => [
            { name => 'sum', native_shape => { kind => 'i64_binary_leaf', test_ready => JSON::XS::true() } },
            { full_name => 'App::Math::other', native_shape => { kind => 'i64_binary_leaf' } },
            { native_shape => { kind => 'i64_binary_leaf' } },
            { name => 'empty_shape', native_shape => {} },
            'not a sub record',
        ],
        compiled_subs => [
            { name => 'compiled', native_shape => { kind => 'i64_binary_leaf' } },
            { name => 'native_without_path', native_shape => { kind => 'i64_loop', test_missing_path => JSON::XS::true() } },
            { name => 'missing_metadata', native_shape => { kind => 'i64_loop', test_missing_kind => JSON::XS::true() } },
        ],
    });
    $static_artifacts = $analysis->native_artifacts(
        entrypoint => $entrypoint,
        code_units => [
            { bytes => $record },
            {},
            { bytes => '' },
            { bytes => 'not json' },
            { bytes => JSON::XS::encode_json([]) },
            { bytes => JSON::XS::encode_json({}) },
            { bytes => JSON::XS::encode_json({ subs => [ { name => 'empty' } ] }) },
            { bytes => JSON::XS::encode_json({ subs => [ { name => 'main_default', native_shape => { kind => 'i64_leaf' } } ] }) },
            'not a code unit',
        ],
    );
}
is( $static_artifacts->{summary}{total}, 6, 'static native extraction combines sub and compiled_sub records and skips malformed inputs' );
is( $static_artifacts->{summary}{native_ready}, 1, 'static native summary counts compiled executable artifacts' );
is( $static_artifacts->{summary}{fallback_only}, 5, 'static native summary counts artifacts missing native metadata or an executable' );
ok( !defined $static_artifacts->{items}[-2]{entry_kind}, 'an artifact without tier metadata remains an explicit fallback item' );
is( $static_artifacts->{items}[-1]{region_name}, 'main::main_default', 'static extraction uses the main package when metadata omits a package name' );
is_deeply(
    [ map { $_->{region_name} } @{ $static_artifacts->{items} } ],
    [ 'App::Math::sum', 'App::Math::other', 'App::Math::compiled', 'App::Math::native_without_path', 'App::Math::missing_metadata', 'main::main_default' ],
    'static extraction handles full-name, package-qualified, default-package, and nameless metadata paths',
);
ok( $static_artifacts->{items}[0]{executable_path}, 'native-ready result retains its executable and library paths' );
is_deeply(
    [ sort keys %{ $static_artifacts->{items}[0]{guards}[0] } ],
    [ sort qw(compatibility_classification id invalidation_key predicate) ],
    'static native metadata receives the default guard records',
);
is_deeply(
    $static_artifacts->{runtime_epochs},
    { package_symbols => 1, method_resolution => 1, loaded_modules => 1 },
    'static native metadata receives the default runtime epoch set',
);

ok( Developer::Dashboard::Pax::StandaloneAnalysis::_native_probe_worthwhile([undef]) == 0, 'native source probe skips an undefined candidate path' );
ok( Developer::Dashboard::Pax::StandaloneAnalysis::_native_probe_worthwhile([$entrypoint]) == 0, 'native source probe rejects code without a supported shape' );
ok( Developer::Dashboard::Pax::StandaloneAnalysis::_native_probe_worthwhile([ File::Spec->catfile( $root, 'missing' ) ]) == 0, 'native source probe skips missing paths' );
ok( !Developer::Dashboard::Pax::StandaloneAnalysis::_native_probe_worthwhile([$empty_source]), 'native source probe skips an empty source file' );
ok( Developer::Dashboard::Pax::StandaloneAnalysis::_source_has_native_candidate('sub leaf { my ($a, $b) = @_; return $a * $b; }'), 'native source matcher accepts a binary leaf' );
ok( Developer::Dashboard::Pax::StandaloneAnalysis::_source_has_native_candidate('sub loop { my $sum = 0; for (my $i=0; $i<10; $i++) { $sum += $i } }'), 'native source matcher accepts an accumulating for loop' );
ok( Developer::Dashboard::Pax::StandaloneAnalysis::_source_has_native_candidate('sub loop { my $sum = 0; my $one = 1; while ($sum < 10) { $sum += $one } }'), 'native source matcher accepts an accumulating while loop' );

my $no_native = $analysis->native_artifacts( entrypoint => $entrypoint, code_units => [] );
is_deeply( $no_native, { items => [], summary => { native_ready => 0, fallback_only => 0, total => 0 }, runtime_epochs => undef }, 'live native analysis skips a source tree with no supported candidate' );
my $defaulted_native = $analysis->native_artifacts( entrypoint => $entrypoint );
is_deeply( $defaulted_native, $no_native, 'native analysis defaults omitted code units to an empty collection' );
my $missing_native_entrypoint = eval { $analysis->native_artifacts(); 1 };
ok( !$missing_native_entrypoint, 'native analysis requires an entrypoint' );
like( $@, qr/entrypoint required/, 'native analysis reports a missing entrypoint' );
is_deeply(
    [ Developer::Dashboard::Pax::StandaloneAnalysis::_native_probe_paths( $entrypoint, [ { source_path => $entrypoint }, { source_path => undef } ] ) ],
    [ $entrypoint ],
    'native probe path collection removes duplicate paths and undefined candidates',
);
{
    local @INC = ( sub { }, '/tmp/missing-include', $lib );
    is( Developer::Dashboard::Pax::StandaloneAnalysis::_locate_module('Foo::Nested'), abs_path($nested_module), 'module lookup ignores reference and absent include roots' );
}
{
    local @INC = ( $lib );
    Developer::Dashboard::Pax::StandaloneAnalysis::_expand_dependency_closure( {}, [ undef, '', 'Missing::Standalone' ], {} );
    my %existing = ( 'Pure' => { used_in_code => 1 } );
    Developer::Dashboard::Pax::StandaloneAnalysis::_expand_dependency_closure(
        \%existing,
        [ 'App::Local', 'App::Local' ],
        { 'App::Local' => { source_path => $local_module } },
    );
    ok( $existing{Pure}{used_in_code}, 'dependency closure tolerates empty seeds, missing paths, and repeated child references' );
    my $shared_source = File::Spec->catfile( $lib, 'Shared.pm' );
    _write( $shared_source, "package Shared;\n" );
    Developer::Dashboard::Pax::StandaloneAnalysis::_expand_dependency_closure(
        {},
        [ 'Alias::One', 'Alias::Two' ],
        { 'Alias::One' => { source_path => $shared_source }, 'Alias::Two' => { source_path => $shared_source } },
    );
    my %cycles;
    my $cycle_a = File::Spec->catfile( $lib, 'CycleA.pm' );
    my $cycle_b = File::Spec->catfile( $lib, 'CycleB.pm' );
    _write( $cycle_a, "use CycleB;\n" );
    _write( $cycle_b, "use CycleA;\n" );
    Developer::Dashboard::Pax::StandaloneAnalysis::_expand_dependency_closure( \%cycles, [ 'CycleA' ], {} );
    ok( $cycles{CycleA}{used_in_code} && $cycles{CycleB}{used_in_code}, 'dependency closure terminates safely on a cyclic module graph' );
}

_write( $entrypoint, 'sub leaf { my ($a, $b) = @_; return $a + $b; }' );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::new = sub { return bless {}, 'Test::StandaloneAnalysis::Capture' };
    local *Test::StandaloneAnalysis::Capture::capture = sub { die "capture fixture failure\n" };
    my $failed = $analysis->native_artifacts( entrypoint => $entrypoint, code_units => [] );
    is( $failed->{diagnostics}[0]{code}, 'native_capture_failed', 'live-capture exceptions become explicit native-capture diagnostics' );
    like( $failed->{diagnostics}[0]{message}, qr/capture fixture failure/, 'capture failure details are retained' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::new = sub { return bless {}, 'Test::StandaloneAnalysis::Capture' };
    local *Test::StandaloneAnalysis::Capture::capture = sub { return undef };
    my $missing = $analysis->native_artifacts( entrypoint => $entrypoint, code_units => [] );
    is( $missing->{diagnostics}[0]{code}, 'native_capture_failed', 'an absent capture result reports a capture diagnostic' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::new = sub { return bless {}, 'Test::StandaloneAnalysis::Capture' };
    local *Test::StandaloneAnalysis::Capture::capture = sub { return { status => 'failed' } };
    my $failed = $analysis->native_artifacts( entrypoint => $entrypoint, code_units => [] );
    is_deeply( $failed, { items => [], summary => { native_ready => 0, fallback_only => 0, total => 0 } }, 'non-ok capture status returns an empty native result without analysis diagnostics' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::new = sub { return bless {}, 'Test::StandaloneAnalysis::Capture' };
    local *Test::StandaloneAnalysis::Capture::capture = sub { return { status => 'ok', payload => 'captured' } };
    local *Developer::Dashboard::Pax::Manifest::new = sub { die "analysis fixture failure\n" };
    my $failed = $analysis->native_artifacts( entrypoint => $entrypoint, code_units => [] );
    is( $failed->{diagnostics}[0]{code}, 'native_analysis_failed', 'native lowering exceptions become explicit analysis diagnostics' );
    like( $failed->{diagnostics}[0]{message}, qr/analysis fixture failure/, 'native analysis failure details are retained' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::new = sub { return bless {}, 'Test::StandaloneAnalysis::Capture' };
    local *Developer::Dashboard::Pax::Manifest::new = sub { return bless {}, 'Test::StandaloneAnalysis::Manifest' };
    local *Developer::Dashboard::Pax::RegionSelector::new = sub { return bless {}, 'Test::StandaloneAnalysis::Regions' };
    local *Developer::Dashboard::Pax::HIR::new = sub { return bless {}, 'Test::StandaloneAnalysis::HIR' };
    local *Developer::Dashboard::Pax::GuardedSSA::new = sub { return bless {}, 'Test::StandaloneAnalysis::SSA' };
    local *Developer::Dashboard::Pax::Tier1::new = sub { return bless {}, $_[0] };
    local *Developer::Dashboard::Pax::Tier1::compile = sub {
        return { status => 'compiled', entry_kind => 'native_i64_leaf', reason => 'ok', executable_path => '/tmp/live-native', library_path => '/tmp/live-native.so' };
    };
    my $live = $analysis->native_artifacts( entrypoint => $entrypoint, code_units => [] );
    is( $live->{summary}{native_ready}, 1, 'successful live capture and lowering produces a native-ready artifact' );
    is_deeply( $live->{runtime_epochs}, { loaded_modules => 7 }, 'live native artifacts preserve manifest runtime epochs' );
    is( $live->{items}[0]{region_name}, 'live', 'live native artifacts preserve region metadata' );
}

done_testing();

sub _write {
    # Create one fixture file and ensure its bytes are fully written.
    # Inputs are a file path and content string; output is true after close.
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content or die "cannot write $path: $!";
    close $fh or die "cannot close $path: $!";
    return 1;
}

sub Test::StandaloneAnalysis::Capture::capture { return { status => 'ok' } }
sub Test::StandaloneAnalysis::Manifest::to_hash { return { runtime_epochs => { loaded_modules => 7 } } }
sub Test::StandaloneAnalysis::Regions::select { return { selected => [ { region_id => 'live-region' } ] } }
sub Test::StandaloneAnalysis::HIR::lower_all { return [ { region_id => 'live-region' } ] }
sub Test::StandaloneAnalysis::SSA::build_all { return [ { region_id => 'live-region', region_name => 'live', guards => undef, deopt => undef } ] }

__END__

=pod

=head1 NAME

t/235-pax-standalone-analysis-coverage.t - standalone analysis coverage tests

=head1 PURPOSE

This test exercises dependency discovery, source parsing, packaged and bundled
module classification, static native-shape extraction, and live native-analysis
outcomes in C<Developer::Dashboard::Pax::StandaloneAnalysis>.

=head1 WHY IT EXISTS

Standalone analysis decides what modules and native payloads ship inside a
compiled application. Its result controls both runtime completeness and which
native regions are eligible for the guarded execution pipeline, so malformed
source, unavailable modules, and failed capture/lowering need explicit tests.

=head1 WHEN TO USE

Run this test when changing dependency closure, cpanfile parsing, module path
resolution, XS detection, native-candidate recognition, or artifact summaries.

=head1 HOW TO USE

Run from the repository root in the development Docker service. The test creates
a temporary application and library tree, injects isolated runtime collaborators,
and makes no network calls or changes to installed modules.

=head1 WHAT USES IT

The PAX build pipeline uses this module to classify dependencies and prepare
native artifacts for standalone application images. The unit suite uses this
test to pin each analysis result and failure shape.

=head1 EXAMPLES

Example 1:

  prove -lv t/235-pax-standalone-analysis-coverage.t

Run the focused standalone analysis tests.

Example 2:

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lv t/235-pax-standalone-analysis-coverage.t

Measure the test's coverage contribution while iterating in the development
container.

=cut
