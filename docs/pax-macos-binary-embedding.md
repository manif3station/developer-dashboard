# How PAX standalone binaries will embed payloads on macOS

This page describes a planned mechanism, not yet implemented or
verified live (DD-1014) - it exists to record sourced research so the
next work on this doesn't start cold. Everything below is marked with
its actual confidence level; nothing here should be treated as proven
until a "VERIFIED LIVE" note says so.

## Why the Linux mechanism doesn't transfer

`_compile_launcher`'s Linux path (DD-1020) converts each raw payload
file into a linkable object via `objcopy --input binary --output
<target> --binary-architecture <arch>`, then links those objects into
the final launcher binary. The generated C source reads the payload
back through symbols GNU objcopy names automatically:
`_binary_<file>_start` / `_binary_<file>_end`.

**llvm-objcopy - the tool Xcode Command Line Tools actually ships -
does not support this same binary-to-object conversion for Mach-O.**
Passing `-O mach-o-arm64` for a binary input returns "invalid output
format" (documented LLVM behavior across multiple releases). There is
no drop-in Mach-O row to add to DD-1020's ELF-class/machine lookup
table - macOS needs a structurally different embedding mechanism, not
a table extension.

## The mechanism macOS is expected to use: `-sectcreate`

`cc`/`ld`'s own `-sectcreate <segment> <section> <file>` flag embeds a
raw file's bytes directly into a Mach-O section **at link time** - no
separate objcopy-equivalent step at all:

```sh
cc -sectcreate __DATA __mypayload payload.bin -o out main.c
```

This is the documented, standard technique for embedding arbitrary
data into a macOS executable (used for exactly this class of problem
by, among others, Node.js's own "Single Executable Application"
tooling on macOS).

**The runtime read-back side is also different, not just the build
side.** `-sectcreate` produces no `_binary_*_start` symbols the way
objcopy does - the embedded section must be located at runtime via
`getsectbyname()` / `getsectdata()` from `<mach-o/getsect.h>`. So
`_launcher_source()` (the C template generator) needs a real
macOS-specific branch, not just a different `system()` call in
`_compile_launcher`.

**Known constraint to verify:** Mach-O segment/section names are
limited to 16 characters each, unlike ELF symbol names. This project's
payload file names (`code.pkg`, `runtime.pkg`, `assets.pkg`,
`native.pkg`) need an explicit, verified mapping to valid Mach-O
section names, not an assumption that the existing names fit.

## What is NOT yet verified

None of the above has been confirmed by actually compiling and running
anything on real macOS - `macdev` (this project's real QEMU macOS host)
was not reachable during DD-1014's research session (SSH connection
refused, no local container running). Before implementation lands:

1. Confirm `-sectcreate` actually works as documented on a real
   macos-14/arm64 Xcode toolchain.
2. Confirm the section-name-length mapping.
3. Confirm `getsectbyname()` correctly reads back an embedded payload
   at runtime, on the actual compiled binary.

## Where to look

- `lib/Developer/Dashboard/Pax/StandaloneImage.pm::_compile_launcher` -
  the Linux/ELF path this needs a macOS sibling for.
- `docs/standaloneimage-compile-launcher-error-reporting.md` - the
  Linux (DD-1020) side of the same subsystem.
- `.github/workflows/pax-release.yml`'s `macos-arm64` job - currently
  a placeholder (`echo "TODO (DD-1014/1015)..."`), to be replaced once
  this mechanism is verified.
