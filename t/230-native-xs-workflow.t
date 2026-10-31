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
    ( $_->{name} // q{} ) eq 'Build the Dashboard XS extension (Windows)'
} @{ $arm_job->{steps} || [] };
ok( ref($arm_build) eq 'HASH', 'the Windows ARM64 job builds the XS extension with Windows Perl' );
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
like( $architecture_check->{run} // q{}, qr/PROCESSOR_ARCHITECTURE/,
    'the ARM64 preflight still rejects a non-ARM64 runner' );
like( $architecture_check->{run} // q{}, qr/native_perl=false/,
    'the ARM64 preflight records when native Perl is unavailable' );
like( $architecture_check->{run} // q{}, qr/::warning title=Native ARM64 Perl unavailable/,
    'the ARM64 preflight makes unavailable Perl visible as a warning' );
unlike( $architecture_check->{run} // q{}, qr/FFI::Platypus|FFI::CheckLib/,
    'the architecture check does not require FFI' );
my ($arm_cpanm) = grep { ( $_->{name} // q{} ) eq 'Install cpanminus' } @{ $arm_job->{steps} || [] };
is( $arm_cpanm->{if}, "steps.arm64-perl.outputs.native_perl == 'true'",
    'ARM64 dependency installation only runs with native Perl' );
my ($arm_dependencies) = grep {
    ( $_->{name} // q{} ) eq 'Install project dependencies'
} @{ $arm_job->{steps} || [] };
is( $arm_dependencies->{if}, "steps.arm64-perl.outputs.native_perl == 'true'",
    'ARM64 dependencies are not installed into an x64 Perl runtime' );
is( $arm_build->{if}, "steps.arm64-perl.outputs.native_perl == 'true'",
    'ARM64 XS compilation only runs with native Perl' );
is( $watch_test->{if}, "steps.arm64-perl.outputs.native_perl == 'true'",
    'the watcher test is visibly skipped unless native Perl is available' );

my ($unix_build) = grep {
    ( $_->{name} // q{} ) eq 'Build the Dashboard XS extension (Unix)'
} @{ $full_suite->{steps} || [] };
ok( ref($unix_build) eq 'HASH', 'the full-suite job has a Unix XS build step' );
is( $unix_build->{shell}, 'bash', 'the Unix XS build uses bash' );
like( $unix_build->{run} // q{}, qr/perl Makefile\.PL.*\bmake\b/s,
    'the Unix XS build uses the configured Perl and make' );

my ($windows_build) = grep {
    ( $_->{name} // q{} ) eq 'Build the Dashboard XS extension (Windows)'
} @{ $full_suite->{steps} || [] };
ok( ref($windows_build) eq 'HASH', 'the Windows x64 job has its own XS build step' );
is( $windows_build->{shell}, 'pwsh', 'the Windows XS build uses PowerShell, not Git Bash Perl' );
like( $windows_build->{run} // q{}, qr/perl Makefile\.PL.*\bgmake\b/s,
    'the Windows XS build uses the setup-perl runtime and GNU make' );
unlike( $windows_build->{run} // q{}, qr/FFI::Platypus|FFI::CheckLib/,
    'the Windows XS build has no FFI prerequisite' );

my ($unix_test_tools) = grep {
    ( $_->{name} // q{} ) eq 'Install test tools and export project environment (Unix)'
} @{ $full_suite->{steps} || [] };
ok( ref($unix_test_tools) eq 'HASH', 'the Unix test-tools step is explicit' );
is( $unix_test_tools->{shell}, 'bash', 'the Unix test-tools step uses bash' );
my ($windows_test_tools) = grep {
    ( $_->{name} // q{} ) eq 'Install test tools and export project environment (Windows)'
} @{ $full_suite->{steps} || [] };
ok( ref($windows_test_tools) eq 'HASH', 'the Windows test-tools step is explicit' );
is( $windows_test_tools->{shell}, 'pwsh', 'the Windows test-tools step uses PowerShell' );
like( $windows_test_tools->{run} // q{}, qr/\$env:GITHUB_ENV/,
    'the Windows test-tools step exports variables using Windows semantics' );

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
XS extension before running native tests, selects the configured Windows Perl
through PowerShell for build and coverage-tool steps, and does not report an
ARM64 watcher pass when the hosted runner lacks native ARM64 Perl.

=head1 WHY IT EXISTS

Crypto and filesystem notification backends now use the distribution's XS
extension rather than optional FFI distributions. A workflow that only runs
Perl tests without compiling the extension would silently skip the native
implementation, so the build and test paths must stay explicit.

=head1 WHEN TO USE

Run this source-checkout test when changing the cross-platform XS build,
Windows ARM64 native watcher job, Windows shell selection, or optional native
dependencies. The test skips only when workflow files are absent from a
packaged distribution.

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

The Windows ARM64 job verifies its runner and Perl architectures. If the
runner has no native ARM64 Perl, it emits a warning and visibly skips
Perl-dependent steps rather than claiming native watcher coverage.

=item *

Windows x64 builds the extension and prepares coverage tools in PowerShell so
it uses the workflow-installed Perl rather than Git Bash's MSYS Perl.

=back

=cut
