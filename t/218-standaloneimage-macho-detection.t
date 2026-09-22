#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneImage;

# AC-1: Mach-O magic bytes are recognized and reported as a distinct
# format, distinguishable from ELF/COFF - never silently mistaken for
# either, and never guessed at for a target this project cannot verify
# live from this host.
#
# Magic values are the real, documented Mach-O header constants from
# <mach-o/loader.h> (Apple's own headers): MH_MAGIC_64 = 0xfeedfacf
# (64-bit, native byte order), MH_CIGAM_64 = 0xcffaedfe (64-bit,
# byte-swapped - the form a little-endian host like an Apple Silicon Mac
# actually writes to disk, since the magic constant itself is defined in
# BIG-endian conceptual order and the file's bytes are the host's native
# byte order). A real macos-arm64 `cc -c` output's first 4 bytes are
# therefore CF FA ED FE, not FE ED FA CF - this project's own probe must
# recognize the on-disk (byte-swapped) form, not just the constant's
# textbook value.
my @magic_cases = (
    [ "\xcf\xfa\xed\xfe", 'MH_CIGAM_64 (on-disk bytes for a real little-endian arm64 Mach-O object)' ],
    [ "\xfe\xed\xfa\xcf", 'MH_MAGIC_64 (big-endian host form, recognized defensively)' ],
    [ "\xce\xfa\xed\xfe", 'MH_CIGAM (32-bit byte-swapped)' ],
    [ "\xfe\xed\xfa\xce", 'MH_MAGIC (32-bit)' ],
);

for my $case (@magic_cases) {
    my ( $magic, $label ) = @$case;
    ok(
        Developer::Dashboard::Pax::StandaloneImage::_is_macho_magic($magic),
        "recognizes $label as Mach-O"
    );
}

# AC-2: real ELF and COFF magic are never misclassified as Mach-O.
ok( !Developer::Dashboard::Pax::StandaloneImage::_is_macho_magic("\x7fELF"), 'ELF magic is not Mach-O' );
ok( !Developer::Dashboard::Pax::StandaloneImage::_is_macho_magic("\x64\x86\x00\x00"), 'a COFF AMD64 machine field (0x8664 LE) is not Mach-O' );
ok( !Developer::Dashboard::Pax::StandaloneImage::_is_macho_magic("\x00\x00\x00\x00"), 'all-zero bytes are not Mach-O' );

# AC-3: _compile_launcher_darwin exists and, called against a manifest,
# fails with a clear, honest reason rather than silently producing a
# broken binary - this sub's real -sectcreate/getsectbyname mechanism is
# implemented (DD-1014) but has ONLY been verified against real
# documentation, never a live macOS toolchain (macdev unreachable, no
# other macOS host available to this host). Calling it on THIS (Linux)
# host must fail cleanly at the "no macOS toolchain here" point, not
# produce something that looks like success.
{
    my $manifest = {
        output_path      => '/tmp/dd-t218-darwin-probe',
        code_units       => [],
        runtime_payloads => [],
        assets           => [],
        native_payloads  => [],
    };
    my $result = Developer::Dashboard::Pax::StandaloneImage::_compile_launcher_darwin($manifest);
    is( $result->{status}, 'not_built', '_compile_launcher_darwin reports not_built on a non-macOS host' );
    like( $result->{reason}, qr/mach-o|darwin|sectcreate/i, 'the failure reason names the macOS-specific mechanism, not a generic error' );
}

done_testing();

__END__

=pod

=head1 NAME

218-standaloneimage-macho-detection.t - proves DD-1014's Mach-O format detection

=head1 PURPOSE

Guards C<Developer::Dashboard::Pax::StandaloneImage>'s ability to
recognize a compiled probe object as Mach-O (macOS), distinct from the
ELF (Linux, DD-1020) and COFF (Windows, DD-1015) formats the same
probe-based detection strategy already handles - the entry point
C<_compile_launcher> needs to route macOS builds to a structurally
different mechanism (C<-sectcreate> at link time, no objcopy-equivalent
step at all - see C<docs/pax-macos-binary-embedding.md>) rather than
attempting (and silently failing or misbehaving on) the objcopy path
that only works for ELF/COFF.

=head1 WHY IT EXISTS

Without explicit Mach-O recognition, a macOS host would either crash
inside C<_objcopy_target_for_compiler> with a generic "neither ELF nor
COFF" error that does not explain the REAL reason (macOS's own
llvm-objcopy cannot do binary-to-object conversion at all - a tooling
gap, not a missing-target-name gap), or worse, silently proceed down a
path assuming ELF/COFF semantics and produce a broken binary. This file
proves the detection is explicit and the failure path (when run on a
non-macOS host, as this test always is) is honest about why.

=head1 WHEN TO USE

Run this file whenever C<StandaloneImage.pm>'s Mach-O detection or
C<_compile_launcher_darwin> changes.

=head1 HOW TO USE

    prove -lv t/218-standaloneimage-macho-detection.t

Real functional verification of the C<-sectcreate>/C<getsectbyname>
mechanism itself requires a real macOS toolchain (a macos-14 GitHub
Actions runner, or macdev) - this file only proves the detection logic
and the clean-failure path on a non-macOS host, both of which are
testable anywhere.

=head1 WHAT USES IT

C<StandaloneImage.pm>'s Mach-O detection and macOS launcher-compile path
are not exercised by any other test file in this suite.

=head1 EXAMPLES

Example 1:

    prove -lv t/218-standaloneimage-macho-detection.t

Confirm Mach-O magic recognition and the clean-failure path.

=cut
