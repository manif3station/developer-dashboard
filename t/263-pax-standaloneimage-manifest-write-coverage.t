#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use Cwd qw(abs_path);
use JSON::XS ();
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneImage ();

my $root = tempdir( CLEANUP => 1 );
my $nested_manifest = File::Spec->catfile( $root, 'new', 'manifest.json' );
Developer::Dashboard::Pax::StandaloneImage::_write_json(
    $nested_manifest,
    { app => { name => 'fixture' }, code_units => [ { logical_path => 'Fixture.pm', bytes => "\x00\xFF" } ] },
);
ok( -f $nested_manifest, 'manifest writer creates its parent directory and output file' );
open my $nested_fh, '<', $nested_manifest or die "Unable to read $nested_manifest: $!";
local $/;
my $nested_data = JSON::XS->new->decode(<$nested_fh>);
close $nested_fh or die "Unable to close $nested_manifest: $!";
is( $nested_data->{app}{name}, 'fixture', 'manifest writer serializes structured metadata as JSON' );
ok( !exists $nested_data->{code_units}[0]{bytes}, 'manifest writer removes binary payload fields before serialization' );

my $existing_dir = File::Spec->catdir( $root, 'existing' );
make_path($existing_dir);
my $existing_manifest = File::Spec->catfile( $existing_dir, 'manifest.json' );
Developer::Dashboard::Pax::StandaloneImage::_write_json( $existing_manifest, { version => 1 } );
open my $existing_fh, '<', $existing_manifest or die "Unable to read $existing_manifest: $!";
my $existing_data = JSON::XS->new->decode(<$existing_fh>);
close $existing_fh or die "Unable to close $existing_manifest: $!";
is( $existing_data->{version}, 1, 'manifest writer uses an existing output directory without replacing it' );

