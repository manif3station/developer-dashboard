#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Capture::Tiny qw(capture);
use Developer::Dashboard::Platform ();
use File::Temp qw(tempdir);
use Test::More;

# ===========================================================================
# CPAN-green skip work (Michael, 25 Nov 2026): the CPAN report should go
# green for things that are the environment's fault, not our code's. A test
# that cannot run in an environment should SKIP, not fail, with the reason
# printed and diag adding the detail - skip and show, both together. Never
# a blanket skip just to turn red green.
#
# These tests pin the contract for the one shared ACL capability probe
# (AC 1, 2, 3, 6). The probe is the single place that answers "can this
# environment set owner-only ACLs?":
#   Developer::Dashboard::Platform::windows_acl_can_set_owner_only()
# In list context it returns ($ok, $reason): $ok is 1 when the environment
# can set owner-only ACLs and 0 when it cannot; $reason is undef when
# capable, and when incapable it is a string naming the missing capability
# (owner-only ACLs) and the underlying cause (icacls). In scalar context
# it returns $ok alone. $ENV{DD_TEST_WINDOWS_ACL} is the simulation hook,
# following the existing DD_TEST_* pattern: '0' forces incapable (the
# tester sandbox shape), '1' forces capable, unset means a real check.
# The probe never consults the CPU architecture: 32-bit is out of scope
# entirely (AC 6), so the verdict is arch-independent.
#
# The tests are expected to FAIL until Harry implements the probe: the
# exists-check fails and the probe calls are skipped, and the
# representative ACL-dependent file dies at compile time instead of
# skipping. That is the red this file is written for.
# ===========================================================================

my $repo_lib = File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

my $can_probe = Developer::Dashboard::Platform->can('windows_acl_can_set_owner_only');

ok( $can_probe, 'probe helper windows_acl_can_set_owner_only exists' );

SKIP: {
    skip 'probe helper missing', 11 if !$can_probe;

    # AC 3 (capable branch): on this Linux host the owner-only mechanism
    # is mode bits, which work, so the probe reports capable.
    {
        delete local $ENV{DD_TEST_WINDOWS_ACL};
        my ( $ok, $reason ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok, 1, 'probe reports capable on a Linux host (mode bits work)' );
        is( $reason, undef, 'probe reason is undef when capable' );
        is( scalar Developer::Dashboard::Platform::windows_acl_can_set_owner_only(), 1,
            'probe returns capable in scalar context too' );
    }

    # AC 1 (incapable branch): the simulated tester sandbox cannot set
    # owner-only ACLs, so the probe reports incapable with a reason naming
    # the missing capability.
    {
        local $ENV{DD_TEST_WINDOWS_ACL} = '0';
        my ( $ok, $reason ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok, 0, 'probe reports incapable under DD_TEST_WINDOWS_ACL=0 (sandbox shape)' );
        ok( defined $reason, 'probe reason is defined when incapable' );
        like( $reason, qr/owner-only ACL/, 'skip reason names the missing ACL capability' );
        like( $reason, qr/icacls/, 'skip reason names icacls, the mechanism that cannot do it' );
    }

    # Forced capable: the hook can also force the capable verdict.
    {
        local $ENV{DD_TEST_WINDOWS_ACL} = '1';
        my ( $ok, $reason ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok, 1, 'probe reports capable under DD_TEST_WINDOWS_ACL=1' );
        is( $reason, undef, 'probe reason is undef when forced capable' );
    }

    # AC 6 (no 32-bit work, no 32-bit skips): the verdict does not depend
    # on the CPU architecture. A 32-bit marker must not change it.
    {
        local $ENV{DD_TEST_ARCH} = 'i686';
        delete local $ENV{DD_TEST_WINDOWS_ACL};
        my ( $ok, undef ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok, 1, 'probe verdict ignores a 32-bit arch marker (capable stays capable)' );
        local $ENV{DD_TEST_WINDOWS_ACL} = '0';
        my ( $ok_sandbox, undef ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok_sandbox, 0, 'probe verdict ignores a 32-bit arch marker (incapable stays incapable)' );
    }
}

