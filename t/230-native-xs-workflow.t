use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;
use YAML::XS qw(LoadFile);

my $root = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $workflow_path = File::Spec->catfile( $root, '.github', 'workflows', 'platform-compatibility.yml' );
plan skip_all => 'GitHub workflow sources are excluded from source distributions'
  if !-f $workflow_path;

my $workflow = LoadFile($workflow_path);
my $jobs = $workflow->{jobs};
ok( ref($jobs) eq 'HASH', 'the workflow declares its platform jobs' );

my $full_suite = $jobs->{'perl-tests'};
ok( ref($full_suite) eq 'HASH', 'the cross-platform full-suite job is defined' );
my ($xs_build) = grep {
    ( $_->{name} // q{} ) eq 'Build the Dashboard XS extension'
} @{ $full_suite->{steps} || [] };
ok( ref($xs_build) eq 'HASH', 'the full-suite job builds the Dashboard XS extension' );
my $build_run = $xs_build->{run} // q{};
like( $build_run, qr/perl Makefile\.PL/, 'the full-suite job generates the native build files' );
like( $build_run, qr/\bgmake\b/, 'Windows uses its GNU make toolchain for the XS build' );
like( $build_run, qr/\bmake\b/, 'Unix platforms use make for the XS build' );
unlike( $build_run, qr/FFI::Platypus|FFI::CheckLib/, 'the build step has no FFI prerequisite' );
my ($full_suite_step) = grep {
    ( $_->{name} // q{} ) eq 'Run complete test suite'
} @{ $full_suite->{steps} || [] };
ok( ref($full_suite_step) eq 'HASH', 'the platform job runs the complete test suite' );
like(
    $full_suite_step->{run} // q{},
    qr/prove\s+-Iblib\/arch\s+-Iblib\/lib\s+-lr\s+t/,
    'the complete suite loads the just-built XS extension from blib'
);

my $arm_job = $jobs->{'windows-arm64-native-watcher'};
ok( ref($arm_job) eq 'HASH', 'the Windows ARM64 native watcher job is defined' );
is( $arm_job->{'runs-on'}, 'windows-11-arm', 'the native watcher job uses a Windows ARM64 runner' );
my ($arm_build) = grep {
    ( $_->{name} // q{} ) eq 'Build the Dashboard XS extension'
} @{ $arm_job->{steps} || [] };
ok( ref($arm_build) eq 'HASH', 'the Windows ARM64 job builds the XS extension' );
my ($watch_test) = grep {
    ( $_->{name} // q{} ) eq 'Run Windows ARM64 native filesystem watcher test'
} @{ $arm_job->{steps} || [] };
ok( ref($watch_test) eq 'HASH', 'the Windows ARM64 job runs its native watcher test' );
like(
    $watch_test->{run} // q{},
    qr/prove\s+-Iblib\/arch\s+-Iblib\/lib\s+-Ilib\s+-lv\s+t\/669-problem48-inotify-watch\.t/,
    'the ARM64 watcher test loads the just-built XS extension'
);
my ($architecture_check) = grep {
    ( $_->{name} // q{} ) eq 'Verify Windows ARM64 runner and report its Perl runtime'
} @{ $arm_job->{steps} || [] };
ok( ref($architecture_check) eq 'HASH', 'the ARM64 job verifies runner and Perl architecture' );
unlike( $architecture_check->{run} // q{}, qr/FFI::Platypus|FFI::CheckLib/,
    'the architecture check does not require FFI' );

my $workflow_text = do {
    open my $fh, '<:raw', $workflow_path or die "Unable to read '$workflow_path': $!";
    local $/;
    <$fh>;
};
unlike( $workflow_text, qr/FFI::Platypus|FFI::CheckLib/,
    'the platform workflow contains no FFI dependency install or reference' );

done_testing;

__END__

=pod

=head1 NAME

230-native-xs-workflow.t - verify platform XS build and watcher workflow setup

=head1 PURPOSE

Checks that the platform compatibility workflow builds the shared Dashboard
XS extension before running native tests, and that the Windows ARM64 job
compiles the extension before loading the watcher test.

=head1 WHY IT EXISTS

Crypto and filesystem notification backends now use the distribution's XS
extension rather than optional FFI distributions. A workflow that only runs
Perl tests without compiling the extension would silently skip the native
implementation, so the build and test paths must stay explicit.

=head1 WHEN TO USE

Run this source-checkout test when changing the cross-platform XS build,
Windows ARM64 native watcher job, or optional native dependencies. The test
skips only when workflow files are absent from a packaged distribution.

=head1 HOW TO USE

  d2 docker compose exec dev prove -lv t/230-native-xs-workflow.t

The test parses the checked-in YAML; it does not contact GitHub, install
dependencies, or execute a workflow.

=head1 WHAT USES IT

The repository test suite runs this test as a guard against platform jobs that
omit XS compilation or reintroduce FFI dependencies.

=head1 EXAMPLES

=over 4

=item *

The full-suite job runs C<perl Makefile.PL> and selects C<gmake> on Windows or
C<make> on Unix.

=item *

The Windows ARM64 job verifies its Perl architecture, builds the extension,
and passes C<-Iblib/arch> to the native watcher test.

=back

=cut
