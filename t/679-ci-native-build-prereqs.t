use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;
use YAML::XS ();

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $workflow_path = File::Spec->catfile( $ROOT, '.github', 'workflows', 'test.yml' );

plan skip_all => 'test workflow is excluded from the built distribution'
  if !-f $workflow_path;

my $doc   = YAML::XS::LoadFile($workflow_path);
my $steps = $doc->{jobs}{test}{steps} || [];

my ($native_index) =
  grep { ( $steps->[$_]{name} // '' ) eq 'Install Linux native build dependencies' }
  0 .. $#$steps;
my ($build_index) =
  grep { ( $steps->[$_]{name} // '' ) eq 'Build the Dashboard XS extension' }
  0 .. $#$steps;

ok( defined $native_index,
    'test workflow installs Linux native build dependencies' );
ok( defined $build_index,
    'test workflow still has the Dashboard XS build step' );

if ( defined $native_index ) {
    my $run = $steps->[$native_index]{run} // '';
    like( $run, qr/\bpkg-config\b/,
        'native dependency step installs pkg-config' );
    like( $run, qr/\blibgtk-3-dev\b/,
        'native dependency step installs GTK 3 headers' );
    like( $run, qr/\blibayatana-appindicator3-dev\b/,
        'native dependency step installs Ayatana AppIndicator headers' );
}

ok(
    defined $native_index
      && defined $build_index
      && $native_index < $build_index,
    'native Linux dependencies are installed before the XS build'
);

my ($audit_index) =
  grep { ( $steps->[$_]{name} // '' ) eq 'Install the audit tool outside the scanned root' }
  0 .. $#$steps;

ok( defined $audit_index, 'audit-tool installation step exists' );
is( $steps->[$audit_index]{if} // '', 'always()',
    'audit tool installation survives earlier build failures' );

done_testing();

__END__

=head1 NAME

t/679-ci-native-build-prereqs.t - protect CI prerequisites for the Dashboard native build

=head1 DESCRIPTION

Verifies that the primary Linux Test workflow installs the native GTK/Ayatana
headers before building the Dashboard XS bundle, and that its CPAN::Audit setup
still runs when an earlier verification step fails.

=cut
