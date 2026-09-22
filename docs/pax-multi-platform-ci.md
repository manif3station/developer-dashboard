# Multi-platform PAX CI

Standalone `d2`/`dashboard` binaries, built and functionally verified for
every supported platform/arch on every push to `master`.

## What this is

A GitHub Actions workflow that wires this project's existing PAX
self-compile system (`dashboard pax build`, backed by
`lib/Developer/Dashboard/Pax/StandaloneImage.pm`,
`StandaloneRuntime.pm`, `CodeUnitCompiler.pm`, and the rest of
`lib/Developer/Dashboard/Pax/`) into a CI build matrix. It is not a new
compilation approach — `pax build` already produces a working, fully
self-contained binary for a single platform when run locally (see
`t/182-dashboard-self-compile.t`, `t/183-pax-cli-build-run-contract.t`).
This workflow runs that same build once per platform/arch target and
publishes each result.

## Platform/arch matrix

Owner-confirmed (resolved via DD-1007's comment thread before this epic
existed):

| OS      | Architectures       |
|---------|----------------------|
| macOS   | arm64                |
| Linux   | arm64, amd64, i686   |
| Windows | arm64, amd64         |

Six targets total. Notably **no macOS x86_64/Intel** target — this was an
ambiguity in the original request that the owner resolved explicitly.

## Trigger

