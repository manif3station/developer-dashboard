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

is_deeply( \@files, ['test-coverage.yml', 'unit-tests.yml'], 'exactly two dependent test workflows are active' );

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
like( $unit->{run} // '', qr/--rules='seq=t\/09-runtime-manager\.t'/,
  'the server lifecycle test runs outside concurrent test workers' );
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

done_testing();

__END__

=head1 NAME

t/227-skills-md-ci-triggers.t - enforce dependent unit-test and coverage workflows

=head1 PURPOSE

Protect the owner's two-workflow contract: first a full unit test run,
then a four-metric 100 percent coverage gate only after upstream success.
Both workflows build native XS and run ten parallel test workers.

=head1 WHY IT EXISTS

The repository's former publishing and cross-platform workflows were removed.
The active design permits exactly two test workflows and requires the second
to follow a successful Unit Tests run. This protects against a detached
coverage run or an accidental restoration of publishing jobs.

=head1 WHEN TO USE

Run this test when changing the GitHub Actions workflow file, Perl bootstrap,
native library paths, testing parallelism, or the repository's CI contract.
Its checks help catch mismatches between the workflow that GitHub will run
and the streamlined, test-only workflow that the maintainer requested.

=head1 HOW TO USE

From a source checkout that includes the tracked GitHub Actions YAML,
install the declared Perl dependencies and run the test with C<prove>.
The test reads the workflow from the repository rather than invoking
remote GitHub APIs or executing a nested CI job. It parses both YAML files and
checks their triggers, permissions, revision selection and job commands,
including ten-worker parallelism and XS library path configuration.

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
