# A stray, untracked file on disk ships in the release tarball unless it is named in dist.ini

`dzil build`'s `[GatherDir]` plugin reads whatever is present on disk in the
checkout root and below - it has no concept of git tracking status at all.
An untracked, un-gitignored file left behind by a local tool run (profiler
output, a scratch log, an editor swap file) is gathered exactly the same
way a real source file is, and ships in the tarball.

## Why `.gitignore` alone does not protect the tarball

`.gitignore` only ever affects `git add`/`git status` - it has no bearing
on what `GatherDir` reads from disk. And even a `.gitignore` entry only
helps if it exists *before* the stray file is created; a tool that drops
its output into the checkout root with no gitignore rule for it will leak
into every build until someone notices and adds one.

The only thing that actually keeps a file out of the tarball is `dist.ini`'s
own `exclude_filename`/`exclude_match` list - the same mechanism this
project already uses for every operator/dev-only file (`CLAUDE.md`,
`MISTAKE.md`, `SCORECARD_ACTIONS.md`, and the rest). A stray build/profiling
artifact needs the identical treatment: an explicit exclusion, not an
assumption that "it's not tracked, so it's fine."

## The concrete instance (DD-950)

A leftover `nytprof.out` (from someone running `perl -d:NYTProf` locally at
some point, dated a day before it was found) sat untracked and ungitignored
in the checkout root. `tar -tzf` on the built `Developer-Dashboard-4.46.tar.gz`
showed `Developer-Dashboard-4.46/nytprof.out` - it shipped, silently, because
nothing in `dist.ini` named it and nothing in `.gitignore` did either.

This is the same underlying mechanism as DD-401's `FIX.md` leak into the
4.22 tarball: **`dist.ini`'s exclusion list is the ONLY tarball protection**,
and it protects only what is explicitly listed in it.

## How to apply

- **Before treating a tarball audit as clean, actually list its full
  contents**, not just grep for the known operator-file names. `tar -tzf
  <tarball> | grep -iE '<the known list>'` only ever catches what is
  already on the list - the failure mode by definition is something that
  is not.
- **Every project-standard profiling/scratch-output convention deserves a
  standing `.gitignore` entry the moment it is adopted**, not only after
  the first leak is found (NYTProf's own default output is `nytprof.out`,
  or a `nytprof/` directory in `-d` "moose" mode).
- A `.gitignore` entry and a `dist.ini` exclusion are still two separate
  promises even here (see
  `tarball-exclusion-does-not-guard-the-git-index.md` for the operator-file
  version of that same split) - add both, don't assume one implies the
  other.

## Related

- `tarball-exclusion-does-not-guard-the-git-index.md` - the companion gap
  for *tracked* operator files (does an exclusion also guarantee the file
  never enters the git index), a different question from this page's
  (does an *untracked* stray file get excluded at all).