Runs on push to `master` — i.e. at this project's own git-gate step (`git
add`, `git commit`, `git merge` branch back to master, `git push`),
matching the established convention already used by
`release-github.yml`/`package-ghcr.yml`.

## Correctness bar

The owner's own words: *"The independent binary d2/dashboard will be 100%
functional matching to the source Perl script."* A binary that merely
finished building is not sufficient evidence of that. Each of the 6
binaries must be run through a real functional/smoke check before
publishing:

- **Linux targets** verify natively in the CI runner.
- **Windows/Mac targets** verify via this project's existing E2E
  convention — a genuine `qemu-system-x86_64` guest boot (the `windev`/
  `macdev` hosts, or a prepared qcow2), never a cross-compiled artifact
  nobody actually ran. See `CLAUDE.md`'s "E2E cross-platform gate" section
  for the established discipline this workflow must follow inside CI.

## Native builds only — no cross-compilation

`StandaloneImage.pm`'s `_compile_launcher` shells out to `cc`/`objcopy` on
whatever host it runs on and produces a binary for *that host's own*
platform/arch — there is no cross-compilation path. Every matrix job must
therefore run natively on (or under genuine emulation for) its own target;
none of the 6 jobs can build another job's target.

## Runner mapping (verified 2026-09-22)

| Target             | Runner                                    | Notes |
|---------------------|--------------------------------------------|-------|
| Linux amd64          | `ubuntu-latest`                            | native |
| Linux arm64          | `ubuntu-24.04-arm` (or current GA label)   | native — GitHub-hosted arm64 Linux runners are GA |
| Linux i686           | `ubuntu-latest` + `gcc-multilib`/`-m32`, or QEMU-user | **no native 32-bit GitHub-hosted runner exists** — this is the one target needing a workaround, left for DD-1013 to resolve |
| macOS arm64          | `macos-14` (or current default)            | native Apple Silicon |
| Windows amd64        | `windows-latest`                           | native |
| Windows arm64        | `windows-11-arm` (or current GA label)     | native — GitHub-hosted Windows arm64 runners reached GA in 2025-08 (public repos) / 2026-01 (private repos); an earlier draft of this page incorrectly assumed no such runner existed |

Exact runner labels should be re-confirmed against GitHub's current
documentation when DD-1013/DD-1014/DD-1015 actually wire their build
steps — GitHub's runner-image naming has changed before and will again.

## Build invocation: no paxfile.yml needed

`t/182-dashboard-self-compile.t` already proves the simplest working
form: `pax build --compact -o <output> bin/dashboard` — a direct
positional entrypoint argument, no `paxfile.yml` at all. The build tool
auto-discovers dependencies via its own capture/manifest step. DD-1013's
Linux CI jobs mirror this exact proven local invocation rather than
authoring a new build-spec file — simpler, and more directly "wire the
EXISTING pax build command" (DDE-006's own stated intent) than inventing
a new mechanism.

**Dashboard first, d2 followed once unblocked.** `bin/d2`'s re-exec line
used to unconditionally shell through `perl` to invoke its sibling
`dashboard`, with no handling for the case where that sibling is a
*compiled* binary rather than Perl source — found live while implementing
DD-1013, fixed by DD-1017 (a shebang-byte check now branches the dispatch
correctly for either case). DD-1013 itself still ships dashboard-only;
adding d2 to its CI matrix entries is natural follow-up work now that the
blocker is cleared.

## CI environment gap: cpanm is not preinstalled

Found live (DD-1018, 2026-09-22): every real `pax-release.yml` CI run
failed from the moment it first shipped, because GitHub-hosted
`ubuntu-latest`/`ubuntu-24.04-arm` runners do not ship `cpanm`
pre-installed — they are generic runners, not Perl-specific images. The
local `dashboard pax build` invocation this file wires in was never in
question (proven working by DD-1013's own local and container-based
tests); the gap was purely that CI never got as far as running it.

The fix already exists in this repo: `test.yml` bootstraps Perl and
`cpanm` via `shogo82148/actions-setup-perl` (a pinned SHA, `perl-version:
'5.44'`) before any `cpanm`-dependent step. `pax-release.yml`'s Linux jobs
need the identical step.

## CI environment gap: `as` is not reliably present (DD-1023)

Found live (2026-09-22): `release-github.yml` and `test.yml`'s
`ubuntu-latest` runners failed t/183's self-hosted pax-build scenarios
(which compile real C code) with `cc: fatal error: cannot execute
'as': execvp: No such file or directory` - the GNU assembler was
missing entirely on the runner, in a way neither workflow had ever
installed explicitly. `pax-release.yml`'s own `linux-i686` job does not
hit this, because it already installs `gcc-multilib`/`g++-multilib`
explicitly for its own 32-bit cross-compile - the other two workflows
never had an equivalent step, because neither previously needed to
compile anything.

Fixed by adding an explicit `apt-get install -y build-essential
binutils` step to both `release-github.yml` and `test.yml`, before
dependency installation - matching the same "install the toolchain
explicitly, never assume the runner image provides it" discipline this
page already documents for `cpanm` and the i686 32-bit workaround
above.

## The i686 workaround

The only one of the 6 targets with no native GitHub-hosted runner
(verified 2026-09-22): install `gcc-multilib`/`g++-multilib` on an
`ubuntu-latest` (amd64) runner, then put a wrapper named `cc` earlier on
`PATH` that forces `-m32` — `StandaloneImage.pm`'s `_compile_launcher`
hardcodes `_which('cc') || _which('gcc')` and never reads `$ENV{CC}`, so
a plain `CC=...` override is silently ignored.

**The wrapper must exec an absolute `cc` path, never the bare name.**
DD-1013 caught this live: a wrapper written as `exec cc -m32 "$@"`
resolves `cc` through the very `PATH` it was just prepended to, finds
itself, and calls itself forever — observed as an 18+ minute CPU-pegged
runaway with zero output. Resolve the real `cc` first
(`real_cc=$(command -v cc)`), then have the wrapper `exec` that absolute
path.

## Structure

This capability is broken into an epic (DDE-006) containing:

- one ticket for the workflow skeleton and its trigger,
- one ticket per platform/arch target (6 total),
- one ticket for the functional-parity verification harness shared across
  targets.

Each child ticket carries its own acceptance criteria; the epic's own
acceptance criteria (recorded on DDE-006, not duplicated here) are
verified against the *assembled* workflow once every child lands — per
this project's own SOW/EPIC/TICKET convention, a parent's acceptance
criteria are never just the sum of its children's.

## Origin

Filed as DD-1007 (superseded, discarded — see DD-1007's own comment
pointing here), whose own scope note called for exactly this
decomposition: *"expect this to decompose into an EPIC with several
tickets... per this project's own SOW/EPIC/TICKET sizing convention."*
