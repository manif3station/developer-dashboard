use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;
use YAML::XS ();

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $WORKFLOWS = File::Spec->catdir( $ROOT, '.github', 'workflows' );

plan skip_all => 'Scorecard guardrails are source-tree-only checks'
  if !-f File::Spec->catfile( $WORKFLOWS, 'platform-compatibility.yml' );

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    my $text = do { local $/; <$fh> };
    close $fh or die "Unable to close $path: $!";
    return $text // '';
}

for my $required (qw(LICENSE SECURITY.md SECURITY_CHECKS.md)) {
    ok( -f File::Spec->catfile( $ROOT, split m{/}, $required ),
        "$required is present in the source tree" );
}

ok( !-e File::Spec->catfile( $ROOT, '.github', 'dependabot.yml' ),
    'Dependabot automation remains disabled by keeping dependabot.yml absent' );

my $license = _slurp( File::Spec->catfile( $ROOT, 'LICENSE' ) );
like( $license, qr/\AMIT License\n\nCopyright \(c\) \d{4} Developer Dashboard Contributors\n/s,
    'LICENSE uses the canonical MIT heading and project copyright' );
like( $license, qr/THE SOFTWARE IS PROVIDED "AS IS"/,
    'LICENSE includes the canonical MIT warranty disclaimer' );

my $security = _slurp( File::Spec->catfile( $ROOT, 'SECURITY.md' ) );
like( $security, qr/Reporting A Vulnerability/i,
    'SECURITY.md documents vulnerability reporting' );
like( $security, qr/security@/i,
    'SECURITY.md includes a private reporting contact' );

my @workflow_files = qw(
  coverage.yml
  platform-compatibility.yml
  release-github.yml
  dockerhub-image.yml
);

