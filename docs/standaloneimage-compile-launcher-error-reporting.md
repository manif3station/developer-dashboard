# StandaloneImage's launcher compile step reports the real build failure

This page describes the current behavior of the system, not any one
ticket. `Developer::Dashboard::Pax::StandaloneImage::_compile_launcher`
compiles a Pax launcher binary in two nested `eval` blocks: the first runs
`objcopy` and `cc`; the second restores the process's original working
directory afterward, regardless of whether the first succeeded.

## Why this matters

Perl resets `$@` to the empty string at the start of every `eval` block,
and again on that block's successful completion. Two sequential `eval`
blocks therefore share one mutable `$@` - whichever eval ran *last*
determines what `$@` holds, not whichever eval actually failed.

The cwd-restore eval runs unconditionally after the build eval, regardless
of whether the build succeeded. If the build eval died (objcopy or cc
failed) and the restore eval then succeeded - the common case, since
restoring a working directory rarely fails - the restore eval's own
success resets `$@` to `''`, destroying the build failure's diagnostic
message before anything reads it.

## The fix

Each eval's `$@` is captured into its own local variable **immediately**
after that eval returns, before the other eval runs and can overwrite the
shared `$@`:

```perl
my $ok = eval { ... 1; };
my $build_error = $@;                                    # captured first
my $restore_ok = eval { chdir $cwd or die "..."; 1; };
my $restore_error = $@;                                   # captured second
return { status => 'not_built', reason => $build_error }   if !$ok;
return { status => 'not_built', reason => $restore_error } if !$restore_ok;
```

The failure path that actually occurred now reports its own real
diagnostic - `objcopy code.pkg failed`, `launcher compile failed`, or
whichever step died - instead of an empty string whenever the cwd restore
that follows happened to succeed.

## Verification

`t/209-standaloneimage-build-error-capture.t` proves this directly: it
forces `objcopy` to fail (via a stubbed `_which` pointing at a failing
binary) while the cwd restore succeeds, and asserts the returned `reason`
contains the real objcopy failure text rather than an empty string. It
also proves the cwd-restore failure path reports its own distinct message,
and that the happy path (`status => 'built'`) is unaffected.

## Architecture detection for objcopy (DD-1020)

`_compile_launcher`'s four `objcopy` calls previously hardcoded
`--output elf64-x86-64 --binary-architecture i386:x86-64` unconditionally
- correct only when the build host itself is x86_64. Confirmed live in
real CI: `linux-arm64` failed outright (`objcopy code.pkg failed` -
objcopy cannot honor an x86-64 spec on an aarch64 toolchain), and
`linux-i686` failed at the final link (`launcher compile failed` - a
32-bit/64-bit object mismatch, since objcopy kept emitting 64-bit x86-64
objects while DD-1013's `-m32` `cc` wrapper linked for 32-bit).

**First fix attempt (superseded the same day) detected the build host's
architecture from `$Config{archname}`.** That is wrong for a
cross-compiling target: confirmed live in real CI, `linux-i686` still
failed at the final link even after this landed, because that runner
cross-compiles 32-bit objects via a `-m32`-forcing `cc` wrapper on an
ordinary *native x86_64* Perl - `$Config{archname}` there is
`x86_64-linux-gnu-thread-multi` regardless of the actual `-m32` target,
so the archname-based detection silently selected the wrong (64-bit)
spec. `gcc -m32 -dumpmachine` also does not report the 32-bit target on
this project's own hosts, so no metadata-only signal here is
trustworthy.

**The real fix compiles a probe object with the ACTUAL `cc` and reads
back its genuine ELF header** - `_compile_probe_object_header($cc)`
writes a trivial `int main(void) { return 0; }`, compiles it with
whatever `cc` `_compile_launcher` will actually use (honoring any PATH
wrapper, `-m32` included), and reads the resulting object's real
`EI_CLASS`/`e_machine` bytes directly. `_objcopy_target_for_elf_header`
maps that pair to the correct `objcopy` target - every value verified
against the *real* tool, not assumed:

| ELF class | `e_machine` | `--output`             | `--binary-architecture` |
|-----------|-------------|-------------------------|--------------------------|
| 64-bit    | EM_X86_64 (62)  | `elf64-x86-64`          | `i386:x86-64`            |
| 32-bit    | EM_386 (3)      | `elf32-i386`            | `i386`                   |
| 64-bit    | EM_AARCH64 (183)| `elf64-littleaarch64`   | `aarch64`                |

The aarch64 row was confirmed by installing real cross-binutils
(`binutils-aarch64-linux-gnu`) in a fresh container and running
`aarch64-linux-gnu-objcopy --info` directly - not by trusting an
unverified web search result. Confirmed live via a real GitHub Actions
run (35714535676) that the archname-based version genuinely fixed
`linux-arm64` (a native aarch64 runner, real artifact produced) while
missing only `linux-i686` for the cross-compilation reason above -
`linux-amd64` was unaffected throughout.

**Scope note:** this only covers Linux hosts (amd64/i686/aarch64) -
whether macOS ships an `objcopy` compatible with this mechanism at all
(Apple's own toolchain differs from GNU binutils) is a separate, deeper
question, left for whichever ticket does real macOS verification of the
PAX standalone build.
