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

# AC-1 (DD-1035 real root cause): a hybrid_compiled_pcu_v1 dependency's
# real source_path is already known from the dependency scan itself
# (StandaloneImage.pm's own @force_runtime_source_files, built directly
# from $args{dependencies}). Before this fix, that file was ONLY ever
# actually bundled into a runtime_inc payload if a completely separate,
# independent @INC walk (_locate_module_runtime_file, inside
# _runtime_selected_files) ALSO happened to resolve the same module -
# which silently fails whenever nothing else on @INC carries a copy of
# the module (the real GitHub Actions runner condition: no installed
# copy of this project's own package anywhere, ever - only its CPAN
# dependencies). This fixture reproduces that exact condition
# deterministically on ANY host: a module name guaranteed to be absent
# from @INC everywhere, so the old (buggy) code path silently drops it
# and the fixed code path must bundle it directly from its own known
# source_path regardless.
# _file_list_payloads only ever bundles a file that lives UNDER the
# directory it is asked to bundle FROM (a real, deliberate safety
# check - it must never pull in a file from outside the given root).
# The fix bundles hybrid_compiled_pcu_v1 dependencies from
# $PAX_OWN_LIB_ROOT (this checkout's own lib/, exactly where a real
# hybrid dependency's source_path always lives), so the fixture must
# genuinely live there too, not in an unrelated tempdir, or this test
# would validate nothing. Written and removed within this test only -
# never left behind, and never git-tracked.
# Derive the same root StandaloneImage.pm's own $PAX_OWN_LIB_ROOT
# computes: three directories up from its own install location.
my $standaloneimage_pm = abs_path( $INC{'Developer/Dashboard/Pax/StandaloneImage.pm'} );
my $lib_root = $standaloneimage_pm;
$lib_root =~ s{/Developer/Dashboard/Pax/StandaloneImage\.pm\z}{};
my $fixture_dir  = File::Spec->catdir( $lib_root, qw(Fixture DD1035) );
make_path($fixture_dir);
my $fixture_path = File::Spec->catfile( $fixture_dir, 'NeverOnInc.pm' );
open my $fh, '>', $fixture_path or die "cannot write fixture: $!";
print {$fh} "package Fixture::DD1035::NeverOnInc;\nour \$VERSION = '0.01';\n1;\n";
close $fh;
$fixture_path = abs_path($fixture_path);
END {
    remove_tree( File::Spec->catdir( $lib_root, 'Fixture' ) ) if defined $lib_root;
}

# Note: the fixture necessarily lives under $PAX_OWN_LIB_ROOT (this
# checkout's own lib/, on @INC via `use lib 'lib'` above), because
# _file_list_payloads refuses to bundle a file from outside the
# directory it is told to bundle FROM - the same containment check a
# real hybrid dependency's source_path is always subject to. That is
# also exactly the CI condition: _runtime_inc_dirs() deliberately
# excludes $PAX_OWN_LIB_ROOT from its own bundling roots (so an app
# never accidentally embeds its OWN dev lib/ wholesale), so a file that
# resolves only under $PAX_OWN_LIB_ROOT cannot be bucketed by the OLD
# by-inc-dir mechanism regardless of whether a bare @INC walk can find
# it - only a real installed copy living OUTSIDE $PAX_OWN_LIB_ROOT (as
# this ticket found on every local/container host this session, never
# on a genuinely clean GitHub Actions runner) can mask that gap.

my $manifest = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest(
    mode                 => 'bundled_perl',
    app_namespace        => 'Fixture::DD1035',
    app_legacy_namespace => '',
    dependencies         => [
        {
            class      => 'compiled_dependency',
            packaging  => 'hybrid_compiled_pcu_v1',
            module     => 'Fixture::DD1035::NeverOnInc',
            source_path => $fixture_path,
        },
    ],
    lib_dirs      => [],
    exclude_files => [],
    exclude_dirs  => [],
);

