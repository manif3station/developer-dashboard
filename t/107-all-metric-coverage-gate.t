use strict;
use warnings;

use Capture::Tiny qw(capture);
use File::Spec;
use Test::More;

my $gate = File::Spec->catfile( 'script', 'check-all-metric-coverage' );

sub run_gate {
    my ($report) = @_;
    my ( $stdout, $stderr, $exit );
    ( $stdout, $stderr ) = capture {
        open my $input, '|-', $^X, $gate or die "cannot run $gate: $!";
        print {$input} $report;
        close $input;
        $exit = $? >> 8;
    };
    return ( $exit, $stdout, $stderr );
}

# Feature: enforce all four lib coverage metrics.
# Scenario: reject a report whose branch total is below 100.
# Given a Devel::Cover text report with statement, subroutine, and condition at
# 100 but branch at 99.9, when the coverage gate checks the report, then it
# exits nonzero and identifies the failing branch metric.
{
    my ( $exit, $stdout, $stderr ) = run_gate(<<'REPORT');
File              stmt   branch   cond    sub
Total            100.0     99.9  100.0  100.0
REPORT

    isnt( $exit, 0, 'coverage gate rejects a branch total below 100' );
    like( $stderr, qr/branch.*99\.9/i, 'coverage gate identifies the failing branch total' );
    unlike( $stdout, qr/coverage gate:/, 'failed coverage gate emits no success message' );
}

# Scenario: parse the abbreviated columns emitted by Devel::Cover 1.52.
# Given its real header and aggregate total column, when checked, then the
# aggregate is ignored and the four required metrics are enforced by name.
{
    my ( $exit, $stdout, $stderr ) = run_gate(<<'REPORT');
File              stmt   bran   cond    sub  total
Total            100.0  100.0  100.0  100.0  100.0
REPORT

    is( $exit, 0, 'coverage gate accepts the Devel::Cover 1.52 report shape' );
    like( $stdout, qr/coverage gate:/, 'real report shape emits the success message' );
    is( $stderr, '', 'real report shape emits no error output' );
}

# Scenario: accept a report only when all four totals equal 100.0.
# Given exact 100.0 totals, when checked, then the gate succeeds and names all
# four enforced metrics.
{
    my ( $exit, $stdout, $stderr ) = run_gate(<<'REPORT');
File              stmt   branch   cond    sub
Total            100.0    100.0  100.0  100.0
REPORT

    is( $exit, 0, 'coverage gate accepts exact 100 totals for all four metrics' );
    like( $stdout, qr/statement.*branch.*condition.*subroutine/i, 'success names all four enforced metrics' );
    is( $stderr, '', 'successful coverage gate emits no error output' );
}

# Scenario: reject a malformed report instead of silently passing it.
# Given no parseable Total row, when checked, then the gate fails closed.
{
    my ( $exit, $stdout, $stderr ) = run_gate("File stmt branch cond sub\n");

    isnt( $exit, 0, 'coverage gate rejects a report with no Total row' );
    like( $stderr, qr/missing Total row/i, 'malformed report explains the missing Total row' );
    unlike( $stdout, qr/coverage gate:/, 'malformed report emits no success message' );
}

# Scenario: reject reports that omit an enforced metric.
# Given a report without branch and condition columns, when checked, then the
# gate fails closed rather than treating the three displayed 100s as complete.
{
    my ( $exit, $stdout, $stderr ) = run_gate(<<'REPORT');
File              stmt    sub
Total            100.0  100.0
REPORT

    isnt( $exit, 0, 'coverage gate rejects a report missing enforced metrics' );
    like( $stderr, qr/(?:missing metrics: branch, condition|duplicate or unknown metric columns)/i, 'missing metrics are identified' );
    unlike( $stdout, qr/coverage gate:/, 'incomplete report emits no success message' );
}

