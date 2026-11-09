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
like( $install_command, qr/\blibayatana-appindicator3-dev\b/,
    'the Linux dependency step installs Ayatana AppIndicator development files' );
like( $install_command, qr/\blibgtk-3-dev\b/,
    'the Linux dependency step installs GTK 3 development files' );

my $job_env = $job->{env} || {};
is( $job_env->{DD_REQUIRE_SYSTEM_MENU_HELPER}, '1',
    'Linux coverage fails closed instead of skipping the helper when native build packages are missing' );

done_testing();

__END__

=head1 NAME

t/811-linux-coverage-workflow-dependencies.t - enforce Linux XS build packages

=head1 PURPOSE

Check that the active Linux coverage workflow installs the native development
packages needed to compile the Dashboard System Menu helper and requires that
helper during the CI build.

=head1 WHY IT EXISTS

The Linux amd64 local coverage job failed during XS compilation because
pkg-config could not find C<ayatana-appindicator3-0.1> or C<gtk+-3.0>, and the
compiler could not find C<gtk/gtk.h>. These checks keep the workflow package
list aligned with the native helper build. The strict environment setting
ensures CI fails if dependency installation or pkg-config detection does not
produce the required binary; only ordinary Linux builds may take the optional
headless path.

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

A passing workflow installs both C<libayatana-appindicator3-dev> and
C<libgtk-3-dev> before compiling the XS extension. Removing either package
causes the test to fail with the missing package named in its assertion. The
workflow must also set C<DD_REQUIRE_SYSTEM_MENU_HELPER=1> so Makefile.PL refuses
to skip the helper in CI.

=cut
