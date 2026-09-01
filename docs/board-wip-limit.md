# The in-progress WIP limit: what it's actually for

The `wip-limit` policy on the `in-progress` column caps how many cards may be
claimed there at once. This page describes what the cap protects and why its
stated justification changed, so the next reader does not have to re-derive
it from the policy's history.

## What the limit protects

Full-suite verification (`prove -lr t`) and the coverage gate
(`Devel::Cover`) are **host-exclusive** on this project: only one such run
may hold the host at a time, because a contended run is not valid gate
evidence (timing-sensitive branches misread under load). The WIP limit
exists to keep the number of cards approaching that gate small enough that
the host-exclusive serialization stays workable rather than becoming a queue
nobody can reason about.

## Why the limit's message changed (DD-654)

The policy's original message (`POL-060`, declared 2026-08-15) stated its
reason as *"Single-agent project, and full-suite verification is
host-exclusive."* That was true when written. It stopped being true the
moment a second Claude session began working this board concurrently
(owner-confirmed intended, 2026-08-29) - and the message kept asserting it
anyway.

A justification that is visibly false invites the wrong inference: a reader
meeting the rule, checking whether "single-agent project" still holds,
finding it does not, is naturally led to conclude the *limit itself* is
stale too - when in fact the durable reason (host-exclusive verification)
never stopped being true. The stale half of the message was actively
undermining the half that still mattered.

**The fix (`POL-117` replacing `POL-060`) removed only the false half.** The
limit itself (`max=1`) was left untouched - whether one slot is still right
for two sessions sharing one host-exclusive gate is a real question, but it
belongs to the project owner, not to a message-wording fix.

## How to apply

Before trusting a policy's stated justification, ask whether it is still
true of the project *now*, not only whether the *limit* still makes sense.
A policy can be correctly configured and incorrectly explained at the same
time, and the wrong explanation is the more dangerous of the two failures -
it doesn't just fail to convince, it actively argues against a rule that is
still doing its job.
