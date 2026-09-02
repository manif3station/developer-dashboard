# Checkouts on this host: which are ours, and whether their work landed

This host carries many working copies of this repository, plus working copies
of *other* projects sitting in the same directories. Anything that walks them —
a sweep looking for work nobody has landed, a script cleaning up, a person
answering "is there anything unfinished on disk?" — has to answer two questions
before it can say anything true:

1. **Is this checkout ours?**
2. **Did the work in it land?**

Both have obvious cheap answers that are wrong, and the wrong answers do not
look wrong. This page describes the system, not any one ticket.

## There are at least three roots, and one of them is inside the checkout

    /home/mv/Sandbox/ddd                               the declared root
    /home/mv/dd-worktree-sandbox                       the superseded root, still populated
    /home/mv/projects/developer-dashboard/.worktrees   inside the main checkout

Measured 2026-09-02: 169 registered worktrees, split 32 / 100 / 36. The third is
the one people forget, because it lives inside the repository it belongs to.

**So a search of "the sandbox roots" is not a search of the host.** Looking for
one ticket's worktree under the two `Sandbox`-style roots returns nothing for
any card whose tree happens to live in `.worktrees/`, and the honest-sounding
next sentence — *"that ticket has no checkout on this host"* — is false. Ask git:

```sh
git worktree list | grep -i <ref>
```

Case-insensitively: branches here are sometimes `dd-528` against a card ref of
`DD-528`, and a case-sensitive match returns a confident nothing.

## Identity: location is not ownership, and one test is not enough

A directory under a sandbox root is **not** evidence that it belongs to this
repository. `/home/mv/dd-worktree-sandbox/dd-583` and `dd-584` are correctly
registered worktrees of `~/dd-tg`, a different project, that happen to sit in
this project's old root:

```sh
$ cat /home/mv/dd-worktree-sandbox/dd-583/.git
gitdir: /home/mv/dd-tg/.git/worktrees/dd-583
```

`git worktree list` run from here does not show them — which means *they belong
to another repository*, not that they are orphaned. Reading it the second way
turns them into "unaccounted work" and invites action on a neighbouring
project, which the project rules forbid outright.

**A checkout is ours if EITHER test holds. Neither is sufficient alone:**

```sh
git -C "$D" rev-parse --path-format=absolute --git-common-dir   # == our .git ?
git -C "$D" remote get-url origin                               # == our origin ?
```

In a linked worktree, `GIT_COMMON_DIR` points back to the main worktree's
`GIT_DIR`, so the first test identifies worktrees. **It misses clones**: a clone
of this repository has its own `.git`, so its common-dir is itself. Measured on
four real checkouts:

| checkout | common-dir | verdict by (a) | actually |
|---|---|---|---|
| `dd-worktree-sandbox/dd-583` | `/home/mv/dd-tg/.git` | not ours | **not ours** |
| `Sandbox/ddd/dd-733` | our `.git` | ours | **ours** |
| `.worktrees/dd-443` | our `.git` | ours | **ours** |
| `Sandbox/ddd/DD-633` | its own `.git` | not ours | **ours — a clone** |

The last row is why the second test exists: that clone's `origin` is identical
to ours. And the second test excludes the foreign case too — `dd-583` has an
empty `origin`, so it fails both and is rejected twice over rather than by luck.

## "Differs from master" is the cheap question and it cries wolf

The tempting test is whether a checkout holds content that is not on master.
Scored against the three cases examined by hand:

| card | content differs? | work landed? | cheap test says |
|---|---|---|---|
| DD-633 | yes | **yes**, as `3c2f267` | false alarm |
| DD-443 | yes | **yes**, as `ea9c53c6` | false alarm |
| dd-528 | yes | no | correct |

One true finding in three. A worktree routinely holds a **superseded draft** —
work that was rewritten better before landing — and DD-633's draft was actively
*worse* than what shipped, so preserving it would have preserved a regression.

**The useful question is whether the card's work landed**, which needs the
commit carrying the ref, not a diff against a directory:

```sh
git log --oneline --grep='<REF>' origin/master
git merge-base --is-ancestor <sha> origin/master
```

Require **both** to agree — a commit titled with a range (`DD-505..DD-531`)
matches refs it never carried, and a bare hex match picks up strings that merely
look like SHAs.

## Report the two risks separately

Uncommitted content and unlanded commits carry different risk and must not be
merged into one "has work" flag:

- **Uncommitted content** can be destroyed by a single command. Urgent.
- **An unlanded commit** is safe on its branch — but if the checkout is a
  *clone* rather than a worktree, it is single-copy: a worktree shares the main
  repository's object store, a clone does not.

A flag that says only "has work" makes the urgent case unfindable among the
tolerable ones.

## How to apply

- Enumerate with `git worktree list` **plus** a directory walk — the walk finds
  clones and unregistered repositories that the command does not report.
- Establish identity per checkout with both tests before reporting anything.
  A checkout satisfying neither belongs to someone else: read nothing further
  and leave it alone.
- Ask whether the *card's work* landed, never whether the *directory* differs.
- Distinguish "clean" from "could not look" with separate exit codes. A checkout
  that cannot be read must never be counted as clean.