# ===========================================================================
# AC 1 + AC 2 + AC 3 end to end: a representative ACL-dependent test file
# that probes capability in a BEGIN block and skips with the reason (plus
# diag) when the environment cannot set owner-only ACLs. The file is
# written to a temp dir and run as a subprocess, so these tests assert the
# TAP output a real ACL-dependent file produces - not just the probe.
# ===========================================================================

sub _representative_acl_file {
    my ($dir) = @_;
    my $path = File::Spec->catfile( $dir, 'acl-dependent-representative.t' );
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} <<"PERL";
use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use lib '$repo_lib';
use Developer::Dashboard::Platform ();
BEGIN {
    my ( \$ok, \$reason ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
    if ( !\$ok ) {
        diag(\$reason);
        plan skip_all => \$reason;
    }
}
my \$dir = tempdir( CLEANUP => 1 );
# Verify owner-only with the platform's own mechanism. On Windows,
# Perl's chmod does not set Unix mode bits and stat synthesizes 0777
# for a directory regardless, so mode bits cannot measure it there
# (build #167 failed with got 511, expected 448). On Windows the
# probe's own calls set and check the DACL instead; on Unix mode
# bits are the mechanism, so chmod + stat stays as it is.
if ( Developer::Dashboard::Platform::is_real_windows() ) {
    Developer::Dashboard::Platform::windows_acl_set_owner_only(\$dir);
    ok( Developer::Dashboard::Platform::windows_acl_is_owner_only(\$dir),
        'owner-only mechanism works where the environment supports it' );
}
else {
    chmod 0700, \$dir or die "Unable to chmod \$dir: \$!";
    my \@st = stat \$dir;
    is( ( \$st[2] & 07777 ), 0700, 'owner-only mechanism works where the environment supports it' );
}
done_testing();
PERL
    close $fh or die "Unable to close $path: $!";
    return $path;
}

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $file = _representative_acl_file($dir);

    # AC 1 + AC 2: under the simulated sandbox the file skips, exit 0,
    # with the reason in the SKIP line and diag showing why.
    {
        local $ENV{DD_TEST_WINDOWS_ACL} = '0';
        my ( $out, $err, $exit ) = capture { system( $^X, $file ) };
        my $tap = $out . $err;
        is( $exit, 0, 'ACL-dependent file exits 0 (skip, not fail) when the environment cannot set owner-only ACLs' );
        like( $tap, qr/^1\.\.0 # SKIP .*owner-only ACL/m, 'skip line names the missing ACL capability' );
        like( $tap, qr/^# .*icacls/m, 'diag shows why it skipped (icacls)' );
    }

    # AC 3: where the environment supports owner-only, the file RUNS its
    # tests instead of skipping.
    {
        delete local $ENV{DD_TEST_WINDOWS_ACL};
        my ( $out, $err, $exit ) = capture { system( $^X, $file ) };
        my $tap = $out . $err;
        is( $exit, 0, 'ACL-dependent file exits 0 where the environment supports owner-only' );
        like( $tap, qr/^ok 1/m, 'ACL tests run (not skipped) where the environment supports owner-only' );
        like( $tap, qr/owner-only mechanism works/, 'ACL tests ran their checks where the environment supports owner-only' );
    }
}

done_testing();

__END__

=head1 NAME

t/999-cpan-green-acl-skip.t - failing tests for the CPAN-green ACL skip (AC 1, 2, 3, 6)

=head1 PURPOSE

Pin the contract for the one shared ACL capability probe,
C<Developer::Dashboard::Platform::windows_acl_can_set_owner_only()>, and
the BEGIN-block skip pattern every ACL-dependent test file uses: probe
first, diag the reason and C<plan skip_all> when the environment cannot
set owner-only ACLs, run the tests when it can. The probe verdict never
depends on the CPU architecture (no 32-bit work, AC 6).

=head1 EXPECTED STATE

RED until Harry implements the probe: the exists-check fails, the probe
calls are skipped, and the representative file dies at compile time
instead of skipping.