is( Developer::Dashboard::Pax::StandaloneImage::_default_name('/src/My app.pl'), 'My-app', 'default image name is a filesystem-safe entrypoint basename' );
is( Developer::Dashboard::Pax::StandaloneImage::_entrypoint_default_command('/src/start-here.pl'), 'start-here', 'default command derives from the entrypoint basename' );
my $metadata = Developer::Dashboard::Pax::StandaloneImage::_app_metadata(
    entrypoint => '/src/start-here.pl',
    app_namespace => ' Example::App ',
);
is( $metadata->{name}, 'pax-standalone', 'application metadata defaults its name when no image name is supplied' );
is( $metadata->{compat}{namespace}, 'Example::App', 'application metadata normalizes its compatibility namespace' );
is( $metadata->{compat}{legacy_namespace}, 'Example::App', 'legacy namespace defaults to the normalized application namespace' );
is( $metadata->{entrypoint_command}, 'start-here', 'application metadata defaults the entrypoint command consistently' );
is( Developer::Dashboard::Pax::StandaloneImage::_infer_app_namespace(
    units => [ { package => 'Example::App::One' }, { package => 'Example::App::Two' }, { package => 'Other::Module' } ],
), 'Example::App', 'namespace inference selects the strongest shared package prefix' );
is( Developer::Dashboard::Pax::StandaloneImage::_infer_app_namespace( units => [ { package => 'Single' } ] ), '', 'namespace inference returns empty when no package has a namespace' );
is( Developer::Dashboard::Pax::StandaloneImage::_safe_dir_abs(''), '', 'safe directory resolution preserves the empty-path sentinel' );
is( Developer::Dashboard::Pax::StandaloneImage::_safe_dir_abs($nested_manifest), dirname($nested_manifest), 'safe directory resolution returns the absolute parent directory' );
is( Developer::Dashboard::Pax::StandaloneImage::_absolute_output($nested_manifest), $nested_manifest, 'absolute output paths are preserved' );
is( Developer::Dashboard::Pax::StandaloneImage::_absolute_output('relative-output'), File::Spec->rel2abs('relative-output'), 'relative output paths resolve against the current directory' );
my ( @existing_paths, $path_warnings );
{
    local $SIG{__WARN__} = sub { $path_warnings .= join '', @_ };
    @existing_paths = Developer::Dashboard::Pax::StandaloneImage::_abs_existing(
        [ $root, undef, File::Spec->catdir( $root, 'missing' ), $root ],
    );
}
is_deeply( \@existing_paths, [$root], 'existing path resolution drops absent paths and deduplicates canonical directories' );
is( $path_warnings // '', '', 'existing path resolution rejects undefined inputs without warnings' );

my $bin_dir = File::Spec->catdir( $root, 'bin' );
my $lib_dir = File::Spec->catdir( $root, 'lib' );
make_path( $bin_dir, $lib_dir );
my $entrypoint = File::Spec->catfile( $bin_dir, 'entry.pl' );
open my $entry_fh, '>', $entrypoint or die "Unable to write $entrypoint: $!";
print {$entry_fh} "use lib '\$Bin/../lib';\nuse lib 'missing-lib';\n";
close $entry_fh or die "Unable to close $entrypoint: $!";
is_deeply(
    [ Developer::Dashboard::Pax::StandaloneImage::_entrypoint_declared_lib_dirs($entrypoint) ],
    [ File::Spec->catdir( $bin_dir, '..', 'lib' ) ],
    'entrypoint lib scanning expands $Bin and keeps only existing directories',
);
is( Developer::Dashboard::Pax::StandaloneImage::_logical_root('lib', File::Spec->catdir( $root, 'Foo', 'Bar' )), 'lib/Bar', 'logical roots use the source directory basename under their prefix' );
is( Developer::Dashboard::Pax::StandaloneImage::_progress_source_label('unit', 'nested/Thing.pm'), 'unit:nested/Thing.pm', 'progress labels preserve nested logical source names' );

my $payload = Developer::Dashboard::Pax::StandaloneImage::_file_payload_bytes( $entrypoint, 'code', 'bin/entry.pl', 'payload' );
is( $payload->{size}, 7, 'file payload metadata records byte length' );
is( $payload->{sha256}, sha256_hex('payload'), 'file payload metadata records the byte digest' );
is( Developer::Dashboard::Pax::StandaloneImage::_payload_bytes([ $payload, { size => 5 } ]), 12, 'payload size aggregation sums all payload entries' );
is(
    Developer::Dashboard::Pax::StandaloneImage::_source_hash( [ $payload ], [], [], [] ),
    Developer::Dashboard::Pax::StandaloneImage::_source_hash( [ $payload ], [], [], [] ),
    'source fingerprinting is stable for an unchanged payload set',
);
is( Developer::Dashboard::Pax::StandaloneImage::_pax_launcher_build_dir_name( uid => 123 ), '.pax-launcher-build-123', 'launcher build cache name is scoped to the supplied uid' );
is( Developer::Dashboard::Pax::StandaloneImage::_manifest_fast_version({ entrypoint => { logical_path => 'main.pl' }, code_units => [ { logical_path => 'other.pl', bytes => '{"version":"wrong"}' }, { logical_path => 'main.pl', bytes => '{"version":"5.18"}' } ] }), '5.18', 'manifest version lookup selects the entrypoint unit record' );
is( Developer::Dashboard::Pax::StandaloneImage::_manifest_fast_version({ entrypoint => { logical_path => 'main.pl' }, code_units => [ { logical_path => 'main.pl', bytes => 'not-json' } ] }), undef, 'manifest version lookup safely skips malformed entrypoint records' );
is( Developer::Dashboard::Pax::StandaloneImage::_payload_package_blob([]), "PAXP\n0\n\n", 'empty payload packages retain the canonical header and separator' );
is( Developer::Dashboard::Pax::StandaloneImage::_payload_package_blob([{ logical_path => 'lib/Foo.pm', size => 3, bytes => 'abc' }]), "PAXP\n1\nlib/Foo.pm\t3\n\nabc", 'payload packages concatenate metadata headers and raw payload bytes' );
like( Developer::Dashboard::Pax::StandaloneImage::_string_array_c('fixture', []), qr/fixture_count = 0/, 'empty C string arrays emit a zero count declaration' );
like( Developer::Dashboard::Pax::StandaloneImage::_string_array_c('fixture', ['alpha', 'two"lines']), qr/fixture_count = 2.*"alpha".*"two\\\"lines"/s, 'C string arrays quote and escape every item' );

my $native_dir = File::Spec->catdir( $root, 'native' );
make_path($native_dir);
my $native_executable = File::Spec->catfile( $native_dir, 'probe' );
my $native_library = File::Spec->catfile( $native_dir, 'library.so' );
my $native_ir = File::Spec->catfile( $native_dir, 'module.ll' );
for my $native_file ( [$native_executable, 'binary'], [$native_library, 'shared'], [$native_ir, 'llvm'] ) {
    open my $native_fh, '>', $native_file->[0] or die "Unable to write $native_file->[0]: $!";
    print {$native_fh} $native_file->[1];
    close $native_fh or die "Unable to close $native_file->[0]: $!";
}
my $native_records = [
    { region_id => 'missing', executable_path => File::Spec->catfile( $native_dir, 'absent' ) },
    { region_id => 'add', executable_path => $native_executable, library_path => $native_library, tier2_artifact => { path => $native_ir } },
    { region_id => 'no_extras', executable_path => $native_executable, library_path => File::Spec->catfile( $native_dir, 'no-library' ), tier2_artifact => {} },
];
my $native_payloads = Developer::Dashboard::Pax::StandaloneImage::_native_payloads($native_records);
is( scalar @$native_payloads, 4, 'native payload collection includes existing executables, libraries, and Tier 2 IR only' );
is_deeply(
    [ sort map { $_->{logical_path} } @$native_payloads ],
    [ qw(native/add/library.so native/add/module.ll native/add/probe native/no_extras/probe) ],
    'native payloads receive stable region-scoped logical names',
);
my $dispatch_manifest = Developer::Dashboard::Pax::StandaloneImage::_native_dispatch_manifest([
    { region_id => '', executable_path => $native_executable },
    { region_id => 'add', executable_path => $native_executable, library_path => $native_library, tier2_artifact => { path => $native_ir }, guards => undef, deopt => undef },
    { region_id => 'plain', tier2_artifact => {} },
]);
is( scalar @$dispatch_manifest, 2, 'native dispatch manifests omit records with no region identifier' );
is( $dispatch_manifest->[0]{tier2_logical_path}, 'native/add/module.ll', 'native dispatch entries include the Tier 2 artifact path when present' );
is( $dispatch_manifest->[1]{executable_logical_path}, undef, 'native dispatch entries omit absent executable artifacts' );
is_deeply( $dispatch_manifest->[0]{guards}, [], 'native dispatch records default missing guard metadata to an empty list' );
my $stripped_native = Developer::Dashboard::Pax::StandaloneImage::_strip_native_runtime_paths({
    executable_path => $native_executable,
    library_path => $native_library,
    tier2_artifact => { path => $native_ir, target => 'llvm' },
});
ok( !exists $stripped_native->{executable_path} && !exists $stripped_native->{library_path}, 'native runtime path stripping removes host filesystem paths' );
is_deeply( $stripped_native->{tier2_artifact}, { target => 'llvm' }, 'native runtime path stripping retains non-path Tier 2 metadata' );

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneImage::_pax_runtime_helper_payloads = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_pax_runtime_helper_module_files = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_inc_dirs = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_selected_files = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_shared_lib_payloads = sub { return; };
    my $manifest = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest( mode => 'bundled_perl' );
    is( $manifest->{perl_binary_logical_path}, 'bin/perl', 'bundled runtime manifests identify the embedded Perl executable' );
    is( scalar @{ $manifest->{payloads} }, 1, 'empty runtime-helper discovery leaves only the Perl binary payload' );
}

