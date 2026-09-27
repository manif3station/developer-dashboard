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

## How the exclusions are guarded, and how the guard guards itself

`dist.ini`'s exclusions are the only thing keeping the vault, operator tooling
and `OLD_CODE/` out of a release archive, so `t/15-release-metadata.t` checks
them two different ways — and the difference matters.

**By spelling.** A handful of `like()` assertions pin that specific
`exclude_match` lines are present, plus two `unlike()` assertions pinning that
`integration/` and `.md` are *not* excluded. Those catch a deleted line. They
cannot catch a line that is present and wrong.

**By meaning.** A second block compiles *every* `exclude_match` out of
`dist.ini` and applies the compiled patterns to sample paths, asserting each
sample is excluded. Its own comment states the principle: text assertions
"cannot catch a pattern that is present but does not actually match the paths it
is meant to stop".

The second is the stronger check, and it had a gap that is worth understanding
because the shape recurs: **the patterns were derived, but the samples were
not.** Every pattern in `dist.ini` was compiled and applied — to a hardcoded
list of eight paths. Nine patterns therefore matched nothing in that list, were
exercised by nothing, and passed in silence. Three of them were `^docs/`,
`^\.claude/` and `^OLD_CODE/`.

So the block that was gated by meaning rather than spelling was itself gated by
a list somebody had to remember to extend.

**The fix is to derive the second half too:**

```perl
for my $pat (@exclude_match) {
    ok( scalar( grep { $_ =~ $pat } @must_be_excluded ),
        "at least one sample path exercises $pat" );
}
```

Now a new `exclude_match` added without a sample *fails*. Adding the nine
missing samples alone would have closed the gap for exactly as long as nobody
touched `dist.ini` again.

**The general form, which is not about tarballs at all:** when a check derives
one half of its inputs and hardcodes the other, the hardcoded half is where it
silently stops covering things. Ask of any guard not only "what does it check"
but "what would have to be added by hand for it to keep checking everything".

One thing these samples do *not* test: `dist.ini`'s patterns are applied here by
Perl, not by `dzil`. `GatherDir` matches `exclude_match` against paths relative
to the distribution root — which is the form these samples use — but it also
prunes matching *directories* during traversal rather than filtering file by
file. The samples verify the pattern; `t/36-release-kwalitee.t` verifies a real
built archive. Neither replaces the other.

## A missing `doc/` whitelist entry doesn't just fail to ship - it can lose the edit entirely

Forgetting `docs/`'s glob costs nothing (a new page is covered automatically).
Forgetting `doc/`'s per-file entry is a different failure shape, and it is
worse than "the page doesn't ship": since every ticket sandbox is disposable
and gets cleaned up after merge, an untracked edit inside `doc/` that nobody
ever `git add`ed is not lying dormant somewhere waiting to be whitelisted -
it is gone the moment that sandbox is removed.

Measured directly (DD-1042): a ticket's own comment claimed it had "updated
the existing SYSTEM-scoped `doc/ask.md`" for a CLI feature. Checked later -
`git log --all -- doc/ask.md` returned nothing, ever, on any branch, and the
file did not exist on disk in any sandbox. The edit, if it was ever written,
was a plain file sitting in that ticket's own sandbox, invisible to git
because `doc/`'s whitelist had no line for it, and it stopped existing the
day that sandbox was cleaned up. No error, no warning - the next person to
look just finds nothing where a page was claimed to be.

It cost nothing real here only because the feature turned out to already be
correctly documented elsewhere, in `docs/` (the plural vault), under a
different name than the one the ticket's comment used - the "existing
SYSTEM-scoped" phrasing was itself a symptom of the confusion this page
exists to prevent: `doc/` (singular) is the shipped/process-doc directory,
never the SYSTEM-scoped-mechanism one, and a per-CLI-feature page belongs in
`docs/`, not `doc/`, regardless of whitelisting.

**The lesson: before writing into `doc/`, ask whether the page is really a
shipped/process doc (security, testing, release process) rather than a
SYSTEM-scoped mechanism description - the latter belongs in `docs/` and needs
no whitelist edit at all. If a page genuinely belongs in `doc/`, add its
whitelist line in the SAME commit that adds the page**, not as a follow-up -
an untracked file in a sandbox that will be deleted is not a "add the
whitelist line later" TODO, it is a page with an expiry date nobody set on
purpose.

## How to apply

- Writing an operator-facing page describing a mechanism? It goes in
  `docs/` and needs no `.gitignore` change - the glob already covers it.
- Writing a page meant to ship with the distribution? It goes in `doc/`,
  and does need its own explicit whitelist entry (per-file, since `doc/`'s
  pages are curated individually, not a flat auto-included set) - add that
  entry in the same commit as the page, or the edit can be lost outright
  once its sandbox is cleaned up, not merely left unshipped.
- Before assuming a `.gitignore` change affects what ships, check
  `dist.ini`'s `[GatherDir]` - `.gitignore` and the release manifest are
  governed by different mechanisms, and the only way to be sure which
  applies is to build and look.
