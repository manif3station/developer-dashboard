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

## How it knows work is already in flight (DD-742)

The selection order above reads every working column, but not all of them
suppress a new recommendation, and the difference is easy to miss because the
columns *are* all present in the file.

    line 104   in-flight    in-progress researching analysing documentation
    line 117   candidates   todo buglist new-enhancements ready planning backlog
    line 130                final-check git-gate        "not been landed"
    line 137                unit-test vulnerability-scan platform-test  "at a gate"

Only line 104 suppresses. A card sitting at `unit-test` is reached at 137 —
*after* the candidate loop has already answered — so the guard proposes starting
something new while that card is mid-gate. Observed 2026-09-02: with a card in
`unit-test` holding a standing suite verdict, the guard answered *"DD-659 is
waiting to be started. Claim it and work it"*, because DD-659 was in `ready` and
`ready` is reached at 117.

**So "never start something new while something is claimed" is enforced for four
columns and not for the other five.** That is a ranking, not an omission — and
reading line 104 alone shows four names and looks like the whole story.

### The set is published; do not write it down

The board declares its own columns, so the working set does not have to be
maintained by hand:

```sh
d2 tira.column.list --type ticket -o json
```

`required_actions > 0` selects exactly the eleven working columns
(`researching` … `git-gate`) and excludes exactly the ten that are not — the
queues, both `blocked-*`, and the four terminal columns. A column that demands
work before you leave it is a working column *by construction*, so a twelfth one
needs no code change.

Three properties of that interface bite if ignored:

- **`--type ticket` is required.** `epic` and `sow` return 21 columns with
  **zero** `required_actions`. A derivation that omits the type yields an empty
  set — and an empty in-flight set reports *"nothing is in flight"*, which is
  this very defect in its most complete form. Assert the result is non-empty and
  fail into the existing exit-3 path.
- **A column may declare several `next` columns.** This board forks at
  `final-check → {git-gate, admin-done}`. A walk assuming one successor stops at
  the first.
- **The candidate set overlaps the working set** at `ready` and `planning`.
  That overlap is deliberate (DD-724): a card in `ready` is claimed but not
  being worked, and is legitimately pickable. Deriving the working set must not
  quietly remove those from what the guard can offer.

### Why the list existed at all

DD-733 extended the in-flight check from one column to four, because that is
what the incident it came from involved — a session told to claim a new card
while holding one in `analysing`. Four contiguous names read as a complete
answer. **A fix derived from an incident covers the incident**; the set it
should cover has to come from the system's own definition.

## Priority within a column (DD-747)

Column order (`todo` → `buglist` → `new-enhancements` → `ready` → `planning`
→ `backlog`) decides which *column* the guard looks in first, but nothing
originally decided the order *within* one. `col()` returns whatever
`tira.ticket.list --refs-only` gives, which is ref-ascending — so the
candidate loop always offered the **oldest** card in a column, never the
**highest-priority** one. Measured on this board: `backlog` returned DD-637
(priority 2) before DD-744 (priority 4), and the guard recommended DD-637 —
directly contradicting the board's own `priority-skipped` rule, which exists
to enforce exactly the ordering the guard was ignoring.

The fix fetches `tira.export --fields ref,priority` **once**, before the
candidate loop runs, and `sort_by_priority()` reorders each column's `col()`
output by descending priority before the loop iterates it. Column order is
untouched — a `buglist` card is still never reached before an available
`todo` one, however high its priority, because the sort happens *within*
each `$(col X)` call, not across the concatenated list.

Two properties the fix is asserted against, not just the happy path:

- **A tie (or an unset priority, which reads as 0) falls back to the
  original ref-ascending order.** The fix must not become order-dependent on
  something new for cards that never had a stated priority; without this a
  fix could pass by coincidence on a board that happens to have one
  high-priority card and say nothing about ties.
- **The priority fetch failing does not lose refs.** `sort_by_priority()`
  falls back to its input, unsorted, if the export call or the JSON it
  returns cannot be parsed — a could-not-sort is not a could-not-look, and
  the guard's exit-3 contract belongs to the board-read step, not this one.

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