my $runtime_lib_root = abs_path('lib');
my $runtime_helper_file = abs_path('lib/Developer/Dashboard/Pax/StandaloneRuntime.pm');
my $runtime_helper_payload = {
    source_path => $runtime_helper_file,
    logical_path => 'inc/000/Developer/Dashboard/Pax/StandaloneRuntime.pm',
    unit_kind => 'runtime_inc',
    sha256 => sha256_hex('runtime helper'),
    size => 14,
    bytes => 'runtime helper',
};
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneImage::_pax_runtime_helper_payloads = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_pax_runtime_helper_module_files = sub { return ($runtime_helper_file) };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_inc_dirs = sub { return ($runtime_lib_root) };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_selected_files = sub { return ($runtime_helper_file) };
    local *Developer::Dashboard::Pax::StandaloneImage::_inc_root_for_file = sub { return $runtime_lib_root };
    local *Developer::Dashboard::Pax::StandaloneImage::_file_list_payloads = sub { return ($runtime_helper_payload) };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_tree_family_dirs = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_looks_like_shared_object = sub { return 0 };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_shared_lib_payloads = sub { return; };
    my $manifest = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest( mode => 'bundled_perl' );
    is( scalar @{ $manifest->{bundled_inc_roots} }, 1, 'runtime manifest does not add a second root when a forced helper is already selected' );
    is( scalar( grep { $_->{source_path} eq $runtime_helper_file } @{ $manifest->{payloads} } ), 1, 'runtime manifest avoids duplicate copies of an already-bundled helper' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneImage::_pax_runtime_helper_payloads = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_pax_runtime_helper_module_files = sub { return ($runtime_helper_file) };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_inc_dirs = sub { return ($runtime_lib_root) };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_selected_files = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_shared_lib_payloads = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_tree_family_dirs = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_file_list_payloads = sub { return ($runtime_helper_payload) };
    my $manifest = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest( mode => 'bundled_perl' );
    is( scalar @{ $manifest->{bundled_inc_roots} }, 1, 'runtime manifest creates one root for a helper found through forced inclusion' );
    is( scalar( grep { $_->{source_path} eq $runtime_helper_file } @{ $manifest->{payloads} } ), 1, 'runtime manifest force-includes a known helper omitted by normal include selection' );
}

