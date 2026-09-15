# PAX on Alpine i686: two stacked bugs, not one

Follow-up to
[docs/pax-alpine-and-runtime-speed-measured.md](pax-alpine-and-runtime-speed-measured.md)
(DD-872), which found PAX's `bin/dashboard` build fails on Alpine x86_64
(musl) with one specific, fixable `objcopy` bug. The owner asked whether
the same holds on Alpine i686 (32-bit x86). It does, plus a second,
separate bug that DD-872 could not have seen on a 64-bit target.

## Bug 1: the same objcopy ambiguity as DD-872

PAX's `_compile_launcher` (`lib/PAX/StandaloneImage.pm`, in the sibling
`~/projects/pax` checkout) shells out to `objcopy` with abbreviated GNU
long options:

    objcopy --input binary --output elf64-x86-64 --binary-architecture i386:x86-64 code.pkg code.pkg.o

Reproduced live in a genuine 32-bit `i386/alpine:3` container (confirmed
32-bit via `readelf -h /bin/busybox` showing `Class: ELF32`,
`Machine: Intel 80386` - Docker on Linux runs a 32-bit container's
userland natively through the kernel's IA-32 compatibility mode, so
`uname -m` inside can misleadingly still report the host's `x86_64`; the
binaries themselves are the real signal):

    objcopy: option `--input' is ambiguous

Identical failure mode to DD-872's x86_64 finding - this binutils build
(2.45.1) rejects the same abbreviation regardless of target word width.

## Bug 2: the hardcoded output format is wrong for 32-bit targets

This one only shows up once you go looking for it on a 32-bit target,
which is why DD-872 (64-bit only) could not have found it. The same
`_compile_launcher` invocation hardcodes:

    --output elf64-x86-64 --binary-architecture i386:x86-64

unconditionally, for every target, with no branch anywhere in the
function that selects a 32-bit output format. Confirmed by reading the
function's full body (all four `objcopy` calls use the identical
64-bit-only string) and by testing directly: running the corrected
option names (`--input-target`/`--output-target`, fixing Bug 1) but
*still* with the hardcoded 64-bit values produces the wrong artifact -
whereas substituting the correct 32-bit values,

    objcopy --input-target binary --output-target elf32-i386 --binary-architecture i386 code.pkg code.pkg.o

succeeds and produces a genuine 32-bit object, verified directly:

    readelf -h code.pkg.o
      Class:    ELF32
      Machine:  Intel 80386

So fixing Bug 1 alone (spelling out the long options) is not sufficient
for a working i686 build - PAX would compile without error but link a
64-bit object header into what is supposed to be a 32-bit launcher.

## What this means for SOW DDS-001 / epic DDE-002

- i686 support needs BOTH of PAX's own fixes: the option-abbreviation fix
  DD-872 already identified, AND making the output-target/architecture
  values conditional on the actual build target's word width instead of
  hardcoded to 64-bit.
- Both are PAX's own bugs to fix, not developer-dashboard's - reported as
  findings to hand back to that project, consistent with DD-872's
  objcopy finding.
- This project's own CLAUDE.md already documents Alpine/iSH-aware code in
  `RuntimeManager` (POSIX signal handling), so platform-sensitive spots
  in this codebase are a known category - this is the same shape one
  level down, in the compiler PAX itself rather than in our own code.
