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
my @files = sort grep { /\.ya?ml\z/ && -f File::Spec->catfile( $dir, $_ ) }
  readdir $fh;
closedir $fh or die "Unable to close $dir: $!";

is_deeply(
    \@files,
    ['macos-arm64-unit-tests.yml', 'windows-amd64-unit-tests.yml'],
    'only the macOS and Windows coverage workflows remain',
);

sub events {
    my ($workflow) = @_;
    my ($events) = grep { ref $_ eq 'HASH' }
      map { $workflow->{$_} }
      grep { /\A(?:on|true|1)\z/ } keys %{$workflow};
    return $events || {};
}

sub find_step {
    my ( $steps, $name ) = @_;
    my ($step) = grep { ( $_->{name} // '' ) eq $name } @{$steps};
    ok( defined $step, "$name is present" );
    return $step || {};
}

my $mac = YAML::XS::LoadFile(
    File::Spec->catfile( $dir, 'macos-arm64-unit-tests.yml' )
);
is( $mac->{name}, 'macOS arm64 Test Coverage', 'the macOS workflow is named' );
my $mac_events = events($mac);
is_deeply( [ sort keys %{$mac_events} ],
    [qw(pull_request push workflow_dispatch)],
    'macOS starts on PRs, master pushes and manual dispatch' );
is_deeply( $mac_events->{push}{branches}, ['master'],
    'macOS push trigger is restricted to master' );
is( $mac->{permissions}{contents}, 'read',
    'the macOS workflow has read-only permissions' );
is_deeply( [ sort keys %{ $mac->{jobs} || {} } ],
    [qw(macos-arm64 windows-amd64)],
    'macOS starts coverage and then calls Windows coverage' );

my $mac_job = $mac->{jobs}{'macos-arm64'} || {};
is( $mac_job->{'runs-on'}, 'macos-15', 'macOS uses hosted Apple Silicon' );
like( $mac_job->{if} // '', qr/github\.repository/,
    'macOS checks the trusted repository' );
my $mac_steps = $mac_job->{steps} || [];
my $mac_step_budget = 0;
$mac_step_budget += ($_->{'timeout-minutes'} // 0) for @{$mac_steps};
cmp_ok( $mac_job->{'timeout-minutes'} // 0, '>=', $mac_step_budget,
    'macOS job timeout accommodates all declared step budgets' );
my $mac_arch = find_step( $mac_steps, 'Verify Apple Silicon runner' );
like( $mac_arch->{run} // '', qr/uname -m.*arm64/s,
    'the macOS job checks the physical arm64 host' );
my $mac_deps = find_step( $mac_steps, 'Install Devel::Cover' );
like( $mac_deps->{run} // '', qr/cpanm --notest -L local Devel::Cover/,
    'macOS installs coverage instrumentation' );
my $mac_build = find_step( $mac_steps, 'Build native XS extension' );
like( $mac_build->{run} // '', qr/perl Makefile\.PL.*\bmake\b/s,
    'macOS builds native XS before coverage' );
my $mac_cover =
  find_step( $mac_steps, 'Require 100% four-metric coverage (10 workers)' );
like( $mac_cover->{run} // '', qr/perl script\/coverage-gate --jobs 10/,
    'macOS runs the full coverage gate with ten test workers' );
like( $mac_cover->{run} // '', qr/PERL5LIB=.*blib\/arch.*\$local_lib/s,
    'macOS retains its compiled XS and local library paths' );
unlike( $mac_cover->{run} // '', qr/PERL5LIB=.*blib\/lib/s,
    'macOS does not instrument duplicate source in blib/lib' );
like( $mac_cover->{run} // '', qr/BASH_ENV.*perl-ci-bashenv/s,
    'macOS preserves the selected Perl for nested shell tests' );

my $call = $mac->{jobs}{'windows-amd64'} || {};
is( $call->{needs}, 'macos-arm64',
    'Windows cannot start until macOS coverage succeeds' );
is( $call->{uses}, './.github/workflows/windows-amd64-unit-tests.yml',
    'macOS invokes the Windows reusable workflow' );
is( $call->{permissions}{contents}, 'read',
    'the Windows call has read-only permissions' );

my $win = YAML::XS::LoadFile(
    File::Spec->catfile( $dir, 'windows-amd64-unit-tests.yml' )
);
is( $win->{name}, 'Windows amd64 Test Coverage', 'Windows workflow is named' );
is_deeply( [ sort keys %{ events($win) } ], ['workflow_call'],
    'Windows cannot start independently of the macOS gate' );
is( $win->{permissions}{contents}, 'read',
    'Windows uses read-only permissions' );
is_deeply( [ sort keys %{ $win->{jobs} || {} } ], ['windows-amd64'],
    'Windows has one coverage job' );
my $win_job = $win->{jobs}{'windows-amd64'} || {};
is( $win_job->{'runs-on'}, 'windows-latest',
    'Windows amd64 uses the hosted x64 runner' );
like( $win_job->{if} // '', qr/macos-arm64-unit-tests\.yml/,
    'Windows reusable call checks its macOS caller' );
my $win_steps = $win_job->{steps} || [];
my $win_step_budget = 0;
$win_step_budget += ($_->{'timeout-minutes'} // 0) for @{$win_steps};
cmp_ok( $win_job->{'timeout-minutes'} // 0, '>=', $win_step_budget,
    'Windows job timeout accommodates all declared step budgets' );
my $win_arch = find_step( $win_steps, 'Verify Windows amd64 runner' );
like( $win_arch->{run} // '', qr/RUNNER_ARCH.*X64/s,
    'Windows asserts that it runs on a real amd64 host' );
my $bootstrap = find_step( $win_steps, 'Install pinned Strawberry Perl' );
like( $bootstrap->{run} // '', qr/Get-FileHash.*SHA256/s,
    'Windows checks its pinned Perl archive' );
my ($expected_sha) = ($bootstrap->{run} // '') =~
  /\$expectedSha256 = '([0-9a-f]+)'/;
is( length($expected_sha // ''), 64,
    'the Strawberry Perl SHA256 has exactly 64 hex digits' );
like( $bootstrap->{run} // '', qr/cpanm\.Source\.StartsWith/,
    'Windows rejects cpanm from a different Perl installation' );
my $win_deps =
  find_step( $win_steps, 'Install Devel::Cover (required on Windows)' );
like( $win_deps->{run} // '', qr/cpanm --notest -L local Devel::Cover/,
    'Windows must install real Devel::Cover instrumentation' );
like( $win_deps->{run} // '', qr/exit \$LASTEXITCODE/,
    'Windows does not silently skip failed coverage installation' );
my $win_build = find_step( $win_steps, 'Build native XS extension' );
like( $win_build->{run} // '', qr/perl Makefile\.PL.*\bgmake\b/s,
    'Windows builds native XS before coverage' );
my $win_cover =
  find_step( $win_steps, 'Require 100% four-metric coverage (10 workers)' );
like( $win_cover->{run} // '', qr/perl script\/coverage-gate --jobs 10/,
    'Windows invokes the full coverage gate with ten workers' );
like( $win_cover->{run} // '', qr/DD_SUITE_LOCK.*RUNNER_TEMP/s,
    'Windows uses a valid host-lock path under the runner temporary directory' );
like( $win_cover->{run} // '', qr/exit \$LASTEXITCODE/,
    'Windows fails the job when the coverage gate fails' );
unlike( $win_cover->{run} // '', qr/Join-Path[^\n]*blib\/lib/,
    'Windows does not double-instrument compiled copies of lib/' );

my $gate_path = File::Spec->catfile( $root, 'script', 'coverage-gate' );
open my $gate_fh, '<', $gate_path
  or die "Unable to read $gate_path: $!";
my $gate_source = do { local $/; <$gate_fh> };
close $gate_fh or die "Unable to close $gate_path: $!";
like( $gate_source, qr/my \@parallel = \$jobs > 1.*?'-j', \$jobs/s,
    'the coverage gate drives prove -j 10 from --jobs 10' );
like( $gate_source, qr/-coverage', 'statement'.*?-coverage', 'branch'.*?-coverage', 'condition'.*?-coverage', 'subroutine'/s,
    'all four code coverage metrics remain mandatory' );
like( $gate_source, qr/capture \{.*?system \$\^X, '-MDevel::Cover::DB::IO'/s,
    'serializer verification launches Perl without shell-specific quoting' );

done_testing();

__END__

=head1 NAME

227-skills-md-ci-triggers.t - enforce two ordered platform coverage workflows

=head1 PURPOSE

Only macOS arm64 and Windows amd64 workflows may run CI. On both PRs and master,
macOS enforces 100% statement, branch, condition and subroutine coverage with
ten TAP workers. Windows runs only after macOS succeeds, and uses the same gate.

=head1 WHY IT EXISTS

A separate Unit Tests and Coverage pipeline duplicated the suite and allowed
a passing platform job to report ordinary unit tests without coverage. This
regression guards the streamlined two-workflow design and rejects skip-only
Windows instrumentation.

=head1 WHEN TO USE

Run whenever changing workflow triggers, native builds, the Perl bootstrap,
coverage tooling, or the cross-platform ordering contract.

=head1 HOW TO USE

  prove -lv t/227-skills-md-ci-triggers.t

=head1 WHAT USES IT

The full suite on both coverage hosts invokes this test.

=head1 EXAMPLES

Check the ordered two-workflow contract:

  prove -lv t/227-skills-md-ci-triggers.t

Both platforms run the full coverage gate with ten workers:

  perl script/coverage-gate --jobs 10

=cut
