use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;
use YAML::XS qw(LoadFile);

my $root = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $workflow_path = File::Spec->catfile( $root, '.github', 'workflows', 'linux-coverage.yml' );
plan skip_all => 'GitHub workflow sources are excluded from source distributions'
  if !-f $workflow_path;

my $workflow = LoadFile($workflow_path);
my $job = $workflow->{jobs}{'linux-coverage'};
ok( ref($job) eq 'HASH', 'the Linux coverage job is defined' );

my ($native_dependencies) = grep {
    ( $_->{name} // q{} ) eq 'Install Linux Perl and XS build dependencies'
} @{ $job->{steps} || [] };
ok( ref($native_dependencies) eq 'HASH',
    'the Linux job has an explicit native build dependency step' );
my $install_command = $native_dependencies->{run} // q{};
like( $install_command, qr/\bpkg-config\b/,
    'the Linux helper build has pkg-config available' );
like( $install_command, qr/\blibayatana-appindicator3-dev\b/,
    'the strict Linux coverage job installs Ayatana AppIndicator development files' );
like( $install_command, qr/\blibgtk-3-dev\b/,
    'the strict Linux coverage job installs GTK 3 development files' );
my $makefile_path = File::Spec->catfile( $root, 'Makefile.PL' );
open my $makefile_handle, '<', $makefile_path
  or die "Unable to read build configuration '$makefile_path': $!";
my $makefile = do { local $/; <$makefile_handle> };
close $makefile_handle or die "Unable to close build configuration '$makefile_path': $!";
like( $makefile, qr/system \{ \$pkg_config \} \$pkg_config, '--exists',\s*'ayatana-appindicator3-0\.1', 'gtk\+-3\.0'/,
    'the Linux native helper is built only when both system libraries are available' );

my $job_env = $job->{env} || {};
is( $job_env->{DD_REQUIRE_SYSTEM_MENU_HELPER}, '1',
    'Linux coverage fails closed instead of skipping the helper when native build packages are missing' );

done_testing();

__END__

=head1 NAME

t/811-linux-coverage-workflow-dependencies.t - keep optional GTK packages out of Linux CI

=head1 PURPOSE

Check that the strict Linux coverage workflow installs the optional GTK and
Ayatana development packages and requires the helper during CI.

=head1 WHY IT EXISTS

GTK and Ayatana are needed only for the optional System Menu helper. Ordinary
Linux package builds can skip that helper, while this strict CI job installs
its development packages and refuses to silently skip the native build.

=head1 WHEN TO USE

Run this test after changing the Linux coverage workflow, its apt dependencies,
or the Linux System Menu XS build.

=head1 HOW TO USE

    d2 docker compose exec dev prove -lv t/811-linux-coverage-workflow-dependencies.t

The test reads the active workflow YAML and does not start a runner or contact
GitHub. It skips when workflow sources are absent from a distribution.

=head1 WHAT USES IT

The project test suite executes this contract test with the other repository
workflow tests.

=head1 EXAMPLES

A passing workflow installs C<libayatana-appindicator3-dev>, C<libgtk-3-dev>,
and C<pkg-config>, and sets C<DD_REQUIRE_SYSTEM_MENU_HELPER=1>. Ordinary Linux
package builds skip only the helper when its pkg-config modules are absent;
CI fails closed if they are absent.

=cut
