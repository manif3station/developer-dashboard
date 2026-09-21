#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);

use Developer::Dashboard::Pax::StandaloneImage;

# DD-926: the pax launcher build cache directory used to be a single literal
# name (.pax-launcher-build) shared by every uid that ever builds against the
# same output parent directory. A root-owned build (e.g. from inside a
# developer-dashboard:latest container) would leave that directory owned
# root:root, and every later non-root build sharing the same output parent
# then failed outright with Permission Denied - the failure did not
# self-clear, because a non-root user cannot delete root-owned files.
#
# The fix namespaces the directory per invoking uid via a small, directly
# testable helper: _pax_launcher_build_dir_name(%args), which _compile_launcher
# now uses instead of the bare literal. These tests exercise that helper (and
# the real filesystem behaviour it produces) without requiring real root.

# --- AC-1: two distinct uids derive two distinct, uid-specific dir names -------
{
    my $name_a = Developer::Dashboard::Pax::StandaloneImage::_pax_launcher_build_dir_name( uid => 0 );
    my $name_b = Developer::Dashboard::Pax::StandaloneImage::_pax_launcher_build_dir_name( uid => 1000 );

    isnt( $name_a, $name_b, 'AC-1: build-dir names differ for two distinct uids' );
    like( $name_a, qr/(?<!\d)0\z/,    'AC-1: uid 0 is reflected in its own dir name' );
    like( $name_b, qr/(?<!\d)1000\z/, 'AC-1: uid 1000 is reflected in its own dir name' );
    like( $name_a, qr/^\.pax-launcher-build-/, 'AC-1: dir name keeps the original .pax-launcher-build prefix' );
}

# --- AC-1 (default): with no uid supplied, the REAL invoking uid ($<) is used --
{
    my $default_name = Developer::Dashboard::Pax::StandaloneImage::_pax_launcher_build_dir_name();
    is( $default_name, '.pax-launcher-build-' . $<, 'AC-1: default derivation uses the real process uid ($<)' );
}

# --- AC-3: the SAME uid always derives the SAME path (cache reuse preserved) ---
{
    my $first  = Developer::Dashboard::Pax::StandaloneImage::_pax_launcher_build_dir_name( uid => 4242 );
    my $second = Developer::Dashboard::Pax::StandaloneImage::_pax_launcher_build_dir_name( uid => 4242 );
    is( $first, $second, 'AC-3: repeated derivation for the same uid is stable across calls' );
}

# --- AC-2: a foreign-uid dir already on disk is never touched or reused --------
{
    my $parent = tempdir( CLEANUP => 1 );

    # Simulate a pre-existing build dir left behind by a DIFFERENT uid (e.g. a
    # prior root-owned container build), made inaccessible the way a
    # different real uid's ownership would make it inaccessible to us.
    my $foreign_uid  = 0;
    my $current_uid  = 999999;    # a uid guaranteed not to be ours
    my $foreign_name = Developer::Dashboard::Pax::StandaloneImage::_pax_launcher_build_dir_name( uid => $foreign_uid );
    my $current_name = Developer::Dashboard::Pax::StandaloneImage::_pax_launcher_build_dir_name( uid => $current_uid );

    my $foreign_dir = File::Spec->catdir( $parent, $foreign_name );
    make_path($foreign_dir);
    my $foreign_marker = File::Spec->catfile( $foreign_dir, 'code.pkg' );
    open my $fh, '>', $foreign_marker or die "cannot write fixture: $!";
    print {$fh} 'belongs-to-foreign-uid';
    close $fh;

    # No chmod here on purpose: this test does not rely on the OS actually
    # enforcing a permission denial (which root - as this suite may run under
    # in a container - would defeat anyway, per t/168-permission-assertion-
    # guards.t). The invariant under test is purely path separation: the
    # current uid's derived path never equals, and never touches, the
    # foreign uid's derived path.

    # The current (different) uid derives its OWN, separate build_dir and can
    # freely create and write into it, without ever touching the foreign one.
    my $current_dir = File::Spec->catdir( $parent, $current_name );
    ok( !-e $current_dir, 'AC-2: the current uid\'s build_dir does not exist yet and is distinct from the foreign one' );
    isnt( $current_dir, $foreign_dir, 'AC-2: current-uid and foreign-uid build_dir paths are different paths' );

    make_path($current_dir);
    my $current_marker = File::Spec->catfile( $current_dir, 'code.pkg' );
    open my $ok_fh, '>', $current_marker or die "current-uid build failed to write: $!";
    print {$ok_fh} 'belongs-to-current-uid';
    close $ok_fh;

    ok( -f $current_marker, 'AC-2: current uid successfully wrote into its own build_dir' );

    open my $read_fh, '<', $foreign_marker or die "cannot re-read fixture: $!";
    my $foreign_contents = do { local $/; <$read_fh> };
    close $read_fh;
    is( $foreign_contents, 'belongs-to-foreign-uid', 'AC-2: the foreign uid\'s file was never touched or overwritten' );
}

done_testing();

__END__

=head1 NAME

t/202-pax-launcher-build-dir-per-uid.t - regression coverage for DD-926

=head1 PURPOSE

Prove that C<Developer::Dashboard::Pax::StandaloneImage>'s launcher build
cache directory is namespaced per invoking uid, so a root-owned build (e.g.
from inside a C<developer-dashboard:latest> container) and a non-root
host-side build sharing the same output parent directory never collide on
the same cache path.

=head1 WHY IT EXISTS

DD-926: before this fix, C<_compile_launcher> derived its intermediate
build cache directory as the single literal name C<.pax-launcher-build>,
with no uid component. The first process (of any uid) to create it under a
shared output parent (commonly bare F</tmp>) left it owned by that uid;
every later build by a DIFFERENT uid against the same parent then failed
outright with Permission Denied when trying to write into it - a failure
that did not self-clear, since a non-root user cannot remove root-owned
files without C<sudo>.

=head1 WHEN TO USE

Run this file whenever C<_pax_launcher_build_dir_name> or
C<_compile_launcher>'s build-directory derivation changes, to confirm the
per-uid namespacing invariant still holds.

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/202-pax-launcher-build-dir-per-uid.t

=head1 WHAT USES IT

C<Developer::Dashboard::Pax::StandaloneImage::_compile_launcher>, invoked by
C<dashboard pax build> (via C<InternalCLI> / C<share/private-cli/pax>) and
by the dashboard's own self-compile hook.

=head1 EXAMPLES

    prove -lv t/202-pax-launcher-build-dir-per-uid.t

=cut
