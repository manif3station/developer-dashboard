# A tool that answers "what next" encodes a model of the board — and that model drifts

A recommender is not a lookup. When something answers *"what should I work on
next?"*, it necessarily hard-codes a picture of what the board looks like: which
columns hold work, which states mean *available*, what order to consult them in,
and what makes a card unworkable. Every one of those is a fact about the board at
the moment the tool was written, and every one of them changes without the tool
being touched.

Nothing tells you when it has drifted. The tool keeps answering confidently, and
the answers keep looking reasonable, because a wrong recommendation is
indistinguishable from a right one until you open the card it names.

## The four ways one recommender had drifted

Measured in a single session, all in one 124-line script that had been correct
when written:

| what drifted | how it showed |
|---|---|
| what makes a card unworkable | offered a card the owner had deliberately deferred, five times over |
| which columns hold work | never proposed a card from the largest source of it, and did not know two columns existed at all |
| what a column means | asserted every card in one column was parked on a condition; 24 of 27 carried none |
| which columns are "in flight" | blind to three working columns, so its own *"never start something new while something is claimed"* rule could not fire |

The last one is the sharpest, because the tool **already stated the rule it was
failing to apply.** It could not see the column the claimed card was sitting in,
so the rule was correct, present, and unreachable.

## Why this class is hard to notice

**A recommendation is cheap to reject and expensive to doubt.** Opening the named
card and deciding "not that one" takes a minute, feels like ordinary work, and
produces no signal that anything is wrong. The cost is paid every session by
whoever runs it, and it never accumulates anywhere visible.

**The failure is silent in the direction that matters.** A tool that says
*"nothing to do"* while workable items exist is worse than one that names the
wrong item, and it looks identical to a genuinely quiet board.

**The tool's own documentation ages with it.** Messages like *"each of these is
parked on a condition"* were true statements about the board once. They become
assertions the reader has no reason to question, because they arrive from the
thing that just looked.

## What to do about it

**Read the tool, not its output.** Behaviour tells you what it does in the case
you happened to hit. The source tells you which columns it consults, which states
it treats as blocking, and what order it walks — and those are the things that go
stale. Enumerating them takes one grep and is the whole diagnosis.

**Prefer signals the board already stores over new conventions.** A recommender
that needs a new label to be taught something creates a second thing to keep in
sync. If the board already records the fact — a per-record exemption carrying its
own reason and release condition, say — read that instead. It cannot drift apart
from itself.

**Check the cost before rejecting an approach for it.** The obvious objection to
reading richer per-card state is that it will be slow. Measure which records the
tool actually evaluates: a check that runs over *candidates* rather than over the
whole board may cost two lookups where it appeared to cost hundreds. That
objection collapsed under one measurement here.

**Protect the "could not look" path above everything else.** A recommender that
cannot reach the board must say so and exit distinctly — never fall through to
*"nothing to do"*. Every other defect costs a wasted read; this one costs a false
all-clear, and it is the single behaviour most likely to be lost in a refactor
that is otherwise an improvement. Make it a non-regression criterion in its own
right.

**Write down what the tool believes.** The drift is invisible because the model
is implicit. A comment naming the columns it consults, the order it walks them,
and what it treats as unworkable turns a silent assumption into something a
reader can compare against the board — which is how the next drift gets caught
before it costs anybody a session.
