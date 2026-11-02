use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;
use YAML::XS ();

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $test_workflow_path =
  File::Spec->catfile( $ROOT, '.github', 'workflows', 'test.yml' );
my $platform_workflow_path =
  File::Spec->catfile( $ROOT, '.github', 'workflows', 'platform-compatibility.yml' );
my $makefile_pl_path = File::Spec->catfile( $ROOT, 'Makefile.PL' );
my $cpanfile_path    = File::Spec->catfile( $ROOT, 'cpanfile' );

plan skip_all => 'CI workflow sources are excluded from the built distribution'
  if !-f $test_workflow_path || !-f $platform_workflow_path;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $content;
}

my $test_doc   = YAML::XS::LoadFile($test_workflow_path);
my $test_steps = $test_doc->{jobs}{test}{steps} || [];

my ($native_index) =
  grep { ( $test_steps->[$_]{name} // '' ) eq 'Install Linux native build dependencies' }
  0 .. $#$test_steps;
my ($build_index) =
  grep { ( $test_steps->[$_]{name} // '' ) eq 'Build the Dashboard XS extension' }
  0 .. $#$test_steps;

ok( defined $native_index,
    'test workflow installs Linux native build dependencies' );
ok( defined $build_index,
    'test workflow still has the Dashboard XS build step' );

if ( defined $native_index ) {
    my $run = $test_steps->[$native_index]{run} // '';
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
  grep { ( $test_steps->[$_]{name} // '' ) eq 'Install the audit tool outside the scanned root' }
  0 .. $#$test_steps;

ok( defined $audit_index, 'audit-tool installation step exists' );
is( $test_steps->[$audit_index]{if} // '', 'always()',
    'audit tool installation survives earlier build failures' );

my $platform_doc   = YAML::XS::LoadFile($platform_workflow_path);
my $platform_steps = $platform_doc->{jobs}{'perl-tests'}{steps} || [];
my ($platform_native_index) = grep {
    ( $platform_steps->[$_]{name} // '' ) eq 'Install Linux native build dependencies'
} 0 .. $#$platform_steps;
my ($platform_build_index) = grep {
    ( $platform_steps->[$_]{name} // '' ) eq 'Build the Dashboard XS extension (Unix)'
} 0 .. $#$platform_steps;

ok( defined $platform_native_index,
    'platform workflow installs Linux native build dependencies' );
ok( defined $platform_build_index,
    'platform workflow still has the Unix Dashboard XS build step' );

if ( defined $platform_native_index ) {
    my $step = $platform_steps->[$platform_native_index];
    is( $step->{if} // '', q{runner.os == 'Linux'},
        'platform native package installation is Linux-only' );
    my $run = $step->{run} // '';
    like( $run, qr/\bpkg-config\b/,
        'platform workflow installs pkg-config' );
    like( $run, qr/\blibgtk-3-dev\b/,
        'platform workflow installs GTK 3 headers' );
    like( $run, qr/\blibayatana-appindicator3-dev\b/,
        'platform workflow installs Ayatana AppIndicator headers' );
}

ok(
    defined $platform_native_index
      && defined $platform_build_index
      && $platform_native_index < $platform_build_index,
    'platform Linux native dependencies are installed before the Unix XS build'
);

my $makefile_pl = _slurp($makefile_pl_path);
like(
    $makefile_pl,
    qr/elsif\s*\(\s*\$\^O\s+eq\s+'darwin'\s*\).*?\$helper_compile\s*=\s*q\{[^}]*-fobjc-arc[^}]*system_menu_helper_mac\.m/s,
    'macOS System Menu helper is compiled with ARC for weak references',
);

my $cpanfile = _slurp($cpanfile_path);
like(
    $cpanfile,
    qr/if\s*\(\s*\$\^O\s+ne\s+'MSWin32'\s*\)\s*\{\s*requires\s+'Devel::Cover';\s*\}/s,
    'Windows dependency bootstrap skips the unsupported Devel::Cover tool',
);

done_testing();

__END__

=head1 NAME

t/679-ci-native-build-prereqs.t - protect CI prerequisites for native cross-platform builds

=head1 DESCRIPTION

Verifies that the primary Linux Test workflow and the platform compatibility
workflow install the native GTK/Ayatana headers before building the Dashboard
XS bundle, that macOS compiles its Objective-C helper with ARC, and that the
Windows dependency bootstrap does not require the optional Devel::Cover tool.
It also protects the Test workflow's CPAN::Audit setup from being skipped after
an earlier verification failure.

=cut
