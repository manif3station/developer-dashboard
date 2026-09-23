# dashboard's self-compile status: built, root causes fixed, exec live (DD-1010)

This page describes the current behavior of the system, not any one
ticket. `bin/dashboard` (and `bin/d2`, which re-execs it) compiles itself
into a standalone binary via the PAX subsystem
(`Developer::Dashboard::PaxCache`, `Developer::Dashboard::Pax::StandaloneImage`)
and execs that binary directly on later invocations instead of running
interpreted every time.

## What exists and is live

- **`Developer::Dashboard::PaxCache`** provides adaptive, per-source-hash
  compile-once caching: a resolve() call returns a cached binary path on a
  hit, or triggers a non-blocking background compile on a miss and returns
  undef immediately - a caller is never blocked waiting for a compile.
- **`Developer::Dashboard::Pax::StandaloneImage`** is the actual PAX
  compiler/linker that produces the standalone binary.
- **`bin/dashboard`'s `_maybe_exec_self_compiled_dashboard`** (DD-882,
  re-enabled by DD-1010) is wired into the switchboard's own startup path,
  calling `PaxCache->resolve($self_path)` for its own entrypoint on every
  invocation (skipped under `$ENV{HARNESS_ACTIVE}` so the test suite does
  not spawn its own compiles) and, on a defined hit, execs the resolved
  binary via `_exec_switchboard_command()` - the same mechanism the `ps1`
  allowlist (DD-877) already used.
- A narrow proof-of-concept allowlist (`PAX_CACHE_ELIGIBLE_COMMANDS`,
  DD-877) still exists for one staged helper command (`ps1`), independent
  of the main entrypoint's own self-exec.

## History: two real defects found and fixed before this could ship

Self-exec for the main dashboard entrypoint was disabled twice after real
defects surfaced in compiled-binary behavior, and re-enabled a third time
once both were fixed:

- **DD-905** found a compiled binary silently corrupting `%ENV` loading.
- **DD-922** root-caused and fixed that (a `local $/` scope bug in the
  vendored Pax runtime's script-unit dispatcher) and re-enabled exec.
- **DD-930** found a second, different defect minutes later (a
  `CodeUnitCompiler` special-case for `EnvLoader.pm` producing an
  unreachable method call in the compiled binary's runtime) and disabled
  exec again.
- **DD-1010** re-enabled exec once DD-930's own root cause had shipped,
  confirmed via t/182's regression coverage (both a hand-seeded sentinel
  binary and a REAL PAX compile of dashboard itself) and a full-suite
  verification run in a container.

## What full-suite verification found (DD-1010)

Running `prove -lr t` in a container with self-exec genuinely live (not
`DD_SKIP_REAL_PAX_COMPILE_TEST`-skipped) surfaced 9 failing test files.
Every one was independently confirmed to be a pre-existing environmental
gap in that container image, unrelated to self-exec:

- `t/108-cpan-security-metadata.t` (15 tests) - the `cpan-audit` binary is
  missing from the image (tracked separately as DD-1045).
- `t/13-integration-assets.t`, `t/34-scorecard-guardrails.t`,
  `t/158-operator-tool-specs.t` - the git-worktree-in-container limitation
  (a sandbox's `.git` gitlink points to an absolute host path invisible
  inside the container, so "tracked by git" assertions fail).
- `t/149/150/169/175/200` (32 tests, all coverage-gate/pax-coverage-select
  files) - `Devel::Cover` was not installed in the plain `dev` service
  image used for this check (it is a dev/test tool deliberately absent
  from `cpanfile`'s runtime deps). Installing it and re-running those 5
  files standalone: 67/67 PASS.

None of the 9 files' failures were caused by, or related to, dashboard's
own self-exec becoming live.

## Real measured timing (DD-1010)

In a container, MD5-cache-seeded from a real PAX build:

| what | time |
|---|---|
| Cold PAX compile of dashboard (117 app files) | 86.8s |
| Interpreted `dashboard version` (no cache) | 165ms |
| Self-exec warm run via `bin/dashboard` (cache hit, full exec chain) | 129-138ms |
| The SAME compiled binary invoked directly (bypassing the wrapper) | 2-4ms |

**The compiled binary itself is 40-80x faster than the interpreted path**,
but `bin/dashboard`'s own outer interpreted startup - loading Perl and
`require`ing `PaxCache.pm` just to check whether a cache hit exists -
currently dominates the end-to-end warm-path cost for a trivial command
like `version`. The real runtime-speed win from self-exec will be far more
visible on heavier commands, where the *avoided* interpreted body (not
just process startup) is itself expensive - the "version" measurement is
close to a worst case for showing the benefit, since there is almost
nothing to avoid.

## What is NOT covered by this page

The `PAX_CACHE_ELIGIBLE_COMMANDS` allowlist for individual staged helper
commands (currently just `ps1`) is a separate mechanism from the main
entrypoint's own self-exec this page describes, and is not widened by
DD-1010. Widening that allowlist, and the larger architectural question of
moving beyond pattern-matched code units toward genuine op-tree-driven
native compilation for real runtime speed (not just startup-avoidance),
is tracked separately - see the PAX-native-shape-JIT planning discussion
for that larger effort.
