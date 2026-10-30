use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );

plan skip_all => 'GitHub workflow sources are excluded from source distributions'
  if !-d File::Spec->catdir( $ROOT, '.github' );

# _slurp($path)
# Purpose: read a repository-owned workflow for platform dependency assertions.
# Input: path to the platform-compatibility workflow.
# Output: the complete file content, or an empty string if the path is absent.
sub _slurp {
    my ($path) = @_;
    return q{} if !-f $path;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh or die "Unable to close $path after reading: $!";
    return defined $content ? $content : q{};
}

my $workflow_path = File::Spec->catfile( $ROOT, '.github', 'workflows', 'platform-compatibility.yml' );
my $workflow = _slurp($workflow_path);

ok( -f $workflow_path, 'the platform compatibility workflow exists' );
like(
    $workflow,
    qr/name: Prepare Homebrew OpenSSL for macOS arm64\s+if: matrix\.label == 'macOS arm64'/,
    'the macOS arm64 job has an explicit OpenSSL preparation step',
);
like( $workflow, qr/brew install openssl\@3/, 'the workflow installs the supported Homebrew OpenSSL formula' );
like( $workflow, qr/OPENSSL_PREFIX=\$prefix.*GITHUB_ENV/s, 'the discovered OpenSSL prefix is exported to later steps' );
like( $workflow, qr/\[ ! -f "\$prefix\/include\/openssl\/ssl\.h" \]/, 'the workflow fails clearly if OpenSSL headers are absent' );
like( $workflow, qr/lipo -verify_arch arm64 .*libssl\.dylib/, 'the selected OpenSSL library is verified as arm64' );
like(
    $workflow,
    qr/name: Install macOS arm64 Net::SSLeay with diagnostics\s+if: matrix\.label == 'macOS arm64'.*?cpanm --verbose --notest -L local Net::SSLeay/s,
    'macOS arm64 Net::SSLeay failures include verbose compiler and linker diagnostics',
);
like(
    $workflow,
    qr/Prepare Homebrew OpenSSL for macOS arm64.*?Install project dependencies/s,
    'OpenSSL is prepared before Net::SSLeay can be built as a project dependency',
);

done_testing();

__END__

=head1 NAME

t/229-platform-openssl-workflow.t - enforce explicit macOS ARM64 OpenSSL setup

=head1 PURPOSE

This repository-only test checks the macOS ARM64 dependency setup in the
platform compatibility workflow. It requires a pinned Homebrew OpenSSL formula,
an explicit OpenSSL prefix for CPAN builds, an ARM64 library check, and verbose
dependency-build diagnostics on that runner.

=head1 WHY IT EXISTS

The platform workflow failed while building Net::SSLeay, a native dependency
of IO::Socket::SSL and LWP::Protocol::https. Net::SSLeay supports the
C<OPENSSL_PREFIX> environment variable to select its OpenSSL installation.
Making that selection explicit prevents the runner's default OpenSSL discovery
from silently choosing a different installation and ensures a future build
failure exposes its compiler and linker output.

=head1 WHEN TO USE

Run this test when changing the macOS ARM64 runner, Perl dependency
installation, OpenSSL selection, or diagnostic output in the platform
compatibility workflow.

=head1 HOW TO USE

Run the test inside the development container:

    d2 docker compose exec dev prove -lv t/229-platform-openssl-workflow.t

The test skips when the workflow files are absent from a source distribution.

=head1 WHAT USES IT

The repository test suite runs this test alongside the other workflow contract
tests. It reads the checked-in workflow only; it does not contact GitHub,
install OpenSSL, or execute a macOS build.

=head1 EXAMPLES

=over 4

=item *

The macOS ARM64 job installs OpenSSL 3 through Homebrew, exports its prefix, and
checks that the selected library contains ARM64 code before installing Perl
dependencies.

=item *

If Net::SSLeay still fails to build, the macOS ARM64 dependency step runs
cpanm verbosely so its configure, compiler, and linker diagnostics are visible
in the GitHub Actions log.

=back

=cut
