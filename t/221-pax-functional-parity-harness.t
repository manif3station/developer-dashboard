#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Spec;
use Capture::Tiny qw(capture);

my $harness = File::Spec->catfile( 'script', 'pax-functional-parity-check' );
ok( -f $harness, 'script/pax-functional-parity-check exists' );
ok( -x $harness, 'script/pax-functional-parity-check is executable' );

my $correct = File::Spec->catfile( 't', 'fixtures', 'parity-fake-correct.pl' );
my $wrong   = File::Spec->catfile( 't', 'fixtures', 'parity-fake-wrong.pl' );

# AC-1 (DD-1016): when the "compiled" and "source" sides behave
# identically across every representative check, the harness reports
# every check as passing and exits 0 - proves the harness does not
# fail unconditionally or report false negatives.
{
    my ( $stdout, $stderr, $exit ) = capture {
        system( $^X, $harness,
            '--compiled',      $correct,
            '--source-perl',   $^X,
            '--source-script', $correct,
        );
    };
    is( $exit, 0, 'harness exits 0 when compiled and source agree on every check' );
    like( $stdout, qr/PASS/, 'harness reports at least one PASS on stdout' );
    unlike( $stdout, qr/FAIL/, 'harness reports no FAIL when everything matches' );
}

# AC-2: when the "compiled" side genuinely diverges on ONE check (jq),
# the harness must catch it, report exit non-zero, and name the
# SPECIFIC check that failed with its actual and expected values - not
# just a generic "something went wrong".
{
    my ( $stdout, $stderr, $exit ) = capture {
        system( $^X, $harness,
            '--compiled',      $wrong,
            '--source-perl',   $^X,
            '--source-script', $correct,
        );
    };
    isnt( $exit, 0, 'harness exits non-zero when a real mismatch exists' );
    like( $stdout, qr/FAIL/, 'harness reports FAIL on stdout' );
    like( $stdout, qr/jq/i, "the failure report names the SPECIFIC check that diverged ('jq')" );
    like( $stdout, qr/999/, 'the failure report shows the actual (wrong) value' );
    like( $stdout, qr/\b1\b/, 'the failure report shows the expected value' );

    # the checks that DID match must still be reported as passing -
    # one real mismatch must not make the whole report look uniformly
    # broken, which would hide which specific behavior actually regressed.
    like( $stdout, qr/PASS/, 'the checks that genuinely matched are still reported as PASS' );
}

# AC-3: the representative command set is real and multi-part - not
# just a single version-string check (which is what the ad hoc
# per-platform steps in pax-release.yml did before this harness
# existed). At least 3 distinct checks, covering more than one kind of
# CLI surface (a static value, a --help-style informational output, and
# a real data-processing command).
{
    my ( $stdout, $stderr, $exit ) = capture {
        system( $^X, $harness, '--list-checks' );
    };
    is( $exit, 0, '--list-checks exits 0' );
    my @check_names = ( $stdout =~ /^\s*-\s*(\S+)/mg );
    ok( scalar(@check_names) >= 3, 'at least 3 representative checks are defined' )
        or diag "stdout was: $stdout";
    ok( ( grep { /version/i } @check_names ), 'version is one of the checks' );
    ok( ( grep { /jq/i } @check_names ), 'a real data-processing command (jq) is one of the checks' );
}

done_testing();

__END__

=pod

=head1 NAME

221-pax-functional-parity-harness.t - proves DD-1016's shared PAX functional-parity harness works

=head1 PURPOSE

Guards C<script/pax-functional-parity-check>, the shared harness that lets
every DDE-006 platform-build ticket (Linux, macOS, Windows) run the SAME
functional-parity comparison against its own compiled binary, instead of
each platform inventing its own ad hoc single-command (C<version>-only)
check as C<.github/workflows/pax-release.yml> did before this ticket.

=head1 WHY IT EXISTS

The owner's explicit acceptance bar for DDE-006 is "the independent binary
d2/dashboard will be 100% functional matching to the source Perl script" -
not just "the build succeeded". A harness that only checks C<version>
cannot make that claim; this test proves the harness runs a real,
multi-part representative command set and genuinely detects a divergence
on any one of them, naming which one and showing actual vs expected.

=head1 WHEN TO USE

Run this file whenever C<script/pax-functional-parity-check> changes, or
whenever a new representative check is added to its command set.

=head1 HOW TO USE

    prove -lv t/221-pax-functional-parity-harness.t

=head1 WHAT USES IT

C<script/pax-functional-parity-check> is not exercised by any other test
file in this suite; C<.github/workflows/pax-release.yml>'s per-platform
smoke-verify steps invoke it directly in CI, which this file cannot
reach from a unit test - those steps are E2E-verified by real CI runs,
matching how the rest of this workflow's own steps are verified (see
this subsystem's own vault documentation pages for the Windows and macOS
binary-embedding mechanisms).

=head1 EXAMPLES

Example 1:

    prove -lv t/221-pax-functional-parity-harness.t

Confirm the harness both passes cleanly and genuinely catches a real
divergence.

=cut
