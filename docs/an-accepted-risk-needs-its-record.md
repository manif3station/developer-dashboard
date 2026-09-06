# An accepted risk needs its record

**System-scoped.** This is about any risk this project decides to live with —
an unbacked directory, a known-flaky path, a gate that cannot run on this host,
a dependency nobody will upgrade yet. It is not about one ticket.

## The claim

**An acceptance is only honest while it is a decision.** The moment everyone who
made it has moved on, an undocumented acceptance is indistinguishable from an
oversight — and it will be *read* as an oversight by whoever finds it, or worse,
not found at all.

So accepting a risk is not the absence of work. It has a deliverable, and the
deliverable is the record.

## What the record has to contain

**The measurement, with the command that produced each figure.** Not "about
forty files" and not "42 files" — the number plus the one-liner that regenerates
it. A bare count ages silently, and it ages in the one place nobody updates.
Measured on the case that produced this page: the card said *42 files*, and by
the time it was worked the directory held **43**, with **54** under the parent.
Nothing was wrong; the number had simply moved, and a reader comparing it to
reality would have had to decide whether the card was stale or lying.

**The attribution.** Which question authorised this, which option was chosen,
the answer's own words, and when it was answered and marked. Read those back
from the record rather than from memory. An acceptance with no author is a
convention nobody re-examines, including the person who wrote it.

**The residual risk in the form somebody would act on.** This is the part most
often skipped, and it is where the value is. "No backup" is a category. What
breaks, silently, when this bites — that is a finding.

## The failure this page exists for

A directory of operator tooling was git-ignored, untracked, and unbacked. The
card described it as *"42 files with no git object and no backup"*, which reads
as untidiness.

The measurement said something else. **Eight cron entries invoked that
directory** — the hourly card-vs-evidence sweep, the policy sweep, the decline
watch, a reminder guard, CI health, release parity, the outstanding-violation
gate, and *the board's own backup job*.

> Losing the directory would silently stop every guardrail, **including the
> backup**.

And the failure compounds in the worst possible direction. A cron entry whose
script is missing fails *before* the script runs, so the redirect that would
have logged the error is never reached. The log stays quiet. **Quiet is
indistinguishable from clean.** The thing that would have noticed is the thing
that vanished.

That is not hypothetical here: two scheduled jobs on this project were once
found disabled for **nine days**, discovered only by asking whether the loop was
still *scheduled* rather than by reading its silent log.

## Two traps when writing the record

**A nearby copy is not a backup.** Twenty-nine working trees each carried a copy
of the directory. Same filesystem, deleted with the worktree — and this project
has already watched a single commit untrack such paths and delete them from
every tree that merged it. Say explicitly why the copies do not count, because
they look like they do.

**Criteria written before the decision become unreachable after it.** When the
answer is "leave it as it is", every criterion that assumed a mechanism —
*document the procedure*, *exercise the recovery* — can no longer be met by
anybody. Leaving them in place parks the work forever against a definition
nobody can satisfy, which is the same defect as a release trigger naming a state
that cannot occur.

Re-specify against what the card is now *for*. Where the tooling cannot delete a
superseded item, **say on the record that it is unreachable by decision rather
than outstanding by neglect** — and do not tick it. A box ticked to tidy the
list is worse than one left open, because the open box is honest.

## Keep one criterion that is trivially true

When nothing is built, at least one criterion should still assert that nothing
*became* built — here, that no path under the directory became tracked.

It passes by construction today. Its purpose is the next person: an attempt to
"help" by committing the files should **fail** this card rather than pass it
silently. A criterion that costs nothing now can still be the one that catches
somebody later.
