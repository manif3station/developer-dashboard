#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';

use Developer::Dashboard::Pax::AppImage ();

my $root = tempdir( CLEANUP => 1 );
my $entrypoint = File::Spec->catfile( $root, 'app entry.pl' );
my $lib = File::Spec->catdir( $root, 'lib' );
my $nested = File::Spec->catdir( $lib, 'nested' );
my $asset_dir = File::Spec->catdir( $root, 'assets' );
make_path( $nested, $asset_dir );

_write( $entrypoint, "use strict;\nuse warnings;\nuse Local::Entry;\nrequire Local::Dynamic;\n" );
_write( File::Spec->catfile( $lib, 'Entry.pm' ), "package Local::Entry;\nuse Local::Helper;\n1;\n" );
_write( File::Spec->catfile( $nested, 'helper.pl' ), "package Local::Helper;\nuse utf8;\n1;\n" );
_write( File::Spec->catfile( $nested, 'plain' ), "use Local::Plain;\n" );
_write( File::Spec->catfile( $nested, 'ignored.txt' ), "use Local::Ignored;\n" );
_write( File::Spec->catfile( $asset_dir, 'picture.bin' ), "\0\xFFpayload" );
_write( File::Spec->catfile( $asset_dir, 'empty.bin' ), '' );

my $default_root = Developer::Dashboard::Pax::AppImage->new;
is( $default_root->{root}, '.pax/apps', 'new defaults to the documented app-image directory' );
{
    local $ENV{PAX_APP_ROOT} = File::Spec->catdir( $root, 'env-apps' );
    is( Developer::Dashboard::Pax::AppImage->new->{root}, $ENV{PAX_APP_ROOT}, 'new uses PAX_APP_ROOT when no root argument is supplied' );
    is( Developer::Dashboard::Pax::AppImage->new( root => 'explicit' )->{root}, 'explicit', 'an explicit root overrides PAX_APP_ROOT' );
}
my $missing_entrypoint_required = eval { $default_root->build; 1 };
ok( !$missing_entrypoint_required && $@ =~ /entrypoint required/, 'build requires an entrypoint argument' );

is( Developer::Dashboard::Pax::AppImage::_default_name($entrypoint), 'app-entry.pl', 'default name replaces unsafe filename characters' );
is( Developer::Dashboard::Pax::AppImage::_default_name(''), 'pax-app', 'default name falls back for an empty entrypoint string' );
my @unfiltered_perl_files = Developer::Dashboard::Pax::AppImage::_perl_files(
    [ $lib, File::Spec->catdir( $root, 'missing' ), File::Spec->catdir( $root, 'missing-parent', 'missing' ) ]
);
my @perl_files = sort @unfiltered_perl_files;
my @expected_perl_files = sort(
    File::Spec->catfile( $lib, 'Entry.pm' ),
    File::Spec->catfile( $nested, 'helper.pl' ),
    File::Spec->catfile( $nested, 'plain' ),
);
is_deeply(
    \@perl_files,
    \@expected_perl_files,
    '_perl_files returns Perl and extensionless source files and skips other files and missing roots',
);
is_deeply(
    Developer::Dashboard::Pax::AppImage::_discover_preload_modules( $entrypoint, [$lib] ),
    [qw(Local::Dynamic Local::Entry Local::Helper Local::Plain)],
    'preload discovery scans use and require statements while excluding compiler pragmas and non-source files',
);