my @matches = grep {
    ( $_->{source_path} // '' ) eq $fixture_path
        || ( $_->{logical_path} // '' ) =~ m{Fixture/DD1035/NeverOnInc\.pm\z}
} @{ $manifest->{payloads} // [] };

ok( scalar(@matches) >= 1,
    'a hybrid_compiled_pcu_v1 dependency invisible to a bare @INC walk is still bundled, from its own known source_path' );

# AC-2: a build with NO caller-supplied hybrid_compiled_pcu_v1
# dependencies at all (the common case for most application code) must
# still succeed normally. Note: @force_runtime_source_files always also
# contains the 4 runtime-helper module files regardless of $args{dependencies}
# (see StandaloneImage.pm's own "uncoverable branch false" annotation at
# the `if (@force_runtime_source_files)` check) - so this does not exercise
# an empty force-list, only confirms passing zero dependencies works.
my $manifest_no_hybrid = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest(
    mode                 => 'bundled_perl',
    app_namespace        => 'Fixture::DD1035',
    app_legacy_namespace => '',
    dependencies         => [],
    lib_dirs             => [],
    exclude_files        => [],
    exclude_dirs         => [],
);
ok( ref( $manifest_no_hybrid->{payloads} ) eq 'ARRAY',
    'a build with zero hybrid_compiled_pcu_v1 dependencies still produces a valid manifest (the force-include block is a no-op, not an error)' );

# AC-3: the false branch of `if -f $abs` inside the @missing grep - a
# force-listed dependency whose recorded source_path does not actually
# exist on disk (a stale/incorrect scan result) must be silently skipped
# by the force-include pass, not crash it or bundle a non-existent file.
my $nonexistent_path = File::Spec->catfile( $lib_root, qw(Fixture DD1035 DoesNotExist.pm) );
my $manifest_missing_file = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest(
    mode                 => 'bundled_perl',
    app_namespace        => 'Fixture::DD1035',
    app_legacy_namespace => '',
    dependencies         => [
        {
            class       => 'compiled_dependency',
            packaging   => 'hybrid_compiled_pcu_v1',
            module      => 'Fixture::DD1035::DoesNotExist',
            source_path => $nonexistent_path,
        },
    ],
    lib_dirs      => [],
    exclude_files => [],
    exclude_dirs  => [],
);
my @nonexistent_matches = grep {
    ( $_->{source_path} // '' ) eq $nonexistent_path
} @{ $manifest_missing_file->{payloads} // [] };
is( scalar(@nonexistent_matches), 0,
    'a force-listed dependency whose source_path does not exist on disk is silently skipped, not bundled as a broken payload' );

# AC-4: a hybrid_compiled_pcu_v1 dependency whose source_path is ALSO
# reachable via a real, non-excluded @INC entry (e.g. an installed copy
# outside this checkout) ends up bundled exactly once, never duplicated.
# Note: this does not exercise the `if (@missing)` false branch either -
# see StandaloneImage.pm's own "uncoverable branch false" annotation
# there, for the same structural reason as AC-2 (the always-present
# helper module files can never be pre-bundled by the normal path, so
# @missing can never be empty) - this instead verifies the dedup logic
# (%already_bundled / the seen-check inside _file_list_payloads) produces
# exactly one payload when a dependency is reachable both ways.
my $installed_json_path;
for my $inc (@INC) {
    next if ref $inc;
    my $candidate = File::Spec->catfile( $inc, qw(Developer Dashboard JSON.pm) );
    if ( -f $candidate ) { $installed_json_path = abs_path($candidate); last; }
}
SKIP: {
    skip 'no installed Developer::Dashboard::JSON.pm found on @INC on this host - AC-4 needs one to construct the already-selected case', 1
        if !$installed_json_path;
    my $manifest_already_bundled = Developer::Dashboard::Pax::StandaloneImage::_runtime_manifest(
        mode                 => 'bundled_perl',
        app_namespace        => 'Fixture::DD1035',
        app_legacy_namespace => '',
        dependencies         => [
            {
                class       => 'compiled_dependency',
                packaging   => 'hybrid_compiled_pcu_v1',
                module      => 'Developer::Dashboard::JSON',
                source_path => $installed_json_path,
            },
        ],
        lib_dirs      => [],
        exclude_files => [],
        exclude_dirs  => [],
    );
    my @duplicate_matches = grep {
        ( $_->{source_path} // '' ) eq $installed_json_path
    } @{ $manifest_already_bundled->{payloads} // [] };
    is( scalar(@duplicate_matches), 1,
        'a hybrid_compiled_pcu_v1 dependency already bundled by the normal selection path is not duplicated by the force-include pass' );
}

done_testing();

__END__

=pod

=head1 NAME

223-standaloneimage-hybrid-dependency-force-include.t - proves DD-1035's real root-cause fix

=head1 PURPOSE

Guards that C<_runtime_manifest> genuinely bundles every
C<hybrid_compiled_pcu_v1>-packaged dependency from its own known
C<source_path>, rather than depending on a separate, independent C<@INC>
walk (C<_locate_module_runtime_file>) to rediscover the same file.

=head1 WHY IT EXISTS

DD-1035 found that the real, published GitHub Release standalone binary
crashes C<dashboard --help>/C<dashboard jq> with C<Can't locate
Developer/Dashboard/SeedSync.pm in @INC>. Root-caused: SeedSync.pm is
packaged as C<hybrid_compiled_pcu_v1>, and the force-include mechanism
meant to guarantee its bundling only ever protected an
already-independently-selected file from exclusion - it never added a
file that C<_locate_module_runtime_file>'s bare C<@INC> walk failed to
find. That walk silently fails whenever nothing else on C<@INC> happens
to carry an installed copy of this project's own package - true of a
genuinely clean GitHub Actions runner, but masked on every local/container
environment this ticket was ever diagnosed on (each one, for a different
reason, happened to have a stray installed copy of Developer::Dashboard
somewhere on C<@INC>). This test reproduces the exact failure condition
deterministically, on any host, via a fixture module name guaranteed to
be absent from C<@INC> everywhere.

=head1 WHEN TO USE

Run this file whenever C<_runtime_manifest>, C<_runtime_selected_files>,
or C<_file_list_payloads> change.

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/223-standaloneimage-hybrid-dependency-force-include.t

=head1 WHAT USES IT

This exact force-include path is not exercised by any other test file in
this suite - every other StandaloneImage.pm test targets a different
concern (overload detection, launcher compilation, build-dir naming).

=head1 EXAMPLES

Example 1:

    prove -lv t/223-standaloneimage-hybrid-dependency-force-include.t

Confirm the fix is present: a hybrid_compiled_pcu_v1 dependency with no
independently-resolvable copy on C<@INC> is still bundled.

=cut
