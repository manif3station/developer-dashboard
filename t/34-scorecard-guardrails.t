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

my $unit_workflow_path = File::Spec->catfile( $WORKFLOWS, 'unit-tests.yml' );
ok( -f $unit_workflow_path, 'the owner-approved unit-test workflow is present' );
my $unit_workflow = _slurp($unit_workflow_path);
like( $unit_workflow, qr/^permissions:\s*$/m,
    'the unit-test workflow declares token permissions explicitly' );
like( $unit_workflow, qr/^\s+contents:\s*read\s*$/m,
    'the unit-test workflow only requests read access' );
unlike( $unit_workflow, qr/^\s+\w[\w-]*:\s*write\s*$/m,
    'the unit-test workflow requests no write permissions' );
like( $unit_workflow, qr/^concurrency:\s*$/m,
    'the unit-test workflow bounds concurrent runs' );
like( $unit_workflow, qr/^\s+timeout-minutes:\s*\d+\s*$/m,
    'the unit-test workflow has an explicit timeout' );
unlike( $unit_workflow, qr/uses:\s*[^@\s]+\@[Vv]?\d+(?:\.\d+)*(?:\s|$)/,
    'the unit-test workflow does not use floating action tags' );
my @pins;
while ( $unit_workflow =~ /uses:\s*(\S+)\@([^\s#]+)/g ) {
    my ( $action, $pin ) = ( $1, $2 );
    push @pins, $action;
    like( $pin, qr/\A[0-9a-f]{40}\z/,
        "the unit-test workflow pins $action to a full commit SHA" );
}
cmp_ok( scalar(@pins), '>=', 2, 'the unit-test workflow has pinned dependencies' );

for my $retired (qw(
  coverage.yml dockerhub-image.yml platform-compatibility.yml release-github.yml
  test.yml codeql.yml package-ghcr.yml fuzz-js.yml
)) {
    ok( !-e File::Spec->catfile( $WORKFLOWS, $retired ),
        "$retired stays absent from the active workflow set" );
}

like( $unit_workflow, qr/\bprove -j 10\b/,
    'the full Perl test suite is run with ten parallel workers' );

my $coverage_workflow_path = File::Spec->catfile( $WORKFLOWS, 'test-coverage.yml' );
ok( -f $coverage_workflow_path, 'the dependent coverage workflow is present' );
my $coverage_workflow = _slurp($coverage_workflow_path);
like( $coverage_workflow, qr/^permissions:\s*$/m,
    'coverage declares token permissions explicitly' );
like( $coverage_workflow, qr/^\s+contents:\s*read\s*$/m,
    'coverage requests read-only permission' );
unlike( $coverage_workflow, qr/^\s+\w[\w-]*:\s*write\s*$/m,
    'coverage requests no write permission' );
like( $coverage_workflow, qr/^concurrency:\s*$/m,
    'coverage bounds duplicated upstream runs' );
like( $coverage_workflow, qr/^\s+timeout-minutes:\s*\d+\s*$/m,
    'coverage sets an explicit timeout' );
unlike( $coverage_workflow, qr/uses:\s*[^@\s]+\@[Vv]?\d+(?:\.\d+)*(?:\s|$)/,
    'coverage avoids floating action tags' );
my @coverage_pins;
while ( $coverage_workflow =~ /uses:\s*(\S+)\@([^\s#]+)/g ) {
    my ( $action, $pin ) = ( $1, $2 );
    push @coverage_pins, $action;
    like( $pin, qr/\A[0-9a-f]{40}\z/,
        "coverage pins $action by full SHA" );
}
cmp_ok( scalar(@coverage_pins), '>=', 2,
    'coverage has SHA-pinned actions' );
like( $coverage_workflow, qr/workflow_run\.conclusion == 'success'/,
    'coverage only runs after passing unit tests' );
like( $coverage_workflow, qr/perl script\/coverage-gate --jobs 10/,
    'coverage enforces all metrics with ten workers' );

unlike( $unit_workflow, qr/gh\s+release\s+(?:create|upload)\b|docker\/build-push-action/,
    'the unit-test workflow does not publish releases or Docker images' );

my $property_test = _slurp( File::Spec->catfile( $ROOT, 't', '35-js-fast-check.t' ) );
like( $property_test, qr/'fuzz:scorecard'/,
    'the complete test suite retains the JavaScript property-based tests' );

done_testing();

__END__

=head1 NAME

34-scorecard-guardrails.t - guard the retained CI and release security surface

=head1 DESCRIPTION

Checks security-policy files and the two active test workflows for pinned
actions, explicit read-only permissions, timeouts and the four-metric
100 percent coverage gate following successful unit tests.

=head1 PURPOSE

Keep the reduced workflow set secure without reintroducing CodeQL, GHCR,
Dependabot automation, a standalone Test workflow, or a standalone JavaScript
fuzz workflow merely to satisfy historical Scorecard assumptions.

=head1 WHY IT EXISTS

Removing workflows changes which automated Scorecard signals exist, but the
remaining test and coverage workflows still handle quality and repository
identity. Their least-privilege and coverage properties must remain explicit.

=head1 WHEN TO USE

Run this test whenever changing F<.github/workflows/>, test or coverage
permissions, action pins, coverage gates or the decision to keep Dependabot
automation disabled.

=head1 HOW TO USE

  prove -lv t/34-scorecard-guardrails.t

=head1 WHAT USES IT

The source-tree unit-test and coverage workflows use these assertions to
guard the retained CI security surface.

=head1 EXAMPLES

Check the workflow security contract directly:

  prove -lv t/34-scorecard-guardrails.t

Run it with the full suite:

  prove -lr t

=cut
