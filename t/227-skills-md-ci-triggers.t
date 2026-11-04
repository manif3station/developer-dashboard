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

is_deeply( \@files, ['unit-tests.yml'], 'exactly one GitHub Actions workflow is active' );

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
like( $unit->{run} // '', qr/\bprove -j 10 -Iblib\/arch -Iblib\/lib -lr t\b/,
  'the entire t/ suite runs with prove -j 10 and built XS paths' );
like( $unit->{run} // '', qr/PERL5LIB=.*blib\/arch.*blib\/lib.*\$local_lib/s,
  'test subprocesses see the native build and local dependencies' );

done_testing();

__END__

=head1 NAME

t/227-skills-md-ci-triggers.t - enforce the single-workflow unit-test contract

=head1 PURPOSE

Protect the owner's decision to keep one GitHub Actions workflow with a
full Perl unit-test suite run by ten parallel TAP workers. The assertions
check the set of workflow files, test triggers, toolchain selection,
isolated dependency installation, and native XS build before execution.

=head1 WHY IT EXISTS

The repository previously had separate publishing, coverage, and
cross-platform workflows. Those were removed by request, so the test suite
must not require them or silently allow them to return. This test ensures
the remaining workflow builds the native code and executes the repository
tests with the requested parallelism.

=head1 WHEN TO USE

Run this test when changing the GitHub Actions workflow file, Perl bootstrap,
native library paths, testing parallelism, or the repository's CI contract.
Its checks help catch mismatches between the workflow that GitHub will run
and the streamlined, test-only workflow that the maintainer requested.

=head1 HOW TO USE

From a source checkout that includes the tracked GitHub Actions YAML,
install the declared Perl dependencies and run the test with C<prove>.
The test reads the workflow from the repository rather than invoking
remote GitHub APIs or executing a nested CI job. It parses the YAML and
checks both structured metadata and the literal suite command, including
the ten-worker concurrency setting and XS library path configuration.

=head1 WHAT USES IT

The repository's main Perl test suite uses this file during every workflow
run. Developers can also execute it directly when editing workflow triggers,
permissions, native dependency setup, or the required C<prove> arguments.
It is skipped only when the packaged distribution omits GitHub workflow
sources, where checking repository-only CI metadata is not meaningful.

=head1 EXAMPLES

Check the workflow contract directly after editing the YAML:

  prove -lv t/227-skills-md-ci-triggers.t

Check the workflow contract as part of the complete parallel suite:

  prove -j 10 -Iblib/arch -Iblib/lib -lr t

=cut
