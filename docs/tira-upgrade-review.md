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
nothing about the job's health. **That held for 5.80 through 5.83 only — 5.84's
TKT-963 added a real `last_run_at`, and the guidance inverts: read all three
stamps and know which absence means what.** `last_due_at` says the window came
round, `last_run_at` says the command ran, `last_output_at` says it said
something. A manual Run now has the second without the first; a command exiting
0 in silence has the second without the third — and before 5.84 it had
*neither*, so a silent success and a mere due-window read identically.

**This page is now an instance of its own thesis, which is why the correction is
dated rather than swallowed.** The claim above was about the TOOL, it was true
when written, and it went stale in three days — sitting inside the document that
exists to warn that a declared rule can change meaning without changing name.
Nothing in the original sentence said which version it described, so a reader a
month later would have taken a past-tense observation as current guidance. That
is the same failure one level along: not an undeclared rule, but an undated
fact. **Date any claim about what a Tira field or rule means.**

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

## 5.85 -> 5.86: a genuinely new rule surface arrived, and most of an upgrade can still be internal-only

`tira.policy.undeclared` had answered empty for two reviews running (5.84 and
5.85 - "every rule this board could adopt was already declared"). 5.86 broke
that streak: `checklist-item-terminal` (TKT-867, test-hardened by TKT-1000)
is a genuinely new rule surface - it reports an epic/SOW checklist item once
every card it names in free text has reached a terminal column while the item
itself stays open.

**Before declaring it, checked whether it applies to THIS board at all,
not just whether it exists.** A rule that watches epic/SOW checklists is
vacuous on a board with none. This one has 10 epics and 3 SOWs, so the rule
was declared for real, not as a formality.

**18 of 19 entries needed no decision at all**, which is the more common
shape and worth naming so the next reviewer does not expect every upgrade to
carry a new policy: police-pass journal caching, UI shake/reserved-space
fixes, a job-announcement race fix, several error-message quality
improvements, and two test-only changes (TKT-1000, TKT-961's summarizer). None
of these change what this board's own declared rules mean or require a
decision - they change how correctly or efficiently Tira's *existing*
behaviour is delivered.

**One entry (TKT-984) closed a defect this project's own session memory had
recorded as an open workaround** - `tira.job.list --id` had silently ignored
its filter, documented here as a standing "never trust an unverified filter
flag" caution. Verified live post-upgrade (`--id JOB-001` now returns exactly
one job) and the memory file was corrected in place rather than left to assert
a defect that no longer exists - the same "correct rather than delete"
discipline this page itself follows.
