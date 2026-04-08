use strict;
use warnings FATAL => 'all';

use Capture::Tiny qw(capture);
use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $repo_workflow = File::Spec->catfile( $ROOT, '.github', 'workflows', 'test.yml' );

plan skip_all => 'Scorecard guardrails are source-tree-only checks'
  if !-d File::Spec->catdir( $ROOT, '.git' ) || !-f $repo_workflow;

ok( _git_tracks('LICENSE'), 'root LICENSE is tracked for Scorecard license detection' );
ok( _git_tracks('SECURITY.md'), 'root SECURITY.md is tracked for Scorecard security-policy detection' );
ok( _git_tracks('.github/dependabot.yml'), 'Dependabot config is tracked for Scorecard dependency-update-tool detection' );
ok( _git_tracks('.github/workflows/codeql.yml'), 'CodeQL workflow is tracked for Scorecard SAST detection' );
ok( _git_tracks('.github/workflows/package-ghcr.yml'), 'GHCR packaging workflow is tracked for Scorecard packaging detection' );
ok( _git_tracks('.github/workflows/github-release.yml'), 'GitHub release workflow is tracked for signed-release automation' );
ok( _git_tracks('.github/workflows/fuzz-js.yml'), 'fuzzing workflow is tracked for Scorecard fuzzing detection' );

my $license = _slurp('LICENSE');
like( $license, qr/Perl_5|same terms as Perl 5|Artistic License|GNU General Public License/i, 'LICENSE states the Perl 5 licensing terms' );

my $security = _slurp('SECURITY.md');
like( $security, qr/Reporting A Vulnerability/i, 'SECURITY.md documents vulnerability reporting' );
like( $security, qr/security@/i, 'SECURITY.md includes a private reporting contact' );

my $dependabot = _slurp('.github/dependabot.yml');
like( $dependabot, qr/package-ecosystem:\s*["']github-actions["']/, 'Dependabot manages GitHub Actions updates' );
like( $dependabot, qr/package-ecosystem:\s*["']npm["']/, 'Dependabot manages npm-based fuzzing dependencies' );

my $codeql = _slurp('.github/workflows/codeql.yml');
like( $codeql, qr/\bsecurity-events:\s*write\b/, 'CodeQL workflow grants security-events write permission' );
like( $codeql, qr/uses:\s*github\/codeql-action\/init\@[0-9a-f]{40}/, 'CodeQL init action is pinned by full SHA' );
like( $codeql, qr/uses:\s*github\/codeql-action\/analyze\@[0-9a-f]{40}/, 'CodeQL analyze action is pinned by full SHA' );

my $package_workflow = _slurp('.github/workflows/package-ghcr.yml');
like( $package_workflow, qr/\bpackages:\s*write\b/, 'packaging workflow can publish packages' );
like( $package_workflow, qr/ghcr\.io/i, 'packaging workflow publishes to GHCR' );
like( $package_workflow, qr/uses:\s*docker\/build-push-action\@[0-9a-f]{40}/, 'docker build-push action is pinned by full SHA' );
like( $package_workflow, qr/uses:\s*docker\/login-action\@[0-9a-f]{40}/, 'docker login action is pinned by full SHA' );

my $release_workflow = _slurp('.github/workflows/github-release.yml');
like( $release_workflow, qr/\.intoto\.jsonl/, 'release workflow publishes an intoto provenance asset for Scorecard signed-releases detection' );
like( $release_workflow, qr/Developer-Dashboard-\$\{\{\s*steps\.meta\.outputs\.version\s*\}\}\.tar\.gz/, 'release workflow uploads the distribution tarball asset' );
like( $release_workflow, qr/\bcontents:\s*write\b/, 'release workflow can publish GitHub releases' );

my $fuzz_workflow = _slurp('.github/workflows/fuzz-js.yml');
like( $fuzz_workflow, qr/fast-check/, 'fuzz workflow runs the fast-check property-based suite' );
like( $fuzz_workflow, qr/uses:\s*actions\/setup-node\@[0-9a-f]{40}/, 'setup-node action is pinned by full SHA in the fuzz workflow' );

my $package_json = _slurp('package.json');
like( $package_json, qr/"fast-check"\s*:/, 'package.json declares fast-check for fuzz/property testing' );

my $package_lock = _slurp('package-lock.json');
like( $package_lock, qr/"fast-check"/, 'package-lock.json locks the fast-check dependency' );

for my $workflow (
    qw(
    .github/workflows/test.yml
    .github/workflows/release-cpan.yml
    .github/workflows/codeql.yml
    .github/workflows/package-ghcr.yml
    .github/workflows/github-release.yml
    .github/workflows/fuzz-js.yml
    )
  )
{
    my $text = _slurp($workflow);
    like( $text, qr/^permissions:\s*$/m, "$workflow declares an explicit permissions block" );
    unlike( $text, qr/uses:\s*[^@\s]+\@[Vv]?\d+(?:\.\d+)*(?:\s|$)/, "$workflow does not use floating action tags" );
    unlike( $text, qr/curl\s+-L\s+https:\/\/cpanmin\.us\s*\|\s*perl/, "$workflow does not install cpanm via curl pipe" );
}

done_testing;

sub _git_tracks {
    my ($path) = @_;
    my ( $stdout, $stderr, $exit ) = capture {
        system( 'git', '-C', $ROOT, 'ls-files', '--error-unmatch', $path );
    };
    return $exit == 0;
}

sub _slurp {
    my ($relative_path) = @_;
    my $path = File::Spec->catfile( $ROOT, split m{/}, $relative_path );
    open my $fh, '<:raw', $path or die "Unable to read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $text;
}

__END__

=pod

=head1 NAME

t/34-scorecard-guardrails.t - enforce repository-side Scorecard guardrails

=head1 PURPOSE

This test locks in the repository files and workflow structure that are meant
to satisfy the repo-fixable OpenSSF Scorecard checks.

=head1 WHY IT EXISTS

The repository now treats Scorecard as a delivery gate. This test keeps the
basic guardrails from drifting: tracked policy files, update tooling, SAST,
packaging/signing workflow presence, fuzzing signal, pinned action SHAs, and
explicit workflow permissions.

=head1 WHEN TO USE

Run this test whenever repository metadata, GitHub workflows, packaging
automation, or Scorecard-related policy files change.

=head1 HOW TO USE

Run it directly:

  prove -lv t/34-scorecard-guardrails.t

It also runs as part of the normal C<prove -lr t> suite.

=head1 WHAT USES IT

Release verification, local TDD while hardening Scorecard findings, and future
contributors who need a fast failure when a Scorecard guardrail drifts.

=head1 EXAMPLES

  prove -lv t/34-scorecard-guardrails.t

  prove -lr t

The first command checks only the Scorecard guardrails. The second command
includes those checks in the full repository test suite.

=cut
