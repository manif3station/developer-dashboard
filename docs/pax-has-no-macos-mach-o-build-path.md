# PAX's compile stage has no macOS (Mach-O) build path

Follow-up to
[docs/pax-alpine-and-runtime-speed-measured.md](pax-alpine-and-runtime-speed-measured.md)
(DD-872), which proved PAX compiles `bin/dashboard` on Linux (glibc, and
Alpine musl once a `binutils` abbreviated-flag bug was worked around). The
owner asked (Telegram msg #1962, 2026-09-15) whether the same build has been
tried on macOS. It has not, and it currently cannot be, for a reason
verifiable from PAX's own source with no macOS machine required (DD-876,
2026-09-15).

## The mechanism: objcopy, hardcoded to ELF

PAX's standalone-binary build embeds four packaged assets (`code.pkg`,
`runtime.pkg`, `assets.pkg`, `native.pkg`) into the final executable by
shelling out to `objcopy` (`lib/PAX/StandaloneImage.pm`, around line
1351-1367):

    objcopy --input binary --output elf64-x86-64 --binary-architecture i386:x86-64 code.pkg code.pkg.o

The `--output` target is the literal string `elf64-x86-64` for all four
packages, and the whole file has **zero** `$^O` or `uname` checks - no
platform-conditional branch exists anywhere in it. This is not "PAX fails on
macOS": there is no macOS code path to fail. The step was written for one
object format only.

## Why installing a different tool on macOS would not help

The natural next question - could a macOS-side `objcopy` (or its LLVM
equivalent) simply be pointed at a Mach-O target instead - was checked
against both toolchains' own documentation and a real reported attempt
(2026-09-15):

- **GNU binutils `objcopy`** has never had a Mach-O write target in its BFD
  output-target list, on any current build (`objcopy --help` enumerates the
  supported `-O` targets; Mach-O is not among them). Stock macOS does not
  ship this tool at all.
- **`llvm-objcopy`** (the closest macOS-available equivalent, via
  `brew install llvm`) does not support it either: a user who tried
  `llvm-objcopy -I binary -O mach-o-arm64` got an explicit
  `invalid output format` error, and `--binary-architecture` is documented
  as accepted-but-ignored there.

So the raw-binary-to-object-file idiom PAX relies on for this embedding step
has no Mach-O equivalent in either toolchain PAX could reach for. Closing
this gap is a real PAX-project change (a macOS-specific embedding path,
whatever mechanism macOS's own toolchain supports for it - `ld -r`,
a `.o` built from an assembly stub, or similar), not a flag PAX or this
project could set today.

## What this means for the PAX-compiled-d2/dashboard effort (DDS-001)

The `PaxCache` wrapper
([docs/paxcache-md5-keyed-non-blocking-compile-cache.md](paxcache-md5-keyed-non-blocking-compile-cache.md))
degrades gracefully whenever PAX cannot produce a binary - on macOS today,
every `resolve()` call would behave exactly like PAX-not-installed:
always-interpreted, never blocking, never attempting a compile it knows will
fail. No code in this repository needs to special-case macOS for that
reason. Getting a macOS-native compiled binary at all is upstream PAX work,
tracked as an open question rather than a developer-dashboard defect.

## What was NOT done, and why

The literal ask was to attempt the build on `macdev` (this project's real
macOS QEMU guest). At the time of this investigation the guest was not
running (SSH refused, no `qemu-system` process on the host, no discoverable
provisioning script) - the source-level finding above is decisive
independently of whether the guest happens to be up, so this was reported
to the owner as a card question (Q-161) rather than spending a QEMU boot
cycle to reconfirm a conclusion the source and both toolchains' own
documentation already settle. If empirical on-guest confirmation is still
wanted once macdev is reachable, the reproduction is: `pax build
bin/dashboard` on macdev, expect a failure at the `objcopy` step (or, if
`objcopy`/`llvm-objcopy` is not even installed there, a failure earlier, at
tool resolution).
