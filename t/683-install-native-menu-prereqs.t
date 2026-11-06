use strict;
use warnings FATAL => 'all';
use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $root = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "Cannot close $path: $!";
    return $text // '';
}
for my $name (qw(aptfile apkfile dnfile install.sh)) {
    unlike( slurp( File::Spec->catfile($root, $name) ),
        qr/libayatana-appindicator|libgtk-3-dev/,
        "$name no longer requires native menu packages" );
}
my $makefile = slurp( File::Spec->catfile($root, 'Makefile.PL') );
unlike( $makefile, qr/SystemMenu|system_menu_helper|ayatana-appindicator|-framework AppKit/,
    'core build rules do not depend on desktop-menu compilation' );
my $xs = slurp( File::Spec->catfile($root, 'HtmlEscape.xs') );
unlike( $xs, qr/SystemMenu/,
    'Dashboard XS bundle does not register system-menu XSUBs' );
done_testing;

__END__

=head1 NAME

t/683-install-native-menu-prereqs.t - optional menu build dependencies

=head1 PURPOSE

Ensure the standalone system-menu distribution owns desktop build packages.

=head1 WHY IT EXISTS

Core installation should work without GTK, Ayatana or menu helper toolchains.

=head1 WHEN TO USE

Run when editing installer manifests or XS build rules.

=head1 HOW TO USE

  prove -lv t/683-install-native-menu-prereqs.t

=head1 EXAMPLES

Core C<Makefile.PL> must not include C<SystemMenu.xs>.

=head1 WHAT USES IT

The core Perl suite.

=cut