my $manifest = Developer::Dashboard::Pax::AppImage::_asset_manifest(
    [
        File::Spec->catfile( $asset_dir, 'picture.bin' ),
        File::Spec->catfile( $root, 'missing.bin' ),
        File::Spec->catfile( $root, 'missing-parent', 'missing.bin' ),
    ],
    [ $asset_dir, File::Spec->catdir( $root, 'missing-assets' ), File::Spec->catdir( $root, 'missing-parent', 'assets' ) ],
);
is( scalar @{$manifest}, 2, 'asset manifest skips missing assets and de-duplicates matching logical paths' );
is( $manifest->[0]{logical_path}, 'picture.bin', 'direct asset uses its basename as its logical path' );
is( $manifest->[0]{bytes}, "\0\xFFpayload", 'asset bytes are read without text decoding' );
is( $manifest->[1]{logical_path}, 'empty.bin', 'asset directories contribute relative paths and zero-byte files' );
is( Developer::Dashboard::Pax::AppImage::_asset_bytes($manifest), 9, 'asset byte count sums payload sizes' );
is(
    Developer::Dashboard::Pax::AppImage::_safe_logical_path('assets/../private//./image.bin'),
    'assets/private/image.bin',
    'logical paths drop empty, current, and parent segments',
);
is( Developer::Dashboard::Pax::AppImage::_logical_name('/some/assets/picture.bin'), 'picture.bin', 'logical name uses the final path component' );
like( Developer::Dashboard::Pax::AppImage::_asset_table_c([]), qr/pax_asset_count = 0/, 'empty asset table emits a valid zero-count C table' );
my $asset_c = Developer::Dashboard::Pax::AppImage::_asset_table_c($manifest);
like( $asset_c, qr/0x00, 0xff/, 'asset table emits byte values as hexadecimal C initializers' );
like( $asset_c, qr/0 \}/, 'empty asset payload emits a legal zero initializer' );
is( Developer::Dashboard::Pax::AppImage::_c_string('a"b\\c'), '"a\\"b\\\\c"', 'C string encoding escapes quotes and backslashes' );

my $source_hash = Developer::Dashboard::Pax::AppImage::_source_hash( $entrypoint, [$lib], $manifest );
like( $source_hash, qr/\A[0-9a-f]{64}\z/, 'source hash is a SHA-256 digest over source and asset metadata' );
isnt(
    $source_hash,
    Developer::Dashboard::Pax::AppImage::_source_hash( $entrypoint, [$lib], [] ),
    'asset metadata changes the source hash',
);
is(
    Developer::Dashboard::Pax::AppImage::_source_hash( File::Spec->catfile( $root, 'absent.pl' ), [], undef ),
    Developer::Dashboard::Pax::AppImage::_source_hash( File::Spec->catfile( $root, 'absent.pl' ), [], [] ),
    'source hashing tolerates a missing entrypoint and an undefined asset list',
);
is( Developer::Dashboard::Pax::AppImage::_slurp( File::Spec->catfile( $root, 'absent.pl' ) ), '', 'text slurp returns empty content for a missing file' );
is( Developer::Dashboard::Pax::AppImage::_slurp_bytes( File::Spec->catfile( $root, 'absent.bin' ) ), '', 'binary slurp returns empty content for a missing file' );
is( Developer::Dashboard::Pax::AppImage::_slurp( File::Spec->catfile( $asset_dir, 'empty.bin' ) ), '', 'text slurp returns an empty string for an empty file' );
is( Developer::Dashboard::Pax::AppImage::_slurp_bytes( File::Spec->catfile( $asset_dir, 'empty.bin' ) ), '', 'binary slurp returns an empty string for an empty file' );

my $image = {
    name => 'fixture',
    entrypoint => $entrypoint,
    socket_path => File::Spec->catfile( $root, 'fixture.sock' ),
    asset_root => File::Spec->catdir( $root, 'embedded' ),
    assets => $manifest,
};
my $launcher_source = Developer::Dashboard::Pax::AppImage::_launcher_source($image);
like( $launcher_source, qr/struct pax_asset/, 'launcher source contains the asset data structures' );
like( $launcher_source, qr/fallback_exec/, 'launcher source contains the Perl fallback path' );
like(
    Developer::Dashboard::Pax::AppImage::_launcher_source(
        { %{$image}, assets => undef, lib_dirs => undef, socket_path => 'socket', entrypoint => 'entry.pl', asset_root => 'assets' }
    ),
    qr/pax_asset_count = 0/,
    'launcher source handles absent assets and library directories',
);

my $root_dir = File::Spec->catdir( $root, 'app-images' );
my $app = Developer::Dashboard::Pax::AppImage->new( root => $root_dir );
my $missing_entry_error = eval { $app->build( entrypoint => File::Spec->catfile( $root, 'missing-parent', 'not-there.pl' ) ); 1 };
ok( !$missing_entry_error && $@ =~ /entrypoint not found/, 'build rejects an entrypoint that cannot be resolved' );
my $missing_name_error = eval { $app->load; 1 };
ok( !$missing_name_error && $@ =~ /name required/, 'load requires an image name' );
my $missing_image_error = eval { $app->load( name => 'not-built' ); 1 };
ok( !$missing_image_error && $@ =~ /cannot read app image/, 'load reports a missing image manifest' );

