#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Capture::Tiny qw(capture);
use File::Temp qw(tempdir);
use Test::More;

# ===========================================================================
# CPAN-green skip work (Michael, 25 Nov 2026): the aarch64 tester box
# fails t/180 test 1. The test builds a fixture HOME whose .profile has a
# line valid in bash but a syntax error under dash, reproducing the real
# ~/.bashrc lesspipe hazard - and its first check asserts that fixture
# genuinely breaks a dash login shell (sh -lc true exits non-zero). On the
# aarch64 box that assertion fails: the box's sh is not dash, or it
# tolerates the line, so the fixture cannot reproduce the hazard there.
# AC 5: the dash login-shell fixture must behave correctly on the aarch64
# box, or skip with a reason if the shell cannot support it.
#
# These tests pin the outcome by running t/180 itself as a subprocess:
# under a shell that cannot reproduce the hazard, t/180 must SKIP (exit
# 0, skip in the TAP output), not fail. The fake sh below is that shell:
# it exits 0 whatever it is asked, never reads the profile, so the
# fixture cannot break it. The control runs t/180 under the real sh
# (dash on this host), where the fixture does break the shell and the
# test passes as today.
#
# The tests are expected to FAIL until Harry gates t/180's first check
# with a skip when the shell cannot reproduce the hazard: under the fake
# sh the assertion fails and t/180 exits non-zero.
# ===========================================================================

my $t180 = File::Spec->catfile( $FindBin::Bin, '180-command-on-path-avoids-login-shell.t' );

sub _fake_sh_bin {
    my $bin = tempdir( CLEANUP => 1 );
    my $sh  = File::Spec->catfile( $bin, 'sh' );
    open my $fh, '>', $sh or die "Unable to write $sh: $!";
    print {$fh} "#!/bin/sh\nexit 0\n";
    close $fh or die "Unable to close $sh: $!";
    chmod 0755, $sh or die "Unable to chmod $sh: $!";
    return $bin;
}

SKIP: {
    skip 'dash login-shell hazard is Linux-only', 5 if $^O ne 'linux';

    # AC 5: under a shell that cannot reproduce the hazard, t/180 skips
    # instead of failing.
    {
        my $fake_bin = _fake_sh_bin();
        local $ENV{PATH} = "$fake_bin:$ENV{PATH}";
        my ( $out, $err, $exit ) = capture { system( $^X, $t180 ) };
        my $tap = $out . $err;
        is( $exit, 0, 't/180 exits 0 (skip, not fail) under a shell that cannot reproduce the dash hazard' );
        like( $tap, qr/# skip/i, 't/180 skips the fixture check under a shell that cannot reproduce the hazard' );
        unlike( $tap, qr/^not ok/m, 't/180 has no failing test under a shell that cannot reproduce the hazard' );
    }

    # Control: under the real sh (dash on this host) the fixture does
    # break the login shell, and t/180 passes as today.
    {
        my ( $out, $err, $exit ) = capture { system( $^X, $t180 ) };
        my $tap = $out . $err;
        is( $exit, 0, 't/180 exits 0 under the real sh' );
        like( $tap, qr/^ok 1/m, 't/180 fixture check passes under the real sh' );
    }
}

done_testing();

__END__

=head1 NAME

t/1001-cpan-green-dash-fixture.t - failing tests for the CPAN-green t/180 fix (AC 5)

=head1 PURPOSE

Pin that t/180 skips (exit 0, skip in the TAP output) instead of
failing when the login shell cannot reproduce the dash hazard - the
aarch64 tester box shape, simulated here with a fake C<sh> that exits 0
whatever it is asked. Under the real sh (dash) the fixture check passes
as today.

=head1 EXPECTED STATE

RED until Harry gates t/180's first check with a skip when the shell
cannot reproduce the hazard: under the fake sh the assertion fails and
t/180 exits non-zero.