for my $workflow (@workflow_files) {
    my $path = File::Spec->catfile( $WORKFLOWS, $workflow );
    ok( -f $path, "$workflow is present" );
    my $text = _slurp($path);
    like( $text, qr/^permissions:\s*$/m,
        "$workflow declares an explicit permissions block" );
    like( $text, qr/^concurrency:\s*$/m,
        "$workflow declares an explicit concurrency block" );
    like( $text, qr/^\s*timeout-minutes:\s*\d+\s*$/m,
        "$workflow sets an explicit job timeout" );
    unlike( $text, qr/uses:\s*[^@\s]+\@[Vv]?\d+(?:\.\d+)*(?:\s|$)/,
        "$workflow does not use floating action tags" );
    while ( $text =~ /uses:\s*(\S+)\@([^\s#]+)/g ) {
        my ( $action, $pin ) = ( $1, $2 );
        like( $pin, qr/\A[0-9a-f]{40}\z/,
            "$workflow pins $action by full commit SHA" );
    }
}

for my $removed (qw(test.yml codeql.yml package-ghcr.yml fuzz-js.yml)) {
    ok( !-e File::Spec->catfile( $WORKFLOWS, $removed ),
        "$removed remains absent from the active workflow set" );
}

my $platform_text = _slurp(
    File::Spec->catfile( $WORKFLOWS, 'platform-compatibility.yml' ) );
like( $platform_text, qr/script\/audit-action-pins/,
    'Platform compatibility audits the provenance of every retained action pin' );
like( $platform_text, qr/name:\s*Set up Node for property tests/,
    'Platform compatibility prepares Node for the in-suite property test' );
unlike( $platform_text, qr/name:\s*Run fast-check property tests/,
    'Platform compatibility does not duplicate the in-suite property test' );
my $property_test = _slurp( File::Spec->catfile( $ROOT, 't', '35-js-fast-check.t' ) );
like( $property_test, qr/'fuzz:scorecard'/,
    'the complete suite retains the property-based JavaScript scorecard tests' );
like( $platform_text, qr/label:\s*Windows arm64.*?runner:\s*windows-11-arm/s,
    'Platform compatibility includes Windows ARM64 in the full test matrix' );
unlike( $platform_text, qr/name:\s*Verify all-metric lib coverage/,
    'Platform compatibility does not duplicate the dedicated Coverage workflow' );
unlike( $platform_text, qr/^\s*permissions:\s*\n(?:\s+.*:\s*write\s*\n)+/m,
    'Platform compatibility has no workflow-level write permission' );

my $coverage_text = _slurp(
    File::Spec->catfile( $WORKFLOWS, 'coverage.yml' ) );
like( $coverage_text, qr/perl\s+script\/coverage-gate/,
    'Coverage workflow runs the canonical all-metric test coverage gate' );
like( $coverage_text, qr/perl\s+script\/pod-coverage-gate/,
    'Coverage workflow requires repository-wide POD coverage' );
like( $coverage_text, qr/perl\s+script\/markdown-coverage-gate/,
    'Coverage workflow requires repository-wide Markdown coverage' );

my $docker_text = _slurp(
    File::Spec->catfile( $WORKFLOWS, 'dockerhub-image.yml' ) );
like( $docker_text, qr/registry:\s*docker\.io/,
    'Docker publishing targets Docker Hub' );
like( $docker_text, qr/docker\/login-action\@[0-9a-f]{40}/,
    'Docker Hub login action is SHA pinned' );
like( $docker_text, qr/docker\/build-push-action\@[0-9a-f]{40}/,
    'Docker Hub build/push action is SHA pinned' );
unlike( $docker_text, qr/ghcr\.io/i,
    'the retained Docker publishing workflow does not publish to GHCR' );

my $release_path = File::Spec->catfile( $WORKFLOWS, 'release-github.yml' );
my $release_text = _slurp($release_path);
like( $release_text, qr/gh\s+release\s+create\b/,
    'GitHub Release creates releases' );
like( $release_text, qr/gh\s+release\s+upload\b/,
    'GitHub Release updates release assets when needed' );
like( $release_text, qr/actions\/attest-build-provenance\@[0-9a-f]{40}/,
    'GitHub Release generates provenance with a SHA-pinned first-party action' );
like( $release_text, qr/\.intoto\.jsonl\b/,
    'GitHub Release attaches an in-toto provenance asset' );
like( $release_text, qr/\.asc\b/,
    'GitHub Release attaches a detached signature asset' );

my $release_yaml = YAML::XS::LoadFile($release_path);
my $release_job = $release_yaml->{jobs}{release} // {};
my $provenance_job = $release_yaml->{jobs}{provenance} // {};
is( $release_job->{permissions}{'id-token'}, undef,
    'the release job that executes project code cannot mint OIDC tokens' );
is( $provenance_job->{permissions}{'id-token'}, 'write',
    'the dedicated provenance job alone receives OIDC token permission' );
is( $provenance_job->{permissions}{'attestations'}, 'write',
    'the dedicated provenance job can write attestations' );
is( $provenance_job->{needs}, 'release',
    'provenance runs only after the release artifact is published' );

my $provenance_steps = join "\n", map { $_->{run} // '' } @{ $provenance_job->{steps} || [] };
like( $provenance_steps, qr/sha256sum\s+(?:--check|-c)\b/,
    'provenance verifies the published checksum before attesting the artifact' );
unlike( $provenance_steps, qr/\bprove\b|\bdzil\b|\bcpanm\b/,
    'the OIDC-enabled provenance job runs no repository project code' );

done_testing();

__END__

=head1 NAME

34-scorecard-guardrails.t - guard the retained CI and release security surface

=head1 DESCRIPTION

Checks the security-policy files and the four owner-approved GitHub Actions
workflows for pinned actions, explicit permissions, timeouts, dedicated
100-percent coverage gates, Docker Hub-only publishing, consolidated platform
verification, and isolated release provenance.

=head1 PURPOSE

Keep the reduced workflow set secure without reintroducing CodeQL, GHCR,
Dependabot automation, a standalone Test workflow, or a standalone JavaScript
fuzz workflow merely to satisfy historical Scorecard assumptions.

=head1 WHY IT EXISTS

Removing workflows changes which automated Scorecard signals exist, but the
remaining verification, release, and publishing paths still handle project
quality, credentials, and repository identity. Their least-privilege and
coverage properties must remain explicit.

=head1 WHEN TO USE

Run this test whenever changing F<.github/workflows/>, release provenance,
Docker Hub publishing, workflow permissions, action pins, coverage gates, or
the decision to keep Dependabot automation disabled.

=head1 HOW TO USE

  prove -lv t/34-scorecard-guardrails.t

=head1 WHAT USES IT

The source-tree test suite and Platform compatibility workflow use these
assertions to guard the retained CI security surface.

=head1 EXAMPLES

Check the workflow security contract directly:

  prove -lv t/34-scorecard-guardrails.t

Run it with the full suite:

  prove -lr t

=cut