my $standalone_root = File::Spec->catdir( $root, 'standalone-builds' );
my $builder = Developer::Dashboard::Pax::StandaloneImage->new( root => $standalone_root );
isa_ok( $builder, 'Developer::Dashboard::Pax::StandaloneImage', 'constructor creates a standalone image builder' );
is( $builder->{root}, $standalone_root, 'constructor retains the requested output root' );
is( scalar @{ Developer::Dashboard::Pax::StandaloneImage->build_progress_tasks }, 12, 'progress task metadata names each standalone build phase' );
is( Developer::Dashboard::Pax::StandaloneImage::_progress_emit( undef, {} ), 1, 'progress reporting is a no-op when no callback is supplied' );
my $received_progress;
Developer::Dashboard::Pax::StandaloneImage::_progress_emit( sub { $received_progress = $_[0] }, { task_id => 'fixture' } );
is( $received_progress->{task_id}, 'fixture', 'progress reporting forwards task events to a callback' );

my $build_entrypoint = File::Spec->catfile( $root, 'build-app.pl' );
open my $build_entry_fh, '>', $build_entrypoint or die "Unable to write $build_entrypoint: $!";
print {$build_entry_fh} "#!/usr/bin/env perl\nprint 'fixture';\n";
close $build_entry_fh or die "Unable to close $build_entrypoint: $!";
chmod 0700, $build_entrypoint or die "Unable to make $build_entrypoint executable: $!";
my ( $build_attempt, @build_progress ) = ( 0 );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneImage::_standalone_source_plan = sub { return {}; };
    local *Developer::Dashboard::Pax::StandaloneImage::_code_manifest = sub { return; };
    local *Developer::Dashboard::Pax::StandaloneImage::_asset_manifest = sub { return []; };
    local *Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest = sub {
        return { payloads => [], bundled_inc_roots => [], perl_binary => undef, perl_binary_logical_path => undef, runtime_hash => 'runtime-fixture' };
    };
    local *Developer::Dashboard::Pax::StandaloneImage::_compile_launcher = sub {
        $build_attempt++;
        return $build_attempt == 1 ? { status => 'built' } : { status => 'not_built', reason => 'fixture compiler failure' };
    };
    local *Developer::Dashboard::Pax::StandaloneAnalysis::dependencies = sub { return { items => [], summary => { packaged_app => 0, bundled_xs => 0 } }; };
    local *Developer::Dashboard::Pax::StandaloneAnalysis::native_artifacts = sub { return { items => [], summary => { native_ready => 0, fallback_only => 0 }, runtime_epochs => {} }; };

    my $built = $builder->build(
        entrypoint => $build_entrypoint,
        name => 'fixture',
        runtime_mode => 'host_perl',
        output_path => File::Spec->catfile( $root, 'explicit-output' ),
        progress => sub { push @build_progress, $_[0] },
    );
    is( $built->{status}, 'built', 'build orchestration returns built when launcher compilation succeeds' );
    is( $built->{standalone}{output_path}, File::Spec->catfile( $root, 'explicit-output' ), 'build orchestration honors an explicit output path' );
    ok( -f $built->{manifest_path}, 'build orchestration writes its standalone manifest' );
    is( $builder->path_for('fixture'), $built->{manifest_path}, 'manifest path lookup follows the configured builder root' );
    is( $builder->load( name => 'fixture' )->{launcher_status}, 'built', 'manifest loading reads the just-written standalone record' );
    ok( scalar( grep { $_->{task_id} eq 'compile_launcher' && $_->{status} eq 'done' } @build_progress ), 'progress callback receives completed compile task' );

    my $failed = $builder->build(
        entrypoint => $build_entrypoint,
        name => 'fixture-failed',
        runtime_mode => 'host_perl',
    );
    is( $failed->{status}, 'not_built', 'build orchestration returns not_built when launcher compilation fails' );
    is( $failed->{standalone}{launcher_reason}, 'fixture compiler failure', 'build orchestration preserves a clear launcher failure reason' );
    like( $failed->{standalone}{output_path}, qr{standalone-builds/fixture-failed/fixture-failed\z}, 'default output path is derived from the configured root and image name' );
}

