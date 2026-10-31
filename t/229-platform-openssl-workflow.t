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
    qr/name: Prepare Homebrew OpenSSL 3 for macOS\s+if: startsWith\(matrix\.label, 'macOS'\)/,
    'both macOS architecture jobs have an explicit OpenSSL 3 preparation step',
);
like( $workflow, qr/brew install openssl\@3/, 'the workflow installs the supported Homebrew OpenSSL formula' );
like( $workflow, qr/OPENSSL_PREFIX=\$prefix.*GITHUB_ENV/s, 'the discovered OpenSSL prefix is exported to later steps' );
like( $workflow, qr/\[ ! -f "\$prefix\/include\/openssl\/ssl\.h" \]/, 'the workflow fails clearly if OpenSSL headers are absent' );
like( $workflow, qr/lipo -archs "\$prefix\/lib\/libssl\.dylib"/, 'the selected OpenSSL library architectures are inspected' );
like(
    $workflow,
    qr/expected_arch=x86_64.*DD_EXPECTED_ARCH.*arm64/s,
    'the selected OpenSSL library architecture follows the runner architecture',
);
like(
    $workflow,
    qr/grep -Eq .*\$expected_arch/s,
    'the selected OpenSSL library must include the expected architecture',
);
like(
    $workflow,
    qr/name: Install macOS Net::SSLeay with diagnostics\s+if: startsWith\(matrix\.label, 'macOS'\).*?cpanm --verbose --notest -L local Net::SSLeay/s,
    'both macOS jobs build Net::SSLeay with verbose compiler and linker diagnostics',
);
like(
    $workflow,
    qr/Prepare Homebrew OpenSSL 3 for macOS.*?Install project dependencies/s,
    'OpenSSL 3 is prepared before Net::SSLeay can be built as a project dependency',
);

done_testing();

__END__

=head1 NAME

t/229-platform-openssl-workflow.t - enforce macOS OpenSSL 3 setup

=head1 PURPOSE

This repository-only test checks the macOS dependency setup in the platform
compatibility workflow for both Intel x64 and ARM64. It requires Homebrew's
OpenSSL 3 formula, an explicit OpenSSL prefix for CPAN builds, a library check
against the runner architecture, and verbose Net::SSLeay build diagnostics.

=head1 WHY IT EXISTS

The platform workflow failed while building Net::SSLeay, a native dependency
of IO::Socket::SSL and LWP::Protocol::https. The macOS jobs must use Homebrew's
C<openssl@3> formula, selected through Net::SSLeay's C<OPENSSL_PREFIX>
environment variable. Making that selection explicit prevents default OpenSSL
discovery from choosing another installation and ensures build failures expose
their compiler and linker output on both macOS architectures.

=head1 WHEN TO USE

Run this test when changing either macOS runner, Perl dependency installation,
OpenSSL selection, or diagnostic output in the platform compatibility workflow.

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

Both macOS jobs install OpenSSL 3 through Homebrew, export its prefix, and check
that the selected library matches the runner's x64 or ARM64 architecture before
installing Perl dependencies.

=item *

If Net::SSLeay still fails to build, the macOS dependency step runs cpanm
verbosely so its configure, compiler, and linker diagnostics are visible in
the GitHub Actions log.

=back

=cut
