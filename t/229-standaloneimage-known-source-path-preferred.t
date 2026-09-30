#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Basename qw(dirname);
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use FindBin qw($Bin);

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneImage;

# DD-1049: _locate_module_runtime_file and its callers (_runtime_selected_files,
# _expand_runtime_module_files) resolve a module by walking @INC and returning
# the FIRST existing file - with no mechanism to prefer the dependency scan's
# own already-known source_path for that module, even though every
# %args{dependencies} entry carries one (already used elsewhere in the same
# function for the hybrid_compiled_pcu_v1 case - the DD-1035 fix). If an
# earlier @INC entry happens to hold a stale/duplicate copy of the module, the
# wrong file wins silently. DD-1035's own investigation found this exact
# masking condition already present on this project's development hosts (a
# leftover installed copy of this project's own package on PERL5LIB).

# Build two real, distinguishable fixture files for the SAME module name:
# one under a synthetic @INC entry placed FIRST (the "stale/duplicate" copy),
# one under a second @INC root that the dependency scan already knows about
# (the "REAL copy"). Both use a genuine module-relative path so package-family
# expansion sees the same module identity for both copies.
# Keep this a unique module family so an unrelated installed Foo::Bar (or a
# previous family-cache lookup for Foo) cannot influence the integration case.
my $fixture_root = tempdir( 'dd1049-known-source-path-XXXXXX', DIR => File::Spec->tmpdir, CLEANUP => 1 );
my $real_dir  = File::Spec->catdir( $fixture_root, 'real' );
my $stale_dir = File::Spec->catdir( $fixture_root, 'stale' );
make_path($real_dir);
make_path($stale_dir);

my $real_path  = File::Spec->catfile( $real_dir,  qw(DD1049 KnownSource Widget.pm) );
my $stale_path = File::Spec->catfile( $stale_dir, qw(DD1049 KnownSource Widget.pm) );
make_path( File::Spec->catdir( $real_dir,  qw(DD1049 KnownSource) ) );
make_path( File::Spec->catdir( $stale_dir, qw(DD1049 KnownSource) ) );

open my $real_fh, '>', $real_path or die "cannot write fixture: $!";
print {$real_fh} "package DD1049::KnownSource::Widget;\nour \$VERSION = '0.01';\nsub which { 'real' }\n1;\n";
close $real_fh;

open my $stale_fh, '>', $stale_path or die "cannot write fixture: $!";
print {$stale_fh} "package DD1049::KnownSource::Widget;\nour \$VERSION = '0.00';\nsub which { 'stale' }\n1;\n";
close $stale_fh;

$real_path  = abs_path($real_path);
$stale_path = abs_path($stale_path);

# AC-1 / BDD-1: _locate_module_runtime_file, called with a known source_path
# for DD1049::KnownSource::Widget, must return the REAL copy - never the stale one, even when the
# stale directory sits earlier on @INC than anywhere the real copy would
# normally be found by a bare walk.
{
    local @INC = ( $stale_dir, $real_dir, @INC );
    my $known_paths = { 'DD1049::KnownSource::Widget' => $real_path };
    my $resolved = Developer::Dashboard::Pax::StandaloneImage::_locate_module_runtime_file(
        'DD1049::KnownSource::Widget', $known_paths,
    );
    is( $resolved, $real_path,
        'a module with a known source_path resolves to the REAL copy, not an earlier @INC entry\'s stale duplicate' );
}

# AC-2 / BDD-2: the SAME synthetic @INC, but calling _locate_module_runtime_file
# with NO known source_path for this module (the _expand_runtime_module_files
# transitive-scan case, which has nothing to prefer) - fallback path preserved,
# still returns the first @INC match.
{
    local @INC = ( $stale_dir, $real_dir, @INC );
    my $resolved_no_known = Developer::Dashboard::Pax::StandaloneImage::_locate_module_runtime_file(
        'DD1049::KnownSource::Widget',
    );
    is( $resolved_no_known, $stale_path,
        'with no known source_path, the existing first-match @INC walk is preserved unchanged' );
}