is(
    Developer::Dashboard::Pax::StandaloneImage::_extract_payload_path( $root, 'code', 'lib//Fixture/Foo.pm' ),
    File::Spec->catfile( $root, 'code', 'lib', 'Fixture', 'Foo.pm' ),
    'payload paths normalize repeated separators while preserving logical components',
);
is( Developer::Dashboard::Pax::StandaloneImage::_extracted_manifest_path( $root, 'code', 'missing.pm' ), '', 'extracted manifest lookup rejects absent payload files' );
my $extracted_file = File::Spec->catfile( $root, 'code', 'lib', 'Fixture.pm' );
make_path( dirname($extracted_file) );
open my $extracted_fh, '>', $extracted_file or die "Unable to write $extracted_file: $!";
print {$extracted_fh} "1;\n";
close $extracted_fh or die "Unable to close $extracted_file: $!";
is( Developer::Dashboard::Pax::StandaloneImage::_extracted_manifest_path( $root, 'code', 'lib/Fixture.pm' ), $extracted_file, 'extracted manifest lookup returns a present payload file' );

my $entrypoint_source = Developer::Dashboard::Pax::StandaloneImage::_materialize_entrypoint_source(
    $root,
    { logical_path => 'bin/start.service.json', source_bytes => "print 'entry';\n" },
);
like( $entrypoint_source, qr{source-entrypoint/start\.pl\z}, 'entrypoint materialization maps service records to Perl script names' );
open my $materialized_entry_fh, '<:raw', $entrypoint_source or die "Unable to read $entrypoint_source: $!";
is( <$materialized_entry_fh>, "print 'entry';\n", 'entrypoint materialization preserves source bytes' );
close $materialized_entry_fh or die "Unable to close $entrypoint_source: $!";
is( Developer::Dashboard::Pax::StandaloneImage::_materialize_entrypoint_source( $root, { source_bytes => '' } ), '', 'entrypoint materialization ignores an empty source payload' );

my $source_root = File::Spec->catdir( $root, 'original' );
my $original_bin = File::Spec->catdir( $source_root, 'bin' );
my $original_lib = File::Spec->catdir( $source_root, 'lib', 'Fixture' );
make_path( $original_bin, $original_lib );
my $original_entrypoint = File::Spec->catfile( $original_bin, 'app.pl' );
my $original_module = File::Spec->catfile( $original_lib, 'Foo.pm' );
for my $source_file ( [$original_entrypoint, "print 'app';\n"], [$original_module, "package Fixture::Foo; 1;\n"] ) {
    open my $source_fh, '>', $source_file->[0] or die "Unable to write $source_file->[0]: $!";
    print {$source_fh} $source_file->[1];
    close $source_fh or die "Unable to close $source_file->[0]: $!";
}
my $source_manifest = {
    lib_dirs => ['lib'],
    source_roots => [],
    code_units => [
        { unit_kind => 'lib', logical_path => 'lib/Fixture/Foo.pm', source_path => $original_module, source_bytes => "package Fixture::Foo; 1;\n" },
        { unit_kind => 'entrypoint', logical_path => 'entrypoint/app.pl', source_path => $original_entrypoint, source_bytes => "print 'app';\n" },
    ],
    entrypoint => { source_path => $original_entrypoint, source_bytes => "print 'app';\n" },
};
is(
    Developer::Dashboard::Pax::StandaloneImage::_common_source_parent( $original_module, $original_entrypoint ),
    $source_root,
    'common source parent finds the shared original tree root',
);
my $materialized_tree = Developer::Dashboard::Pax::StandaloneImage::_materialize_manifest_source_tree( $root, $source_manifest );
ok( -f $materialized_tree->{entrypoint}, 'manifest source materialization writes the application entrypoint' );
is_deeply(
    $materialized_tree->{lib_dirs}, [ File::Spec->catdir( $root, 'rebuild-source', 'lib' ) ],
    'manifest source materialization maps declared library roots into the rebuilt tree',
);
is_deeply(
    Developer::Dashboard::Pax::StandaloneImage::_materialized_manifest_roots( $source_manifest, 'lib_dirs', 'lib', $source_root, File::Spec->catdir( $root, 'rebuild-source' ) ),
    [ File::Spec->catdir( $root, 'rebuild-source', 'lib' ) ],
    'materialized roots resolve from logical manifest prefixes',
);
is_deeply(
    Developer::Dashboard::Pax::StandaloneImage::_original_manifest_roots( $source_manifest, 'lib_dirs', 'lib' ),
    [ File::Spec->catdir( $source_root, 'lib' ) ],
    'original roots resolve from source file locations and unit kinds',
);
is(
    Developer::Dashboard::Pax::StandaloneImage::_original_source_root_for_logical( $source_manifest, 'lib', 'lib' ),
    File::Spec->catdir( $source_root, 'lib' ),
    'original source root is returned only when its directory exists',
);
is(
    Developer::Dashboard::Pax::StandaloneImage::_manifest_source_root_for_logical( $source_manifest, 'lib', 'lib' ),
    File::Spec->catdir( $source_root, 'lib' ),
    'manifest source root maps a logical directory back to its original tree',
);
is_deeply(
    Developer::Dashboard::Pax::StandaloneImage::_extracted_manifest_roots( $root, 'code', ['lib', 'missing', 'lib'] ),
    [ File::Spec->catdir( $root, 'code', 'lib' ) ],
    'extracted roots keep existing directories once and skip absent roots',
);

