use strict;
use warnings FATAL => 'all';

use Capture::Tiny qw(capture);
use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $repo_workflow = File::Spec->catfile( $ROOT, '.github', 'workflows', 'test.yml' );

# Detect the checkout by EXISTENCE, never by directory-ness. In the primary
# checkout .git is a directory, but in a linked git worktree it is a regular file
# holding a "gitdir:" pointer - and ticket work in this repository is done in
# per-ticket worktrees. A -d test here therefore skipped this entire file exactly
# where changes are authored, so every guardrail below (SHA pins, workflow
# permission scoping, dependency floors) was inert at the one moment it was most
# needed. An unpacked release tarball has neither shape, so the original intent -
# do not run source-tree checks against an installed dist - is unchanged.
plan skip_all => 'Scorecard guardrails are source-tree-only checks'
  if !-e File::Spec->catdir( $ROOT, '.git' ) || !-f $repo_workflow;

ok( _git_tracks('LICENSE'), 'root LICENSE is tracked for Scorecard license detection' );
ok( _git_tracks('SECURITY.md'), 'root SECURITY.md is tracked for Scorecard security-policy detection' );
ok( _git_tracks('SECURITY_CHECKS.md'), 'root SECURITY_CHECKS.md is tracked so OWASP and release audit tests read the same repo state on CI' );
ok( _git_tracks('.github/dependabot.yml'), 'Dependabot config is tracked for Scorecard dependency-update-tool detection' );
ok( _git_tracks('.github/workflows/codeql.yml'), 'CodeQL workflow is tracked for Scorecard SAST detection' );
ok( _git_tracks('.github/workflows/package-ghcr.yml'), 'GHCR packaging workflow is tracked for Scorecard packaging detection' );
ok( _git_tracks('.github/workflows/fuzz-js.yml'), 'fuzzing workflow is tracked for Scorecard fuzzing detection' );
ok( _git_tracks('.github/workflows/release-github.yml'), 'GitHub release workflow is tracked for Scorecard signed-release detection' );
ok( _git_tracks('.clusterfuzzlite/Dockerfile'), 'ClusterFuzzLite Dockerfile is tracked for Scorecard fuzzing detection' );

my $license = _slurp('LICENSE');
like( $license, qr/\AMIT License\n\nCopyright \(c\) \d{4} Developer Dashboard Contributors\n\nPermission is hereby granted, free of charge, to any person obtaining a copy/s, 'LICENSE uses the canonical MIT text that GitHub can classify' );
like( $license, qr/THE SOFTWARE IS PROVIDED "AS IS"/, 'LICENSE includes the canonical MIT warranty disclaimer' );

my $security = _slurp('SECURITY.md');
like( $security, qr/Reporting A Vulnerability/i, 'SECURITY.md documents vulnerability reporting' );
like( $security, qr/security@/i, 'SECURITY.md includes a private reporting contact' );

