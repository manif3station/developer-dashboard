# How PAX standalone binaries embed payloads on Windows

This page describes the current behavior of the system for
windows-amd64, and a still-planned mechanism for windows-arm64
(DD-1015). Everything below is marked with its actual confidence
level; nothing here should be treated as proven until a "VERIFIED
LIVE" note says so.

## windows-amd64: VERIFIED LIVE (DD-1015)

Confirmed via a real GitHub Actions `windows-latest` runner build
(the standard GitHub-hosted runner - no local QEMU/windev access was
needed or used for this; that host only matters for later functional
E2E verification of the compiled binary, not for compiling it).
`shogo82148/actions-setup-perl` installs Strawberry Perl on Windows,
which bundles its own MinGW-w64 C toolchain (real GNU `gcc`/`ld`/
`objcopy`) specifically so XS module compilation works - the same
toolchain `_compile_launcher`'s Windows path uses, with no separate
install step.

`StandaloneImage.pm::_compile_probe_object_header_multi_format`
compiles the same trivial probe DD-1020's Linux path already uses,
then distinguishes ELF from COFF by checking for ELF's unambiguous
magic bytes first; if absent, it reads the first 2 bytes as a COFF
`Machine` field and confirms it matches a known, real value (`0x8664`)
before treating it as COFF - COFF object files carry no signature the
way ELF/Mach-O do, so a recognized machine value is the only positive
confirmation available.
`_objcopy_target_for_coff_header` maps `0x8664` to `{output =>
'pe-x86-64', binary_architecture => 'i386:x86-64'}`.

## Why this is more tractable than macOS

`_compile_launcher`'s Linux path (DD-1020) converts each raw payload
file into a linkable object via GNU `objcopy --input binary --output
<target> --binary-architecture <arch>`. macOS's own toolchain
(`llvm-objcopy`, shipped by Xcode Command Line Tools) does not support
this same binary-to-object conversion for Mach-O at all (see
`docs/pax-macos-binary-embedding.md`).

**Windows is different: MinGW-w64 ships REAL GNU binutils**, the same
family DD-1020's Linux path already uses - `x86_64-w64-mingw32-objcopy`
and `aarch64-w64-mingw32-objcopy` support the identical `-I binary -O
<format> -B <arch>` conversion, targeting PE-COFF instead of ELF. This
means DD-1020's own probe-based mechanism
(`_compile_probe_object_header` / `_objcopy_target_for_elf_header`)
likely extends cleanly, by reading a compiled object's PE header
machine field instead of an ELF class/machine pair, and mapping to the
correct PE `--output` target name.

## PE machine-field values (verified against Microsoft's own docs)

Confirmed via Microsoft's official `winnt.h` reference
(learn.microsoft.com), not an unverified web search:

| Constant                   | Value    |
|-----------------------------|----------|
| `IMAGE_FILE_MACHINE_AMD64`  | `0x8664` |
| `IMAGE_FILE_MACHINE_ARM64`  | `0xAA64` |

## windows-arm64: still a placeholder

`_objcopy_target_for_coff_header` deliberately dies with a clear
message for any COFF machine value other than `0x8664` (amd64) rather
than guessing. binutils' PE-ARM64 objcopy target name was not
confirmed against the real tool before amd64 landed - PE support for
ARM64 in binutils may be less mature than amd64's and needs its own
verification pass, not an assumption it mirrors amd64's naming
(`pe-x86-64` -> something ARM64-specific, unconfirmed). Real
functional E2E verification of the compiled amd64 binary (does it
actually run correctly, not just "did the build step exit 0") is also
still open - that is where `windev`/QEMU access becomes genuinely
relevant, once there is a real binary worth verifying that way.

## Where to look

- `lib/Developer/Dashboard/Pax/StandaloneImage.pm::_compile_probe_object_header_multi_format`
  / `_objcopy_target_for_coff_header` - the Windows/COFF detection and
  mapping.
- `docs/standaloneimage-compile-launcher-error-reporting.md` - the
  Linux (DD-1020) side of the same subsystem.
- `docs/pax-macos-binary-embedding.md` - the macOS side, which needs a
  structurally different (non-objcopy) mechanism, unlike Windows.
- `.github/workflows/pax-release.yml`'s `windows-amd64` job - the real,
  landed build step; `windows-arm64` still shows the placeholder.
