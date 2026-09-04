# `docs/` and `doc/`: two directories, two different fates

Why this project has both a `docs/` and a `doc/` directory, why the
distinction is load-bearing, and what actually governs whether a page
reaches the release tarball. This page describes the system, not any one
ticket.

## The two directories

- **`docs/` (plural)** is the operator vault - SYSTEM-scoped pages
  describing what a mechanism in this codebase IS and how it behaves,
  written as part of a ticket's documentation gate. It is git-ignored by
  default (`*.md` in `.gitignore`), with individual pages tracked via an
  explicit negation.
- **`doc/` (singular)** is the shipped documentation directory - the pages
  that are part of the released distribution.

Confusing the two has real consequences in both directions: writing a page
meant for operators into `doc/` ships it to every installer; writing a page
meant to ship into `docs/` silently keeps it out of every release.

## What actually decides what ships

**`.gitignore` governs git tracking only. It does not decide what reaches
the release tarball.** That is `dist.ini`'s `[GatherDir]` plugin — and the
way it excludes `docs/` matters, because getting it wrong invites somebody to
delete the line that does the work.

`[GatherDir]` here declares no `root`, so it gathers the **whole distribution
root** — `docs/` included. What keeps the vault out of the tarball is one
explicit line:

    dist.ini:37    exclude_match = ^docs/

**Delete that line and `docs/` ships.** It is not belt-and-braces beside some
other protection; it is the only protection. `.gitignore` cannot stand in for
it, because dzil gathers from disk rather than from git — which is exactly how
`FIX.md` reached the local 4.22 tarball (DD-401).

Verified empirically (DD-683), because this is exactly the kind of claim
that must be checked rather than assumed: a `dzil build` before and after
widening `docs/`'s `.gitignore` whitelist from 19 per-page negations to a
single `!docs/*.md` glob produced a tarball with **zero** `docs/` entries
both times (checked against both the generated `MANIFEST` and the actual
tar contents), while `doc/`'s files were unaffected. Widening what git
tracks under `docs/` does not widen what ships, because what reaches the
tarball is decided by `exclude_match`, not by git. The check was right; the
reason it works is the exclusion above, not an absence of gathering.

## Why the vault whitelist is one glob, not one line per page

`docs/` is a flat directory with no subdirectories, so `!docs/*.md`
whitelists every page in it uniformly. The earlier convention - one
`!docs/<page>.md` negation added by whichever ticket created the page -
manufactured a merge conflict every time two tickets added a page at once:
both edited the same region of `.gitignore`, and the only correct
resolution was always "keep both lines," which is exactly the kind of
conflict that trains people to resolve without reading. A single glob
removes the conflict at its source: a new page needs no `.gitignore` edit
at all.

## How to apply

- Writing an operator-facing page describing a mechanism? It goes in
  `docs/` and needs no `.gitignore` change - the glob already covers it.
- Writing a page meant to ship with the distribution? It goes in `doc/`,
  and does need its own explicit whitelist entry (per-file, since `doc/`'s
  pages are curated individually, not a flat auto-included set).
- Before assuming a `.gitignore` change affects what ships, check
  `dist.ini`'s `[GatherDir]` - `.gitignore` and the release manifest are
  governed by different mechanisms, and the only way to be sure which
  applies is to build and look.
