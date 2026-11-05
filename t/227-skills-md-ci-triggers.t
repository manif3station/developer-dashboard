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
  ['macos-arm64-unit-tests.yml', 'test-coverage.yml', 'unit-tests.yml'],
  'the Linux, coverage and macOS arm64 test workflows are active'
);

my $path = File::Spec->catfile( $dir, 'unit-tests.yml' );
my $workflow = YAML::XS::LoadFile($path);
my ($events) = grep { ref $_ eq 'HASH' }
  map { $workflow->{$_} } grep { /\A(?:on|true|1)\z/ } keys %$workflow;

ok( ref($events) eq 'HASH', 'GitHub Actions trigger definitions are present' );
is_deeply( $events->{push}{branches}, ['master'], 'push runs on master only' );
ok( exists $events->{pull_request}, 'pull requests run the tests' );
ok( exists $events->{workflow_dispatch}, 'manual test runs are available' );

is_deeply( [ sort keys %{ $workflow->{jobs} || {} } ], ['unit-tests'],
  'the workflow has one unit-test job' );
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
like( $unit->{run} // '', qr/PERL5LIB=.*blib\/arch.*blib\/lib.*\$local_lib/s,
  'test subprocesses see the native build and local dependencies' );


my $coverage_path = File::Spec->catfile( $dir, 'test-coverage.yml' );
my $coverage = YAML::XS::LoadFile($coverage_path);
my ($coverage_events) = grep { ref $_ eq 'HASH' }
  map { $coverage->{$_} } grep { /\A(?:on|true|1)\z/ } keys %$coverage;
is_deeply( [ sort keys %{$coverage_events} ], ['workflow_run'],
  'coverage cannot be independently triggered by push, PR or manual dispatch' );
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
like( $coverage_checkout->{with}{repository} // '', qr/workflow_run\.head_repository\.full_name/,
  'coverage resolves the original source repository, including forks' );
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
is_deeply( [ sort keys %$macos_trigger ], ['workflow_run'],
  'macOS only starts from an upstream workflow completion' );
my $macos_run = ref($macos_trigger->{workflow_run}) eq 'HASH'
  ? $macos_trigger->{workflow_run} : {};
is_deeply( $macos_run->{workflows}, ['Unit Tests'],
  'macOS waits for the existing Linux Unit Tests workflow' );
is_deeply( $macos_run->{types}, ['completed'],
  'macOS only triggers after the Linux workflow completes' );
is( $macos->{permissions}{contents}, 'read',
  'macOS does not need write permissions on upstream completion' );
is_deeply( [ sort keys %{ $macos->{jobs} || {} } ], ['macos-arm64'],
  'macOS workflow has one dedicated arm64 job' );
my $macos_job = $macos->{jobs}{'macos-arm64'} || {};
like( $macos_job->{if} // '',
  qr/workflow_run\.conclusion\s*==\s*'success'/,
  'macOS suite is skipped unless Linux unit tests pass' );
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
like( $macos_checkout->{with}{repository} // '', qr/workflow_run\.head_repository\.full_name/,
  'macOS checks out the upstream source repository' );
like( $macos_checkout->{with}{ref} // '', qr/workflow_run\.head_sha/,
  'macOS checks out the exact Linux-tested commit' );
ok( !$macos_checkout->{with}{'persist-credentials'},
  'macOS checkout does not persist credentials from workflow_run' );
my $macos_arch = find_macos_step( \@macos_steps, 'Verify Apple Silicon runner' );
like( $macos_arch->{run} // '', qr/uname -m.*arm64/s,
  'macOS runner is checked for arm64 architecture' );
my $macos_perl = find_macos_step( \@macos_steps, 'Set up Perl' );
is( $macos_perl->{with}{'perl-version'}, '5.44',
  'macOS matches the supported Linux Perl version' );
ok( $macos_perl->{with}{'multi-thread'},
  'macOS Perl has threads for native XS' );
my $macos_deps = find_macos_step( \@macos_steps, 'Install Perl dependencies' );
like( $macos_deps->{run} // '', qr/cpanm --installdeps --notest -L local \./,
  'macOS installs the full local Perl dependency set' );
my $macos_build = find_macos_step( \@macos_steps, 'Build native XS extension' );
like( $macos_build->{run} // '', qr/perl Makefile\.PL.*\bmake\b/s,
  'macOS builds the XS extension before running tests' );
my $macos_test =
  find_macos_step( \@macos_steps, 'Run all unit tests (10 parallel workers)' );
like( $macos_test->{run} // '',
  qr/\bprove -j 10\b.*-Iblib\/arch -Iblib\/lib -lr t\b/s,
  'macOS runs the full suite with ten parallel TAP workers' );
like( $macos_test->{run} // '', qr/--rules='seq=t\/05-cli-smoke\.t'/,
  'macOS preserves serial execution for the CLI smoke test' );
like( $macos_test->{run} // '', qr/--rules='seq=t\/09-runtime-manager\.t'/,
  'macOS preserves serial execution for the server lifecycle test' );
like( $macos_test->{run} // '', qr/--rules='seq=t\/15-release-metadata\.t'/,
  'macOS preserves serial execution for the release metadata test' );
like( $macos_test->{run} // '', qr/--rules='par=\*\*'/,
  'macOS retains parallel scheduling for the remaining tests' );
like( $macos_test->{run} // '',
  qr/PERL5LIB=.*blib\/arch.*blib\/lib.*\$local_lib/s,
  'macOS test subprocesses see the XS build and local dependencies' );

done_testing();

__END__

=head1 NAME

t/227-skills-md-ci-triggers.t - enforce Linux, coverage and macOS CI workflows

=head1 PURPOSE

Protect the existing Linux unit-test and four-metric coverage contract.
The macOS arm64 suite starts only after the Linux Unit Tests workflow completes
successfully, and checks out that exact tested revision.

=head1 WHY IT EXISTS

The active design permits exactly three workflows: Linux unit tests, coverage
and macOS arm64 tests. Both downstream workflows depend on Linux Unit Tests
success. Neither downstream workflow runs in parallel with the upstream
workflow, and coverage is not made dependent on macOS test results.

=head1 WHEN TO USE

Run this test when changing the GitHub Actions workflow file, Perl bootstrap,
native library paths, testing parallelism, or the repository's CI contract.
Its checks help catch mismatches between the workflow that GitHub will run
and the streamlined, test-only workflow that the maintainer requested.

=head1 HOW TO USE

From a source checkout that includes the tracked GitHub Actions YAML,
install the declared Perl dependencies and run the test with C<prove>.
The test reads the workflows from the repository rather than invoking remote
GitHub APIs or running nested CI jobs. It parses all three YAML files and
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
