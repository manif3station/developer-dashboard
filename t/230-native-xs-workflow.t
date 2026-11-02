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
    [ sort qw(macos-26 macos-26-intel ubuntu-24.04-arm ubuntu-latest windows-latest) ],
    'the full-suite matrix covers Linux, macOS, and Windows x64 plus Linux and macOS arm64',
);

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
ok( ref($windows_build) eq 'HASH', 'the Windows x64 job has its own XS build step' );
is( $windows_build->{shell}, 'pwsh', 'the Windows XS build uses PowerShell' );
like( $windows_build->{run} // q{}, qr/perl Makefile\.PL.*\bgmake\b/s,
    'the Windows XS build uses the setup-perl runtime and GNU make' );
unlike( $windows_build->{run} // q{}, qr/FFI::Platypus|FFI::CheckLib/,
    'the Windows XS build has no FFI prerequisite' );

my ($unix_tools) = grep {
    ( $_->{name} // q{} ) eq 'Install test tools and export project environment (Unix)'
} @{$steps};
ok( ref($unix_tools) eq 'HASH', 'the Unix test-tools step is explicit' );
like( $unix_tools->{run} // q{}, qr/cpanm\s+--notest\s+-L\s+local\s+Devel::Cover/,
    'Unix installs Devel::Cover for the consolidated Linux x64 coverage gate' );
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
like( $windows_tools->{run} // q{}, qr/Linux x64 platform leg/,
    'Windows documentation points to the Linux x64 platform leg for coverage' );

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
    'Windows runs App::Prove through the setup-perl interpreter' );

my %consolidated = map {
    ( $_->{name} // q{} ) => $_
} @{$steps};
for my $name (
    'Audit action pin provenance',
    'Install the audit tool outside the scanned root',
    'Audit isolated dependency root (RELEASE GATE)',
    'Audit declared dependency chain (RELEASE GATE)',
    'Verify all-metric lib coverage',
    'Install JS test dependencies',
    'Run fast-check property tests',
) {
    ok( ref($consolidated{$name}) eq 'HASH',
        "Platform compatibility contains the consolidated '$name' gate" );
    is( $consolidated{$name}{if}, "matrix.label == 'Linux x64'",
        "'$name' runs only once on the Linux x64 matrix leg" );
}
like( $consolidated{'Audit action pin provenance'}{run} // q{},
    qr/script\/audit-action-pins/,
    'the consolidated workflow audits SHA pin provenance' );
like( $consolidated{'Audit isolated dependency root (RELEASE GATE)'}{run} // q{},
    qr/script\/cpan-audit-project\s+local\/lib\/perl5/,
    'the consolidated workflow audits the isolated dependency root' );
like( $consolidated{'Audit declared dependency chain (RELEASE GATE)'}{run} // q{},
    qr/script\/cpan-audit-declared-chain\s+local\/lib\/perl5/,
    'the consolidated workflow audits the declared transitive dependency chain' );
like( $consolidated{'Verify all-metric lib coverage'}{run} // q{},
    qr/perl\s+script\/coverage-gate/,
    'the consolidated workflow runs the canonical coverage gate' );
like( $consolidated{'Install JS test dependencies'}{run} // q{},
    qr/npm\s+ci\s+--ignore-scripts/,
    'the consolidated workflow installs JavaScript test dependencies reproducibly' );
like( $consolidated{'Run fast-check property tests'}{run} // q{},
    qr/npm\s+run\s+fuzz:scorecard/,
    'the consolidated workflow retains the fast-check property tests' );

my ($node_setup) = grep {
    ( $_->{name} // q{} ) eq 'Set up Node for property tests'
} @{$steps};
ok( ref($node_setup) eq 'HASH', 'the Linux x64 leg configures Node for property tests' );
is( $node_setup->{if}, "matrix.label == 'Linux x64'",
    'Node setup is not duplicated across non-JavaScript matrix legs' );
like( $node_setup->{uses} // q{}, qr/actions\/setup-node\@[0-9a-f]{40}\z/,
    'Node setup stays pinned by full commit SHA' );

my $arm_job = $jobs->{'windows-arm64-native-watcher'};
ok( ref($arm_job) eq 'HASH', 'the Windows ARM64 native watcher job is defined' );
is( $arm_job->{'runs-on'}, 'windows-11-arm',
    'the native watcher job uses a Windows ARM64 runner' );
my ($architecture_check) = grep {
    ( $_->{name} // q{} ) eq 'Verify Windows ARM64 runner and report its Perl runtime'
} @{ $arm_job->{steps} || [] };
ok( ref($architecture_check) eq 'HASH', 'the ARM64 job verifies runner and Perl architecture' );
like( $architecture_check->{run} // q{}, qr/native_perl=false/,
    'the ARM64 preflight records when native Perl is unavailable' );
my ($watch_test) = grep {
    ( $_->{name} // q{} ) eq 'Run Windows ARM64 native filesystem watcher test'
} @{ $arm_job->{steps} || [] };
ok( ref($watch_test) eq 'HASH', 'the Windows ARM64 job runs its native watcher test when possible' );
is( $watch_test->{if}, "steps.arm64-perl.outputs.native_perl == 'true'",
    'the watcher test is visibly skipped unless native Perl is available' );

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

230-native-xs-workflow.t - verify consolidated platform testing and XS setup

=head1 DESCRIPTION

Validates the cross-platform matrix, native XS build paths, Windows ARM64
watcher handling, and the Linux x64 gates consolidated from the former Test and
JS Fuzz workflows. It also checks that GitHub Release still builds XS before
running its release suite.

=head1 PURPOSE

Ensure Platform compatibility is the single source of routine CI test truth
across Linux, macOS, and Windows while retaining coverage, dependency audits,
action-pin provenance, and JavaScript property tests without separate workflows.

=head1 WHY IT EXISTS

The Dashboard native extension and System Menu helper behave differently across
operating systems. A Linux-only Test workflow duplicated work while providing
less platform evidence, so the repository now keeps those verification gates in
the platform matrix instead.

=head1 WHEN TO USE

Run this test when changing the platform matrix, native helper prerequisites,
coverage or audit wiring, JavaScript property tests, Windows shell selection, or
GitHub Release build/test ordering.

=head1 HOW TO USE

  prove -lv t/230-native-xs-workflow.t

=head1 WHAT USES IT

The repository test suite and Platform compatibility workflow use this test as a
source-level guard for the consolidated CI design.

=head1 EXAMPLES

Check the workflow contract directly:

  prove -lv t/230-native-xs-workflow.t

Run it with the whole suite:

  prove -lr t

=cut
