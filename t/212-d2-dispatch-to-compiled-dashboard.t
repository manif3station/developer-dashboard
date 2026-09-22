#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use Capture::Tiny qw(capture);

my $repo_root = abs_path( File::Spec->catdir( dirname(__FILE__), '..' ) );
my $lib       = File::Spec->catdir( $repo_root, 'lib' );
my $d2        = File::Spec->catfile( $repo_root, 'bin', 'd2' );

# --------------------------------------------------------------------------
# AC-2 (fast slice): a synthetic non-Perl "dashboard" (executable, no '#!'
# shebang, deliberately NOT valid Perl source) proves d2 dispatches to it
# DIRECTLY rather than through $^X. Before DD-1017's fix, d2 unconditionally
# runs `perl $dashboard`, which would fail to compile this file (its first
# bytes are not valid Perl) - so a correct direct exec is what makes this
# pass, and the pre-fix behavior is what makes it fail.
# --------------------------------------------------------------------------
{
    my $dir = tempdir( CLEANUP => 1 );
    my $fake_dashboard = File::Spec->catfile( $dir, 'fake-compiled-dashboard' );

    open my $fh, '>:raw', $fake_dashboard or die "cannot write $fake_dashboard: $!";
    # ELF-magic-like bytes, then a real shell interpreter line as a portable
    # stand-in for "a binary that is not Perl source" - deliberately opens
    # with bytes that are NOT '#!' so DD-1017's detection treats it as
    # compiled, but is still something exec() can actually run for the test
    # to observe a distinguishing result.
    print {$fh} "\x7fELF-NOT-REALLY-BUT-NOT-A-SHEBANG\n";
    close $fh;
    chmod 0755, $fake_dashboard;

    # Make it directly executable by giving it a real shebang-less
    # self-identifying behavior is not possible for a plain text file
    # without '#!' (the OS itself won't know how to run it) - so instead
    # this slice asserts the NEGATIVE: d2 must NOT attempt `perl
    # $fake_dashboard` (which would emit a Perl "Unrecognized character"
    # compile error naming this file), proving the code path took the
    # non-perl branch rather than proving what the branch actually execs
    # into (AC-2's REAL end-to-end proof is the SKIP-guarded real-binary
    # block below).
    my ( $out, $err, $exit ) = capture {
        local $ENV{DEVELOPER_DASHBOARD_D2_DASHBOARD_PATH} = $fake_dashboard;
        system( $^X, '-I', $lib, $d2, 'version' );
    };
    unlike( $err, qr/Unrecognized character/, 'd2 does NOT try to run the non-shebang file through perl (the pre-fix failure mode)' );
    unlike( $err, qr/\Q$fake_dashboard\E line 1/, 'no perl compile error naming the fake dashboard file' );
}

# --------------------------------------------------------------------------
# AC-2 (real slice, SKIP-guarded like t/182/t/184's own real-compile
# blocks): build a REAL pax-compiled dashboard binary and confirm d2
# correctly execs it directly, with output matching the binary's own.
# --------------------------------------------------------------------------
SKIP: {
    skip 'DD_SKIP_REAL_PAX_COMPILE_TEST is set', 3 if $ENV{DD_SKIP_REAL_PAX_COMPILE_TEST};

    my $dir = tempdir( CLEANUP => 1 );
    my $compiled_dashboard = File::Spec->catfile( $dir, 'dashboard-compiled' );
    my $pax = File::Spec->catfile( $repo_root, 'share', 'private-cli', 'pax' );
    my $dashboard_src = File::Spec->catfile( $repo_root, 'bin', 'dashboard' );

    my ( $build_out, $build_err, $build_exit ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $^X, $pax, 'build', '--compact', '-o', $compiled_dashboard, $dashboard_src );
    };
    skip 'a real pax build did not succeed in this environment', 3 if ( $build_exit >> 8 ) != 0 || !-x $compiled_dashboard;

    my ( $direct_out, $direct_err, $direct_exit ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $compiled_dashboard, 'version' );
    };

    my ( $d2_out, $d2_err, $d2_exit ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        local $ENV{DEVELOPER_DASHBOARD_D2_DASHBOARD_PATH} = $compiled_dashboard;
        system( $^X, '-I', $lib, $d2, 'version' );
    };

    is( $d2_exit >> 8, 0, 'd2 exits cleanly when dispatching to a real compiled dashboard binary' );
    is( $d2_out, $direct_out, 'd2 output matches running the compiled dashboard binary directly' );
    unlike( $d2_err, qr/Unrecognized character/, 'no perl compile error - d2 execed the binary directly, not through perl' );
}

done_testing();

__END__

=pod

=head1 NAME

212-d2-dispatch-to-compiled-dashboard.t - proves DD-1017's compiled-sibling dispatch fix

=head1 PURPOSE

Guards DD-1017: C<bin/d2>'s dispatch line must detect whether its sibling
C<$dashboard> is Perl source or a PAX-compiled standalone binary, and exec
it accordingly - directly for a compiled binary, through C<$^X> for Perl
source. Before this fix, C<bin/d2> unconditionally routed through
C<$^X>, which crashes trying to parse a compiled binary as Perl source.

=head1 WHY IT EXISTS

C<t/49-d2-entrypoint.t> only ever exercises the interpreted-dashboard
path (a Perl C<bin/dashboard> file) - it never puts a compiled binary in
C<$dashboard>'s place, so it structurally cannot catch this defect. This
file exists specifically to exercise the other case: a real
PAX-compiled C<dashboard> binary as the dispatch target.

=head1 WHEN TO USE

Run this file whenever C<bin/d2>'s dispatch logic changes, or whenever
the PAX compile mechanism itself changes in a way that could affect
compiled-binary detection (e.g. if compiled binaries ever gained a
shebang-like prefix).

=head1 HOW TO USE

    prove -lv t/212-d2-dispatch-to-compiled-dashboard.t

Set C<DD_SKIP_REAL_PAX_COMPILE_TEST=1> to skip the real-compile block
(slow - a full PAX build) and keep only the fast synthetic-file slice.

=head1 WHAT USES IT

C<bin/d2>'s dispatch line is not exercised for the compiled-sibling case
by any other test file in this suite.

=head1 EXAMPLES

The pre-fix failure this file specifically catches:

    $ perl bin/d2 version   # with DEVELOPER_DASHBOARD_D2_DASHBOARD_PATH
                             # pointing at a compiled ELF binary
    Unrecognized character \x7F; marked by <-- HERE ...

=cut
