# Reviewing a Tira version-upgrade ticket

Since Tira 5.77, an upgrade to the board tool itself raises its own ticket
automatically: `police_pass` detects a version change and, in the same
guarded branch that writes its one-line bridge announcement, files a card in
`backlog` at priority 5, titled with the old and new version, carrying the
Changes entries between them as its description and a checklist with one item
to read the new commands plus one item per rule `d2 tira.policy.undeclared`
still lists.

## What this ticket actually asks

Two things, both checkable directly against this project's own board state:

1. **Nothing is left undeclared.** `d2 tira.policy.undeclared` returns the
   rules Tira knows about that this project has neither declared nor
   declined. An empty result means there is nothing to act on for this half
   — the checklist's "one item per rule" clause has no members.
2. **Nothing this project already declared would now be refused.** An
   upgrade can add a new validation to `policy_add` (for example, 5.61 added
   `forbids => ['age']` to eighteen rules that never read that option). Check
   by exporting `d2 tira.policy.list -o json` and testing the declared
   policies against whatever the new validation actually is — read from the
   Changes text, not guessed at from the rule names.

## What it does not ask

It does not ask for a diff of every command or option that changed between
the two versions. There is no per-version manifest to diff against, so a
"what's new" review can only lean on the Changes text as written — never
claim to have reviewed further than was actually read, and say the boundary
explicitly (e.g. "read only to 5.74") rather than letting "reviewed" imply
the whole range.

## Reading the Changes text

- Read entries by what they actually changed, not by title alone — a title
  can undersell an entry that also touches something board-relevant (a
  print encoding fix that affects a standing monitor, a locking change that
  affects gate runs).
- A version that changes internal validation (an accepted-but-unread option
  now refused, a new required field) is the one worth checking our own
  declared state against. A version that is purely a UI fix, a doc
  correction, or an internal implementation detail with no externally
  visible contract change needs no further action here beyond having been
  read.
- If the range is large, split the reading across sessions rather than
  claim the whole thing from a partial read — state which versions were
  actually read, the same way a filter's scope is stated with any other
  finding.

## Closing the ticket

Record the conclusion on the card either way: what was checked, what was
found (a real declared-policy conflict, worth fixing directly), or nothing
requiring action, with the evidence that produced that conclusion. A card
that concludes "nothing to declare" without showing the check that
established it is a comment, not a review.

## The two checks are the FLOOR, not the ceiling

Both checks above are about **policy declarations**. An upgrade can change
things that are not policies at all, and those changes will pass both checks
silently.

Measured on DD-779 (5.77 -> 5.83): `policy.undeclared` was empty and no
declared policy would be refused — both checks clean — while the most
consequential finding of that upgrade was neither. Two entries together
explained a failure this board had been watching for a day without
understanding it:

- **5.81 TKT-944** connected a job executor that had existed since TKT-841 with
  no caller but the manual Run-now button, so command-mode jobs went from
  announcing-and-doing-nothing to actually running.
- **5.82 TKT-945** widened `monitor-output` to carry cron command output, so
  those runs' failures began reaching the bridge.

The job had not started failing. It had started *running* — and its failure had
started *being visible*. **A defect that appears the day after an upgrade is
often one that was always there and has only now become observable**, and
neither policy check can tell you that.

It also voided a piece of evidence on another card: 5.80 retired `last_run` as a
field nothing ever wrote, so an argument resting on `last_run: null` proved
nothing about the job's health.

**So read the Changes text for behaviour, not only for policy validation.** The
checks tell you whether your declarations still bind; they do not tell you what
the board now does differently underneath them.

## Confirm a store can carry the signal before grepping it

An upgrade entry that says *"the fix line for X now reads Y"* invites one
obvious verification: grep whatever store you have of past findings for Y. If
the grep returns zero, the entry looks unlanded, or the reviewer looks wrong.

**That grep only means something if the store records the field the entry
changed.** Before reading a count from it, check that the field is ever
populated there at all — run the grep for the *old* value too, or count how many
rows carry the field with any value. A store that returns zero for every value
is not disagreeing with the entry; it is structurally unable to witness it.

Measured on the 5.84 -> 5.85 review (TKT-866, which made police fix lines for
`JOB-`/`TSK-` subjects runnable as `d2 tira.job.list` / `d2 tira.tasklist.list`):

- `d2 tira.policy.bridge.logs` holds a `fix` field, and it was **empty on 769 of
  769** `JOB-`/`TSK-` entries — before and after the upgrade alike. A grep of the
  logs for the new fix text returns 0 and proves nothing.
- The **rendered bridge** (`d2 tira.policy.bridge`) carries the fix line, and a
  finding raised after the upgrade showed the new text there on its first
  appearance.

So the same change is invisible in one store and plain in another, and the
store that is cheap to grep is the blind one. The general rule: **a zero from a
grep is a claim about the store as much as about the change.** Establish that
the store can say something other than zero — a control row you know must
match — before quoting its answer.

The same review also showed the other way a changelog entry is useful: **an
entry can hand you a yardstick you did not have.** TKT-978 published a median
police-pass time for this board (5.49 s). A pass observed running for several
minutes was, until that number existed, merely "slow"; against a published
median it is a measurable finding for the board's owner. Read entries for
numbers you can compare against, not only for behaviour that changed — and
record the finding rather than acting on it when the command it measures is not
yours to run.
