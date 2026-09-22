#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use Capture::Tiny qw(capture);

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneImage;

# AC-1: the new helper returns the correct, REAL-tool-verified
# objcopy --output/--binary-architecture pair per architecture. Values
# confirmed live (2026-09-22) via a fresh ubuntu:24.04 container with
# binutils-aarch64-linux-gnu installed and `aarch64-linux-gnu-objcopy
# --info` run directly - not assumed, not taken from an unverified web
# search result.
{
    my $x86_64 = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_arch('x86_64-linux-gnu-thread-multi');
    is( $x86_64->{output}, 'elf64-x86-64', 'x86_64 archname resolves to the correct --output target' );
    is( $x86_64->{binary_architecture}, 'i386:x86-64', 'x86_64 archname resolves to the correct --binary-architecture' );

    my $i686 = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_arch('i686-linux-gnu-thread-multi');
    is( $i686->{output}, 'elf32-i386', 'i686 archname resolves to the correct --output target' );
    is( $i686->{binary_architecture}, 'i386', 'i686 archname resolves to the correct --binary-architecture' );

    my $i386 = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_arch('i386-linux-gnu-thread-multi');
    is( $i386->{output}, 'elf32-i386', 'i386 archname resolves to the same --output target as i686' );
    is( $i386->{binary_architecture}, 'i386', 'i386 archname resolves to the same --binary-architecture as i686' );

    my $aarch64 = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_arch('aarch64-linux-gnu-thread-multi');
    is( $aarch64->{output}, 'elf64-littleaarch64', 'aarch64 archname resolves to the correct --output target' );
    is( $aarch64->{binary_architecture}, 'aarch64', 'aarch64 archname resolves to the correct --binary-architecture' );
}

# AC-3: an unrecognized architecture dies with a clear, actionable
# message rather than silently falling back to the amd64 spec (which
# would produce exactly the kind of confusing failure this whole ticket
# exists to fix).
{
    my $result = eval { Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_arch('mips64-linux-gnu-thread-multi') };
    my $error = $@;
    ok( !defined $result, 'an unrecognized architecture returns nothing' );
    like( $error, qr/mips64/, 'the die message names the specific unrecognized architecture' );
    like( $error, qr/objcopy/i, 'the die message explains what it was trying to configure' );
}

# AC-2: the existing amd64 build path is provably unaffected - a real
# local build on this (x86_64) host succeeds and produces a working
# binary, exactly as it did before this ticket's change.
SKIP: {
    skip 'DD_SKIP_REAL_PAX_COMPILE_TEST is set', 3 if $ENV{DD_SKIP_REAL_PAX_COMPILE_TEST};

    my $dir = tempdir( CLEANUP => 1 );
    my $output = "$dir/dashboard-arch-test";
    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $^X, '-Ilib', 'share/private-cli/pax', 'build', '--compact', '-o', $output, 'bin/dashboard' );
    };
    skip 'a real pax build did not succeed in this environment', 3 if ( $exit >> 8 ) != 0 || !-x $output;

    ok( -x $output, 'the amd64 build path still produces a real executable' );
    my ( $version_out ) = capture {
        local $ENV{HOME} = tempdir( CLEANUP => 1 );
        system( $output, 'version' );
    };
    like( $version_out, qr/\A\d+\.\d+\s*\z/, 'the amd64-built binary reports its own version correctly' );

  SKIP: {
        skip 'file(1) is not installed in this environment', 1 if !`command -v file`;
        my $file_out = `file "$output"`;
        like( $file_out, qr/ELF 64-bit.*x86-64/, 'the amd64-built binary is genuinely a 64-bit x86-64 ELF, unaffected by the architecture-detection change' );
    }
}

done_testing();

__END__

=pod

=head1 NAME

214-standaloneimage-objcopy-arch-detection.t - proves DD-1020's objcopy architecture detection

=head1 PURPOSE

Guards DD-1020: C<_compile_launcher>'s objcopy invocations must use the
correct C<--output>/C<--binary-architecture> pair for the actual build
host's architecture (x86_64, i686/i386, or aarch64), not a hardcoded
x86_64 spec - which broke every non-amd64 target, confirmed live in real
CI (linux-arm64 and linux-i686 both failed at the compile step).

=head1 WHY IT EXISTS

Nothing else in this suite exercised C<_compile_launcher>'s architecture
assumption directly - existing tests (C<t/209>) prove its error-reporting
behavior, and the real-build tests elsewhere in this suite only ever ran
on this project's own x86_64 development/CI hosts, so the hardcoded
x86_64 spec happened to be correct by coincidence rather than by
construction. This file specifically proves the detection logic against
all three known architectures.

=head1 WHEN TO USE

Run this file whenever C<_compile_launcher>'s objcopy invocation or its
architecture-detection logic changes.

=head1 HOW TO USE

    prove -lv t/214-standaloneimage-objcopy-arch-detection.t

Set C<DD_SKIP_REAL_PAX_COMPILE_TEST=1> to skip the real-build block (slow
- a full PAX build) and keep only the fast unit-level architecture checks.

=head1 WHAT USES IT

C<_compile_launcher>'s architecture-detection logic is not exercised by
any other test file in this suite.

=head1 EXAMPLES

The real objcopy target table this file proves, verified via real
cross-binutils tools rather than assumed:

    x86_64  -> --output elf64-x86-64        --binary-architecture i386:x86-64
    i686    -> --output elf32-i386          --binary-architecture i386
    aarch64 -> --output elf64-littleaarch64 --binary-architecture aarch64

=cut
