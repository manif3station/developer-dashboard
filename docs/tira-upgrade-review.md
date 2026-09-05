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
