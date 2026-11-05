use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;
use YAML::XS ();

my $root = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $dir = File::Spec->catdir( $root, '.github', 'workflows' );

plan skip_all => 'workflow YAML files are excluded from built distributions'
  if !-d $dir;

opendir my $fh, $dir or die "Unable to read $dir: $!";
my @files = sort grep { /\.ya?ml\z/ && -f File::Spec->catfile( $dir, $_ ) } readdir $fh;
closedir $fh or die "Unable to close $dir: $!";

is_deeply(
  \@files,
  ['macos-arm64-unit-tests.yml', 'test-coverage.yml', 'unit-tests.yml',
   'windows-amd64-unit-tests.yml'],
  'the Linux, coverage, macOS arm64 and Windows amd64 workflows are active'
);

my $path = File::Spec->catfile( $dir, 'unit-tests.yml' );
my $workflow = YAML::XS::LoadFile($path);
my ($events) = grep { ref $_ eq 'HASH' }
  map { $workflow->{$_} } grep { /\A(?:on|true|1)\z/ } keys %$workflow;

ok( ref($events) eq 'HASH', 'GitHub Actions trigger definitions are present' );
is_deeply( $events->{push}{branches}, ['master'], 'push runs on master only' );
ok( exists $events->{pull_request}, 'pull requests run the tests' );
ok( exists $events->{workflow_dispatch}, 'manual test runs are available' );

is_deeply( [ sort keys %{ $workflow->{jobs} || {} } ], ['coverage-pr', 'macos-arm64-pr', 'unit-tests', 'windows-amd64-pr'],
  'the workflow enforces the four-stage PR chain' );
my $macos_pr_job = $workflow->{jobs}{'macos-arm64-pr'} || {};
is( $macos_pr_job->{needs}, 'coverage-pr',
  'macOS PR tests wait for 100% coverage' );
my $coverage_pr = $workflow->{jobs}{'coverage-pr'} || {};
is( $coverage_pr->{needs}, 'unit-tests', 'coverage follows Linux tests' );
is( $coverage_pr->{uses}, './.github/workflows/test-coverage.yml',
  'coverage PR job invokes the existing gate' );
my $windows_pr = $workflow->{jobs}{'windows-amd64-pr'} || {};
is( $windows_pr->{needs}, 'macos-arm64-pr',
  'Windows PR tests wait for macOS success' );
like( $windows_pr->{if} // '', qr/github\.event_name\s*==\s*'pull_request'/,
  'Windows PR job is restricted to pull requests' );
like( $windows_pr->{if} // '', qr/github\.event_name\s*==\s*'workflow_dispatch'/,
  'Windows PR job is available for manual ordered test runs' );
is( $windows_pr->{uses}, './.github/workflows/windows-amd64-unit-tests.yml',
  'Windows PR job invokes the dedicated workflow' );
like( $macos_pr_job->{if} // '', qr/github\.event_name\s*==\s*'pull_request'/,
  'the reusable macOS job runs during PR validation' );
like( $macos_pr_job->{if} // '', qr/github\.event_name\s*==\s*'workflow_dispatch'/,
  'manual dispatch also waits for Linux validation' );
is( $macos_pr_job->{uses}, './.github/workflows/macos-arm64-unit-tests.yml',
  'macOS PR tests call the dedicated reusable workflow' );
is( $macos_pr_job->{permissions}{contents}, 'read',
  'macOS PR tests inherit only read-only repository permissions' );
my $job = $workflow->{jobs}{'unit-tests'};
is( $job->{'runs-on'}, 'ubuntu-latest', 'unit suite runs on Ubuntu' );