my $dependabot = _slurp('.github/dependabot.yml');
like( $dependabot, qr/package-ecosystem:\s*["']github-actions["']/, 'Dependabot manages GitHub Actions updates' );
like( $dependabot, qr/package-ecosystem:\s*["']npm["']/, 'Dependabot manages npm-based fuzzing dependencies' );

my $codeql = _slurp('.github/workflows/codeql.yml');
unlike( $codeql, qr/^permissions:\s*$(?:\n^[^\n]*:\s*write\s*$)+/ms, 'CodeQL workflow does not use top-level write permissions' );
like( $codeql, qr/jobs:\n\s+analyze:\n(?:.+\n)*?\s+permissions:\n(?:.+\n)*?\s+security-events:\s*write\b/ms, 'CodeQL workflow grants security-events write only at the job level' );
like( $codeql, qr/uses:\s*github\/codeql-action\/init\@[0-9a-f]{40}/, 'CodeQL init action is pinned by full SHA' );
like( $codeql, qr/uses:\s*github\/codeql-action\/analyze\@[0-9a-f]{40}/, 'CodeQL analyze action is pinned by full SHA' );

my $package_workflow = _slurp('.github/workflows/package-ghcr.yml');
unlike( $package_workflow, qr/^permissions:\s*$(?:\n^[^\n]*:\s*write\s*$)+/ms, 'packaging workflow does not use top-level write permissions' );
like( $package_workflow, qr/jobs:\n\s+package:\n(?:.+\n)*?\s+permissions:\n(?:.+\n)*?\s+packages:\s*write\b/ms, 'packaging workflow grants package publish access only at the job level' );
like( $package_workflow, qr/ghcr\.io/i, 'packaging workflow publishes to GHCR' );
like( $package_workflow, qr/uses:\s*docker\/build-push-action\@[0-9a-f]{40}/, 'docker build-push action is pinned by full SHA' );
like( $package_workflow, qr/uses:\s*docker\/login-action\@[0-9a-f]{40}/, 'docker login action is pinned by full SHA' );

# The packaging job sets FORCE_JAVASCRIPT_ACTIONS_TO_NODE24, GitHub's transitional
# shim that reroutes actions still declaring node20 onto the node24 runtime. The
# login step is the only one in the pipeline that handles registry credentials, so
# it must not owe its execution to that shim: the docker/login-action v3 line
# declares node20 while the v4 line declares node24 natively. Keep the pin on v4+,
# and keep an auditable vX.Y.Z comment beside the SHA so a reviewer can tell which
# upstream release the 40-hex pin resolves to without a network round-trip.
my ($login_pin_version) = $package_workflow =~ m{uses:\s*docker/login-action\@[0-9a-f]{40}\s+\#\s*v(\d+(?:\.\d+){2})\b};
ok( defined $login_pin_version, 'docker login action pin carries an auditable vX.Y.Z comment beside its SHA' )
  or diag('no "# vX.Y.Z" comment found beside the docker/login-action SHA pin');
cmp_ok( ( split /\./, ( $login_pin_version // '0.0.0' ) )[0],
    '>=', 4, 'docker login action is pinned on the node24-native v4 line, not the node20 v3 line' );

my $github_release_workflow = _slurp('.github/workflows/release-github.yml');
unlike( $github_release_workflow, qr/^permissions:\s*$(?:\n^[^\n]*:\s*write\s*$)+/ms, 'GitHub release workflow does not use top-level write permissions' );
like( $github_release_workflow, qr/jobs:\n\s+release:\n(?:.+\n)*?\s+permissions:\n(?:.+\n)*?\s+contents:\s*write\b/ms, 'GitHub release workflow grants release-publish access only at the job level' );
like( $github_release_workflow, qr/gh\s+release\s+create\b/, 'GitHub release workflow creates GitHub releases' );
like( $github_release_workflow, qr/gh\s+release\s+upload\b/, 'GitHub release workflow updates existing GitHub releases' );
like( $github_release_workflow, qr/cpanm\s+--notest\s+Devel::Cover\b/, 'GitHub release workflow installs Devel::Cover before it runs the numeric coverage gate' );
like( $github_release_workflow, qr/\.asc\b/, 'GitHub release workflow publishes a detached signature asset next to the release tarball' );
like( $github_release_workflow, qr/Developer-Dashboard-\*\.tar\.gz/, 'GitHub release workflow locates built distribution tarballs from the repo root' );

my $fuzz_workflow = _slurp('.github/workflows/fuzz-js.yml');
like( $fuzz_workflow, qr/fast-check/, 'fuzz workflow runs the fast-check property-based suite' );
like( $fuzz_workflow, qr/uses:\s*actions\/setup-node\@[0-9a-f]{40}/, 'setup-node action is pinned by full SHA in the fuzz workflow' );
like( $fuzz_workflow, qr/uses:\s*shogo82148\/actions-setup-perl\@[0-9a-f]{40}/, 'fuzz workflow installs Perl before invoking dashboard commands' );
like( $fuzz_workflow, qr/cpanm\s+--installdeps\s+--notest\s+\./, 'fuzz workflow installs the repo Perl runtime prerequisites' );

my $clusterfuzz = _slurp('.clusterfuzzlite/Dockerfile');
like( $clusterfuzz, qr/\AFROM\s+ubuntu:24\.04\@sha256:/, 'ClusterFuzzLite Dockerfile pins its base image by digest' );
like( $clusterfuzz, qr/\bcpanm\b/, 'ClusterFuzzLite Dockerfile provisions the Perl fuzz runner stack' );

my $package_json = _slurp('package.json');
like( $package_json, qr/"fast-check"\s*:/, 'package.json declares fast-check for fuzz/property testing' );

my $package_lock = _slurp('package-lock.json');
like( $package_lock, qr/"fast-check"/, 'package-lock.json locks the fast-check dependency' );

# fast-check is the whole of the project's property-based fuzzing, so Scorecard's
# Fuzzing signal rests on it staying a maintained dependency rather than merely a
# declared one. Upstream ended the 3.x line at 3.23.2 and ships only 4.x, so a
# range still floored on 3 pins the one fuzz gate to an abandoned major and makes
# the weekly Dependabot npm update a permanent no-op nobody drains. Keep both the
# declared range and the resolved lock entry on 4+, and keep them on the SAME
# major: a range that says 4 over a lock that resolves 3 would let `npm ci` - the
# command both CI and the fuzz test actually run - install the abandoned line
# while the manifest reads as current.
my ($declared_fast_check) = $package_json =~ m{"fast-check"\s*:\s*"[^\d]*(\d+)};
ok( defined $declared_fast_check, 'package.json fast-check range states a major version' )
  or diag('no numeric major found in the package.json fast-check range');
cmp_ok( $declared_fast_check // 0,
    '>=', 4, 'package.json floors fast-check on the maintained 4.x line, not the abandoned 3.x line' );

my ($locked_fast_check) =
  $package_lock =~ m{"node_modules/fast-check"\s*:\s*\{[^{}]*?"version"\s*:\s*"(\d+)};
ok( defined $locked_fast_check, 'package-lock.json records a resolved fast-check version' )
  or diag('no resolved version found for the node_modules/fast-check lock entry');
is( $locked_fast_check, $declared_fast_check,
    'package-lock.json resolves fast-check on the same major the manifest declares' );

for my $workflow (
    qw(
    .github/workflows/test.yml
    .github/workflows/release-cpan.yml
    .github/workflows/codeql.yml
    .github/workflows/package-ghcr.yml
    .github/workflows/fuzz-js.yml
    .github/workflows/release-github.yml
    )
  )
{
    my $text = _slurp($workflow);
    like( $text, qr/^permissions:\s*$/m, "$workflow declares an explicit permissions block" );
    like( $text, qr/^concurrency:\s*$/m, "$workflow declares an explicit concurrency block" );
    like( $text, qr/^\s*timeout-minutes:\s*\d+\s*$/m, "$workflow sets an explicit timeout to avoid hung jobs" );
    unlike( $text, qr/uses:\s*[^@\s]+\@[Vv]?\d+(?:\.\d+)*(?:\s|$)/, "$workflow does not use floating action tags" );
    unlike( $text, qr/curl\s+-L\s+https:\/\/cpanmin\.us\s*\|\s*perl/, "$workflow does not install cpanm via curl pipe" );
}

my $release_cpan_workflow = _slurp('.github/workflows/release-cpan.yml');
like( $release_cpan_workflow, qr/Developer-Dashboard-\*\.tar\.gz/, 'PAUSE release workflow locates dzil tarballs from the repo root instead of a nonexistent .build tree' );
unlike( $release_cpan_workflow, qr/\.build\/\*\.tar\.gz/, 'PAUSE release workflow no longer looks for tarballs under a nonexistent .build directory' );
like(
    $release_cpan_workflow,
    qr/check-all-metric-coverage/,
    'PAUSE release workflow enforces the same all-metric lib coverage gate as the main CI workflow',
);

for my $coverage_workflow (
    qw(
    .github/workflows/test.yml
    .github/workflows/release-cpan.yml
    .github/workflows/release-github.yml
    )
  )
{
    my $text = _slurp($coverage_workflow);
    like(
        $text,
        qr/-coverage statement -coverage branch -coverage condition -coverage subroutine[^\n]*\n[^\n]*check-all-metric-coverage/s,
        "$coverage_workflow pipes the four-metric cover report through the coverage gate script",
    );
    unlike(
        $text,
        qr/grep [-A-Za-z]+ ['"]\^?Total/,
        "$coverage_workflow does not gate coverage on a brittle Total-line grep",
    );
}

my $blank_env_dockerfile = _slurp('integration/blank-env/Dockerfile');
like(
    $blank_env_dockerfile,
    qr/\AFROM\s+perl:5\.44-bookworm\@sha256:[0-9a-f]{64}\b/,
    'blank-env Dockerfile pins the Debian perl:5.44-bookworm base image by digest for dependency hygiene',
);

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

=for comment FULL-POD-DOC START

=head1 PURPOSE

This test is the executable regression contract for the repository-side Scorecard and workflow guardrails. Read it when you need to understand the real fixture setup, assertions, and failure modes for this slice of the repository instead of guessing from the module names alone.

=head1 WHY IT EXISTS

It exists because the repository-side Scorecard and workflow guardrails has enough moving parts that a code-only review can miss real regressions. Keeping those expectations in a dedicated test file makes the TDD loop, coverage loop, and release gate concrete.

=head1 WHEN TO USE

Use this file when changing the repository-side Scorecard and workflow guardrails, when a focused CI failure points here, or when you want a faster regression loop than running the entire suite.

=head1 HOW TO USE

Run it directly with C<prove -lv t/34-scorecard-guardrails.t> while iterating, then keep it green under C<prove -lr t> and the coverage runs before release. 

=head1 WHAT USES IT

Developers during TDD, the full C<prove -lr t> suite, the coverage gates, and the release verification loop all rely on this file to keep this behavior from drifting.

=head1 EXAMPLES

Example 1:

  prove -lv t/34-scorecard-guardrails.t

Run the focused regression test by itself while you are changing the behavior it owns.

Example 2:

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lv t/34-scorecard-guardrails.t

Exercise the same focused test while collecting coverage for the library code it reaches.

Example 3:

  prove -lr t

Put the focused fix back through the whole repository suite before calling the work finished.

=for comment FULL-POD-DOC END

=cut
