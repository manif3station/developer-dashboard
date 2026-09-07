# Ticket sandboxes and the shared operator tools directory

How `.claude/tools/ticket-worktree` keeps a ticket's git worktree in sync with
the main checkout's shared, git-ignored operator tools and specs.

## The problem this solves

Every ticket is worked in its own `git worktree` under `~/Sandbox/ddd/<ref>`,
cut from `origin/master`. `git worktree add` checks out **tracked** files
only. `.claude/tools/` is entirely git-ignored (owner rule, 2026-08-29), so a
fresh sandbox's `.claude/tools/` starts empty except for whatever files that
one ticket happens to create directly inside it.

That silently breaks anything that expects the shared tools/specs to be
present. `t/158-operator-tool-specs.t` is a non-empty-set discriminator by
design (DD-573): it asserts the tools directory holds at least 13 specs
rather than trusting an empty result. Run from inside a sandbox missing the
sync, it correctly goes red on what looks like an almost-empty population -
not because anything is broken, but because the shared tooling was never
copied in (DD-815).

## The rule

> **A ticket sandbox's `.claude/tools/` is synced from the main checkout on
> both creation and resume.** `ticket-worktree` copies every file the main
> checkout's `git ls-files --others --ignored --exclude-standard` reports
> under `.claude/tools/`, without overwriting a file the sandbox has already
> modified locally.

This is the same pattern documented publicly for git worktrees and untracked
files in general - enumerate what git itself reports as ignored, then copy
it - rather than a blind `rsync` of the whole directory, which could carry
scratch/junk files a ticket left there.

## Where it runs

Both places `ticket-worktree` can hand back a sandbox path:

- **Create** - `git worktree add` just succeeded for a ticket with no
  existing sandbox.
- **Resume** - an existing sandbox was found and is being reopened; it may
  have been created before a newer tool existed in the main checkout.

Skipping either path leaves that sandbox's `.claude/tools/` stale - the
create path leaves it empty on day one, the resume path leaves it missing
whatever the main checkout has gained since.

## What this does NOT change

`t/158-operator-tool-specs.t` itself is untouched. Its whole purpose is to
fail on a genuinely empty or near-empty population rather than pass
silently - lowering its threshold, or special-casing a sandbox, would defeat
that. The fix belongs in how the sandbox is populated, not in what the test
expects to find there.
