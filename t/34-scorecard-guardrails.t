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
  if !-e File::Spec->catfile( $ROOT, '.git' );

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

my $mac_workflow_path = File::Spec->catfile( $WORKFLOWS, 'five-platform-coverage.yml' );
ok( -f $mac_workflow_path, 'the five-platform coverage orchestrator is present' );
my $mac_workflow = _slurp($mac_workflow_path);
like( $mac_workflow, qr/^permissions:\s*$/m,
    'the macOS coverage workflow declares token permissions explicitly' );
like( $mac_workflow, qr/^\s+contents:\s*read\s*$/m,
    'the macOS coverage workflow only requests read access' );
unlike( $mac_workflow, qr/^\s+\w[\w-]*:\s*write\s*$/m,
    'the macOS coverage workflow requests no write permissions' );
like( $mac_workflow, qr/^concurrency:\s*$/m,
    'the macOS coverage workflow bounds concurrent runs' );
like( $mac_workflow, qr/^\s+timeout-minutes:\s*\d+\s*$/m,
    'the macOS coverage workflow has an explicit timeout' );
unlike( $mac_workflow, qr/uses:\s*[^@\s]+\@[Vv]?\d+(?:\.\d+)*(?:\s|$)/,
    'the macOS coverage workflow does not use floating action tags' );
my @pins;
while ( $mac_workflow =~ /uses:\s*(\S+)\@([^\s#]+)/g ) {
    my ( $action, $pin ) = ( $1, $2 );
    push @pins, $action;
    like( $pin, qr/\A[0-9a-f]{40}\z/,
        "the macOS coverage workflow pins $action to a full commit SHA" );
}
cmp_ok( scalar(@pins), '>=', 2, 'the macOS coverage workflow has pinned dependencies' );

for my $retired (qw(
  coverage.yml dockerhub-image.yml platform-compatibility.yml release-github.yml
  test.yml codeql.yml package-ghcr.yml fuzz-js.yml
  unit-tests.yml test-coverage.yml
)) {
    ok( !-e File::Spec->catfile( $WORKFLOWS, $retired ),
        "$retired stays absent from the active workflow set" );
}

like( $mac_workflow, qr/perl script\/coverage-gate --jobs 10/,
    'the full macOS coverage suite runs with ten workers' );

my $windows_workflow_path = File::Spec->catfile( $WORKFLOWS, 'windows-amd64-unit-tests.yml' );
ok( -f $windows_workflow_path, 'the dependent Windows coverage workflow is present' );
my $windows_workflow = _slurp($windows_workflow_path);
like( $windows_workflow, qr/^permissions:\s*$/m,
    'coverage declares token permissions explicitly' );
like( $windows_workflow, qr/^\s+contents:\s*read\s*$/m,
    'coverage requests read-only permission' );
unlike( $windows_workflow, qr/^\s+\w[\w-]*:\s*write\s*$/m,
    'coverage requests no write permission' );
unlike( $windows_workflow, qr/^concurrency:\s*$/m,
    'the macOS workflow owns concurrency for both platforms' );
like( $windows_workflow, qr/^\s+timeout-minutes:\s*\d+\s*$/m,
    'coverage sets an explicit timeout' );
unlike( $windows_workflow, qr/uses:\s*[^@\s]+\@[Vv]?\d+(?:\.\d+)*(?:\s|$)/,
    'coverage avoids floating action tags' );
my @coverage_pins;
while ( $windows_workflow =~ /uses:\s*(\S+)\@([^\s#]+)/g ) {
    my ( $action, $pin ) = ( $1, $2 );
    push @coverage_pins, $action;
    like( $pin, qr/\A[0-9a-f]{40}\z/,
        "coverage pins $action by full SHA" );
}
cmp_ok( scalar(@coverage_pins), '>=', 2,
    'coverage has SHA-pinned actions' );
like( $windows_workflow, qr/^\s*workflow_call:\s*$/m,
    'Windows accepts only the reusable workflow trigger' );
like( $mac_workflow, qr/^\s*needs:\s*macos-arm64\s*$/m,
    'Windows waits for successful macOS coverage' );
like( $windows_workflow, qr/perl script\/coverage-gate --jobs 10/,
    'Windows coverage enforces all metrics with ten workers' );

unlike( $mac_workflow, qr/gh\s+release\s+(?:create|upload)\b|docker\/build-push-action/,
    'the macOS coverage workflow does not publish releases or Docker images' );

my $property_test = _slurp( File::Spec->catfile( $ROOT, 't', '35-js-fast-check.t' ) );
like( $property_test, qr/'fuzz:scorecard'/,
    'the complete test suite retains the JavaScript property-based tests' );

done_testing();

__END__

=head1 NAME

34-scorecard-guardrails.t - guard the retained CI and release security surface

=head1 DESCRIPTION

Checks security policy and the five-platform coverage orchestrator for pinned
actions, read-only permissions, timeouts and mandatory 100 percent coverage.

=head1 PURPOSE

Keep the reduced workflow set secure without reintroducing CodeQL, GHCR,
Dependabot automation, a standalone Test workflow, or a standalone JavaScript
fuzz workflow merely to satisfy historical Scorecard assumptions.

=head1 WHY IT EXISTS

Removing workflows changes which automated Scorecard signals exist, but the
five-platform coverage chain handles quality and identity. Its least-privilege
and coverage properties must remain explicit.

=head1 WHEN TO USE

Run this test whenever changing F<.github/workflows/>, test or coverage
permissions, action pins, coverage gates or the decision to keep Dependabot
automation disabled.

=head1 HOW TO USE

  prove -lv t/34-scorecard-guardrails.t

=head1 WHAT USES IT

The source-tree coverage orchestrator and reusable Windows workflow use these
assertions to guard the retained CI security surface.

=head1 EXAMPLES

Check the workflow security contract directly:

  prove -lv t/34-scorecard-guardrails.t

Run it with the full suite:

  prove -lr t

=cut
