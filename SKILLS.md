# Working on Developer Dashboard

How this repo is actually built, tested, and released. Full operator/agent detail
lives in `CLAUDE.md` (not shipped); this is the short, public-facing version for
anyone building or contributing to the distribution itself.

## Layout

- `bin/dashboard` and `bin/d2` are the two shipped entrypoints; `bin/d2` re-execs
  `dashboard` with the same arguments.
- `bin/dashboard` is a thin switchboard - it bootstraps, runs layered hooks,
  stages command bodies, and `exec`s. Command implementations live in
  `share/private-cli/`, staged as working copies at first use.
- `lib/Developer/Dashboard/` is the module tree: `RuntimeManager` (process
  lifecycle), `Web::*` (Dancer2 app, Starman server), `PageRuntime` (saved
  pages/ajax), `CollectorRunner` (scheduled checks), `Housekeeper` (cleanup),
  `PathRegistry`/`Config` (the layered `.developer-dashboard/` directory stack).
- `t/*.t` covers `lib/`; each carries POD naming what it covers.
- `.github/workflows/` contains **four** workflows: the
  `five-platform-coverage.yml` orchestrator, reusable Linux coverage, and
  reusable Windows amd64 and arm64 coverage. By default tests run serially
  on macOS arm64, Ubuntu amd64, Ubuntu arm64, Windows amd64 and Windows arm64,
  each with ten TAP workers and 100% four-metric coverage. A real Git tag
  pointing at the current commit, such as `git tag win-amd64`, selects just
  that platform; multiple Git tags select stages in the usual order. See
  `docs/ci-workflow-triggers.md` for tag creation and push instructions.
  The separate Linux unit-test, Docker Hub and release workflows are retired.

## Running the tests

```
PERL5LIB="$HOME/perl5/lib/perl5" prove -j 10 -lr t
```

`PERL5LIB` must be inline on every invocation - this project's dependencies
(`Plack::Runner`, `Dancer2`, `TOML::Parser`, ...) live outside the system perl
tree, and it is not exported by non-interactive shells.

## Coverage

`lib/` must reach 100.0 on all four Devel::Cover metrics (statement, branch,
condition, subroutine):

```
perl script/coverage-gate --jobs 10
```

Every tracked Perl module/test/script in the POD coverage surface must also
contain valid POD, and every tracked Markdown file must pass the structural
Markdown coverage checks:

```
perl script/pod-coverage-gate
perl script/markdown-coverage-gate
```

All three gates must report `100.0%`; any lower result exits non-zero.

A branch or condition that is genuinely unreachable on the test host must
carry its own `# uncoverable branch ...` / `# uncoverable condition ...`
comment - one criterion per comment line.

## Building the tarball

```
PERL5LIB="$HOME/perl5/lib/perl5" dzil build
```

Operator-only files (`CLAUDE.md`, internal rule and planning documents) are
excluded via `dist.ini`'s `[GatherDir] exclude_filename` / `exclude_match`
list - never via `.gitignore`, which `dzil` does not consult.

## Release

Version is `X.XX` (two decimals, never reused, read from the newest `git tag`).
A version bump touches every `lib/**` `$VERSION`, `dist.ini`, the main POD, and
`t/15-release-metadata.t`'s expected value in one atomic change, then tags
`vX.XX` and pushes it. Releases must now be published manually.
CPAN upload is a separate, manual step.

## Two entrypoints, one CLI

`bin/dashboard` and `bin/d2` must both stay listed in `Makefile.PL`'s
`EXE_FILES`, or a fresh install silently drops one of them.
