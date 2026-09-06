# The version gate and the PAUSE release

Ticket commits never bump the version. The bump happens once per epic, at the
**version gate**, and the PAUSE upload is a separate terminal step that only
ever fires when the owner asks for it. This page records what those two steps
actually touch, and the places where following the procedure literally is not
enough.

## What a version bump has to change

Every one of these must end up declaring the same `X.XX`, or
`t/15-release-metadata.t` fails:

| what | where |
|---|---|
| `our $VERSION` | every `lib/**/*.pm` |
| `version =` | `dist.ini` |
| the bare version line under `=head1 VERSION` | **every module whose POD has that section**, not just the main one |
| the expected version literal | `t/15-release-metadata.t` |
| the generated version line | `README.md`, via `script/sync-readme-from-pod` — never by hand |

**The POD row is the one that bites.** It is natural to write the bump as a
substitution on the `$VERSION` assignment and then check by grepping for that
same pattern — which reports success while a bare version line in a POD
section still reads the old number. At the 4.30 gate that left
`Developer::Dashboard::Handle` with `$VERSION` at 4.30 and its own
`=head1 VERSION` at 4.29; the main module was not the only one with such a
section.

> **Verify by grepping for what should be ABSENT, not for what you replaced.**
> `grep -rn '<old version>' lib bin dist.ini share t/` answers "did anything
> survive"; grepping the pattern you just substituted only answers "did the
> substitution run", which you already know.

## Changes and FIXED_BUGS are append-only, and that is a count

Both files gain new entries at the top and never have an existing entry
rewritten. The check is a number, not an impression:

```sh
git diff v<previous> -- Changes FIXED_BUGS.md | grep -c '^-[^-]'   # must be 0
```

"The diff looks additive" is not a measurement. A removed line is the failure
mode, so count removed lines.

`FIXED_BUGS.md` does not begin with a version heading — it opens with a title
and then the newest version — so a new block is inserted *after* the title,
not at the start of the file. `Changes` does begin with its newest version, so
there a plain prepend is correct.

## Gate the tree that actually ships — and know what your tree is missing

A release must be gated on the tree that will be tagged. Two traps:

**A worktree silently runs a smaller suite.** `t/158-operator-tool-specs.t`
discovers and executes the operator specs under `.claude/tools/`, and skips
entirely when that directory is absent:

```perl
plan skip_all => 'not a source tree, or no operator tools directory'
  if !-e File::Spec->catdir($ROOT,'.git') || !-d $TOOLS;
```

The `.git` half is deliberately `-e` rather than `-d`, because a linked
worktree's `.git` is a *file* holding a gitdir pointer — so that half passes in
a worktree. What fails is `-d .claude/tools`: `.claude/` is untracked, so a
fresh worktree has none, roughly a hundred tests stop running, and the suite
still reports green with a smaller number and no explanation. Gate a release
where those specs exist.

**`.claude/tools/` is inside your gate but outside every diff.** Because it is
untracked, an edit there shows in neither `git status` nor `git diff`, yet
t/158 shells out to those specs during the run, and `coverage-run`'s
working-state fingerprint walks the directory by relative path and content. So
an edit there can both redden a gate and move the fingerprint of a verdict
whose tree you believe you inspected. When more than one session shares a
checkout, freeze `.claude/tools/` along with `t/` and `lib/`.

## Uncommitted work belonging to someone else

A shared checkout may carry another session's in-flight work when the gate
runs. That is survivable, but only if it is stated: name the exact paths in the
gate evidence rather than implying a pristine tree, and confirm each one is
outside the shipped artifact. `dist.ini` excludes `docs/` from the tarball via
`exclude_match = ^docs/`, so a docs page present during the run does not reach
CPAN — but that is a fact to check in `dist.ini`, not to assume.

Stage by explicit path. `git add -A` on a shared checkout sweeps another
session's work into the release commit.

## What the PAUSE step actually does

`dashboard pause-release` is operator-local and is not part of this
repository. Read it before running it; in outline it:

1. reads the version from `dist.ini` and expects
   `Developer-Dashboard-<version>.tar.gz`, running `dzil build` if it is absent
   — which happens *before* the `--dry-run` branch, so a dry run on an
   unbuilt tree still builds a tarball;
2. sources the shell profile for the PAUSE credentials;
3. uploads with `cpan-upload`;
4. force-moves the `PAUSE_RELEASED_HERE` tag to the released commit and pushes
   it.

**`PAUSE_RELEASED_HERE` is the only record of what was actually uploaded.** A
`vX.XX` tag says a version gate happened; it does not say the tarball reached
CPAN. Reading both answers a question neither answers alone — at the 4.30 gate
the `v4.29` tag sat 178 commits behind HEAD while `PAUSE_RELEASED_HERE` sat 63
commits behind it, which together established that 4.29 was both tagged *and*
uploaded and therefore unavailable to reuse.

## Order

```
bump every declaration  ->  Changes + FIXED_BUGS (append)  ->  regenerate README
  ->  security protocol  ->  full suite  ->  coverage 100.0 on all four metrics
  ->  dzil build  ->  the post-build guards  ->  audit the archive's contents
  ->  commit  ->  tag vX.XX  ->  push          (the push fires the signed release)
  ->  the PAUSE upload                          (only on an explicit request)
```

Audit the built archive by listing it, rather than by trusting the exclusion
list that was supposed to keep a file out of it.
