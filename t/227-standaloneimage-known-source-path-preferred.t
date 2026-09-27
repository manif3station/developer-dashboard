#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Spec;
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path);

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
# one at the real project-tree location the dependency scan already knows
# about (the "REAL copy"). Both written under a tempdir-like scratch area,
# removed at the end - never left behind, never git-tracked.
my $standaloneimage_pm = abs_path( $INC{'Developer/Dashboard/Pax/StandaloneImage.pm'} );
my $lib_root = $standaloneimage_pm;
$lib_root =~ s{/Developer/Dashboard/Pax/StandaloneImage\.pm\z}{};

my $real_dir  = File::Spec->catdir( $lib_root, qw(Fixture DD1049 Real) );
my $stale_dir = File::Spec->catdir( $lib_root, qw(Fixture DD1049 Stale) );
make_path($real_dir);
make_path($stale_dir);

my $real_path  = File::Spec->catfile( $real_dir,  qw(Foo Bar.pm) );
my $stale_path = File::Spec->catfile( $stale_dir, qw(Foo Bar.pm) );
make_path( File::Spec->catdir( $real_dir,  'Foo' ) );
make_path( File::Spec->catdir( $stale_dir, 'Foo' ) );

open my $real_fh, '>', $real_path or die "cannot write fixture: $!";
print {$real_fh} "package Foo::Bar;\nour \$VERSION = '0.01';\nsub which { 'real' }\n1;\n";
close $real_fh;

open my $stale_fh, '>', $stale_path or die "cannot write fixture: $!";
print {$stale_fh} "package Foo::Bar;\nour \$VERSION = '0.00';\nsub which { 'stale' }\n1;\n";
close $stale_fh;

$real_path  = abs_path($real_path);
$stale_path = abs_path($stale_path);

END {
    remove_tree( File::Spec->catdir( $lib_root, 'Fixture' ) ) if defined $lib_root;
}

# AC-1 / BDD-1: _locate_module_runtime_file, called with a known source_path
# for Foo::Bar, must return the REAL copy - never the stale one, even when the
# stale directory sits earlier on @INC than anywhere the real copy would
# normally be found by a bare walk.
{
    local @INC = ( $stale_dir, @INC );
    my $known_paths = { 'Foo::Bar' => $real_path };
    my $resolved = Developer::Dashboard::Pax::StandaloneImage::_locate_module_runtime_file(
        'Foo::Bar', $known_paths,
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
        'Foo::Bar',
    );
    is( $resolved_no_known, $stale_path,
        'with no known source_path, the existing first-match @INC walk is preserved unchanged' );
}

# Integration-level: the same masking condition through _runtime_selected_files
# (via _runtime_manifest), for a bundled_pure_perl dependency whose source_path
# is already known from the dependency scan itself.
{
    local @INC = ( $stale_dir, @INC );
    my $manifest = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest(
        mode                 => 'bundled_perl',
        app_namespace        => 'Foo',
        app_legacy_namespace => '',
        dependencies         => [
            {
                class       => 'bundled_pure_perl',
                module      => 'Foo::Bar',
                source_path => $real_path,
            },
        ],
        lib_dirs      => [],
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

done_testing();

__END__

=pod

=head1 NAME

227-standaloneimage-known-source-path-preferred.t - DD-1049 RED/GREEN test

=head1 PURPOSE

Guards that C<_locate_module_runtime_file> (and, through it,
C<_runtime_selected_files>) prefers a dependency scan's own already-known
C<source_path> over the first match found by walking C<@INC>, while
preserving the existing C<@INC> walk exactly as before for a module with no
known C<source_path> (the C<_expand_runtime_module_files> transitive-scan
case).

=head1 WHY IT EXISTS

C<_locate_module_runtime_file> and C<_helper_module_path> walk a candidate
list (C<@INC>, or a roots array) and return the FIRST existing file for a
module name, with no mechanism to prefer or cross-check the dependency
scan's own already-known C<source_path> for that module - even though every
C<%args{dependencies}> entry carries one, and it is already used elsewhere
in the same function for the C<hybrid_compiled_pcu_v1> case (the DD-1035
fix). If an earlier C<@INC> entry happens to hold a stale or same-named copy
of a module the scan already resolved correctly - the exact masking
condition DD-1035's own investigation found already present on this
project's development hosts (a leftover installed copy of this project's
own package on C<PERL5LIB>) - the wrong file is bundled silently: no
warning, no build failure, just a quietly-wrong runtime payload.

=head1 WHEN TO USE

Run this file whenever C<_locate_module_runtime_file>,
C<_runtime_selected_files>, or C<_runtime_manifest> change.

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/227-standaloneimage-known-source-path-preferred.t

=head1 WHAT USES IT

This exact known-source_path-preference path is not exercised by any other
test file in this suite - t/223 covers the separate, already-fixed
C<hybrid_compiled_pcu_v1> force-include path (DD-1035); this file covers the
still-open first-match gap for C<bundled_pure_perl>/C<bundled_xs> (DD-1049).

=head1 EXAMPLES

Example 1:

    prove -lv t/227-standaloneimage-known-source-path-preferred.t

Confirm the fix is present: a module with a known source_path resolves to
that path, never an earlier @INC entry's stale duplicate; a module with no
known source_path still falls back to the existing @INC walk unchanged.

=cut