my @declared_modules = Developer::Dashboard::Pax::StandaloneImage::_declared_modules( <<'PERL_SOURCE' );
use strict;
use Fixture::One;
require Fixture::Two;
no warnings;
use base qw(Fixture::BaseOne Fixture::BaseTwo);
use parent 'Fixture::Parent';
=head1 HIDDEN
use Should::NotAppear;
=cut
__END__
use Also::Hidden;
PERL_SOURCE
is_deeply( \@declared_modules, [ qw(strict Fixture::One base parent Fixture::Two warnings Fixture::BaseOne Fixture::BaseTwo Fixture::Parent) ], 'dependency scanning finds use, require, no, and base/parent forms but ignores POD and data' );
is( Developer::Dashboard::Pax::StandaloneImage::_strip_pod("use Visible;\n=head1 HIDDEN\nuse Hidden;\n=cut\n__DATA__\nuse AlsoHidden;\n"), "use Visible;\n", 'POD and trailing data are removed before source dependency analysis' );
ok( Developer::Dashboard::Pax::StandaloneImage::_skip_dependency_module('strict'), 'compile-only pragmas are omitted from the runtime dependency set' );
ok( Developer::Dashboard::Pax::StandaloneImage::_skip_dependency_module('Developer::Dashboard::Pax::HIR'), 'PAX internals are excluded from embedded dependency discovery' );
ok( !Developer::Dashboard::Pax::StandaloneImage::_skip_dependency_module('File::Temp'), 'runtime modules remain eligible for dependency bundling' );
ok( Developer::Dashboard::Pax::StandaloneImage::_dependency_runtime_only(
    do { my $p = File::Spec->catfile( $root, 'runtime-only.pm' ); open my $f, '>', $p or die $!; print {$f} "sub import { 1 }\n"; close $f; $p },
), 'modules with runtime import behavior are recognized as runtime-only' );
my $safe_dependency = File::Spec->catfile( $root, 'safe-dependency.pm' );
open my $safe_dependency_fh, '>', $safe_dependency or die "Unable to write $safe_dependency: $!";
print {$safe_dependency_fh} "package Local::Safe;\nsub answer { return 42 }\n1;\n";
close $safe_dependency_fh or die "Unable to close $safe_dependency: $!";
ok( !Developer::Dashboard::Pax::StandaloneImage::_dependency_runtime_only($safe_dependency), 'plain dependency modules do not require runtime-only loading' );
ok( Developer::Dashboard::Pax::StandaloneImage::_dependency_codegen_safe($safe_dependency), 'plain dependency modules are safe for code generation' );
my $unsafe_dependency = File::Spec->catfile( $root, 'unsafe-dependency.pm' );
open my $unsafe_dependency_fh, '>', $unsafe_dependency or die "Unable to write $unsafe_dependency: $!";
print {$unsafe_dependency_fh} "package Local::Unsafe;\nsub AUTOLOAD { }\n1;\n";
close $unsafe_dependency_fh or die "Unable to close $unsafe_dependency: $!";
ok( !Developer::Dashboard::Pax::StandaloneImage::_dependency_codegen_safe($unsafe_dependency), 'dynamic AUTOLOAD dependencies are rejected by the code-generation safety scan' );

