# The next-action guard: what it is, and what "available" means

`.claude/tools/next-action` answers one question — "what is the one thing to
do next?" — so that composing a summary is never the thing that ends a work
session. It exists because the agent stopped after writing a report six times
in one day (DD-544): the turn ends when it stops calling tools, and a
finished-looking report reads as a delivered artifact with nothing left to do.
The guard is consulted BEFORE the summary, and its answer is mechanical, read
from the board, not remembered.

## The contract

Exit codes are the whole interface:

- **0** — there is a next action, printed as `NEXT: ...`.
- **1** — nothing actionable right now, with the reason printed (`NOTHING
  ACTIONABLE: ...` / `NOTHING IN FLIGHT: ...`).
- **3** — the board could not be read at all. This is never reported as
  "nothing to do" — an unreadable board and an empty one must never look the
  same, because the first is a guard that has gone blind and the second is a
  guard doing its job.

The selection order is: anything already `in-progress` (never propose starting
something new while something is claimed) → `blocked-by-michael` named
explicitly → the first genuinely workable card in `todo`, `ready`, `planning`
→ unlanded finished work in `final-check`/`git-gate` → a failed gate in
`unit-test`/`vulnerability-scan`/`platform-test` → else report why nothing
qualifies (blocked, backlog-only, filtered, or genuinely empty).
`done-not-released` is deliberately never proposed — releasing is the owner's
own decision (`dashboard pause-release`), and naming a next action nobody may
actually take trains the reader to ignore the guard.

## What "available" means (DD-724)

A column alone is not permission. Before DD-724, `todo`/`ready`/`planning`
membership was the only test, so the guard recommended cards a column cannot
mark as spoken for:

- **DD-667** — assigned to the owner, parked on his own answer that he will
  handle it himself. A column has no way to say "claimed by a specific
  person, not available to anyone else."
- **DD-616** — every question on it is answered, but it is deferred through a
  separate `tira.policy.decline` mechanism entirely (a re-declare trigger set
  in Q-056/Q-080). This is a genuinely third, distinct hold that `next-action`
  still does not check — named here as a known gap, not silently claimed as
  covered.

`workable()` closes the first two gaps the guard can cheaply check without a
new board primitive:

1. **Owner-claimed.** `tira.ticket.show --fields assignee` — if the assignee
   is the owner's configured name (`DD_NEXT_ACTION_OWNER`, default `Michael`),
   the card is skipped.
2. **Unanswered question.** `tira.question.list --ref <ref>` — if any question
   on the card has `status != answered`, the card is skipped.

Both checks apply per-candidate inside the `todo`/`ready`/`planning` loop, so
a filtered card never stops the scan — the next candidate is tried, and only
when every candidate in the loop is filtered does the guard say so explicitly
(`NOTHING ACTIONABLE: N candidate(s) ... were skipped as owner-claimed or
awaiting an unanswered question`) rather than falling through to a generic
"nothing open anywhere" message that would read as an empty board rather than
a filtered one.

**This is deliberately not exhaustive.** A column can express more holds than
these two — DD-616's policy-decline is a third — and any future hold the
board grows should extend `workable()` rather than be treated as covered by
it already. Silently claiming a check covers more than it does is worse than
naming the gap.

## Test seam

`DD_NEXT_ACTION_D2` overrides which `d2` binary the guard calls, so
`.claude/tools/t-next-action` can hand it a scripted fake board without a
live Tira project. This is the only seam — `next-action` always `cd`s into
the real checkout and resolves `./bin/d2` relative to it, so a fake binary
merely prepended to `PATH` is never reached. (The spec's `with_board()`
helper originally tried the `PATH` approach and never actually worked — zero
callers before DD-724 exercised it for the first time and found the dead
seam.)

## Related tooling

See [scheduled-automation-coverage.md](scheduled-automation-coverage.md) for
the jobs that run without being invoked; `next-action` is the opposite shape —
a guard the agent is expected to call itself, at the point it would otherwise
stop.
