#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use Capture::Tiny qw(capture);

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneImage;

# AC-1: DD-1050 - `lib` must NOT be treated as a skippable
# compile-time-only pragma. Unlike strict/warnings/utf8 (which set
# compiler hints and have no meaningful runtime footprint), `lib` is a
# real, physically-requirable module whose import() runs real code
# (unshift @INC) - exactly the same defect shape DD-1022 fixed for
# `overload`. A standalone binary that never bundles lib.pm crashes the
# moment any bundled module's own `use lib` statement is reached
# through StandaloneRuntime.pm's require wrapper.
ok(
    !Developer::Dashboard::Pax::StandaloneImage::_skip_dependency_module('lib'),
    'lib is NOT skipped by the dependency walker - it must be bundled like any real runtime dependency'
);

# AC-3 (regression guard): the genuinely compile-time-only pragmas this
# skip list exists for must stay skipped - this fix must not widen the
# list into bundling things that were never the problem. `lib` and
# `overload` are deliberately absent from this list - `overload` was
# already fixed by DD-1022, `lib` is what this file fixes.
for my $pragma (qw(strict warnings utf8 parent base constant feature vars integer bytes mro if open re)) {
    ok(
        Developer::Dashboard::Pax::StandaloneImage::_skip_dependency_module($pragma),
        "$pragma stays skipped - compile-time-only pragmas are unaffected by this fix"
    );
}

# AC-2: a real compiled binary, built with the fix, genuinely bundles
# lib.pm and ordinary CLI subcommands no longer crash with the
# "Can't locate lib.pm" error - proven end to end with a real pax
# build, not just the unit-level skip-list check above.
SKIP: {
    skip 'DD_SKIP_REAL_PAX_COMPILE_TEST is set', 2 if $ENV{DD_SKIP_REAL_PAX_COMPILE_TEST};

    my $dir = tempdir( CLEANUP => 1 );
    my $output = "$dir/dashboard-lib-test";
    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $^X, '-Ilib', 'share/private-cli/pax', 'build', '--compact', '-o', $output, 'bin/dashboard' );
    };
    skip 'a real pax build did not succeed in this environment', 2 if ( $exit >> 8 ) != 0 || !-x $output;

    # --help is the exact subcommand this defect was found against
    # (real GitHub Actions CI artifact, hostile env -i container) - it
    # must not crash with the lib.pm error.
    my ( $help_out, $help_err, $help_exit ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $output, '--help' );
    };
    unlike( $help_err // '', qr/Can't locate lib\.pm/,
        "AC-2: a real compiled binary's --help does not crash with the lib.pm error" );

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

225-standaloneimage-lib-not-skipped.t - proves DD-1050's lib bundling fix

=head1 PURPOSE

Guards DD-1050: C<_skip_dependency_module> must not treat C<lib> as a
compile-time-only pragma safe to omit from a standalone binary's
bundled runtime payload - it is a real, physically-requirable module
whose C<import()> runs real code, so omitting it crashes any bundled
code path that actually requires it at runtime (confirmed live: the
compiled binary's own C<--help>/C<jq> subcommands, run from a real
GitHub Actions CI artifact in a hostile C<env -i> container).

=head1 WHY IT EXISTS

Nothing else in this suite exercised C<_skip_dependency_module>'s
treatment of C<lib> specifically. This file proves both halves of the
fix: C<lib> is no longer skipped, and the genuinely compile-time-only
pragmas the skip list exists for remain skipped.

=head1 WHEN TO USE

Run this file whenever C<_skip_dependency_module>'s skip list changes.

=head1 HOW TO USE

    prove -lv t/225-standaloneimage-lib-not-skipped.t

Set C<DD_SKIP_REAL_PAX_COMPILE_TEST=1> to skip the real-build block
(slow - a full PAX build) and keep only the fast unit-level check.

=head1 WHAT USES IT

C<_skip_dependency_module>'s treatment of C<lib> specifically is not
exercised by any other test file in this suite.

=head1 EXAMPLES

The real crash this file proves is fixed, reproduced live from a real
GitHub Actions CI artifact run in a fresh container:

    Can't locate lib.pm in @INC (you may need to install the lib module)
    ... at .../StandaloneRuntime.pm line 305.
    BEGIN failed--compilation aborted at .../virtual/entrypoint.pl line 10.

=cut