my $build_dir = File::Spec->catdir( $root, 'build' );
make_path($build_dir);
my $fake_bin = File::Spec->catdir( $root, 'fake-bin' );
make_path($fake_bin);
my $fake_cc = File::Spec->catfile( $fake_bin, 'cc' );
_write( $fake_cc, "#!/bin/sh\nwhile [ \$# -gt 0 ]; do if [ \$1 = -o ]; then shift; : > \"\$1\"; /bin/chmod +x \"\$1\"; fi; shift; done\nexit 0\n" );
chmod 0755, $fake_cc or die "chmod $fake_cc: $!";
my $launcher_path = File::Spec->catfile( $build_dir, 'sample' );
my $launcher = { launcher_path => $launcher_path, socket_path => 's', entrypoint => $entrypoint, asset_root => 'assets', lib_dirs => [], assets => [] };
{
    local $ENV{PATH} = $fake_bin;
    local $? = 7 << 8;
    is_deeply( Developer::Dashboard::Pax::AppImage::_compile_launcher($launcher), { status => 'built' }, 'launcher reports a successful compiler and executable output' );
    is( $? >> 8, 7, 'launcher compilation restores the caller exit status' );
}
{
    my $empty_bin = File::Spec->catdir( $root, 'empty-bin' );
    make_path($empty_bin);
    local $ENV{PATH} = $empty_bin;
    my $result = Developer::Dashboard::Pax::AppImage::_compile_launcher( { %{$launcher}, launcher_path => File::Spec->catfile( $build_dir, 'no-compiler' ) } );
    is_deeply( $result, { status => 'not_built', reason => 'no C compiler available' }, 'launcher reports when neither cc nor gcc is available' );
}
{
    my $gcc_bin = File::Spec->catdir( $root, 'gcc-bin' );
    make_path($gcc_bin);
    my $fake_gcc = File::Spec->catfile( $gcc_bin, 'gcc' );
    _write( $fake_gcc, "#!/bin/sh\nexit 2\n" );
    chmod 0755, $fake_gcc or die "chmod $fake_gcc: $!";
    local $ENV{PATH} = $gcc_bin;
    my $result = Developer::Dashboard::Pax::AppImage::_compile_launcher( { %{$launcher}, launcher_path => File::Spec->catfile( $build_dir, 'compile-fails' ) } );
    is_deeply( $result, { status => 'not_built', reason => 'C launcher compile failed' }, 'launcher reports an unsuccessful gcc compile' );
}
{
    my $noop_bin = File::Spec->catdir( $root, 'noop-bin' );
    make_path($noop_bin);
    my $noop_cc = File::Spec->catfile( $noop_bin, 'cc' );
    _write( $noop_cc, "#!/bin/sh\nexit 0\n" );
    chmod 0755, $noop_cc or die "chmod $noop_cc: $!";
    local $ENV{PATH} = $noop_bin;
    my $result = Developer::Dashboard::Pax::AppImage::_compile_launcher( { %{$launcher}, launcher_path => File::Spec->catfile( $build_dir, 'not-executable' ) } );
    is_deeply( $result, { status => 'not_built', reason => 'C launcher compile failed' }, 'launcher rejects a successful compiler exit without an executable output' );
}
my $write_failure = Developer::Dashboard::Pax::AppImage::_compile_launcher( { %{$launcher}, launcher_path => File::Spec->catfile( $root, 'missing-dir', 'bad' ) } );
like( $write_failure->{reason} || '', qr/cannot write launcher source:/, 'launcher reports source-file creation errors' );

my $write_error = eval { Developer::Dashboard::Pax::AppImage::_write_json( File::Spec->catfile( $root, 'missing-dir', 'bad.json' ), {} ); 1 };
ok( !$write_error && $@ =~ /cannot write/, 'JSON writer exposes filesystem errors' );
{
    local $ENV{PATH};
    is( Developer::Dashboard::Pax::AppImage::_which('cc'), undef, '_which returns undef when PATH is undefined' );
}