# Scenario: reject malformed numeric fields instead of extracting 100 from them.
# Given signed or suffixed values and unexplained extra fields, when checked,
# then the gate rejects each report without emitting a success message.
for my $case (
    [ 'signed totals', "File stmt bran cond sub total\nTotal -100.0 -100.0 -100.0 -100.0 -100.0\n" ],
    [ 'suffixed total', "File stmt bran cond sub total\nTotal 100.0x 100.0 100.0 100.0 100.0\n" ],
    [ 'unexplained extra value', "File stmt bran cond sub\nTotal 100.0 100.0 100.0 100.0 100.0\n" ],
) {
    my ( $label, $report ) = @{$case};
    my ( $exit, $stdout, $stderr ) = run_gate($report);
    isnt( $exit, 0, "coverage gate rejects $label" );
    like( $stderr, qr/coverage gate:/i, "$label produces a gate diagnostic" );
    unlike( $stdout, qr/coverage gate:/, "$label emits no success message" );
}

# Scenario: contributor guidance documents all four required metrics.
# Given the shipped contribution guide, when its coverage rule is inspected,
# then it names statement, subroutine, branch, and condition explicitly.
{
    my $guide = File::Spec->catfile('CONTRIBUTING.pod');
    open my $handle, '<', $guide or die "cannot read $guide: $!";
    my $body = do { local $/; <$handle> };
    close $handle or die "cannot close $guide: $!";

    like(
        $body,
        qr/100 percent statement, subroutine, branch,\s+and condition coverage/,
        'contributor guide documents all four mandatory metrics',
    );
}

# Scenario: every CI path collects and checks all four required metrics.
# Given the repository test and release workflows, when their coverage steps
# are inspected, then every report command requests every metric and pipes its
# output through this fail-closed gate.
for my $workflow_name (qw(test.yml release-cpan.yml release-github.yml)) {
    my $workflow = File::Spec->catfile( '.github', 'workflows', $workflow_name );
    open my $handle, '<', $workflow or die "cannot read $workflow: $!";
    my $body = do { local $/; <$handle> };
    close $handle or die "cannot close $workflow: $!";

    like(
        $body,
        qr/cover -report text -select_re '\^lib\/' -coverage statement -coverage branch -coverage condition -coverage subroutine/,
        "$workflow_name coverage report requests all four metrics",
    );
    like(
        $body,
        qr/\| perl script\/check-all-metric-coverage/,
        "$workflow_name sends the report through the enforcing coverage gate",
    );
}

done_testing;

__END__

=pod

=head1 NAME

t/107-all-metric-coverage-gate.t - acceptance contract for the all-metric coverage gate

=head1 PURPOSE

This test verifies that the repository coverage gate accepts only a
Devel::Cover report whose C<lib/> Total row is 100.0 for statement,
subroutine, branch, and condition coverage. It also verifies that missing,
malformed, or below-target reports fail closed and that CI invokes the gate.

=head1 WHY IT EXISTS

The previous CI check requested only statement and subroutine coverage, so
branch and condition regressions could pass. These executable BDD scenarios
prevent the repository workflow and parser from weakening that contract.

=head1 WHEN TO USE

Use this test when changing the coverage workflow, the coverage-report parser,
or the mandatory all-four-metric quality gate.

=head1 HOW TO USE

Run C<prove -lv t/107-all-metric-coverage-gate.t> while iterating, then run
C<prove -lr t> and the live Devel::Cover command before integration.

=head1 WHAT USES IT

Developers, the full Perl test suite, and GitHub Actions use this acceptance
test to keep coverage enforcement at 100.0 for every required metric.

=head1 EXAMPLES

Example 1:

  prove -lv t/107-all-metric-coverage-gate.t

Run the focused acceptance scenarios.

Example 2:

  cover -report text -select_re '^lib/' \
    -coverage statement -coverage branch \
    -coverage condition -coverage subroutine \
    | perl script/check-all-metric-coverage

Verify a collected coverage database using the same gate as CI.

=cut
