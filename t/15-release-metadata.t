use strict;
use warnings;

use Test::More;

open my $pm_fh, '<', 'lib/Developer/Dashboard.pm' or die $!;
my $pm = do { local $/; <$pm_fh> };
close $pm_fh;

open my $dist_fh, '<', 'dist.ini' or die $!;
my $dist = do { local $/; <$dist_fh> };
close $dist_fh;

open my $changes_fh, '<', 'Changes' or die $!;
my $changes = do { local $/; <$changes_fh> };
close $changes_fh;

open my $makefile_fh, '<', 'Makefile.PL' or die $!;
my $makefile = do { local $/; <$makefile_fh> };
close $makefile_fh;

open my $readme_fh, '<', 'README.md' or die $!;
my $readme = do { local $/; <$readme_fh> };
close $readme_fh;

open my $release_doc_fh, '<', 'doc/update-and-release.md' or die $!;
my $release_doc = do { local $/; <$release_doc_fh> };
close $release_doc_fh;

like( $pm, qr/our \$VERSION = '([^']+)'/, 'module declares a version' );
my ($version) = $pm =~ /our \$VERSION = '([^']+)'/;
is( $version, '0.42', 'module version bumped for the release fix' );
like( $dist, qr/^version = \Q$version\E$/m, 'dist.ini version matches module version' );
like( $changes, qr/^\Q$version\E\s+\d{4}-\d{2}-\d{2}$/m, 'Changes top entry matches module version' );

for my $script (qw(bin/dashboard bin/of bin/open-file bin/pjq bin/pyq bin/ptomq bin/pjp)) {
    like( $makefile, qr/'\Q$script\E'/, "Makefile.PL ships $script" );
}

like( $readme, qr/cpanm \/tmp\/Developer-Dashboard-\Q$version\E\.tar\.gz -v/, 'README documents tarball install verification' );
like( $release_doc, qr/cpanm \/tmp\/Developer-Dashboard-\Q$version\E\.tar\.gz -v/, 'release doc documents tarball install verification' );
like( $release_doc, qr/tar -tzf Developer-Dashboard-\Q$version\E\.tar\.gz/, 'release doc documents tarball content verification' );

done_testing;

__END__

=head1 NAME

15-release-metadata.t - verify release metadata and tarball validation guidance

=head1 DESCRIPTION

This test keeps the shipped version metadata, executable list, and release
verification instructions aligned so the published tarball matches the source
tree that passed the test suite.

=cut