my $module_root = File::Spec->catdir( $root, 'module-root' );
my $module_file = File::Spec->catfile( $module_root, 'Local', 'Sample.pm' );
make_path( dirname($module_file) );
open my $module_fh, '>', $module_file or die "Unable to write $module_file: $!";
print {$module_fh} "package Local::Sample; 1;\n";
close $module_fh or die "Unable to close $module_file: $!";
is( Developer::Dashboard::Pax::StandaloneImage::_locate_pure_perl_module( 'Local::Sample', [$module_root] ), $module_file, 'module lookup finds a pure Perl file under a preferred root' );
is( Developer::Dashboard::Pax::StandaloneImage::_module_name_from_source_path($module_file), undef, 'module source naming ignores paths outside the current include roots' );
{
    local @INC = ($module_root);
    is( Developer::Dashboard::Pax::StandaloneImage::_module_name_from_source_path($module_file), 'Local::Sample', 'module source naming maps an included path back to its Perl package name' );
}
is( Developer::Dashboard::Pax::StandaloneImage::_module_name_from_source_path('not-a-module.txt'), undef, 'module source naming rejects non-module files' );
ok( !Developer::Dashboard::Pax::StandaloneImage::_module_uses_xs($module_file), 'pure Perl source is not marked as an XS module' );
my $xs_module_file = File::Spec->catfile( $module_root, 'Local', 'XS.pm' );
open my $xs_module_fh, '>', $xs_module_file or die "Unable to write $xs_module_file: $!";
print {$xs_module_fh} "package Local::XS; use XSLoader; 1;\n";
close $xs_module_fh or die "Unable to close $xs_module_file: $!";
ok( Developer::Dashboard::Pax::StandaloneImage::_module_uses_xs($xs_module_file), 'module source with XSLoader is classified as XS-backed' );
is( Developer::Dashboard::Pax::StandaloneImage::_locate_pure_perl_module( 'Local::XS', [$module_root] ), undef, 'pure Perl module lookup excludes XS-backed source' );

my $scan_root = File::Spec->catdir( $root, 'scan' );
my $scan_inc = File::Spec->catdir( $scan_root, 'lib' );
make_path($scan_inc);
for my $file ( File::Spec->catfile( $scan_root, 'Main.pm' ), File::Spec->catfile( $scan_root, 'run.pl' ), File::Spec->catfile( $scan_root, 'readme.txt' ), File::Spec->catfile( $scan_inc, 'Hidden.pm' ) ) {
    open my $scan_fh, '>', $file or die "Unable to write $file: $!";
    print {$scan_fh} "1;\n";
    close $scan_fh or die "Unable to close $file: $!";
}
{
    local @INC = ($scan_inc);
    is_deeply( [ Developer::Dashboard::Pax::StandaloneImage::_nested_runtime_inc_dirs($scan_root) ], [$scan_inc], 'nested runtime include directories are identified beneath a scan root' );
    my @all_perl_files = Developer::Dashboard::Pax::StandaloneImage::_perl_files([$scan_root]);
    is( scalar @all_perl_files, 3, 'Perl file enumeration includes nested modules and scripts but ignores other files' );
    my @top_level_files = Developer::Dashboard::Pax::StandaloneImage::_perl_files( [$scan_root], exclude_nested_inc => 1 );
    is( scalar @top_level_files, 2, 'Perl file enumeration prunes nested runtime include directories when requested' );
}

my $explicit_asset = File::Spec->catfile( $root, 'assets', 'logo.svg' );
make_path( dirname($explicit_asset) );
open my $asset_write_fh, '>', $explicit_asset or die "Unable to write $explicit_asset: $!";
print {$asset_write_fh} '<svg/>';
close $asset_write_fh or die "Unable to close $explicit_asset: $!";
my $nested_asset = File::Spec->catfile( $root, 'assets', 'icons', 'mark.svg' );
make_path( dirname($nested_asset) );
open my $nested_asset_fh, '>', $nested_asset or die "Unable to write $nested_asset: $!";
print {$nested_asset_fh} '<svg id="mark"/>';
close $nested_asset_fh or die "Unable to close $nested_asset: $!";
my $assets = Developer::Dashboard::Pax::StandaloneImage::_asset_manifest( [$explicit_asset], [ File::Spec->catdir( $root, 'assets' ) ] );
is( scalar @$assets, 2, 'asset discovery deduplicates explicit assets while walking asset directories' );
is_deeply( [ sort map { $_->{logical_path} } @$assets ], [ 'icons/mark.svg', 'logo.svg' ], 'asset discovery preserves nested logical paths' );

