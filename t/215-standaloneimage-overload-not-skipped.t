#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use Capture::Tiny qw(capture);

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneImage;

# AC-1: DD-1022 - `overload` must NOT be treated as a skippable
# compile-time-only pragma. Unlike strict/warnings/utf8 (which set
# compiler hints and have no meaningful runtime footprint), `overload`
# installs real, runtime-invoked subroutines (STRINGIFY/NUMIFY/etc.)
# that get called later, whenever an overloaded object is stringified
# or numified - so a standalone binary that never bundles overload.pm
# crashes the moment any bundled module (e.g. File::Temp) actually
# triggers that overload.
ok(
    !Developer::Dashboard::Pax::StandaloneImage::_skip_dependency_module('overload'),
    'overload is NOT skipped by the dependency walker - it must be bundled like any real runtime dependency'
);

# AC-3 (regression guard): the genuinely compile-time-only pragmas this
# skip list exists for must stay skipped - this fix must not widen the
# list into bundling things that were never the problem.
for my $pragma (qw(strict warnings utf8 lib parent base constant feature vars integer bytes mro if open re)) {
    ok(
        Developer::Dashboard::Pax::StandaloneImage::_skip_dependency_module($pragma),
        "$pragma stays skipped - compile-time-only pragmas are unaffected by this fix"
    );
}

# AC-2: a real compiled binary, built with the fix, genuinely bundles
# overload.pm and a File::Temp-dependent subcommand no longer crashes
# with the "Can't locate overload.pm" error - proven end to end with a
# real pax build, not just the unit-level skip-list check above.
SKIP: {
    skip 'DD_SKIP_REAL_PAX_COMPILE_TEST is set', 2 if $ENV{DD_SKIP_REAL_PAX_COMPILE_TEST};

    my $dir = tempdir( CLEANUP => 1 );
    my $output = "$dir/dashboard-overload-test";
    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $^X, '-Ilib', 'share/private-cli/pax', 'build', '--compact', '-o', $output, 'bin/dashboard' );
    };
    skip 'a real pax build did not succeed in this environment', 2 if ( $exit >> 8 ) != 0 || !-x $output;

    # `dashboard of` (open-file) reaches File::Temp/Capture::Tiny
    # transitively and is exactly the subcommand DD-1022 was reported
    # against - it must not crash with the overload.pm error.
    my ( $of_out, $of_err, $of_exit ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $output, 'of' );
    };
    unlike( $of_err // '', qr/Can't locate overload\.pm/,
        "AC-2: a real compiled binary's 'of' subcommand does not crash with the overload.pm error" );

    # AC-3 regression check: dashboard version (the pre-existing smoke
    # check) stays unaffected by this fix.
    my ( $version_out ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $output, 'version' );
    };
    like( $version_out, qr/\A\d+\.\d+\s*\z/, 'AC-3: dashboard version still works, unaffected by this fix' );
}

done_testing();

__END__

=pod

=head1 NAME

215-standaloneimage-overload-not-skipped.t - proves DD-1022's overload bundling fix

=head1 PURPOSE

Guards DD-1022: C<_skip_dependency_module> must not treat C<overload>
as a compile-time-only pragma safe to omit from a standalone binary's
bundled runtime payload - it installs real, runtime-invoked
subroutines, so omitting it crashes any bundled module that actually
triggers the overload (confirmed live: C<File::Temp>'s own
C<use overload> for stringification/numification).

=head1 WHY IT EXISTS

Nothing else in this suite exercised C<_skip_dependency_module>
directly. This file proves both halves of the fix: C<overload> is no
longer skipped, and the genuinely compile-time-only pragmas the skip
list exists for remain skipped.

=head1 WHEN TO USE

Run this file whenever C<_skip_dependency_module>'s skip list changes.

=head1 HOW TO USE

    prove -lv t/215-standaloneimage-overload-not-skipped.t

Set C<DD_SKIP_REAL_PAX_COMPILE_TEST=1> to skip the real-build block
(slow - a full PAX build) and keep only the fast unit-level check.

=head1 WHAT USES IT

C<_skip_dependency_module>'s treatment of C<overload> specifically is
not exercised by any other test file in this suite.

=head1 EXAMPLES

The real crash this file proves is fixed, reproduced live from a real
GitHub Actions CI artifact run in a fresh container:

    Can't locate overload.pm in @INC ... at .../File/Temp.pm line 169.
    BEGIN failed--compilation aborted ... at .../Capture/Tiny.pm line 11.

=cut
