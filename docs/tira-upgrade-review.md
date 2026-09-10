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

## 5.86 -> 5.87: `tira.policy.undeclared` empty again, and two entries that bear without needing a declaration

`tira.policy.undeclared` returned empty on this review - back to the more
common shape after 5.86's genuinely new `checklist-item-terminal` surface.
That does not mean the changelog was skimmed: every one of the nine 5.87
entries was read and classified, and two of them change something real about
how this board should be read, without either one being a new rule to declare
or decline.

**TKT-666 bears because this board genuinely has the shape it was written
for.** `card-duration` for a sow/epic now measures dwell from the *later* of
the parent's own arrival or its most recent child's own last move, rather
than only the parent's own arrival - a parent that lives in its working
column for its entire life by design could otherwise never settle the old
measurement short of finishing every child (the same reasoning `wip-limit`
already used, per TKT-333). **Checked whether it applies here rather than
assuming it does**: this board carries 10 epics and 3 SOWs (confirmed via
`d2 tira.export --fields ref,type`), so the fix is a real reduction in false
`card-duration CRITICAL` noise on parent cards, not a no-op. Nothing to
declare - this corrects the *behaviour* of a rule this project already
relies on, it does not introduce a new one.

**TKT-831 retires a hazard this project's own memory had been carrying as a
standing workaround.** `dd-tasklist-prune-is-destructive.md` warned that the
tasklist dashboard's own unattended 5-minute auto-prune timer would silently
delete every done tasklist item board-wide, bypassing the `confirm()` guard
that was only ever wired to the manual Prune button - and that the owner had
confirmed the CLI-driven prune (`d2 tira.tasklist.prune`, run deliberately
after marking items done) was the safe path. 5.87 removes the unattended
timer entirely: pruning now only ever happens through that confirm()-gated
button. **The memory is corrected in place, not deleted**, per this page's
own "correct rather than delete" discipline - the struck-through original
warning stays as the record of what was true, with a superseded note at the
top pointing here.

The remaining seven entries (TKT-672, TKT-669, TKT-658, TKT-653, TKT-641,
TKT-635, and TKT-1002) are message-quality, internal-tooling, or
already-known-to-us fixes: TKT-1002 in particular is this project's *own*
upstream report from earlier the same session (the JOB-005 absolute-path
fix), now folded into `docs/JOBS.md` - a report that bites, gets filed, and
comes back landed inside one upgrade cycle.

## 5.87 -> 5.88 (DD-820)

Entries: TKT-696 (`card_holes`/`ticket.missing` gain a `past_column`
standard for what a card owes past a milestone), TKT-695 (`task-card-mismatch`
now reports a task whose ref names no card, rather than silently deferring to
`task-unlinked`), TKT-692 (four commands stop interpolating an undef id into
their refusal message), TKT-689 (a refusal names the flag the raising
command actually takes).

All four are internal Tira tooling improvements to existing rules/commands -
none introduces a new rule name this project would need to declare via
`d2 tira.policy.add`. `tira.policy.undeclared` confirmed empty.

This content overlaps with DD-828's later 5.88 -> 5.89 review, which already
covered the same ground and declared the one genuinely new rule found across
both passes (`task-created`, as POL-124).

## 5.88 -> 5.91 (DD-836)

Board moved from 5.88 to 5.91 across three releases without an intervening
review being appended here (5.88->5.89's genuinely-new rule, `task-created`,
was already declared as POL-124 by DD-828 - see the note at the end of the
5.87->5.88 section above). Reviewed 5.91's own changelog directly:

Entries: TKT-1035 (a highlight-state reversal on the review-column card
markup), TKT-1032 (confirmed-already-fixed zombie-process report, no new
code), TKT-895/`tira.question.withdraw` (a new discard-with-required-reason
verb for questions we are not required to use), TKT-877 (a meta-guard
comparing two copies of Tira's own commit-gate logic), TKT-876 (a stale
line-count claim in Tira's own README/SKILLS docs), TKT-865 (Tira's own
meta-guard test files documented as a named set).

None of these introduces a new rule name, changes the shape of a command or
field this project reads, or requires a new `d2 tira.policy.add` /
`tira.policy.decline`. `tira.policy.undeclared` confirmed empty. No code
change required; this entry is documentation-only, matching the DD-819/DD-820
pattern for a clean review.

## 5.91 -> 5.92 (DD-837)

Entries: TKT-910 (`link_remove` falsely reported success on a wrong-direction
or self-link removal), TKT-907 (`tasklist.list --sort` edge cases: empty
spec, trailing/leading comma, bare `:desc`), TKT-906 (17 of 18 exemption
entries in Tira's own t/524 wrongly attributed to one card), TKT-903 (a
meta-guard's own regex silently mis-parsed two entries, joining the t/865
meta-guard family as its 21st member), TKT-902 (the commit gate refused a
POD-only lib/*.pm addition, which the documentation column's own required
action instructs), TKT-901 (a killed gate-run left its container running
against an already-removed worktree), TKT-900 (doc-examples harvest widened
from a hard-coded 2-file list to every docs/*.md, catching two real stale
usage-grammar lines in SKILLS.md along the way).

All seven are internal Tira fixes to its own commands, tests and release
tooling - none introduces a new rule name this project would need to declare
via `d2 tira.policy.add`, and none changes the shape of a command or field
this project reads. `tira.policy.undeclared` confirmed empty. No code change
required; documentation-only, matching the DD-819/DD-820/DD-836 pattern.

## 5.92 -> 5.93 (DD-840)

Entries: TKT-1041 (Tira's own `lib/Tira/CLI.pm` move-path guards lifted into
a new `Tira::CLI::Move`, mirroring TKT-607's own shape - forwarding stubs
keep every existing caller working), TKT-1040 (a doc-vs-ships meta-guard
false-positived on the ordinary English word "Specified" in prose, tightened
to the actual bold-and-versioned legend convention), TKT-1039 (two unmarked
bare assertions in Tira's own meta-guard suite), TKT-1030 (a job card's log
panel repainting a stale tail instead of appending the genuinely new lines),
TKT-1038 (a documented command, `attachment.where`, whose entrypoint file was
never actually created - the same missing-file shape TKT-895 fixed once
already), TKT-1015 (a pre-push hook computing "the cards this push is about"
from the wrong ref, ignoring git's own stdin payload), plus several smaller
internal fixes.

**One new policy rule: `backward-move-unexplained`.** Mirrors
`discard-unexplained`'s own mechanism exactly - a comment satisfies it only
if written at or after the card's own last backward move (5s grace,
identical to `discard-unexplained`), not any comment the card has ever
carried. Moves into/out of discard stay `discard-unexplained`'s business; a
forward move gains no prompt; the rule reports, it never refuses. **Declared
as POL-125**, same action (`bridge-reminder`) and message shape as
`discard-unexplained`'s POL-072 - this project already comments on every
state change (the "comment first, then fold into fields" discipline this
file's own rule contract documents elsewhere), so declaring rather than
declining costs nothing and catches a genuine future mistake.

`tira.policy.undeclared` confirmed empty after declaring POL-125. No code
change required beyond the declaration itself.
