# Resolving the checkout root in shell tools, instead of hardcoding it

`.claude/tools/board` solved "find the MAIN checkout from anywhere,
including a ticket worktree" for board access (DD-545), in Perl, using
`git --git-common-dir`. That solution was never shared - three other shell
tools (`board-pulse`, `next-action`, `tira-bridge-run`) each independently
hardcoded the checkout's absolute path instead, so each failed run from
anywhere else (DD-740).

## Why a hardcoded path breaks, specifically

A ticket worktree is cut from `origin/master` and carries no
`.developer-dashboard` runtime layer - only the main checkout has one. A
tool that assumes its own absolute path also works:

- from a sandbox at `~/Sandbox/ddd/<ref>` - a different directory entirely,
- from inside a Docker container - a different filesystem entirely,
- from a different machine, or a checkout moved to a different path.

`cd /home/mv/projects/developer-dashboard || exit 3` fails loudly in every
one of those cases, which is at least honest. `ROOT="/home/mv/projects/..."`
used as a base for further paths can fail more quietly, depending on what
those paths are then used for.

## The shared resolver: `.claude/tools/checkout-root`

```sh
. "$(dirname "$0")/checkout-root"
ROOT="$(dd_checkout_root)" || { echo "myself: cannot resolve the checkout root" >&2; exit 3; }
cd "$ROOT" || exit 3
```

It mirrors `board`'s own Perl resolution exactly:

```perl
my $common = `git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null`;
```

`--git-common-dir` resolves to the main repository's `.git` from inside any
linked worktree - a worktree's own `.git` is a file pointing at this, not a
directory - so it answers "which checkout is this a worktree OF", never
"where is the tree I am running from right now". That second question is
what `dirname(__FILE__)` or the caller's `$PWD` answer instead, and it is
the wrong question whenever the caller is a worktree.

**Resolve from the SCRIPT'S OWN location, never the caller's cwd.** A
caller may have already `cd`'d elsewhere before sourcing this file; the
answer must not depend on that.

## Why this belongs in one file, not three

`.claude/tools/host-ready` already established the pattern this project
uses for one shared shell definition consumed by several tools: source it,
call the function, never re-derive the same logic per caller (DD-729). Two
copies of a resolution that agree today are two resolutions to fix
separately tomorrow.

## Reviewing a change against this

- **A tool that needs the checkout root sources `checkout-root`, never
  hardcodes a path or re-derives `dirname(__FILE__)`'s own logic.**
- **The failure mode is preserved, not just the happy path.** Each of
  `board-pulse`, `next-action` and `tira-bridge-run` kept its own existing
  exit code (3) and message wording when the root cannot be resolved - the
  fix is additive, not a behavior change on the failure side.
- **A raw grep for the old literal path is the regression test.** Each
  caller's own spec now asserts (with comments stripped first, per the
  raw-source-grep-cannot-see-comments lesson) that the hardcoded path is
  gone and that `checkout-root` is sourced.

## Related

- `.claude/tools/board` itself - the original DD-545 resolution, in Perl,
  for board access specifically.
- `checkout-identity-and-unlanded-work.md` - a different question about
  checkouts (which one is "ours" and whether its work landed), not this
  page's subject (locating the one true main checkout from any of its
  worktrees).
