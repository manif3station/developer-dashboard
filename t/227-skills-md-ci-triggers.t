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
    [ 'five-platform-coverage.yml', 'linux-coverage.yml', 'windows-amd64-unit-tests.yml', 'windows-arm64-coverage.yml' ],
    'the active workflow set contains one orchestrator and three reusable platform workflows',
);

# events($workflow)
# Purpose: return the event mapping from a YAML workflow, including YAML 1.1's
# boolean interpretation of the key "on".
# Input: one decoded workflow hash.
# Output: the workflow event hash, or an empty hash when it is absent.
sub events {
    my ($workflow) = @_;
    my ($events) = grep { ref $_ eq 'HASH' }
      map { $workflow->{$_} }
      grep { /\A(?:on|true|1)\z/ } keys %{$workflow};
    return $events || {};
}

# find_step($steps, $name)
# Purpose: find one named step and report whether the workflow contains it.
# Input: an array reference of workflow steps and the expected step name.
# Output: the matching step hash, or an empty hash after a failed assertion.
sub find_step {
    my ( $steps, $name ) = @_;
    my ($step) = grep { ( $_->{name} // '' ) eq $name } @{$steps};
    ok( defined $step, "$name is present" );
    return $step || {};
}

my $orchestrator = YAML::XS::LoadFile(
    File::Spec->catfile( $dir, 'five-platform-coverage.yml' )
);
is( $orchestrator->{name}, 'Five-platform 100% Test Coverage',
    'the coverage orchestrator has its expected name' );
my $events = events($orchestrator);
is_deeply( [ sort keys %{$events} ], [qw(pull_request push workflow_dispatch)],
    'coverage runs on pull requests, master pushes and manual dispatch' );
is_deeply( $events->{push}{branches}, ['master'],
    'push coverage is restricted to master' );
is( $orchestrator->{permissions}{contents}, 'read',
    'the orchestrator requests read-only repository access' );
like( $orchestrator->{concurrency}{group} // '', qr/five-platform-coverage-\$\{\{ github\.ref \}\}/,
    'the orchestrator groups and cancels duplicate runs on the same ref' );

my $jobs = $orchestrator->{jobs} || {};
is_deeply( [ sort keys %{$jobs} ],
    [qw(linux-amd64 linux-arm64 macos-arm64 select-platforms windows-amd64 windows-arm64)],
    'the orchestrator defines one selector and five ordered coverage stages' );

my $selector = $jobs->{'select-platforms'} || {};
is( $selector->{'runs-on'}, 'ubuntu-24.04',
    'the lightweight selector runs independently on Linux' );
my $selector_steps = $selector->{steps} || [];
my $selector_checkout = find_step( $selector_steps, 'Checkout latest source commit for tag selection' );
like( $selector_checkout->{with}{ref} // '', qr/github\.event\.pull_request\.head\.sha/,
    'pull requests select tags from the latest real commit, not a merge commit' );
my $selector_command = find_step( $selector_steps, 'Read last commit platform tags' );
like( $selector_command->{run} // '', qr/git log -1 --format=%B/,
    'selector reads one commit message' );
like( $selector_command->{run} // '', qr/script\/select-ci-platforms.*GITHUB_OUTPUT/s,
    'selector publishes script-derived job outputs' );
like( $selector_command->{run} // '', qr/if ! perl script\/select-ci-platforms.*?exit 1/s,
    'invalid platform tags fail the selector job explicitly' );
like( $selector_command->{run} // '', qr/cat .*dd-platform-outputs.*>> "\$GITHUB_OUTPUT"/s,
    'GitHub receives parsed outputs only after successful selection' );

my @stages = qw(macos-arm64 linux-amd64 linux-arm64 windows-amd64 windows-arm64);
my @outputs = qw(mac ubuntu_amd64 ubuntu_arm64 win_amd64 win_arm64);
for my $i ( 0 .. $#stages ) {
    my $job = $jobs->{ $stages[$i] } || {};
    my @expected_needs = $i
      ? ( 'select-platforms', $stages[ $i - 1 ] )
      : ('select-platforms');
    my $needs = $job->{needs};
    my @actual_needs = ref $needs eq 'ARRAY' ? @{$needs} : ($needs);
    is_deeply( \@actual_needs, \@expected_needs,
        "$stages[$i] is ordered after the previous stage but can skip it" );
    like( $job->{if} // '', qr/!cancelled\(\)\s*&&\s*!failure\(\)/,
        "$stages[$i] remains fail-fast while allowing skipped ancestors" );
    like( $job->{if} // '', qr/needs\.select-platforms\.result == 'success'/,
        "$stages[$i] requires successful tag selection" );
    like( $job->{if} // '', qr/\Qneeds.select-platforms.outputs.$outputs[$i]\E == 'true'/,
        "$stages[$i] runs only when it was selected" );
    like( $selector->{outputs}{ $outputs[$i] } // '', qr/steps\.select\.outputs\.\Q$outputs[$i]\E/,
        "the selector exposes the $stages[$i] switch" );
}

my $mac = $jobs->{'macos-arm64'} || {};
is( $mac->{'runs-on'}, 'macos-15', 'macOS coverage uses Apple Silicon' );
my $mac_steps = $mac->{steps} || [];
my $mac_arch = find_step( $mac_steps, 'Verify Apple Silicon runner' );
like( $mac_arch->{run} // '', qr/uname -m.*arm64/s,
    'macOS validates the native arm64 host' );
my $mac_cover = find_step( $mac_steps, 'Require 100% four-metric coverage (10 workers)' );
like( $mac_cover->{run} // '', qr/coverage-gate --jobs 10/,
    'macOS runs the complete ten-worker coverage gate' );

my $linux_amd64 = $jobs->{'linux-amd64'} || {};
is( $linux_amd64->{uses}, './.github/workflows/linux-coverage.yml',
    'Linux amd64 calls the reusable Linux coverage workflow' );
is( $linux_amd64->{with}{target}, 'amd64',
    'the first Linux stage explicitly selects amd64' );
is( $linux_amd64->{permissions}{contents}, 'read',
    'the Linux amd64 call keeps read-only permissions' );
my $linux_arm64 = $jobs->{'linux-arm64'} || {};
is( $linux_arm64->{uses}, './.github/workflows/linux-coverage.yml',
    'Linux arm64 uses the same reusable Linux coverage workflow' );
is( $linux_arm64->{with}{target}, 'arm64',
    'the second Linux stage explicitly selects arm64' );

my $linux = YAML::XS::LoadFile( File::Spec->catfile( $dir, 'linux-coverage.yml' ) );
my $linux_events = events($linux);
is_deeply( [ sort keys %{$linux_events} ], ['workflow_call'],
    'the Linux workflow can only be called by the orchestrator' );
is( $linux->{permissions}{contents}, 'read',
    'the reusable Linux workflow requests read-only access' );
ok( $linux_events->{workflow_call}{inputs}{target}{required},
    'the Linux target input is required' );
is( $linux_events->{workflow_call}{inputs}{target}{type}, 'string',
    'the Linux target input has a string type' );
my $linux_job = $linux->{jobs}{'linux-coverage'} || {};
like( $linux_job->{'runs-on'} // '', qr/inputs\.target.*ubuntu-24\.04.*ubuntu-24\.04-arm/,
    'the reusable job selects the native runner for its target architecture' );
my $linux_steps = $linux_job->{steps} || [];
my $caller = find_step( $linux_steps, 'Verify coverage caller and target' );
like( $caller->{run} // '', qr/five-platform-coverage\.yml/,
    'the Linux job fails when invoked outside the five-platform orchestrator' );
my $linux_arch = find_step( $linux_steps, 'Verify native Linux architecture' );
like( $linux_arch->{run} // '', qr/uname -m.*x86_64.*aarch64/s,
    'the Linux job verifies the runner architecture' );
my $linux_deps = find_step( $linux_steps, 'Install Linux Perl and XS build dependencies' );
like( $linux_deps->{run} // '', qr/libayatana-appindicator3-dev/,
    'Linux installs Ayatana AppIndicator development files for XS compilation' );
like( $linux_deps->{run} // '', qr/libgtk-3-dev/,
    'Linux installs GTK development files for XS compilation' );
my $linux_build = find_step( $linux_steps, 'Build native XS extension' );
like( $linux_build->{run} // '', qr/perl Makefile\.PL.*\bmake\b/s,
    'Linux builds the native XS extension before coverage' );
my $linux_cover = find_step( $linux_steps, 'Require 100% four-metric coverage (10 workers)' );
like( $linux_cover->{run} // '', qr/coverage-gate --jobs 10/,
    'Linux runs the complete ten-worker coverage gate' );

my $windows = YAML::XS::LoadFile(
    File::Spec->catfile( $dir, 'windows-amd64-unit-tests.yml' )
);
is_deeply( [ sort keys %{ events($windows) } ], ['workflow_call'],
    'Windows amd64 cannot start independently of the coverage chain' );
is( $windows->{permissions}{contents}, 'read',
    'the Windows amd64 workflow requests read-only access' );
my $win_job = $windows->{jobs}{'windows-amd64'} || {};
is( $win_job->{'runs-on'}, 'windows-latest',
    'Windows amd64 uses the hosted x64 runner' );
my $win_steps = $win_job->{steps} || [];
my $win_caller = find_step( $win_steps, 'Verify coverage caller' );
like( $win_caller->{run} // '', qr/five-platform-coverage\.yml/,
    'Windows amd64 validates the orchestrator caller' );
my $win_cover = find_step( $win_steps, 'Require 100% four-metric coverage (10 workers)' );
like( $win_cover->{run} // '', qr/perl script\/coverage-gate --jobs 10/,
    'Windows amd64 runs the complete ten-worker coverage gate' );

my $windows_arm = YAML::XS::LoadFile(
    File::Spec->catfile( $dir, 'windows-arm64-coverage.yml' )
);
is_deeply( [ sort keys %{ events($windows_arm) } ], ['workflow_call'],
    'Windows arm64 cannot start independently of the coverage chain' );
is( $windows_arm->{permissions}{contents}, 'read',
    'the Windows arm64 workflow requests read-only access' );
is( $windows_arm->{jobs}{'windows-arm64'}{'runs-on'}, 'windows-11-arm',
    'Windows arm64 uses the native ARM runner' );
my $win_arm_steps = $windows_arm->{jobs}{'windows-arm64'}{steps} || [];
my $win_arm_cover = find_step( $win_arm_steps, 'Require 100% four-metric coverage (10 workers)' );
like( $win_arm_cover->{run} // '', qr/coverage-gate --jobs 10/,
    'Windows arm64 runs the complete ten-worker coverage gate' );

my $gate_path = File::Spec->catfile( $root, 'script', 'coverage-gate' );
open my $gate_fh, '<', $gate_path or die "Unable to read $gate_path: $!";
my $gate_source = do { local $/; <$gate_fh> };
close $gate_fh or die "Unable to close $gate_path: $!";
like( $gate_source, qr/my \@parallel = \$jobs > 1.*?'-j', \$jobs/s,
    'the coverage gate drives prove -j 10 from --jobs 10' );
like(
    $gate_source,
    qr/-coverage', 'statement'.*?-coverage', 'branch'.*?-coverage', 'condition'.*?-coverage', 'subroutine'/s,
    'all four code coverage metrics remain mandatory',
);
like( $gate_source, qr/capture \{.*?system \$\^X, '-MDevel::Cover::DB::IO'/s,
    'serializer verification launches Perl without shell-specific quoting' );

done_testing();

__END__

=head1 NAME

t/227-skills-md-ci-triggers.t - enforce selectable serial five-platform coverage

=head1 PURPOSE

Verify that untagged GitHub Actions runs preserve the five-platform order and
that tagged commits can skip arbitrary stages without bypassing failure. Check
the native Linux build dependencies and the shared four-metric coverage gate.

=head1 WHY IT EXISTS

The coverage workflow was consolidated into one serial orchestrator and three
reusable platform workflows. Static contracts catch stale workflow inventories,
incorrect stage dependencies, missing tag selectors, build packages, and drift away
from the mandatory coverage gate before a hosted run is needed.

=head1 WHEN TO USE

Run after changing workflow names, triggers, platform ordering, runner setup,
native dependencies, or the coverage-gate invocation.

=head1 HOW TO USE

    prove -lv t/227-skills-md-ci-triggers.t

The test reads checked-in workflow YAML and the coverage-gate script. It does
not contact GitHub or start a runner.

=head1 WHAT USES IT

The full Linux coverage job executes this test as part of the repository suite.

=head1 EXAMPLES

The test verifies that every selected stage waits for earlier selected stages
but can bypass skipped predecessors. It also checks that Linux installs
the GTK and Ayatana development packages before compiling the native helper.

=cut
