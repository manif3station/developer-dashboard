# Host exclusivity belongs to the run

When one thing on a machine must not overlap another — a test suite, a coverage
pass, anything that competes for the whole host — the lock protecting it should
be held for exactly **one run**: acquired immediately before the work starts,
released when that process exits.

Not for a session. Not for a chain of gates. **One run.**

## What the shipped tools already do

| tool | scope | why |
|---|---|---|
| `run-suite` | the prove run only | acquires immediately before `prove`, releases when the process exits. Its own header states it must never be held across a caller's wider gate chain |
| `script/coverage-gate` | per **database**, not per host | so the two tools guard different resources and neither refuses the other |

Both are correct. This page exists because something else once wasn't: a
hand-written per-session wrapper held a host lock across a whole gate chain and
made another session wait **2529 seconds** — forty-plus minutes — for twelve
minutes of work, with the `prove` child long since exited.

That wrapper no longer exists. It was per-session, made by hand, and deleted
with the session that made it. **Nothing in the checkout, the operator tooling,
`~/bin`, or any sandbox takes a session-level host lock today.** This page is a
convention, not a fix.

## Why run-scope, and not something larger

The scope should be the smallest interval during which overlap actually hurts.
For a suite that is the run itself; everything before it (deciding to run,
resolving arguments, reading config) and after it (reading the log, recording a
verdict, moving a card) harms nobody if it overlaps.

A lock held for longer is not more careful. It is a lock held while nothing
needs protecting, and every second of that is a second some other party waits
for no reason.

This is also where the wider world landed. TeamCity's shared resources acquire
when a build starts and release on completion; GitLab prefers per-job locks as
"the unit in which users expect to operate with resources and to keep them in
equal state." Run-scope is the mainstream answer, not a local convenience.

## Two things this convention does NOT solve

A convention that hides its own weaknesses gets trusted past its range. These
are the two that have actually cost time here.

### 1. A waiter cannot tell a deliberate hold from a hang

`flock` exposes no holder identity, no reason, no expected release. A waiter can
only wait blindly or break something.

And holding for a long time is sometimes *correct*: a criterion requiring three
**consecutive** coverage passes on an unchanged tree genuinely needs the host
across all three, because releasing between them lets another run interleave and
turns the honest answer into "two, then someone else's, then one."

So "held a long time" is not evidence of a fault. Which is why this bit:

> A run once deadlocked **inside** the lock and sat 16 minutes at 0% CPU. From
> outside it was indistinguishable from the legitimate long hold the waiting
> party had just been told to expect. What gave it away was the coverage
> database's mtime being 14 minutes stale while the holder was still alive —
> **progress, not liveness.**

A sidecar beside the lock — pid, what is running, expected release, and a
heartbeat updated as work proceeds — would let a waiter say "held by X, run 2 of
4, last progress 14 minutes ago." **That was considered and deliberately not
built.** It is a new capability rather than a convention, and it is recorded
here as declined, not pending, so nobody rediscovers it as outstanding design
work.

Until then: judge a holder by whether its output is growing, never by how long
it has held.

### 2. Run-scope does not prevent starvation

Correct scoping says nothing about *fairness*. Two parties waiting for the same
host with different strategies can starve one of them deterministically:

> One runner required four clear samples before launching. Another launched
> immediately and judged contention afterwards. Neither strategy is wrong on its
> own. Together, the second always goes and the first always yields — the first
> sat parked for over half an hour with **zero** launches while three of the
> other's attempts ran.

Starvation is a named failure mode in CI systems for this reason; Jenkins
documents executor starvation, and TeamCity treats agent starvation as a silent
killer of throughput.

It was resolved by the two parties noticing and one conceding — **an agreement,
not a mechanism.** That works with two participants who are talking. It does not
generalise, and nothing in run-scope exclusivity prevents the next occurrence.

## The short version

- Lock the **run**, not the session, not the chain.
- Release when the process exits, not when the workflow ends.
- A long hold is not a fault; judge holders by **progress**, not elapsed time.
- Correct scope is not fairness. If two parties wait differently, one starves,
  and only an explicit arrangement fixes that.
