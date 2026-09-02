# When one tool judges and another reports, the reporter must read the judgement

Some tools in this repository **produce** a result and **judge** it in the same
run. `run-suite` is one: it runs the suite, samples the process table while it
does, and writes both the outcome and its own verdict on that outcome into one
log —

```
All tests successful.
CONTENDED: a foreign coverage run held the host for 34 of 44 sampled windows (peak 5) - this verdict competed for the host and does not stand
SUITE_EXIT=0
```

Three lines. The first says the suite passed. The second says the result should
not be believed. The third is a machine-readable marker of the first.

**A separate tool then answers "did the gate pass?" for a human.** The failure
this page is about is that the reporting tool read the third line and none of
the second — so it announced a finished, passing gate for a run whose own log
says, in words, that it does not stand.

## Why this is worse than a missing feature

The reporter is what people consult *instead of* reading the log. That is its
entire purpose. So a gap in it is not "one fewer detail shown" — it is the
judgement being deleted from the only place anyone looks.

And the error runs in the reassuring direction. It reports a pass where the
truth is "no usable verdict", which is the direction nobody double-checks.

## Do not re-derive the judgement

The tempting fix is to teach the reporter the rule: read the sample counts,
apply the threshold, decide. **Don't.** A threshold implemented twice is two
thresholds, and they drift — one gets tuned, the other doesn't, and afterwards
the two tools disagree about the same run while both look right.

Read the **classification the writer already emitted**. The producing tool is
the only place that knows how the judgement was made, and it has already made
it. The reporter's job is to carry it, not to reconstruct it.

This repository learned the same lesson from the other side: two tools that must
agree on a fingerprint have a spec asserting their expressions are **identical**,
precisely because a divergence between two implementations of one rule is
invisible until it matters.

## Keep the states distinct — there are three, not two

The instinct on discovering this is to make the bad case report as **failed**.
That is also wrong, and for a reason worth stating:

| state | what it means | what the reader should do |
|---|---|---|
| **passed** | the thing works, and the evidence stands | proceed |
| **did not stand** | the thing may well work; the *evidence* is inadmissible | re-run, don't debug |
| **could not look** | the checker could not reach an answer | fix the checker |

Collapsing "did not stand" into "failed" sends someone to debug working code.
Collapsing it into "passed" ships on evidence the producer already rejected.
**The distinction between broken code and inadmissible evidence is the whole
value**, and it is lost by any two-state reporting.

A reporter that already implements a third state for one reason should extend
that state rather than invent a parallel one — otherwise the same concept ends
up expressed two ways in one tool.

## The general test

For any pair where one tool produces and another reports:

- **List what the producer writes.** Then grep the reporter for each of those
  markers. A zero is a finding, and the count is cheap to take.
- **Ask which of the producer's conclusions the reporter can express.** If the
  producer can say something the reporter has no vocabulary for, that conclusion
  is being silently dropped every time it occurs.
- **Check every exit path in the reporter.** A tool that announces its verdict
  in two places needs the fix in both; a one-sided fix leaves the other path
  reporting the old answer, and nothing looks wrong.