is( $app->path_for('sample-app'), File::Spec->catfile( $root_dir, 'sample-app', 'image.json' ), 'path_for resolves an image manifest under the configured root' );
{
    local $ENV{PATH} = $fake_bin;
    my $built = $app->build(
        entrypoint => $entrypoint,
        lib_dirs => [ $lib, File::Spec->catdir( $root, 'missing-lib' ), File::Spec->catdir( $root, 'missing-parent', 'missing-lib' ) ],
        assets => [ File::Spec->catfile( $asset_dir, 'picture.bin' ) ],
        asset_dirs => [$asset_dir],
    );
    is( $built->{status}, 'built', 'build writes a complete app image' );
    is( $built->{image}{name}, 'app-entry.pl', 'build derives its default name from the entrypoint' );
    is( $built->{image}{lib_dirs}[1], File::Spec->catdir( $root, 'missing-lib' ), 'build preserves unresolved library roots for the launcher' );
    is( $built->{image}{launcher_status}, 'built', 'build records the compiled launcher status' );
    is_deeply( $app->load( name => 'app-entry.pl' ), $built->{image}, 'load returns the persisted image metadata' );
    open my $fh, '<', $built->{config_path} or die $!;
    my $config_text = do { local $/; <$fh> };
    close $fh or die $!;
    is( decode_json($config_text)->{asset_count}, 2, 'build serializes the normalized asset manifest' );
}
{
    my $no_compiler_root = File::Spec->catdir( $root, 'no-compiler-apps' );
    my $no_compiler_app = Developer::Dashboard::Pax::AppImage->new( root => $no_compiler_root );
    my $empty_bin = File::Spec->catdir( $root, 'empty-build-bin' );
    make_path($empty_bin);
    local $ENV{PATH} = $empty_bin;
    my $built = $no_compiler_app->build( entrypoint => $entrypoint, name => 'named-image' );
    is( $built->{image}{name}, 'named-image', 'build accepts an explicit image name' );
    is( $built->{image}{launcher_status}, 'not_built', 'build continues with the Perl fallback when no compiler is found' );
    is( $built->{image}{launcher_reason}, 'no C compiler available', 'build records the launcher fallback reason' );
}

done_testing();

sub _write {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    return;
}

__END__

=pod

=head1 NAME

t/231-pax-appimage-coverage.t - deterministic application-image coverage tests

=head1 PURPOSE

This test exercises the application-image builder's source scanning, logical
asset handling, metadata persistence, C-launcher generation, and Perl fallback
paths. It uses temporary fixtures and a fake compiler so the tests do not
require a host C toolchain or write persistent application images.

=head1 WHY IT EXISTS

Application-image edge behavior affects source inclusion and whether generated
applications can be loaded safely. These direct tests keep that contract
independent of the larger PAX build suites.

=head1 WHEN TO USE

Run this test when changing C<Developer::Dashboard::Pax::AppImage>, especially
source discovery, asset validation, metadata, launcher compilation, or reload
behavior. Extend the relevant fixture before changing its expected outcome.

=head1 HOW TO USE

Run the focused test from the repository root before the broader suite. For a
coverage change, instrument this file with Devel::Cover, then inspect the four
metric columns for AppImage.pm and add a real input case for each missing path.

=head1 WHAT USES IT

The PAX CLI and packaging flow call the application-image builder. This test
owns deterministic unit coverage for that builder and is also run by the
canonical repository coverage gate.

=head1 EXAMPLES

Run the regression test:

  prove -lv t/231-pax-appimage-coverage.t

Measure the module's focused coverage:

  perl -MDevel::Cover=-db,/tmp/appimage-cover,-blib,0 t/231-pax-appimage-coverage.t
  cover /tmp/appimage-cover -report text -select_re '^lib/Developer/Dashboard/Pax/AppImage.pm$'

=head1 RUNNING

Run from the repository root:

  prove -lv t/231-pax-appimage-coverage.t

Run with statement, branch, condition, and subroutine instrumentation:

  perl -MDevel::Cover=-db,/tmp/appimage-cover,-blib,0 t/231-pax-appimage-coverage.t
  cover /tmp/appimage-cover -report text -select_re '^lib/Developer/Dashboard/Pax/AppImage.pm$'

=head1 FIXTURES

All source, library, asset, output, and compiler fixtures live beneath a
C<File::Temp> directory removed when the test exits. The fake C<cc> executable
only creates the expected launcher output path; it never compiles or executes
generated native code.

=head1 COVERAGE INTENT

Each assertion names a public result or defensive failure contract. The test
covers missing and present source trees, duplicate and invalid assets, absent
compilers, both compile outcomes, unreadable metadata, and successful build then
reload. This keeps this module's edge matrix repeatable under the canonical gate.

=cut