my @steps = @{ $job->{steps} || [] };
my ($checkout) = grep { ($_->{name} // '') eq 'Checkout' } @steps;
like( $checkout->{uses} // '', qr{\Aactions/checkout\@[0-9a-f]{40}\z},
  'checkout action is pinned by SHA' );
my ($perl) = grep { ($_->{name} // '') eq 'Set up Perl' } @steps;
is( $perl->{with}{'perl-version'}, '5.44', 'CI selects Perl 5.44' );
ok( $perl->{with}{'multi-thread'}, 'Perl is built with threads for native XS' );

my ($deps) = grep { ($_->{name} // '') eq 'Install Perl dependencies' } @steps;
like( $deps->{run} // '', qr/cpanm --installdeps --notest -L local \./,
  'dependencies install into an isolated local tree' );
my ($build) = grep { ($_->{name} // '') eq 'Build native XS extension' } @steps;
like( $build->{run} // '', qr/perl Makefile\.PL.*\bmake\b/s,
  'XS is compiled before the suite' );
my ($unit) = grep { ($_->{name} // '') eq 'Run all unit tests (10 parallel workers)' } @steps;
like( $unit->{run} // '', qr/\bprove -j 10\b.*-Iblib\/arch -Iblib\/lib -lr t\b/s,
  'the entire t/ suite runs with prove -j 10 and built XS paths' );
like( $unit->{run} // '', qr/--rules='seq=t\/05-cli-smoke\.t'/,
  'the CLI smoke test runs outside concurrent test workers' );
like( $unit->{run} // '', qr/--rules='seq=t\/09-runtime-manager\.t'/,
  'the server lifecycle test runs outside concurrent test workers' );
like( $unit->{run} // '', qr/--rules='seq=t\/15-release-metadata\.t'/,
  'the release metadata test runs outside concurrent test workers' );
like( $unit->{run} // '', qr/--rules='par=\*\*'/,
  'the rest of the suite retains ten-way parallel scheduling' );
like( $unit->{run} // '', qr/seq=t\/148-coverage-gate-entrypoint\.t/,
  'Linux isolates the entrypoint fixture from parallel source mutations' );
like( $unit->{run} // '', qr/seq=t\/149-coverage-gate-moving-target\.t/,
  'Linux serialises the deliberately source-mutating test' );
like( $unit->{run} // '', qr/PERL5LIB=.*blib\/arch.*blib\/lib.*\$local_lib/s,
  'test subprocesses see the native build and local dependencies' );


my $coverage_path = File::Spec->catfile( $dir, 'test-coverage.yml' );
my $coverage = YAML::XS::LoadFile($coverage_path);
my ($coverage_events) = grep { ref $_ eq 'HASH' }
  map { $coverage->{$_} } grep { /\A(?:on|true|1)\z/ } keys %$coverage;
is_deeply( [ sort keys %{$coverage_events} ], ['workflow_call', 'workflow_run'],
  'coverage supports ordered PR calls and post-unit master runs' );
is_deeply( $coverage_events->{workflow_run}{workflows}, ['Unit Tests'],
  'coverage runs only after the named unit-test workflow' );
is_deeply( $coverage_events->{workflow_run}{types}, ['completed'],
  'coverage only reacts to completed upstream runs' );
is_deeply( [ sort keys %{ $coverage->{jobs} || {} } ], ['coverage'],
  'coverage defines one dedicated job' );
my $coverage_job = $coverage->{jobs}{coverage};
like( $coverage_job->{if} // '', qr/workflow_run\.conclusion\s*==\s*'success'/,
  'coverage job skips failed and cancelled upstream tests' );
is( $coverage->{permissions}{contents}, 'read',
  'coverage has read-only repository permissions' );
my @coverage_steps = @{ $coverage_job->{steps} || [] };
my ($coverage_checkout) = grep { ($_->{name} // '') eq 'Checkout tested revision' } @coverage_steps;
like( $coverage_checkout->{with}{ref} // '', qr/workflow_run\.head_sha/,
  'coverage checks out the revision from the upstream test run' );
like( $coverage_checkout->{with}{repository} // '', qr/github\.repository/,
  'coverage checks out only the trusted base repository' );
ok( !$coverage_checkout->{with}{'persist-credentials'},
  'coverage does not persist credentials in checked-out source' );
my ($coverage_perl) = grep { ($_->{name} // '') eq 'Set up Perl' } @coverage_steps;
is( $coverage_perl->{with}{'perl-version'}, '5.44', 'coverage selects Perl 5.44' );
ok( $coverage_perl->{with}{'multi-thread'}, 'coverage Perl supports native threads' );
my ($coverage_dep) = grep { ($_->{name} // '') eq 'Install Devel::Cover' } @coverage_steps;
like( $coverage_dep->{run} // '', qr/cpanm --notest -L local Devel::Cover/,
  'coverage explicitly installs instrumentation' );
my ($coverage_build) = grep { ($_->{name} // '') eq 'Build native XS extension' } @coverage_steps;
like( $coverage_build->{run} // '', qr/perl Makefile\.PL.*\bmake\b/s,
  'coverage builds the native XS extension' );
my ($coverage_gate) = grep {
  ($_->{name} // '') eq 'Require 100% statement, branch, condition, and subroutine coverage'
} @coverage_steps;
like( $coverage_gate->{run} // '', qr/perl script\/coverage-gate --jobs 10/,
  'coverage uses the canonical all-metric gate with ten workers' );
like( $coverage_gate->{run} // '', qr/PERL5LIB=.*blib\/arch.*\$local_lib/s,
  'coverage loads compiled XS objects and local dependencies' );
unlike( $coverage_gate->{run} // '', qr/\$GITHUB_WORKSPACE\/blib\/lib:/,
  'coverage does not re-instrument compiled copies of the source Perl modules' );


my $macos_path = File::Spec->catfile( $dir, 'macos-arm64-unit-tests.yml' );
my $macos = YAML::XS::LoadFile($macos_path);
my ($macos_events) = grep { ref $_ eq 'HASH' }
  map { $macos->{$_} } grep { /\A(?:on|true|1)\z/ } keys %$macos;
ok( ref($macos_events) eq 'HASH', 'macOS workflow has GitHub Actions triggers' );
my $macos_trigger = ref($macos_events) eq 'HASH' ? $macos_events : {};
is_deeply( [ sort keys %$macos_trigger ], ['workflow_call', 'workflow_run'],
  'macOS supports ordered PR calls and post-coverage master runs' );
my $macos_run = ref($macos_trigger->{workflow_run}) eq 'HASH'
  ? $macos_trigger->{workflow_run} : {};
is_deeply( $macos_run->{workflows}, ['Test Coverage'],
  'macOS waits for the existing coverage workflow' );
is_deeply( $macos_run->{branches}, ['master'],
  'post-unit macOS execution is restricted to master' );
is_deeply( $macos_run->{types}, ['completed'],
  'macOS only triggers after the Linux workflow completes' );
is( $macos->{permissions}{contents}, 'read',
  'macOS does not need write permissions on upstream completion' );
is_deeply( [ sort keys %{ $macos->{jobs} || {} } ], ['macos-arm64'],
  'macOS workflow has one dedicated arm64 job' );
my $macos_job = $macos->{jobs}{'macos-arm64'} || {};
like( $macos_job->{if} // '',
  qr/workflow_run\.conclusion\s*==\s*'success'/,
  'post-coverage macOS run requires successful coverage' );
like( $macos_job->{if} // '', qr/workflow_run\.event\s*==\s*'workflow_run'/,
  'post-coverage macOS run only follows the coverage workflow' );
like( $macos_job->{if} // '', qr/workflow_run\.head_repository\.full_name\s*==\s*github\.repository/,
  'post-coverage macOS run never executes code from forked repositories' );
like( $macos_job->{if} // '', qr/github\.event_name\s*!=\s*'workflow_run'/,
  'reusable macOS PR runs are permitted by the job gate' );
like( $macos_job->{if} // '',
  qr/startsWith\(github\.workflow_ref,\s*'manif3station\/developer-dashboard\/\.github\/workflows\/unit-tests\.yml\@'/,
  'macOS reusable calls require the exact Linux Unit Tests workflow file' );
like( $macos_job->{if} // '',
  qr/github\.repository\s*==\s*'manif3station\/developer-dashboard'/,
  'macOS rejects fork repositories even for reusable calls' );
is( $macos_job->{'runs-on'}, 'macos-15',
  'macOS selects the hosted Apple Silicon runner' );

my @macos_steps = @{ $macos_job->{steps} || [] };
my $step_budget = 0;
$step_budget += ($_->{'timeout-minutes'} // 0) for @macos_steps;
cmp_ok( $macos_job->{'timeout-minutes'} // 0, '>=', $step_budget,
  'macOS overall timeout accommodates all individual step timeouts' );

# Return an empty hash after a missing-step assertion, so broken YAML produces
# a useful TAP failure instead of a fatal undef dereference.
sub find_macos_step {
  my ( $steps, $name ) = @_;
  my ($step) = grep { ref($_) eq 'HASH' && ($_->{name} // '') eq $name }
    @$steps;
  ok( defined $step, "macOS step $name is present" );
  return $step || {};
}

my $macos_checkout = find_macos_step( \@macos_steps, 'Checkout' );
like( $macos_checkout->{uses} // '', qr{\Aactions/checkout\@[0-9a-f]{40}\z},
  'macOS checkout action is pinned by SHA' );
is( $macos_checkout->{with}{repository}, '${{ github.repository }}',
  'macOS always checks out the trusted base repository' );
my $macos_trust = find_macos_step( \@macos_steps, 'Verify trusted upstream' );
like( $macos_trust->{run} // '', qr/UPSTREAM_REPOSITORY.*GITHUB_REPOSITORY/s,
  'post-unit macOS checkout rejects an untrusted upstream' );
like( $macos_checkout->{with}{ref} // '', qr/workflow_run\.head_sha/,
  'post-coverage macOS runs check out the exact upstream commit' );
like( $macos_checkout->{with}{ref} // '', qr/github\.sha/,
  'reusable macOS PR runs check out the same revision as Linux' );
ok( !$macos_checkout->{with}{'persist-credentials'},
  'macOS checkout does not persist credentials from workflow_run' );
my $macos_tmp = find_macos_step( \@macos_steps, 'Use unaliased temporary directory' );
like( $macos_tmp->{run} // '', qr/RUNNER_TEMP\/perl-test-tmp/,
  'macOS avoids the /var and /private/var temporary path alias' );
my $macos_arch = find_macos_step( \@macos_steps, 'Verify Apple Silicon runner' );
like( $macos_arch->{run} // '', qr/uname -m.*arm64/s,
  'macOS runner is checked for arm64 architecture' );
my $macos_perl = find_macos_step( \@macos_steps, 'Set up Perl' );
is( $macos_perl->{with}{'perl-version'}, '5.44',
  'macOS matches the supported Linux Perl version' );
ok( $macos_perl->{with}{'multi-thread'},
  'macOS Perl has threads for native XS' );
my $macos_node = find_macos_step( \@macos_steps, 'Set up Node for test suite' );
is( $macos_node->{with}{cache}, 'npm',
  'macOS reuses the npm dependency cache like Linux' );
my $macos_deps = find_macos_step( \@macos_steps, 'Install Perl dependencies' );
like( $macos_deps->{run} // '', qr/cpanm --installdeps --notest -L local \./,
  'macOS installs the full local Perl dependency set' );
my $macos_native = find_macos_step( \@macos_steps, 'Install native build dependencies' );
like( $macos_native->{run} // '', qr/brew install coreutils\b/,
  'macOS provides the GNU timeout utility via Homebrew coreutils' );
my $macos_build = find_macos_step( \@macos_steps, 'Build native XS extension' );
like( $macos_build->{run} // '', qr/perl Makefile\.PL.*\bmake\b/s,
  'macOS builds the XS extension before running tests' );
my $macos_test =
  find_macos_step( \@macos_steps, 'Run all unit tests (10 parallel workers)' );
like( $macos_test->{run} // '',
  qr/\bprove -j 10\b.*-Iblib\/arch -Iblib\/lib -lr t\b/s,
  'macOS runs the full suite with ten parallel TAP workers' );
like( $macos_test->{run} // '',
  qr/gtimeout --signal=TERM --kill-after=30s 900s prove -j 10/,
  'macOS bounds the whole prove suite with graceful termination' );
like( $macos_test->{run} // '', qr/--rules='seq=t\/05-cli-smoke\.t'/,
  'macOS preserves serial execution for the CLI smoke test' );
like( $macos_test->{run} // '', qr/--rules='seq=t\/09-runtime-manager\.t'/,
  'macOS preserves serial execution for the server lifecycle test' );
like( $macos_test->{run} // '', qr/--rules='seq=t\/15-release-metadata\.t'/,
  'macOS preserves serial execution for the release metadata test' );
like( $macos_test->{run} // '', qr/BASH_ENV.*perl-ci-bashenv/s,
  'nested Bash shells inherit the same Perl used to compile XS' );
like( $macos_test->{run} // '', qr/printf '%q' "\$perl_bin"/,
  'the Perl bin directory is safely escaped in the Bash environment' );
like( $macos_test->{run} // '', qr/--rules='par=\*\*'/,
  'macOS retains parallel scheduling for the remaining tests' );
like( $macos_test->{run} // '', qr/seq=t\/149-coverage-gate-moving-target\.t/,
  'macOS isolates the source-mutation regression' );
like( $macos_test->{run} // '',
  qr/PERL5LIB=.*blib\/arch.*blib\/lib.*\$local_lib/s,
  'macOS test subprocesses see the XS build and local dependencies' );


my $windows_path = File::Spec->catfile( $dir, 'windows-amd64-unit-tests.yml' );
my $windows = YAML::XS::LoadFile($windows_path);
my ($windows_events) = grep { ref $_ eq 'HASH' }
  map { $windows->{$_} } grep { /\A(?:on|true|1)\z/ } keys %$windows;
is_deeply( [ sort keys %{$windows_events || {}} ], ['workflow_call', 'workflow_run'],
  'Windows supports reusable PR calls and post-macOS master runs' );
is_deeply( $windows_events->{workflow_run}{workflows}, ['macOS arm64 Unit Tests'],
  'Windows waits for successful macOS tests' );
is_deeply( $windows_events->{workflow_run}{branches}, ['master'],
  'Windows post-macOS trigger is master only' );
is( $windows->{permissions}{contents}, 'read',
  'Windows uses read-only repository permissions' );
my $windows_job = $windows->{jobs}{'windows-amd64'} || {};
is( $windows_job->{'runs-on'}, 'windows-latest', 'Windows uses amd64 host' );
like( $windows_job->{if} // '', qr/workflow_run\.conclusion\s*==\s*'success'/,
  'Windows requires successful macOS completion' );
like( $windows_job->{if} // '', qr/workflow_run\.head_repository\.full_name/,
  'Windows rejects forked upstreams' );
my @windows_steps = @{ $windows_job->{steps} || [] };
my ($arch_step) = grep { ($_->{name} // '') eq 'Verify Windows amd64 runner' }
  @windows_steps;
like( $arch_step->{run} // '', qr/RUNNER_ARCH.*X64/s,
  'Windows asserts the real runner architecture' );
my ($bootstrap_step) = grep { ($_->{name} // '') eq 'Install pinned Strawberry Perl' }
  @windows_steps;
like( $bootstrap_step->{run} // '', qr/Get-FileHash.*SHA256/s,
  'Windows verifies its pinned Strawberry Perl archive' );
like( $bootstrap_step->{run} // '', qr/cpanm\.Source\.StartsWith/,
  'Windows verifies cpanm belongs to pinned Strawberry Perl' );
my ($expected_sha) = ($bootstrap_step->{run} // '') =~
  /\$expectedSha256 = '([0-9a-f]+)'/;
is( length($expected_sha // ''), 64,
  'Windows pinned SHA256 has exactly 64 hexadecimal digits' );
my ($windows_build) = grep { ($_->{name} // '') eq 'Build native XS extension' }
  @windows_steps;
like( $windows_build->{run} // '', qr/perl Makefile\.PL.*gmake/s,
  'Windows builds the native XS before testing' );
my ($windows_suite) = grep { ($_->{name} // '') eq 'Run all unit tests (10 parallel workers)' }
  @windows_steps;
like( $windows_suite->{run} // '',
  qr/App::Prove.*--\s+-j 10\b.*-Iblib\/arch -Iblib\/lib -lr t\b/s,
  'Windows invokes the full prove suite with ten workers' );
like( $windows_suite->{run} // '', qr/--rules=seq=t\/05-cli-smoke\.t/,
  'Windows preserves serialised CLI smoke tests' );
like( $windows_suite->{run} // '', qr/--rules=seq=t\/149-coverage-gate-moving-target\.t/,
  'Windows serialises the source-mutation regression' );

my $coverage_gate_script = File::Spec->catfile( $root, 'script', 'coverage-gate' );
open my $coverage_gate_fh, '<', $coverage_gate_script
  or die "Unable to read $coverage_gate_script: $!";
my $coverage_gate_text = do { local $/; <$coverage_gate_fh> };
close $coverage_gate_fh or die "Unable to close $coverage_gate_script: $!";
like( $coverage_gate_text, qr/--rules=seq=t\/148-coverage-gate-entrypoint\.t/,
  'coverage serialises the test that fingerprints its own fixture' );
like( $coverage_gate_text, qr/--rules=seq=t\/149-coverage-gate-moving-target\.t/,
  'coverage serialises the test that intentionally changes t/' );

done_testing();

__END__

=head1 NAME

t/227-skills-md-ci-triggers.t - enforce all four ordered CI stages

=head1 PURPOSE

Protect Linux tests and the existing 100% four-metric coverage gate.
PRs run Linux, coverage, macOS arm64, then Windows amd64, in that order.
Master runs follow the same sequence through workflow_run triggers.

=head1 WHY IT EXISTS

The four-stage design guards each platform job with its predecessor.
Reusable calls enforce the PR sequence; workflow_run enforces master order.
The two platform jobs cannot bypass the coverage gate.

=head1 WHEN TO USE

Run this test when changing the GitHub Actions workflow file, Perl bootstrap,
native library paths, testing parallelism, or the repository's CI contract.
Its checks help catch mismatches between the workflow that GitHub will run
and the streamlined, test-only workflow that the maintainer requested.

=head1 HOW TO USE

From a source checkout that includes the tracked GitHub Actions YAML,
install the declared Perl dependencies and run the test with C<prove>.
The test reads the workflows from the repository rather than invoking remote
GitHub APIs or running nested CI jobs. It parses all four YAML files and
checks triggers, permissions, revision selection and job commands, including
upstream workflow ordering, macOS arm64 selection, ten-worker parallelism
and XS library paths.

=head1 WHAT USES IT

The repository's main Perl test suite uses this file in both workflow runs.
Developers can execute it directly when changing upstream triggers,
permissions, native XS setup, coverage gates or C<prove> arguments.
It is skipped only when the packaged distribution omits GitHub workflow
sources, where checking repository-only CI metadata is not meaningful.

=head1 EXAMPLES

Check the workflow contract directly after editing the YAML:

  prove -lv t/227-skills-md-ci-triggers.t

Check the workflow contract as part of the complete parallel suite:

  prove -j 10 -Iblib/arch -Iblib/lib -lr t

=cut
