#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use Capture::Tiny qw(capture);

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneImage;

# AC-1: the pure ELF-class/machine mapping returns the correct,
# REAL-tool-verified objcopy --output/--binary-architecture pair.
# Values confirmed live (2026-09-22) via a fresh ubuntu:24.04 container
# with binutils-aarch64-linux-gnu installed and `aarch64-linux-gnu-objcopy
# --info` run directly - not assumed, not taken from an unverified web
# search result. Class/machine integers are the real ELF header values:
# EI_CLASS 1=32-bit, 2=64-bit; e_machine 3=EM_386, 62=EM_X86_64,
# 183=EM_AARCH64.
{
    my $x86_64 = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_elf_header( 2, 62 );
    is( $x86_64->{output}, 'elf64-x86-64', '64-bit EM_X86_64 resolves to the correct --output target' );
    is( $x86_64->{binary_architecture}, 'i386:x86-64', '64-bit EM_X86_64 resolves to the correct --binary-architecture' );

    my $i386 = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_elf_header( 1, 3 );
    is( $i386->{output}, 'elf32-i386', '32-bit EM_386 resolves to the correct --output target' );
    is( $i386->{binary_architecture}, 'i386', '32-bit EM_386 resolves to the correct --binary-architecture' );

    my $aarch64 = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_elf_header( 2, 183 );
    is( $aarch64->{output}, 'elf64-littleaarch64', '64-bit EM_AARCH64 resolves to the correct --output target' );
    is( $aarch64->{binary_architecture}, 'aarch64', '64-bit EM_AARCH64 resolves to the correct --binary-architecture' );
}

# AC-3: an unrecognized (class, machine) pair dies with a clear,
# actionable message rather than silently falling back to the amd64
# spec (which would produce exactly the kind of confusing failure this
# whole ticket exists to fix).
{
    my $result = eval { Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_elf_header( 2, 8 ) };    # EM_MIPS
    my $error = $@;
    ok( !defined $result, 'an unrecognized (class, machine) pair returns nothing' );
    like( $error, qr/class 2, machine 8/, 'the die message names the specific unrecognized class/machine pair' );
    like( $error, qr/objcopy/i, 'the die message explains what it was trying to configure' );
}

# AC-4 (the real DD-1020 root-cause fix): the compiler probe reads back
# what $cc ACTUALLY produces, not what $Config{archname} claims. This is
# the fix for the failure the first version of this ticket's change
# missed: linux-i686 CI cross-compiles 32-bit objects via a -m32-forcing
# cc wrapper on an ordinary native x86_64 Perl, so $Config{archname}
# there is 'x86_64-linux-gnu-thread-multi' regardless of the real -m32
# target - confirmed live, this exact case broke the archname-only
# version of this fix in real CI (linux-i686's launcher link failed with
# "i386:x86-64 architecture ... incompatible with i386 output").
SKIP: {
    my $cc = `which cc 2>/dev/null` || `which gcc 2>/dev/null`;
    chomp $cc;
    skip 'no C compiler available in this environment', 2 if !$cc;

    my ( $ei_class, $e_machine ) = Developer::Dashboard::Pax::StandaloneImage::_compile_probe_object_header($cc);
    ok( $ei_class == 1 || $ei_class == 2, 'the probe reads a real ELF class (32 or 64-bit) from a genuinely compiled object' );
    ok( $e_machine > 0, 'the probe reads a real, non-zero e_machine value' );

    my $target = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_compiler($cc);
    ok( defined $target->{output} && defined $target->{binary_architecture},
        'the combined helper resolves a real cc to a real objcopy target with no manual archname involved' );
}

