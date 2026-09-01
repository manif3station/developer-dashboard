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

## Coexistence is not symmetric: resuming matches the EXACT path

The section above says the two roots coexist while old sandboxes remain open,
and that the real invariant is *pick a recognised root and record it*. That is
true, and it hides a sharp edge worth knowing before anyone changes the
default.

`ticket-worktree` resumes an existing sandbox by matching the path it just
computed, literally:

```perl
my $path = File::Spec->catdir( $sandbox_root, $slug );
...
if ( $listed == 0 && $existing =~ /^worktree \Q$path\E$/m ) {
    say STDERR "ticket-worktree: $ref already has a sandbox - resuming it, not starting again";
```

`$sandbox_root` is whichever root is in force for *this* invocation. So the
resume protection only works when you open a card under the same root it was
created under. Run it with the override on a card whose sandbox was made
without one — or the reverse — and the match finds nothing, the tool falls
through to the create path, and it cuts a **fresh worktree from origin/master**
beside the existing one.

**That failure is silent and looks like success.** There is no error; there is
a new empty sandbox and a cheerful message. The original tree, with whatever
uncommitted work is in it, stays on disk and is never mentioned.

Measured on this machine while the two roots were both populated: 102
sandboxes under the pre-move root against 21 under the declared one. Every one
of those 102 is reachable today only because the tool's default still points
there.

**So the consequence for changing the default**, whenever that happens: it
cannot be a one-line change. Flipping the default without also checking the
old root turns "the old root drains as its cards finish" into "the old root
stagnates while empty trees appear beside it" — because those cards can no
longer be resumed at all. The fix is to look in the other recognised root
before creating anything, and to say which root a sandbox was resumed from.

**And the general form, which outlives this particular path.** When a tool
both *derives* a location from configuration and *detects existing state* at
that location, changing the configuration changes what it can see, not merely
where it writes. Any such change needs to answer: what existing state becomes
invisible, and does the tool report that or silently start again?

## How to apply

Before opening a sandbox, check which root the board's policy currently
names - it has moved once already and nothing prevents it moving again. If a
tool's default has fallen behind that root, override it explicitly rather
than editing the tool under time pressure; fixing the tool's own default is a
separate, deliberate change, not something to bundle into an unrelated
ticket's sandbox setup.
