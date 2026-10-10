# AGENTS.md – Project Instruction Summary

## Overview
Developer‑Dashboard is a Perl‑based local development helper with a web UI, prompt integration and a CLI (`dashboard`).  All production code lives under `lib/Developer/Dashboard/` and the Perl distribution is built with ExtUtils::MakeMaker (`make`).  The repository also contains a small JavaScript fuzz test (`npm run fuzz:scorecard`).

## Development environment
- **Perl**: 5.38 (the Makefile hard‑codes `$VERSION = 3.33`).
- **Local CPAN lib** (recommended):
  ```bash
  cpanm --notest --local-lib-contained ./.perl5 Devel::Cover
  export PERL5LIB="$PWD/.perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"
  export PATH="$PWD/.perl5/bin:$PATH"
  ```
  Gives access to required modules (`Capture::Tiny`, `JSON::XS`, `LWP::UserAgent`, …) without touching the system Perl.
- **Node** (optional): needed only for the `fuzz:scorecard` script defined in `package.json`.
- **Docker**: used by integration tests (`integration/...`).  Ensure Docker is running and the image `dd-int-test:latest` can be built (`make dist` → `docker build`).
- **Operator files** (`*.md` such as `CLAUDE.md`, `ELLEN.md`, `MISTAKE.md`, `SCORECARD_ACTIONS.md`, etc.) are *git‑ignored* and never shipped.  They drive the internal SDLC and Kanban workflow.

## Build & test commands (verified)
- **Full test suite** (Perl): `make test` – expands to the `test_dynamic` target which runs `prove -lr t` with the proper `INST_LIB`/`INST_ARCHLIB` paths.
- **Coverage gate** (required for every change):
  ```bash
  cover -delete
  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t
  cover -report text -select_re '^lib/' -coverage statement -coverage subroutine -coverage branch -coverage condition
  ```
  The *Total* row must read `100.0` for **all four** metrics (statement, subroutine, branch, condition).  Unreachable branches/conditions must be annotated with `# uncoverable branch` or `# uncoverable condition`.
- **JavaScript fast‑check**: `npm run fuzz:scorecard` (runs `node t/fuzz/scorecard-fast-check.mjs`).
- **Installation** (local dev): `make install` – installs the Perl library and runs `install-private-cli-tools` which copies the bundled CLI helpers into `~/.developer-dashboard/cli/`.

## SDLC workflow (kanban-logged end-to-end)

**THE GOLDEN RULE: The Hermes kanban board (`.hermes/kanban.db`) is the single source of truth for all pipeline tracking. No work starts without a kanban ticket. No gate passes without a kanban comment. No ticket advances without a kanban record.**

The project follows the strict nested gate chain defined in `CLAUDE.md`.
```
PROBLEM → SOLUTION → SPEC → SOW →
  EPIC →
    TICKET( SCOPE + PLAN + IMP_DETAILS + TDD(RED TESTS) + BDD + ATDD )
      → IMPLEMENTATION
      → 100% CVE Free - cpan-audit installed and clean
      → 100% TESTED
      → 100% CODE COVERAGE (statement, subroutine, branch, condition)
      → E2E TEST (including cross‑platform QEMU/Docker runs)
```
Key points:
- **TDD first** – write a failing test (`t/…`) before any implementation.
- **100 % coverage** on *all four* Devel::Cover metrics is mandatory.
- **E2E cross‑platform gate** – when a change can behave differently across OSes, run the relevant QEMU Windows/macOS guests or Docker containers for other Linux distros (see `CLAUDE.md` for details).
- **Version gate** occurs at the *EPIC* level: after every ticket in the epic is finished, bump the version (see next section).
- **Git gate** is at the *TICKET* level – one commit + push per finished ticket. Follow the `git-commit-message-format` codename in `ELLEN.md`: use `Problem <number>: <specific title>`, a short summary on its own paragraph, then a multi-line `-` bullet list of delivered changes and verified checks. Preserve real line breaks; do not put the whole summary into the title or literal `\n` escapes. Inspect the final body with `git log -1 --format=%B`.
- **Release to PAUSE** is the final manual step (`dashboard pause-release`).  No automatic releases.

## Version bump procedure (gated by `t/15-release-metadata.t`)
1. Update `$VERSION` in the Makefile (`VERSION = X.XX`).
2. Update the `version =` line in `dist.ini` to the same value.
3. Update the `VERSION` line in the main POD (`lib/Developer/Dashboard.pm`).
4. Verify all `lib/**/*.pm` files now report a single identical version:
   ```bash
   grep -rhoE "VERSION = '[^']+'" lib | sort | uniq -c   # should report "1 X.XX"
   ```
5. Prepend (never rewrite) new entries to `Changes` and `FIXED_BUGS.md`.
6. Regenerate `README.md` via `perl script/sync-readme-from-pod`.
7. Run `t/15-release-metadata.t` to ensure the version bump is reflected everywhere.
8. Commit with a meaningful message and tag `vX.XX` (e.g. `git tag v4.23`).

## Coding conventions (observed)
- **Namespace**: all modules under `Developer::Dashboard::*`.
- **JSON**: use `JSON::XS` exclusively.
- **HTTP**: use `LWP::UserAgent` + `LWP::Protocol::https`.
- **Shell capture**: always the `Capture::Tiny` pattern:
  ```perl
  use Capture::Tiny qw(capture);
  my ($out,$err,$rc) = capture { system($cmd) };
  ```
- **Error handling**: never silence warnings; `use strict; use warnings;` are required and treated as errors by the test harness.
- **POD**: every public function must have a full POD block (`=head2`, description, args, return, examples).  The POD is rendered into `README.md` via `script/sync-readme-from-pod`; keep them in sync.  Boilerplate POD is a test failure.
- **Version consistency**: all `lib/**/*.pm` must share the same `$VERSION` as the Makefile and `dist.ini`.
- **Makefile**: generated by `Makefile.PL`.  Do **not** edit it manually; adjust `Makefile.PL` or the POD instead.
- **CI expectations**: `make test` passes, coverage passes all four metrics, `npm run fuzz:scorecard` exits 0.

## Common pitfalls
- Missing `PERL5LIB` – the test suite will pull system CPAN libs and may fail.
- Forgetting the `capture {}` block – error output is lost.
- Not running `install-private-cli-tools` after a fresh `make install`; the `dashboard` CLI will miss helper binaries.
- Docker integration tests require a built `dd-int-test:latest` image.
- Running `make` on Windows without GNU `make.cmd` shim leads to failures.
- Editing generated files (`Makefile`, generated sections of `README.md`) – changes will be overwritten; modify the source (`Makefile.PL` or POD) instead.
- Coverage gate omits branch/condition metrics – must be enabled with the four‑metric command above.
- E2E changes without running the QEMU/Docker matrix will be rejected.

## Quick start checklist
1. `cpanm --notest --local-lib-contained ./.perl5 Devel::Cover` and export env vars.
2. `make install` (installs library + CLI helpers).
3. `make test` – watch for any failures.
4. `cover -report text` – confirm `100.0` for *statement, subroutine, branch, condition*.
5. (optional) `npm run fuzz:scorecard`.
6. Follow the SDLC gates in `CLAUDE.md` for any new work.

*All agents load this file each session; keep it accurate and concise.*

## Operator communication
- Whenever sending Michael an update or status message, use the `say <message>` command so the message is delivered through the configured operator channel.