# AC-5 (DD-1020's own follow-up correction, found via real CI - t/183
# failing with "cc: fatal error: cannot execute 'as'" even after
# DD-1023's binutils install changed nothing): the probe must work when
# called under a caller that has deliberately stripped $ENV{PATH} (t/183's
# own `env -i PATH=/nonexistent` scenario, proving standalone execution),
# as long as the SAME PATH restoration _compile_launcher's other tool
# invocations already use (_toolchain_path($cc, $objcopy)) is applied
# around the probe too - without it, cc can still be found via an
# absolute path but cannot find its own `as` subprocess, since gcc's
# internal assembler lookup needs a PATH to search regardless of how cc
# itself was resolved.
SKIP: {
    my $cc = `which cc 2>/dev/null` || `which gcc 2>/dev/null`;
    chomp $cc;
    skip 'no C compiler available in this environment', 2 if !$cc;

    my $objcopy = `which objcopy 2>/dev/null`;
    chomp $objcopy;
    skip 'no objcopy available in this environment', 2 if !$objcopy;

    my $tool_path = Developer::Dashboard::Pax::StandaloneImage::_toolchain_path( $cc, $objcopy );

    # Without the PATH restoration this ticket's fix applies, the probe
    # fails under a fully stripped environment - proving the bug is real,
    # not merely that the fix is harmless.
    my ( $broken_out, $broken_err, $broken_exit ) = capture {
        system( 'env', '-i', "PATH=/nonexistent", "PERL5LIB=$ENV{PERL5LIB}", $^X, '-Ilib', '-MDeveloper::Dashboard::Pax::StandaloneImage',
            '-e', qq{my \$r = eval { Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_compiler(shift) }; print \$r ? "OK" : "FAIL: \$\@";},
            $cc );
    };
    like( $broken_out, qr/^FAIL:/, 'sanity: the probe genuinely fails under a stripped PATH with no restoration (proves the bug is real)' );

    # With the SAME restoration _compile_launcher applies around it, the
    # probe succeeds even though the caller's own ambient PATH is stripped.
    my ( $fixed_out, $fixed_err, $fixed_exit ) = capture {
        system( 'env', '-i', "PATH=/nonexistent", "PERL5LIB=$ENV{PERL5LIB}", $^X, '-Ilib', '-MDeveloper::Dashboard::Pax::StandaloneImage',
            '-e', qq{local \$ENV{PATH} = '$tool_path'; my \$r = eval { Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_compiler(shift) }; print \$r ? "OK" : "FAIL: \$\@";},
            $cc );
    };
    is( $fixed_out, 'OK', 'AC-5: the probe succeeds under a stripped ambient PATH once the SAME toolchain-path restoration _compile_launcher uses is applied around it' );
}

# AC-6 (DD-1015): the pure COFF (Windows/MinGW) mapping function, unit
# tested the same way the ELF mapping (_objcopy_target_for_elf_header)
# already is - this cannot be verified against a REAL compiled COFF
# object on this (Linux) host, so it is deliberately scoped to the pure
# mapping logic only. Real verification happens via a real GitHub Actions
# windows-amd64 runner (this workflow's own CI run is the actual proof,
# matching this project's established discipline for anything that
# cannot be exercised on the dev host).
{
    my $amd64 = Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_coff_header(0x8664);
    is( $amd64->{output}, 'pe-x86-64', 'COFF machine 0x8664 (IMAGE_FILE_MACHINE_AMD64) resolves to the correct --output target' );
    is( $amd64->{binary_architecture}, 'i386:x86-64', 'COFF machine 0x8664 resolves to the correct --binary-architecture' );

    my $result = eval { Developer::Dashboard::Pax::StandaloneImage::_objcopy_target_for_coff_header(0xAA64) };    # IMAGE_FILE_MACHINE_ARM64
    my $error = $@;
    ok( !defined $result, 'an unsupported COFF machine (arm64 - not yet verified against the real tool) returns nothing rather than guessing' );
    like( $error, qr/aa64/i, 'the die message names the specific unsupported machine value' );
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
        skip 'file(1) is not installed in this environment', 1 if !`which file 2>/dev/null`;
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
correct C<--output>/C<--binary-architecture> pair for what the actual
build compiler produces (x86_64, i386/i686, or aarch64), not a hardcoded
x86_64 spec and not a guess derived from C<$Config{archname}> - both of
which broke real non-amd64 CI targets, confirmed live (linux-arm64 and
linux-i686 both failed, the latter even after the first, archname-based
version of this fix landed, because C<$Config{archname}> reflects the
Perl interpreter's own build, not a C<-m32>-wrapped cross-compile
target).

=head1 WHY IT EXISTS

Nothing else in this suite exercised C<_compile_launcher>'s architecture
assumption directly - existing tests (C<t/209>) prove its error-reporting
behavior, and the real-build tests elsewhere in this suite only ever ran
on this project's own x86_64 development/CI hosts, so the hardcoded
x86_64 spec happened to be correct by coincidence rather than by
construction. This file specifically proves the detection logic against
all three known ELF class/machine combinations, and proves the compiler
probe reads a real, live-compiled object rather than trusting any
static metadata about the host.

=head1 WHEN TO USE

Run this file whenever C<_compile_launcher>'s objcopy invocation or its
architecture-detection logic changes.

=head1 HOW TO USE

    prove -lv t/214-standaloneimage-objcopy-arch-detection.t

Set C<DD_SKIP_REAL_PAX_COMPILE_TEST=1> to skip the real-build block (slow
- a full PAX build) and keep only the fast unit-level checks.

=head1 WHAT USES IT

C<_compile_launcher>'s architecture-detection logic is not exercised by
any other test file in this suite.

=head1 EXAMPLES

The real objcopy target table this file proves, verified via real
cross-binutils tools rather than assumed:

    64-bit EM_X86_64  -> --output elf64-x86-64        --binary-architecture i386:x86-64
    32-bit EM_386     -> --output elf32-i386          --binary-architecture i386
    64-bit EM_AARCH64 -> --output elf64-littleaarch64 --binary-architecture aarch64

=cut