my $private_cli = File::Spec->catdir( $root, 'project', 'share', 'private-cli' );
my $private_lib = File::Spec->catdir( $root, 'project', 'lib' );
make_path( $private_cli, $private_lib );
my $private_source = File::Spec->catfile( $private_lib, 'Dashboard.pm' );
is( Developer::Dashboard::Pax::StandaloneImage::_repo_private_cli_dir_from_source($private_source), $private_cli, 'repository helper assets resolve relative to the project lib directory' );
is( Developer::Dashboard::Pax::StandaloneImage::_repo_private_cli_dir_from_source(''), undef, 'repository helper asset lookup rejects an empty source path' );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneImage::_shared_private_cli_dir = sub { return $private_cli };
    my @inferred = Developer::Dashboard::Pax::StandaloneImage::_inferred_asset_dirs([
        { source_path => $private_source, subs => [ { op => 'internal_cli_repo_private_cli_root' } ] },
        { source_path => '/other/lib/CLI.pm', subs => [ { op => 'internal_cli_shared_private_cli_root', dist_name => 'Fixture-Dist' } ] },
    ]);
    is_deeply( \@inferred, [$private_cli], 'asset directory inference resolves repository and shared private CLI roots once each' );
}

done_testing();

__END__

=head1 NAME

t/263-pax-standaloneimage-manifest-write-coverage.t - verifies standalone manifest serialization

=head1 PURPOSE

Exercises C<Developer::Dashboard::Pax::StandaloneImage::_write_json> against
temporary output paths, verifying directory creation, JSON encoding, and removal
of binary-only payload fields before the manifest is persisted. It also drives the
source-root materialization, dependency scanning, asset collection, payload
metadata, native payload serialization, and generated C-string helpers used
during standalone image construction. A stubbed analysis/compile fixture also
drives the in-process builder lifecycle, progress events, manifest reload, output
selection, and compiler success/failure outcomes.

=head1 WHY IT EXISTS

The PAX image builder writes a manifest separately from its binary payload files
and can rebuild source trees from packaged source metadata. These checks ensure
manifests remain valid JSON, exclude raw payload bytes, map original and extracted
source roots correctly, classify source dependencies and embedded assets
consistently, and preserve runtime/native payload packaging formats. The direct
builder fixture exercises orchestration without relying on child-process builds
that coverage cannot observe.

=head1 WHEN TO USE

Run this test when changing manifest serialization, payload stripping, path
resolution, source-tree materialization, dependency discovery, asset collection,
runtime manifest version discovery, native payload handling, C launcher metadata,
progress reporting, manifest load/path lookup, or output directory creation in
C<StandaloneImage>.

=head1 HOW TO USE

Run it inside the repository's development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/263-pax-standaloneimage-manifest-write-coverage.t

The test creates an isolated temporary directory and deletes it automatically.

=head1 WHAT USES IT

C<StandaloneImage::build> uses the tested helpers to inspect build inputs,
materialize source and library roots, discover pure-Perl dependencies and assets,
construct payload metadata, process native payloads, emit launcher data, and
persist the final runtime manifest. A direct builder fixture stubs dependency
analysis and launcher compilation to exercise orchestration without a slow
external build. All helpers use isolated temporary fixtures.

=head1 EXAMPLES

Example 1: a missing nested output directory is created before JSON is written,
and binary payload bytes are omitted from the encoded manifest.

Example 2: declared library roots from an original source tree are located and
recreated beneath the temporary materialized source tree.

Example 3: dependency discovery ignores POD and data sections while recognizing
Perl C<use>, C<require>, C<no>, C<base>, and C<parent> declarations.

Example 4: asset scanning retains nested logical paths, and payload metadata
includes byte size and SHA-256 digest values.

Example 5: malformed entrypoint records are skipped during version discovery,
while payload package headers and C string arrays retain their escaped formats.

Example 6: the direct builder fixture verifies explicit and derived output paths,
progress notifications, persisted-manifest loading, and both launcher result
statuses without spawning a child compiler.

=cut
