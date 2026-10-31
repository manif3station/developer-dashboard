use strict;
use warnings;

use Capture::Tiny qw(capture);
use Cwd qw(getcwd abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $source_root = abs_path( File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
my $fixture = tempdir( CLEANUP => 1 );
my $fixture_lib = File::Spec->catdir( $fixture, 'lib', 'Developer', 'Dashboard' );
my $fixture_share = File::Spec->catdir( $fixture, 'share' );
my $fixture_local_lib = File::Spec->catdir( $fixture, '.perl5', 'lib', 'perl5' );

make_path( $fixture_lib, $fixture_share, $fixture_local_lib );
copy(
    File::Spec->catfile( $source_root, 'Makefile.PL' ),
    File::Spec->catfile( $fixture, 'Makefile.PL' ),
) or die "Unable to copy Makefile.PL into fixture: $!";
copy(
    File::Spec->catfile( $source_root, 'lib', 'Developer', 'Dashboard', 'Version.pm' ),
    File::Spec->catfile( $fixture_lib, 'Version.pm' ),
) or die "Unable to copy Version.pm into fixture: $!";

open my $marker, '>', File::Spec->catfile( $fixture_local_lib, 'PortabilityProbe.pm' )
  or die "Unable to create local-lib marker: $!";
print {$marker} "package PortabilityProbe; 1;\n";
close $marker or die "Unable to close local-lib marker: $!";

my $caller_dir = getcwd();
chdir $fixture or die "Unable to enter Makefile fixture: $!";
my ( $stdout, $stderr, $exit ) = capture {
    system( $^X, 'Makefile.PL' );
};
chdir $caller_dir or die "Unable to restore working directory: $!";

is( $exit, 0, 'Makefile.PL generates a Makefile for the portability fixture' );
is( $stderr, '', 'Makefile.PL emits no warnings for the portability fixture' );

my $makefile_path = File::Spec->catfile( $fixture, 'Makefile' );
ok( -f $makefile_path, 'Makefile.PL created the generated Makefile' );

my $makefile = '';
if ( -f $makefile_path ) {
    open my $makefile_fh, '<', $makefile_path
      or die "Unable to read generated Makefile: $!";
    local $/;
    $makefile = <$makefile_fh> // '';
    close $makefile_fh or die "Unable to close generated Makefile: $!";
}

ok( $makefile !~ qr/^PERL5LIB\s*:=/m,
    'generated Makefile avoids GNU-only PERL5LIB := assignment syntax' );
ok( $makefile !~ qr/^export\s+PERL5LIB\s*$/m,
    'generated Makefile avoids GNU-only export syntax for PERL5LIB' );
ok( $makefile !~ qr/^PERL5LIB\b/m,
    'generated Makefile does not inject local Perl paths into make syntax' );

done_testing();

__END__

=head1 NAME

805-makefile-portability.t - guard generated Makefiles against GNU-only syntax

=head1 DESCRIPTION

This regression test runs C<Makefile.PL> in a disposable fixture that contains
a project-local Perl library. It inspects the generated Makefile for shell and
make syntax that BSD make and Solaris make rejected in the CPAN Tester reports
for Developer-Dashboard 6.06. The fixture is isolated so the test does not
replace or modify the checkout's own generated Makefile.

=head1 WHY IT EXISTS

The package build must remain usable on non-GNU make implementations. C<Makefile.PL>
adds local Perl library paths for test commands; that convenience must not make
the generated distribution Makefile unparsable before tests can run.

=head1 PURPOSE

This test prevents unsupported make syntax from breaking a distribution before
its Perl tests can begin.

=head1 WHEN TO USE

Run this regression when changing Makefile.PL configuration or investigating
CPAN Tester failures involving generated Makefiles and non-GNU make.

=head1 HOW TO USE

Run this test from the project development container with:

  d2 docker compose exec dev prove -lv t/805-makefile-portability.t

=head1 WHAT USES IT

The test protects maintainers building source distributions, CPAN Testers
running them with BSD or Solaris make, and users installing the distribution
without GNU make.

=head1 EXAMPLES

Example 1:

  d2 docker compose exec dev prove -lv t/805-makefile-portability.t

Run this test directly while changing the MakeMaker postamble.

Example 2:

  d2 docker compose exec dev prove -lr t

Run the full suite, including this generated-Makefile regression.

=cut
