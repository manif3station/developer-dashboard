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
my $steps = $full_suite->{steps} || [];

my $matrix = $full_suite->{strategy}{matrix}{include} || [];
my @runners = sort map { $_->{runner} // '' } @{$matrix};
is_deeply(
    \@runners,
    [ sort qw(macos-26 macos-26-intel ubuntu-24.04-arm ubuntu-latest windows-11-arm windows-latest) ],
    'the full-suite matrix covers Linux, macOS, and Windows on x64 and arm64 hosts',
);

my ($windows_arm) = grep { ( $_->{label} // q{} ) eq 'Windows arm64' } @{$matrix};
ok( ref($windows_arm) eq 'HASH', 'Windows ARM64 is a full-suite matrix entry' );
is( $windows_arm->{runner}, 'windows-11-arm',
    'Windows ARM64 uses the hosted Windows ARM64 runner' );
ok( !$windows_arm->{'setup-perl'},
    'Windows ARM64 uses its explicit Strawberry Perl bootstrap instead of unsupported setup-perl' );

my ($windows_x64) = grep { ( $_->{label} // q{} ) eq 'Windows x64' } @{$matrix};
ok( !$windows_x64->{'setup-perl'},
    'Windows x64 uses the same pinned Strawberry Perl as Windows ARM64' );

my ($arm_perl) = grep {
    ( $_->{name} // q{} ) eq 'Install supported Strawberry Perl on Windows'
} @{$steps};
ok( ref($arm_perl) eq 'HASH', 'both Windows architectures have a pinned Strawberry Perl bootstrap' );
is( $arm_perl->{if}, "runner.os == 'Windows'",
    'the Strawberry Perl bootstrap runs on both Windows matrix legs' );
like( $arm_perl->{run} // q{}, qr/strawberry-perl-\$version-64bit-portable\.zip/,
    'Windows ARM64 downloads the pinned portable Strawberry Perl release' );
like( $arm_perl->{run} // q{}, qr/6a081a811781c30aca51dbc036afd93092af91e3297901f02c17043795a10690/,
    'Windows ARM64 verifies the portable Strawberry Perl archive SHA256' );
like( $arm_perl->{run} // q{}, qr/Expand-Archive/,
    'Windows ARM64 extracts Strawberry Perl without relying on an MSI installer' );
like( $arm_perl->{run} // q{}, qr/\$\]\s*<\s*5\.038/,
    'Windows ARM64 refuses a Perl older than the project floor' );
unlike( $arm_perl->{run} // q{}, qr/choco install strawberryperl|native_perl=false/,
    'Windows ARM64 no longer relies on the failing MSI or a skip-only state' );

my ($arch_check) = grep {
    ( $_->{name} // q{} ) eq 'Assert runner operating system and architecture'
} @{$steps};
like( $arch_check->{run} // q{}, qr/\$ENV\{RUNNER_ARCH\}/,
    'architecture validation checks GitHub RUNNER_ARCH rather than Perl process architecture' );
like( $arch_check->{run} // q{}, qr/Perl \$Config\{archname\}/,
    'architecture diagnostics still report the emulated Perl architecture' );

my ($linux_native_deps) = grep {
    ( $_->{name} // q{} ) eq 'Install native Linux system-menu build dependencies'
} @{$steps};
ok( ref($linux_native_deps) eq 'HASH',
    'Linux platform jobs install native System Menu build dependencies' );
like( $linux_native_deps->{run} // q{},
    qr/libayatana-appindicator3-dev.*libgtk-3-dev.*pkg-config/s,
    'Linux platform jobs install both pkg-config libraries required by the native menu helper' );

my ($unix_build) = grep {
    ( $_->{name} // q{} ) eq 'Build the Dashboard XS extension (Unix)'
} @{$steps};
ok( ref($unix_build) eq 'HASH', 'the full-suite job has a Unix XS build step' );
is( $unix_build->{shell}, 'bash', 'the Unix XS build uses bash' );
like( $unix_build->{run} // q{}, qr/perl Makefile\.PL.*\bmake\b/s,
    'the Unix XS build uses the configured Perl and make' );
like( $unix_build->{run} // q{}, qr/PERL5LIB=.*local\/lib\/perl5.*perl Makefile\.PL/s,
    'the Unix XS build can load configure prerequisites from the local dependency tree' );

my ($windows_build) = grep {
    ( $_->{name} // q{} ) eq 'Build the Dashboard XS extension (Windows)'
} @{$steps};
ok( ref($windows_build) eq 'HASH', 'the Windows jobs have their own XS build step' );
is( $windows_build->{shell}, 'pwsh', 'the Windows XS build uses PowerShell' );
like( $windows_build->{run} // q{}, qr/perl Makefile\.PL.*\bgmake\b/s,
    'the Windows XS build uses the selected Perl runtime and GNU make' );
unlike( $windows_build->{run} // q{}, qr/FFI::Platypus|FFI::CheckLib/,
    'the Windows XS build has no FFI prerequisite' );

my ($unix_tools) = grep {
    ( $_->{name} // q{} ) eq 'Install test tools and export project environment (Unix)'
} @{$steps};
ok( ref($unix_tools) eq 'HASH', 'the Unix test-tools step is explicit' );
like( $unix_tools->{run} // q{}, qr/cpanm\s+--notest\s+-L\s+local\s+Devel::Cover/,
    'Unix installs Devel::Cover for coverage-aware repository tests' );
like( $unix_tools->{run} // q{}, qr{blib/arch.*blib/lib}s,
    'Unix exports both built XS library paths' );

my ($windows_tools) = grep {
    ( $_->{name} // q{} ) eq 'Install test tools and export project environment (Windows)'
} @{$steps};
ok( ref($windows_tools) eq 'HASH', 'the Windows test-tools step is explicit' );
is( $windows_tools->{shell}, 'pwsh', 'the Windows test-tools step uses PowerShell' );
like( $windows_tools->{run} // q{}, qr/Test::Harness~3\.48/,
    'Windows installs the supported Test::Harness version explicitly' );
unlike( $windows_tools->{run} // q{}, qr/cpanm .*Devel::Cover/,
    'Windows does not require unsupported coverage instrumentation' );
like( $windows_tools->{run} // q{}, qr/dedicated Coverage workflow/,
    'Windows documentation points to the dedicated Coverage workflow' );

my ($unix_suite) = grep {
    ( $_->{name} // q{} ) eq 'Run complete test suite (Unix)'
} @{$steps};
ok( ref($unix_suite) eq 'HASH', 'the platform job runs the Unix complete test suite' );
like( $unix_suite->{run} // q{}, qr/prove\s+-Iblib\/arch\s+-Iblib\/lib\s+-lr\s+t/,
    'the Unix complete suite loads the just-built XS extension from blib' );
like( $unix_suite->{run} // q{}, qr/RUNNER_OS.*macOS.*-lrv\s+t/s,
    'the macOS leg streams individual TAP assertions for hang diagnosis' );

my ($windows_suite) = grep {
    ( $_->{name} // q{} ) eq 'Run complete test suite (Windows)'
} @{$steps};
ok( ref($windows_suite) eq 'HASH', 'the platform job has a distinct Windows full-suite step' );
is( $windows_suite->{shell}, 'pwsh', 'the Windows full-suite step uses native PowerShell' );
like( $windows_suite->{run} // q{}, qr/perl\s+-MApp::Prove.*process_args.*-Iblib\/arch/s,
    'Windows runs App::Prove through the selected Perl interpreter' );

my %consolidated = map { ( $_->{name} // q{} ) => $_ } @{$steps};
for my $name (
    'Audit action pin provenance',
    'Install the audit tool outside the scanned root',
    'Audit isolated dependency root (RELEASE GATE)',
    'Audit declared dependency chain (RELEASE GATE)',
) {
    ok( ref($consolidated{$name}) eq 'HASH',
        "Platform compatibility contains the consolidated '$name' gate" );
    is( $consolidated{$name}{if}, "matrix.label == 'Linux x64'",
        "'$name' runs only once on the Linux x64 matrix leg" );
}
ok( !exists $consolidated{'Install JS test dependencies'},
    'Platform compatibility does not repeat npm installation after the full suite' );
ok( !exists $consolidated{'Run fast-check property tests'},
    'Platform compatibility does not repeat fast-check after the full suite' );
ok( !exists $consolidated{'Verify all-metric lib coverage'},
    'Platform compatibility leaves code coverage to the dedicated Coverage workflow' );
like( $consolidated{'Audit action pin provenance'}{run} // q{},
    qr/script\/audit-action-pins/,
    'the consolidated workflow audits SHA pin provenance' );
like( $consolidated{'Audit isolated dependency root (RELEASE GATE)'}{run} // q{},
    qr/script\/cpan-audit-project\s+local\/lib\/perl5/,
    'the consolidated workflow audits the isolated dependency root' );
like( $consolidated{'Audit declared dependency chain (RELEASE GATE)'}{run} // q{},
    qr/script\/cpan-audit-declared-chain\s+local\/lib\/perl5/,
    'the consolidated workflow audits the declared transitive dependency chain' );

my ($node_setup) = grep {
    ( $_->{name} // q{} ) eq 'Set up Node for property tests'
} @{$steps};
ok( ref($node_setup) eq 'HASH', 'the Linux x64 leg configures Node for property tests' );
is( $node_setup->{if}, "matrix.label == 'Linux x64'",
    'Node setup is not duplicated across non-JavaScript matrix legs' );
like( $node_setup->{uses} // q{}, qr/actions\/setup-node\@[0-9a-f]{40}\z/,
    'Node setup stays pinned by full commit SHA' );

my $property_test_path = File::Spec->catfile( $root, 't', '35-js-fast-check.t' );
open my $property_test_fh, '<:raw', $property_test_path
  or die "Unable to read $property_test_path: $!";
my $property_test_text = do { local $/; <$property_test_fh> };
close $property_test_fh or die "Unable to close $property_test_path: $!";
like( $property_test_text, qr/'fuzz:scorecard'/,
    'the complete test suite retains the fast-check property test command' );

ok( !exists $jobs->{'windows-arm64-native-watcher'},
    'the obsolete skip-only Windows ARM64 watcher job is removed' );

my $makefile_path = File::Spec->catfile( $root, 'Makefile.PL' );
open my $makefile_fh, '<:raw', $makefile_path or die "Unable to read $makefile_path: $!";
my $makefile_text = do { local $/; <$makefile_fh> };
close $makefile_fh or die "Unable to close $makefile_path: $!";
like( $makefile_text, qr/-fobjc-arc/,
    'the macOS System Menu helper compiles with ARC for weak Objective-C references' );
like( $makefile_text, qr/test_requires\{'Devel::Cover'\}\s*=\s*0\s*if\s*\$\^O\s+ne\s+'MSWin32'/,
    'MakeMaker does not require unsupported Devel::Cover on Windows' );

my $cpanfile_path = File::Spec->catfile( $root, 'cpanfile' );
open my $cpanfile_fh, '<:raw', $cpanfile_path or die "Unable to read $cpanfile_path: $!";
my $cpanfile_text = do { local $/; <$cpanfile_fh> };
close $cpanfile_fh or die "Unable to close $cpanfile_path: $!";
like( $cpanfile_text,
    qr/requires\s+'Devel::Cover'\s+if\s+\$\^O\s+ne\s+'MSWin32';/,
    'the cpanfile omits unsupported Devel::Cover on Windows' );

my $release_workflow_path = File::Spec->catfile( $root, '.github', 'workflows', 'release-github.yml' );
my $release_workflow = LoadFile($release_workflow_path);
my $release_job = $release_workflow->{jobs}{release};
ok( ref($release_job) eq 'HASH', 'the release workflow declares its release job' );
my $release_steps = $release_job->{steps} || [];
my ($release_build_index) = grep {
    ( $release_steps->[$_]{name} // q{} ) eq 'Build the Dashboard XS extension'
} 0 .. $#{$release_steps};
my ($release_test_index) = grep {
    ( $release_steps->[$_]{name} // q{} ) eq 'Run tests'
} 0 .. $#{$release_steps};
ok( defined $release_build_index && defined $release_test_index,
    'the release workflow builds XS and runs the complete suite' );
cmp_ok( $release_build_index, '<', $release_test_index,
    'the release workflow builds XS before running tests' );
like( $release_steps->[$release_test_index]{run} // q{},
    qr/prove\s+-Iblib\/arch\s+-Iblib\/lib\s+-lr\s+t/,
    'the release test suite loads the freshly built XS extension from blib' );

done_testing();

__END__

=head1 NAME

230-native-xs-workflow.t - verify platform testing and native XS setup

=head1 DESCRIPTION

Validates the six-host platform matrix, native XS build paths, the Windows ARM64
Perl bootstrap, and the Linux x64 audit/property gates. It also checks that code
coverage moved to the dedicated Coverage workflow and that GitHub Release still
builds XS before running its release suite.

=head1 PURPOSE

Ensure Platform compatibility is the routine cross-platform test source across
Linux, macOS, and Windows while Windows ARM64 actually executes the suite instead
of reporting success after skipping its work.

=head1 WHY IT EXISTS

The Dashboard native extension and System Menu helper behave differently across
operating systems. The Windows ARM64 runner originally shipped an x64 Perl and
the workflow treated that as a reason to skip every useful step, yielding a
green job with no compatibility evidence. The MSI replacement then failed with
Windows Installer error 1603, so the runner now uses Strawberry's portable ZIP.

=head1 WHEN TO USE

Run this test when changing the platform matrix, native helper prerequisites,
Windows ARM64 Perl setup, audit wiring, JavaScript property tests, Windows shell
selection, coverage ownership, or GitHub Release build/test ordering.

=head1 HOW TO USE

  prove -lv t/230-native-xs-workflow.t

=head1 WHAT USES IT

The repository test suite and Platform compatibility workflow use this test as a
source-level guard for the platform CI design.

=head1 EXAMPLES

Check the workflow contract directly:

  prove -lv t/230-native-xs-workflow.t

Run it with the whole suite:

  prove -lr t

=cut
