# Uncoverable annotations — a claim the coverage figure credits

This project's headline gate is 100.0 on all four Devel::Cover metrics. Part of
that figure is not measured, it is **asserted**: an `# uncoverable` comment tells
Devel::Cover that an outcome is physically unreachable, and Devel::Cover honours
it by excluding that outcome from the total.

So every annotation is a promise, and the gate reports the promise rather than
the measurement. This page is about what that promise means, when it stops being
true, and what actually notices. It describes the system, not any one ticket.

> **Not about placement.** If an annotation is being ignored — the coverage
> figure does not move when you add one — that is a *placement* question, and
> `uncoverable-annotation-placement.md` answers it. This page assumes the
> annotation is honoured and asks whether it is still TRUE.

## What the annotation asserts

```perl
# uncoverable branch true
exec { $argv[0] } @argv or die "...";
```

That says: *the true direction of this branch cannot be taken by the test suite
on this host.* Not "is not taken today" — **cannot be**. The `exec` above
replaces the process image, so the code after it is genuinely unreachable; a
disk-write failure path, or an `is_windows()` guard on Linux, is the same shape.

Four criteria can be annotated — `statement`, `branch`, `condition`,
`subroutine` — and the direction matters:

| annotation | excuses |
|---|---|
| `branch true` / `branch false` | that one direction of the `if` |
| `condition left` / `right` / `false` | that one position of the boolean |
| `statement` | the statement itself |

**One criterion per comment.** Devel::Cover honours exactly one, so
`# uncoverable statement uncoverable branch false` is honoured for *neither* —
the line stays uncovered while looking annotated. Two comments on their own
lines work; two criteria in one comment do not. The tell is that the coverage
figure does not move.

## It is a claim about the SUITE, not about the line

This is the whole of it, and it is the part that decays.

Unreachability is a relationship between a line and the tests that exist. Change
the tests, or change which tests can reach the line, and the relationship changes
while the comment stays exactly as it was.

**The comment reads identically whether or not it is still true.** There is no
syntax for a stale one. It cannot be found by reading the source, by review, or
by any grep — which is why the failure below went unnoticed until somebody
compared the annotations against execution data by hand.

### How they go stale in practice: extraction

The realistic way to create a stale annotation is not to write a wrong one. It is
to **move a correct one**.

When two modules with byte-identical helpers are merged into a shared module,
each consumer's test suite can now reach code that was reachable from only one of
them before. Outcomes unreachable in each module separately become reachable in
the shared one — and the annotations travel verbatim with the code.

Four annotations were made false this way in a single afternoon, by a refactor
that was otherwise correct and behaviour-preserving. Nothing failed. The suite
stayed green and the gate stayed at 100.0, because a false annotation's whole
effect is to *keep* the figure at 100.0.

> **Annotations are re-earned, never transported.** After any change that moves
> code between modules, or that changes which suites reach it, every annotation
> that travelled is a fresh claim and has to be justified again.

## What actually notices

Devel::Cover checks its own annotations. When code marked uncoverable **is**
covered, the report marks that row with `***` in a column headed `err`:

```
line  err      %   true  false   branch
----- --- ------ ------ ------   ------
8           - 50     -0      1   if ($x)      <- honest: annotated, never taken
16    ***   -100     -1      1   if ($x)      <- stale: annotated, but exercised
```

Two things are worth reading off that table:

- The `***` is the verdict, per annotation, computed by the instrument.
- The excused position carries the raw count behind a minus: `-0` when the
  outcome never fired, `-1` when it fired once. **A non-zero count behind a
  minus is a false claim** — a reachable, exercised outcome being excluded from
  the figure anyway.

The marker appears on **standard output**, inside the per-line detail sections —
not on stderr, which is where one would reasonably look for something called an
error.

### Reading the report correctly

The report is not one table. It carries several detail-section layouts, whose
headers end in `code`, in `branch` and in `condition`, and **each has its own
column offsets**. A reader that takes one section's offsets and applies them to
the rest silently skips the others — which is exactly where branch and condition
annotations live, and they are the overwhelming majority.

Anything parsing this report must therefore recompute the column layout at every
header. A parser that does not will return a small, plausible, wrong number
rather than an error.

## Where this sits in the gate chain

```
script/coverage-gate
  drops the database, runs the instrumented suite, then runs the report
  captures BOTH streams  ->  $stdout . $stderr
       |
       v
script/check-all-metric-coverage
  judges the four metric totals from the Total row
```

The full report — detail sections and all — reaches the checker on standard
input. The checker's subject is the Total row.

## Reviewing a change against this

- **A refactor that moves code between modules is an annotation event.** Ask
  which annotations travelled, and whether each is still true in its new home.
  "The tests still pass" is not evidence: a false annotation's effect is that
  they do.
- **A coverage figure that does not move after a change that should have moved
  it** is the classic symptom — of a stale annotation, or of one that was
  silently ignored for carrying two criteria in one comment.
- **Never add an annotation to reach 100.0.** The bar exists to force the
  unreachable outcome to be identified, not excused. An annotation is a claim
  that a test *cannot* be written, and it should be as hard to write as that
  sounds.
- **Count the annotations, but do not report the count as the finding.** A total
  is compatible with every annotation being honest and with a third being stale.
  The discriminating figure is per file: how many are marked, versus how many are
  marked **and** still untaken.

## Related

- `uncoverable-annotation-placement.md` — the companion page, and the one to read
  **first** if an annotation is not being honoured. It covers *where* the comment
  has to sit for Devel::Cover to credit it, verified against 1.52 with minimal
  repros, and the one limitation that has no annotation workaround. This page
  does not cover placement at all; that page does not cover staleness. An
  annotation can be perfectly placed and still be a false claim, which is why
  both exist.
- `assertions-that-cannot-fail.md` — the same family from the test side: an
  assertion that passes because it was never in a position to notice. An
  uncoverable annotation is its counterpart in the instrument: a claim the
  coverage figure credits without checking.
- `gate-verdicts.md` — how a coverage verdict is recorded and read, and the three
  states (clean, failed, could-not-look) that must never collapse into two.
