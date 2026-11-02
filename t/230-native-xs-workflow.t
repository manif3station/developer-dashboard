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
my ($unix_full_suite_step) = grep {
    ( $_->{name} // q{} ) eq 'Run complete test suite (Unix)'
} @{ $full_suite->{steps} || [] };
ok( ref($unix_full_suite_step) eq 'HASH', 'the platform job runs the Unix complete test suite' );
is( $unix_full_suite_step->{shell}, 'bash', 'the Unix full-suite step uses bash' );
like(
    $unix_full_suite_step->{run} // q{},
    qr/prove\s+-Iblib\/arch\s+-Iblib\/lib\s+-lr\s+t/,
    'the Unix complete suite loads the just-built XS extension from blib'
);
my ($windows_full_suite_step) = grep {
    ( $_->{name} // q{} ) eq 'Run complete test suite (Windows)'
} @{ $full_suite->{steps} || [] };
ok( ref($windows_full_suite_step) eq 'HASH', 'the platform job has a distinct Windows full-suite step' );
is( $windows_full_suite_step->{shell}, 'pwsh', 'the Windows full-suite step uses native PowerShell' );
like(
    $windows_full_suite_step->{run} // q{},
    qr/perl\s+-MApp::Prove.*process_args.*-Iblib\/arch/s,
    'Windows runs App::Prove through the setup-perl interpreter'
);
unlike(
    $windows_full_suite_step->{run} // q{},
    qr/\b(?:bash|prove)\b/,
    'the Windows full-suite step does not route through Git Bash or a prove executable on PATH'
);
like(
    $unix_full_suite_step->{run} // q{},
    qr/RUNNER_OS.*macOS.*prove\s+-Iblib\/arch\s+-Iblib\/lib\s+-lrv\s+t/s,
    'the macOS full-suite leg streams individual TAP assertions for hang diagnosis'
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
like( $unix_build->{run} // q{}, qr/PERL5LIB=.*local\/lib\/perl5.*perl Makefile\.PL/s,
    'the Unix XS build can load configure prerequisites installed into the local library' );

my ($windows_build) = grep {
    ( $_->{name} // q{} ) eq 'Build the Dashboard XS extension (Windows)'
} @{ $full_suite->{steps} || [] };
ok( ref($windows_build) eq 'HASH', 'the Windows x64 job has its own XS build step' );
is( $windows_build->{shell}, 'pwsh', 'the Windows XS build uses PowerShell, not Git Bash Perl' );
like( $windows_build->{run} // q{}, qr/perl Makefile\.PL.*\bgmake\b/s,
    'the Windows XS build uses the setup-perl runtime and GNU make' );
like( $windows_build->{run} // q{}, qr/\$localLib\s*=\s*Join-Path.*local\/lib\/perl5.*\$env:PERL5LIB\s*=.*perl Makefile\.PL/s,
    'the Windows XS build can load configure prerequisites installed into the local library' );
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
like(
    $windows_test_tools->{run} // q{},
    qr/cpanm\s+--notest\s+-L\s+local\s+Test::Harness~3\.48/,
    'the Windows test-tools step installs the minimum Test::Harness version needed by prove',
);
like(
    $windows_test_tools->{run} // q{},
    qr/\$env:PERL5LIB\s*=\s*\$perl5lib.*?perl\s+-MTAP::Harness::Env/s,
    'the Windows test-tools step verifies TAP::Harness::Env through the assembled local module path',
);
unlike( $windows_test_tools->{run} // q{}, qr/cpanm .*Devel::Cover/,
    'the Windows platform suite does not require the unsupported coverage module' );
like( $unix_test_tools->{run} // q{}, qr{blib/arch},
    'the platform Unix job exports the built XS architecture path to child processes' );
like( $unix_test_tools->{run} // q{}, qr{blib/lib},
    'the platform Unix job exports the built XS library path to child processes' );
like( $windows_test_tools->{run} // q{}, qr{blib[/\\]arch},
    'the platform Windows job exports the built XS architecture path to child processes' );
like( $windows_test_tools->{run} // q{}, qr{blib[/\\]lib},
    'the platform Windows job exports the built XS library path to child processes' );

my $workflow_text = do {
    open my $fh, '<:raw', $workflow_path or die "Unable to read '$workflow_path': $!";
    local $/;
    <$fh>;
};
unlike( $workflow_text, qr/FFI::Platypus|FFI::CheckLib/,
    'the platform workflow contains no FFI dependency install or reference' );
my ($platform_linux_native_deps) = grep {
    ( $_->{name} // q{} ) eq 'Install native Linux system-menu build dependencies'
} @{ $full_suite->{steps} || [] };
ok( ref($platform_linux_native_deps) eq 'HASH',
    'Linux platform jobs install native System Menu build dependencies' );
like( $platform_linux_native_deps->{run} // q{},
    qr/libayatana-appindicator3-dev.*libgtk-3-dev.*pkg-config/s,
    'Linux platform jobs install both pkg-config libraries required by the native menu helper' );
like( $workflow_text,
    qr/if:\s*startsWith\(matrix\.label,\s*'Linux'\)/,
    'native menu dependencies are installed only on Linux matrix jobs' );

my $test_workflow_path = File::Spec->catfile( $root, '.github', 'workflows', 'test.yml' );
my $test_workflow = LoadFile($test_workflow_path);
my $test_job = $test_workflow->{jobs}{test};
ok( ref($test_job) eq 'HASH', 'the Linux test workflow declares its test job' );
my $test_steps = $test_job->{steps} || [];
my ($audit_install_index) = grep {
    ( $test_steps->[$_]{name} // q{} ) eq 'Install the audit tool outside the scanned root'
} 0 .. $#{$test_steps};
ok( defined $audit_install_index,
    'the Linux Test workflow installs the dependency auditor outside the scanned root' );
is( $test_steps->[$audit_install_index]{if}, 'always()',
    'the dependency auditor is installed even when an earlier release gate fails' );
my ($declared_audit_index) = grep {
    ( $test_steps->[$_]{name} // q{} ) eq 'Audit declared dependency chain (RELEASE GATE)'
} 0 .. $#{$test_steps};
ok( defined $declared_audit_index,
    'the Linux Test workflow reports the declared-chain audit result' );
is( $test_steps->[$declared_audit_index]{if}, 'always()',
    'the declared-chain audit still reports after an earlier gate fails' );
cmp_ok( $audit_install_index, '<', $declared_audit_index,
    'the auditor is prepared before the declared-chain audit runs' );
my ($test_native_deps) = grep {
    ( $_->{name} // q{} ) eq 'Install native Linux system-menu build dependencies'
} @{$test_steps};
ok( ref($test_native_deps) eq 'HASH',
    'the Linux Test workflow installs native System Menu build dependencies' );
like( $test_native_deps->{run} // q{},
    qr/libayatana-appindicator3-dev.*libgtk-3-dev.*pkg-config/s,
    'the Linux Test workflow installs both pkg-config libraries required by the native menu helper' );
my ($test_xs_build_index) = grep {
    ( $test_steps->[$_]{name} // q{} ) eq 'Build the Dashboard XS extension'
} 0 .. $#{$test_steps};
ok( defined $test_xs_build_index, 'the Linux test workflow builds the shared XS extension' );
my $test_xs_build = defined $test_xs_build_index ? $test_steps->[$test_xs_build_index] : {};
like( $test_xs_build->{run} // q{}, qr/perl Makefile\.PL.*\bmake\b/s,
    'the Linux test workflow builds XS with its configured Perl and make' );
like( $test_xs_build->{run} // q{}, qr/PERL5LIB=.*local\/lib\/perl5.*perl Makefile\.PL/s,
    'the Linux test build can load configure prerequisites installed into the local library' );
my ($test_run_index) = grep {
    ( $test_steps->[$_]{name} // q{} ) eq 'Run tests'
} 0 .. $#{$test_steps};
ok( defined $test_run_index, 'the Linux test workflow runs its test suite' );
my $test_run = defined $test_run_index ? $test_steps->[$test_run_index] : {};
cmp_ok( defined $test_xs_build_index ? $test_xs_build_index : -1, '<', $test_run_index,
    'the Linux test workflow builds XS before running the test suite' );
like( $test_run->{run} // q{}, qr/prove\s+-Iblib\/arch\s+-Iblib\/lib\s+-lr\s+t/,
    'the Linux test suite loads the just-built XS extension from blib' );
my ($test_coverage_index) = grep {
    ( $test_steps->[$_]{name} // q{} ) eq 'Verify all-metric lib coverage'
} 0 .. $#{$test_steps};
ok( defined $test_coverage_index, 'the Linux test workflow runs its all-metric coverage gate' );
my $test_coverage = defined $test_coverage_index ? $test_steps->[$test_coverage_index] : {};
my ($test_tools_index) = grep {
    ( $test_steps->[$_]{name} // q{} ) eq 'Install test tools and export project environment'
} 0 .. $#{$test_steps};
ok( defined $test_tools_index, 'the Linux test workflow prepares test tools and library paths' );
my $test_tools = defined $test_tools_index ? $test_steps->[$test_tools_index] : {};
cmp_ok( defined $test_xs_build_index ? $test_xs_build_index : -1, '<', $test_coverage_index,
    'the Linux test workflow builds XS before the coverage gate' );
cmp_ok( $test_tools_index, '<', $test_coverage_index,
    'the Linux test workflow exports test libraries before the coverage gate' );
my $test_tools_run = $test_tools->{run} // q{};
like( $test_tools_run, qr{blib/arch},
    'the Linux workflow exports the built XS architecture path to test children' );
like( $test_tools_run, qr{blib/lib},
    'the Linux workflow exports the built XS library path to test children' );
like( $test_tools_run, qr{local/lib/perl5},
    'the Linux workflow exports local dependencies to test children' );

my $fuzz_workflow_path = File::Spec->catfile( $root, '.github', 'workflows', 'fuzz-js.yml' );
my $fuzz_workflow_text = do {
    open my $fh, '<:raw', $fuzz_workflow_path or die "Unable to read '$fuzz_workflow_path': $!";
    local $/;
    <$fh>;
};
like( $fuzz_workflow_text,
    qr/libayatana-appindicator3-dev.*libgtk-3-dev.*pkg-config/s,
    'the JavaScript fuzz workflow installs native menu dependencies before the XS build' );

my $makefile_path = File::Spec->catfile( $root, 'Makefile.PL' );
my $makefile_text = do {
    open my $fh, '<:raw', $makefile_path or die "Unable to read '$makefile_path': $!";
    local $/;
    <$fh>;
};
like( $makefile_text, qr/-fobjc-arc/,
    'the macOS System Menu helper compiles with ARC for its weak Objective-C references' );
like( $makefile_text, qr/test_requires\{'Devel::Cover'\}\s*=\s*0\s*if\s*\$\^O\s+ne\s+'MSWin32'/,
    'MakeMaker does not require unsupported Devel::Cover on Windows' );

my $cpanfile_path = File::Spec->catfile( $root, 'cpanfile' );
my $cpanfile_text = do {
    open my $fh, '<:raw', $cpanfile_path or die "Unable to read '$cpanfile_path': $!";
    local $/;
    <$fh>;
};
like(
    $cpanfile_text,
    qr/if\s*\(\s*\$\^O\s+ne\s+'MSWin32'\s*\)\s*\{\s*requires\s+'Devel::Cover';\s*\}/s,
    'the cpanfile does not install unsupported Devel::Cover on Windows' );

my $release_workflow_path = File::Spec->catfile( $root, '.github', 'workflows', 'release-github.yml' );
my $release_workflow = LoadFile($release_workflow_path);
my $release_job = $release_workflow->{jobs}{release};
ok( ref($release_job) eq 'HASH', 'the release workflow declares its release job' );
my $release_steps = $release_job->{steps} || [];
my ($release_xs_build_index) = grep {
    ( $release_steps->[$_]{name} // q{} ) eq 'Build the Dashboard XS extension'
} 0 .. $#{$release_steps};
ok( defined $release_xs_build_index, 'the release workflow builds the XS extension before testing' );
my $release_xs_build = defined $release_xs_build_index ? $release_steps->[$release_xs_build_index] : {};
like( $release_xs_build->{run} // q{}, qr/perl Makefile\.PL.*\bmake\b/s,
    'the release workflow builds XS using its configured Perl and make' );
my ($release_test_index) = grep {
    ( $release_steps->[$_]{name} // q{} ) eq 'Run tests'
} 0 .. $#{$release_steps};
ok( defined $release_test_index, 'the release workflow runs its complete test suite' );
cmp_ok( defined $release_xs_build_index ? $release_xs_build_index : -1, '<', $release_test_index,
    'the release workflow builds XS before running tests' );
like( $release_steps->[$release_test_index]{run} // q{}, qr/prove\s+-Iblib\/arch\s+-Iblib\/lib\s+-lr\s+t/,
    'the release test suite loads the freshly built XS extension from blib' );

done_testing;

__END__

=pod

=head1 NAME

230-native-xs-workflow.t - verify platform XS build and watcher workflow setup

=head1 PURPOSE

Checks that the platform compatibility workflow builds the shared Dashboard
XS extension before running native tests, selects the configured Windows Perl
through PowerShell for build and coverage-tool steps, invokes C<App::Prove>
through that selected interpreter for the Windows suite, and does not report
an ARM64 watcher pass when the hosted runner lacks native ARM64 Perl.
It also checks that the main Linux Test workflow builds XS and exports the
resulting C<blib> paths to both the ordinary and coverage test runs. Since
checkout dependencies are installed into C<local/lib/perl5>, each XS build
must expose that library to C<perl Makefile.PL> so configure prerequisites
such as C<File::ShareDir::Install> load before C<blib> exists. Linux jobs must
install the GTK and Ayatana AppIndicator development packages needed by the
native menu helper, macOS must enable ARC for its weak Objective-C references,
and Windows must not request Devel::Cover, which is unsupported by its current
toolchain. The main Test workflow also prepares its external CPAN auditor with
C<always()> so an earlier build failure does not make the downstream audit fail
merely because C<CPAN::Audit> was never installed.

=head1 WHY IT EXISTS

Crypto and filesystem notification backends now use the distribution's XS
extension rather than optional FFI distributions. A workflow that only runs
Perl tests without compiling the extension would silently skip the native
implementation, so the build and test paths must stay explicit.
The main Linux Test workflow has its own build and coverage path; it must not
run the source suite without the just-built XS API available. The platform
matrix and JavaScript fuzz workflow also compile the native Linux helper, so
each needs its own Linux-only system package setup. MacOS helper compilation
uses ARC, and Devel::Cover remains a non-Windows test dependency because the
Windows compatibility job runs the full suite without instrumentation. The
regression test also checks that the audit-tool installer runs with
C<if: always()> before the always-run declared-chain audit, allowing that audit
to report its own result after an earlier build failure.

=head1 WHEN TO USE

Run this source-checkout test when changing the cross-platform XS build,
Windows ARM64 native watcher job, Windows shell selection, Linux native menu
packages, macOS Objective-C compiler flags, platform-specific test
dependencies, or the main Linux Test workflow. The test skips only when
workflow files are absent from a packaged distribution.

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
C<make> on Unix, with the local dependency path available during configuration.

=item *

The main Linux Test workflow builds the XS extension before C<prove>, and
exports C<blib/arch>, C<blib/lib>, and the local dependency library so every
test and coverage subprocess loads the same extension.

=item *

The Windows ARM64 job verifies its runner and Perl architectures. If the
runner has no native ARM64 Perl, it emits a warning and visibly skips
Perl-dependent steps rather than claiming native watcher coverage.

=item *

Windows x64 builds the extension and prepares coverage tools in PowerShell so
it uses the workflow-installed Perl rather than Git Bash's MSYS Perl.
The Windows full-suite step launches C<App::Prove> through that Perl as well;
it does not depend on a C<prove> wrapper selected from C<PATH>.

=back

=cut
