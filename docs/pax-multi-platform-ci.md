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
