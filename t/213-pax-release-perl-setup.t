#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use YAML::XS qw(LoadFile);

plan skip_all => 'checkout-only workflow validation; release tarballs exclude .github'
    if !-f '.github/workflows/pax-release.yml' || !-f '.github/workflows/test.yml';

my $workflow = LoadFile('.github/workflows/pax-release.yml');
my $test_yml = LoadFile('.github/workflows/test.yml');

my $job = ( values %{ $workflow->{jobs} } )[0];
my @steps = @{ $job->{steps} };

# AC-1: a Perl-setup step exists and precedes the cpanm-dependent step,
# matching test.yml's own established shogo82148/actions-setup-perl
# pattern (the exact fix for "cpanm: command not found" on GitHub-hosted
# runners, which do not ship cpanm pre-installed).
my ($setup_idx) = grep { ( $steps[$_]{uses} // '' ) =~ m{^shogo82148/actions-setup-perl} } 0 .. $#steps;
my ($deps_idx)  = grep { $steps[$_]{name} eq 'Install Perl dependencies (Linux and Windows)' } 0 .. $#steps;

ok( defined $setup_idx, 'a shogo82148/actions-setup-perl step exists in pax-release.yml' );
ok( defined $deps_idx, 'the Install Perl dependencies step still exists' );

if ( defined $setup_idx && defined $deps_idx ) {
    cmp_ok( $setup_idx, '<', $deps_idx, 'the Perl-setup step runs BEFORE the cpanm-dependent step' );
}

if ( defined $setup_idx ) {
    my $setup_step = $steps[$setup_idx];

    # Must match test.yml's own pin exactly, not merely "some version" -
    # a drifted pin here would defeat the whole point of borrowing an
    # already-proven-working step.
    my ($test_yml_setup_step) = grep { ( $_->{uses} // '' ) =~ m{^shogo82148/actions-setup-perl} }
        @{ ( values %{ $test_yml->{jobs} } )[0]{steps} };
    ok( $test_yml_setup_step, 'sanity: test.yml itself still has its own actions-setup-perl step to compare against' );
    is( $setup_step->{uses}, $test_yml_setup_step->{uses}, 'pax-release.yml pins the identical actions-setup-perl SHA as test.yml' );
    is( $setup_step->{with}{'perl-version'}, $test_yml_setup_step->{with}{'perl-version'}, 'pax-release.yml requests the identical perl-version as test.yml' );

    # Gated the same way as the steps it precedes - Linux plus windows-amd64
    # now that DD-1015 landed a real Windows build step (windows-arm64 is
    # deliberately excluded: no Perl 5.44 binary exists for windows-11-arm
    # at all - see the workflow's own comment - and macOS/DD-1014 remains
    # fully unimplemented).
    is( $setup_step->{if}, q{startsWith(matrix.target, 'linux-') || matrix.target == 'windows-amd64' || matrix.target == 'macos-arm64'}, 'the Perl-setup step is gated to Linux, windows-amd64 and macos-arm64 targets, matching its dependent steps' );
}

# AC-4 (found via a REAL PAX Release CI run, not a local test - share/
# private-cli/pax's own FindBin-based lib resolution ("Can't locate
# Developer/Dashboard/Pax/CLI.pm in @INC") only ever failed in the actual
# GitHub Actions environment; every local invocation this session ran
# succeeded). The build step must pass -Ilib explicitly rather than
# relying on FindBin+cwd inference.
{
    my ($build_step) = grep { $_->{name} eq 'PAX build dashboard (Linux only)' } @steps;
    ok( $build_step, 'the PAX build dashboard step exists' );
    like( $build_step->{run}, qr/perl -Ilib share\/private-cli\/pax build/, 'the PAX build step passes -Ilib explicitly, not relying on FindBin lib resolution' );
}

# AC-3 (found via the same real-CI verification this ticket's git-gate
# performed): every action pin in pax-release.yml must resolve to a
# node24+ runtime - GitHub force-runs node20 actions on node24, which
# some actions survive and others do not (DD-449's own documented lesson,
# already enforced project-wide by script/audit-action-pins). The
# upload-artifact pin this file originally shipped with (v4.6.2) declared
# node20 and was caught failing this exact audit in real CI.
SKIP: {
    skip 'DD_SKIP_NETWORK_TESTS is set', 2 if $ENV{DD_SKIP_NETWORK_TESTS};

    my $audit_out = `PERL5LIB=$ENV{PERL5LIB} script/audit-action-pins 2>&1`;
    my $audit_exit = $? >> 8;
    skip 'audit-action-pins could not reach the GitHub API (network unavailable in this environment)', 2
        if $audit_exit == 3;
    is( $audit_exit, 0, 'script/audit-action-pins passes cleanly against the current workflow set' )
        or diag($audit_out);
    unlike( $audit_out, qr/below the node\d+ floor/, 'no action pin is reported below the node runtime floor' );
}

done_testing();

__END__

=pod

=head1 NAME

213-pax-release-perl-setup.t - proves DD-1018's Perl-bootstrap fix for PAX Release CI

=head1 PURPOSE

Guards DD-1018: C<.github/workflows/pax-release.yml>'s Linux matrix jobs
must bootstrap Perl and C<cpanm> (via the same
C<shogo82148/actions-setup-perl> pin C<test.yml> already uses) before
running any C<cpanm>-dependent step. Every real CI run of this workflow
failed with C<cpanm: command not found> until this fix, because
GitHub-hosted runners do not ship C<cpanm> pre-installed.

=head1 WHY IT EXISTS

Neither C<t/210-pax-release-workflow-skeleton.t> nor
C<t/211-pax-release-linux-build-wiring.t> asserted anything about Perl
availability in the CI environment itself - they only proved the
workflow's own structure and step content, which is correct in isolation
but says nothing about whether the runner environment can actually
execute those steps. This file specifically guards the CI-environment
bootstrap gap that only a real GitHub Actions run exposed.

=head1 WHEN TO USE

Run this file whenever C<pax-release.yml>'s Perl-setup step changes, or
whenever C<test.yml>'s own C<actions-setup-perl> pin is updated (this
file compares against it directly, so drift between the two is caught).

=head1 HOW TO USE

    prove -lv t/213-pax-release-perl-setup.t

The real acceptance bar (AC-1/AC-2) additionally requires a genuine
GitHub Actions run - verified via C<gh run view> after pushing, since no
local test can simulate "does this runner ship cpanm."

=head1 WHAT USES IT

C<.github/workflows/pax-release.yml>'s Perl-bootstrap step is not
exercised by any other test file in this suite.

=head1 EXAMPLES

The real pre-fix CI failure this file's fix resolves:

    Run cpanm --quiet --notest --installdeps .
    /home/runner/work/_temp/....sh: line 1: cpanm: command not found
    Process completed with exit code 127.

=cut
