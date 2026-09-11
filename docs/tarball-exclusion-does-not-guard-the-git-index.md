# A tarball exclusion and a git-index guard are two different promises

`dist.ini`'s `exclude_filename`/`exclude_match` list keeps operator-local
files (`CLAUDE.md`, `.claude/`, and the rest) out of the *release tarball*.
Nothing about that list stops one of those files from being **committed to
git** - the two mechanisms protect against different failures, and one
being in place says nothing about the other.

## Why they are genuinely separate

- **The tarball guard** runs at `dzil build` time, reading the checkout's
  files from disk (`GatherDir`) and filtering by the exclude list. It has
  no idea what git thinks is tracked - a file that is both git-ignored and
  present on disk is excluded from the tarball the same way regardless.
- **The git index** is populated only by `git add`, and `.gitignore`
  prevents an *ordinary* add from picking a file up - but `git add -f`
  bypasses it, and nothing about the tarball exclusion list would notice
  or refuse a subsequent commit.

So a project can have a perfectly correct tarball exclusion list and still
be one `git add -f` (or a script that shells out to `git add -A` on a path
that happens to include an ignored file) away from committing operator
tooling straight into the published history.

## The concrete instance (DD-673)

`.claude/` holds 93KB+ of operator rules, git-ignored via a bare `.claude/`
line, and separately excluded from the release tarball via `dist.ini`'s
`exclude_match = ^\.claude/`. The owner's Q-057 decision (2026-08-29)
formally accepted the risk of this directory having no backup and no
history - a real, separate question about *loss*, not about *accidental
publication*.

A later finding narrowed what that acceptance did **not** cover: nothing
asserted `.claude/` stayed out of the git index, so a future accidental
commit would pass the tarball-exclusion gate (correctly - it is still
excluded from the build) and every other existing check silently, while
publishing operator tooling into the project's public git history anyway.

## The fix: assert the git-index guarantee directly

`t/15-release-metadata.t` already had this exact pattern for `.worktrees/`
and `dogfood-output/` (both sandbox-content classes, not operator files):

```perl
my @tracked = grep { m{^\.worktrees/} || m{^dogfood-output/} }
  split /\n/, `git -C @{[ _repo_path() ]} ls-files 2>/dev/null`;
is_deeply( \@tracked, [], 'no sandbox file is tracked in this repository' );
```

The same shape now covers `.claude/`: confirm the `.gitignore` line exists
*and* confirm `git ls-files` returns nothing under that prefix. Neither
half alone is sufficient - a `.gitignore` line only stops an *ordinary*
add, and an empty `git ls-files` result today says nothing about tomorrow
without a test re-checking it on every run.

## Reviewing a change against this

- **A tarball-exclusion entry and a git-tracking guarantee are two
  different claims.** Adding one is not evidence the other holds.
- **`git add -f` (or an unqualified `git add -A`/`-u`) is the failure mode
  this class of gap protects against** - not a hypothetical, since this
  project's own history includes at least one accidental untracking event
  from the opposite direction (DD-644, §43a in the board contract).
- **An owner's risk acceptance covers exactly what was asked**, never
  every adjacent question the same directory happens to raise. Read what
  was actually decided before treating a related-but-different gap as
  already settled.

## Related

- `checkout-identity-and-unlanded-work.md` - a different class of
  checkout-safety question (which checkout is "ours" and whether its work
  landed), not this page's subject.
