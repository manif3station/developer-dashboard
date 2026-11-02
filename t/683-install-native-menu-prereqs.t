use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $text // '';
}

sub _manifest_lines {
    my ($name) = @_;
    my $text = _slurp( File::Spec->catfile( $ROOT, $name ) );
    return grep { length && $_ !~ /^\s*#/ }
      map {
        my $line = $_;
        $line =~ s/\s*#.*$//;
        $line =~ s/^\s+|\s+$//g;
        $line;
      } split /\n/, $text;
}

sub _has_package {
    my ( $name, $package ) = @_;
    my %packages = map { $_ => 1 } _manifest_lines($name);
    ok( $packages{$package}, "$name includes $package for the Linux System Menu native helper" );
}

_has_package( 'aptfile', 'pkg-config' );
_has_package( 'aptfile', 'libgtk-3-dev' );
_has_package( 'aptfile', 'libayatana-appindicator3-dev' );

_has_package( 'apkfile', 'pkgconf' );
_has_package( 'apkfile', 'libayatana-appindicator-dev' );

_has_package( 'dnfile', 'pkgconf-pkg-config' );
_has_package( 'dnfile', 'libayatana-appindicator-gtk3-devel' );

my $installer = _slurp( File::Spec->catfile( $ROOT, 'install.sh' ) );
for my $package (
    'libgtk-3-dev',
    'libayatana-appindicator3-dev',
    'libayatana-appindicator-dev',
    'libayatana-appindicator-gtk3-devel',
) {
    like(
        $installer,
        qr/^\Q$package\E$/m,
        "install.sh embedded streamed-bootstrap manifests include $package",
    );
}

done_testing();

__END__

=head1 NAME

t/683-install-native-menu-prereqs.t - protect Linux installer prerequisites for the native System Menu helper

=head1 DESCRIPTION

Checks that each supported Linux bootstrap manifest installs the development
package that provides the GTK3/Ayatana headers and pkg-config metadata consumed
by C<Makefile.PL>, and that C<install.sh> carries the same packages in its
embedded fallback manifests for streamed installs where the repo manifest files
are not available yet.

=head1 PURPOSE

Keep source-checkout and streamed Linux installs aligned with the native System
Menu helper's compile-time requirements.

=head1 WHY IT EXISTS

The Perl dependency graph cannot install GTK or Ayatana development headers.
Without explicit system packages, C<cpanm .> reaches the native helper build and
fails even though all CPAN prerequisites were installed successfully.

=head1 WHEN TO USE

Run this test whenever changing Linux installer manifests, C<install.sh>
embedded package fallbacks, or native System Menu build dependencies.

=head1 HOW TO USE

Run the focused regression with:

  prove -lv t/683-install-native-menu-prereqs.t

=head1 WHAT USES IT

Debian/Ubuntu, Alpine, and Fedora bootstrap installs rely on these manifests
before C<cpanm> compiles the Dashboard native extension and menu helper.

=head1 EXAMPLES

Check the installer prerequisites directly:

  prove -lv t/683-install-native-menu-prereqs.t

Run them as part of the complete suite:

  prove -lr t

=cut