# Integration-level: the same masking condition through _runtime_selected_files
# (via _runtime_manifest), for a bundled_pure_perl dependency whose source_path
# is already known from the dependency scan itself.
{
    local @INC = ( $stale_dir, $real_dir, @INC );
    my $manifest = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest(
        mode                 => 'bundled_perl',
        app_namespace        => 'DD1049::KnownSource',
        app_legacy_namespace => '',
        dependencies         => [
            {
                class       => 'bundled_pure_perl',
                module      => 'DD1049::KnownSource::Widget',
                source_path => $real_path,
            },
        ],
        lib_dirs      => [$real_dir],
        exclude_files => [],
        exclude_dirs  => [],
    );
    my @stale_matches = grep {
        ( $_->{source_path} // '' ) eq $stale_path
    } @{ $manifest->{payloads} // [] };
    is( scalar(@stale_matches), 0,
        '_runtime_manifest never bundles the stale @INC duplicate when the dependency scan already knows the real source_path' );

    my @real_matches = grep {
        ( $_->{source_path} // '' ) eq $real_path
    } @{ $manifest->{payloads} // [] };
    ok( scalar(@real_matches) >= 1,
        '_runtime_manifest bundles the REAL copy named by the dependency scan\'s own source_path' );
}

# AC-3 / condition-coverage: $known_source_paths passed but NOT a hashref
# (e.g. a plain scalar) - the "ref $known_source_paths eq 'HASH'" half of the
# guard must be false, so the code falls through to the ordinary @INC walk
# rather than dereferencing a non-hash as one.
{
    local @INC = ( $stale_dir, $real_dir, @INC );
    my $resolved_bad_ref = Developer::Dashboard::Pax::StandaloneImage::_locate_module_runtime_file(
        'DD1049::KnownSource::Widget', 'not-a-hashref',
    );
    is( $resolved_bad_ref, $stale_path,
        'a truthy but non-hashref $known_source_paths falls through to the ordinary @INC walk, never dereferenced as a hash' );
}

# AC-4 / condition-coverage: $known resolves via the guard (exists, -f true)
# but Cwd::abs_path fails to resolve it (returns empty) - the "|| $known"
# fallback half of "abs_path($known) || $known" must be exercised, returning
# $known as-written rather than a resolved absolute path. Cwd::abs_path is
# locally overridden for this one call only, matching this project's own
# precedent for simulating an external dependency's failure path that real
# input cannot reliably trigger.
{
    local @INC = ();
    local *Developer::Dashboard::Pax::StandaloneImage::abs_path = sub { return '' };
    my $known_paths = { 'DD1049::KnownSource::Widget' => $real_path };
    my $resolved_abs_path_fails = Developer::Dashboard::Pax::StandaloneImage::_locate_module_runtime_file(
        'DD1049::KnownSource::Widget', $known_paths,
    );
    is( $resolved_abs_path_fails, $real_path,
        'when Cwd::abs_path fails to resolve a known, existing source_path, the original $known path is returned unchanged' );
}

# AC-5 / condition-coverage: $known is present and truthy but points to a
# file that does not actually exist on disk - the "-f $known" half of the
# "$known && -f $known" guard must be false, so the known-source_path branch
# is skipped entirely and the ordinary @INC walk runs instead.
{
    local @INC = ( $stale_dir, $real_dir, @INC );
    my $known_paths = { 'DD1049::KnownSource::Widget' => File::Spec->catfile( $real_dir, qw(DD1049 KnownSource DoesNotExist.pm) ) };
    my $resolved_missing_known = Developer::Dashboard::Pax::StandaloneImage::_locate_module_runtime_file(
        'DD1049::KnownSource::Widget', $known_paths,
    );
    is( $resolved_missing_known, $stale_path,
        'a known source_path that does not exist on disk is skipped, falling through to the ordinary @INC walk' );
}

# AC-6: a known source file that is intentionally excluded from the runtime
# payload (because it is compiled into the standalone binary) must not suppress
# the separate runtime-family copy needed by runtime-loaded code.
{
    local @INC = ( $stale_dir, $real_dir, @INC );
    my @expanded = Developer::Dashboard::Pax::StandaloneImage::_expand_runtime_module_files(
        inc_dirs      => [],
        seed_files    => [$real_path],
        exclude_files => [$real_path],
    );
    ok( scalar( grep { $_ eq $stale_path } @expanded ),
        'an excluded compiled source path does not hide an available runtime-family copy of the same module' );
}

# AC-7: a module force-included from the PAX library root must be written
# relative to that root, not to a broader ancestor that also appears in @INC.
# The latter yields runtime/inc/NNN/lib/Developer/... even though the C
# launcher only adds runtime/inc/NNN to @INC.
{
    my $own_lib = abs_path( File::Spec->catdir( $Bin, File::Spec->updir, 'lib' ) );
    my $own_parent = dirname($own_lib);
    local @INC = ( $own_lib, $own_parent, @INC );
    my $json_module = File::Spec->catfile( $own_lib, qw(Developer Dashboard JSON.pm) );
    my $manifest = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest(
        mode                 => 'bundled_perl',
        app_namespace        => 'DD229::RuntimeRoot',
        app_legacy_namespace => '',
        dependencies         => [
            {
                class       => 'bundled_pure_perl',
                module      => 'Developer::Dashboard::JSON',
                source_path => $json_module,
            },
        ],
        lib_dirs      => [$own_lib],
        exclude_files => [],
        exclude_dirs  => [],
    );
    my @json_payloads = grep {
        ( $_->{source_path} // '' ) eq $json_module
            && ( $_->{unit_kind} // '' ) eq 'runtime_inc'
    } @{ $manifest->{payloads} // [] };
    ok( @json_payloads, 'a force-included PAX library module is present in the runtime payload' );
    like( $json_payloads[0]{logical_path} // '', qr{\Ainc/\d{3}/Developer/Dashboard/JSON\.pm\z},
        'a force-included PAX library module is payload-rooted at Developer/ rather than the broader parent/lib/' );
}

done_testing();

__END__

=pod

=head1 NAME

229-standaloneimage-known-source-path-preferred.t - DD-1049 RED/GREEN test

=head1 PURPOSE

Guards that C<_locate_module_runtime_file> (and, through it,
C<_runtime_selected_files>, C<_expand_runtime_module_files>, and
C<_runtime_manifest>) preserve known module paths, exclude stale duplicates,
allow an unexcluded runtime copy when a compiled source is omitted, and map
force-included PAX modules relative to the correct runtime C<@INC> root.

=head1 WHY IT EXISTS

C<_locate_module_runtime_file> must prefer a dependency scan's known source
path over an earlier stale duplicate in C<@INC>. During package validation,
two additional edge cases were exposed: family expansion could re-add a
duplicate or treat an excluded compiled source as authoritative, and a
force-included module beneath the PAX library root could be bundled relative
to a broader parent directory. That produced C<runtime/inc/NNN/lib/...>
paths that the standalone launcher's C<@INC> roots cannot import. The tests
make each selection and payload-root rule explicit.

=head1 WHEN TO USE

Run this file whenever C<_locate_module_runtime_file>,
C<_runtime_selected_files>, C<_expand_runtime_module_files>, or
C<_runtime_manifest> change.

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/229-standaloneimage-known-source-path-preferred.t

=head1 WHAT USES IT

This test complements t/223's C<hybrid_compiled_pcu_v1> force-include checks.
It covers C<bundled_pure_perl>/C<bundled_xs> source selection, excluded
family duplicates, and correct mapping of PAX library modules to importable
standalone runtime paths.

=head1 EXAMPLES

Example 1:

    prove -lv t/229-standaloneimage-known-source-path-preferred.t

Confirm the fix is present: a module with a known source_path resolves to
that path, never an earlier @INC entry's stale duplicate; excluded sources
do not hide runtime copies; and included files are rooted at the path the
standalone launcher places on @INC.

Example 2:

    d2 docker compose exec dev prove -lv t/229-standaloneimage-known-source-path-preferred.t

Run all source-path and standalone payload-root regressions in the project
development container, including the fixture with a broad parent directory
in C<@INC>.

=cut
