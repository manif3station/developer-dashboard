# The ticket sandbox root: what it is, and its one open gap

Where a ticket's working sandbox lives, how the board enforces that a card
be worked in one, and the one place this project's own tooling still
disagrees with the board about where. This page describes the system, not
any one ticket.

## The contract

Every ticket is worked in its own git worktree, cut from `origin/master`,
named for the ticket reference. `d2 tira.required-action` entry actions for
`in-progress` name the expected path directly (`Clone origin/master to a
sandbox ~/Sandbox/ddd/<card-ref>`), and the board's `card-sandbox-missing`
policy watches for a card in a working column whose `sandbox` field is empty
or points somewhere the declared policy does not recognise.

**The declared root is `/home/mv/Sandbox/ddd`** (policy `POL-114`, current as
of 2026-08-29). Confirm it live rather than trusting a cached belief:

```sh
d2 tira.policy.list   # filter to card-sandbox-missing - exactly one result should govern
```

If more than one policy declares the same rule, the pass reports from the
**first** of them - a corrected re-declaration does nothing until the
superseded one is explicitly removed.

## The gap: a fixed default in the wrong place

`.claude/tools/ticket-worktree` (this project's helper for opening a
sandbox) still hardcodes an **older** root,
`$ENV{DD_WORKTREE_SANDBOX} || catdir($home, 'dd-worktree-sandbox')`, from
before the board's declared root moved. Running it with no override lands a
fresh sandbox at the old path, which then reports `card-sandbox-missing`
against a board that has already moved on.

**The workaround, until the tool itself is fixed:**

```sh
DD_WORKTREE_SANDBOX=/home/mv/Sandbox/ddd .claude/tools/ticket-worktree DD-NNN
```

**Why the old root's existing trees are left alone.** Dozens of sandboxes
already exist under the pre-move root, most for finished tickets. Migrating
or deleting them was considered and explicitly declined (owner decision): the
old root drains naturally as its cards finish, new work uses the new root,
and nothing on disk or in a recorded `sandbox` field is disturbed. The two
roots therefore coexist for as long as old sandboxes remain open - `pick a
recognised root and record it`, not `there is exactly one correct path`, is
the actual invariant `card-sandbox-missing` needs to check.

## How to apply

Before opening a sandbox, check which root the board's policy currently
names - it has moved once already and nothing prevents it moving again. If a
tool's default has fallen behind that root, override it explicitly rather
than editing the tool under time pressure; fixing the tool's own default is a
separate, deliberate change, not something to bundle into an unrelated
ticket's sandbox setup.
