# A coverage verdict is bound to what the gate actually read, not to a fingerprint taken afterward

`.claude/tools/coverage-run` records `WORKSTATE` - a fingerprint of
uncommitted tracked work plus the content of every file under the
git-ignored `.claude/tools/` directory - in every verdict it writes. Until
DD-787, that fingerprint was computed exactly **once, at the end** of the
run, inside `mark()`. It answered "what was on disk when the run
finished", which is a different question from "what was on disk while the
gate was reading it" - and nothing compared the two.

## Why that gap matters

A `prove -lr t` run under `Devel::Cover` takes tens of minutes. On a
shared host - several sandboxes, several sessions, sometimes another
project entirely - a `lib/` file can genuinely change while that run is in
flight: a concurrent commit lands, a sibling session edits a module, a
rebase happens mid-run. The coverage numbers the gate reports describe
whatever `lib/` looked like at the moment each test file actually ran -
which, for a file touched partway through, can be a mix of the old and new
content.

Before this fix, none of that showed up anywhere. `WORKSTATE` was taken
*after* everything had already happened, so it faithfully fingerprinted
the *post-edit* tree - the verdict looked exactly as clean and current as
a run that measured a genuinely stable tree throughout. A reader comparing
that `WORKSTATE` against their own checkout would see a match and have no
way to know the measurement itself had been taken across a moving target.

## The fix: fingerprint before AND after, and flag a mismatch

`coverage-run` now calls `working_state_fingerprint()` immediately before
launching the gate (`WORKSTATE_BEFORE`, captured right after the log is
truncated and right before `setsid stdbuf -oL $GATE` starts) as well as at
the end (`workstate_after`, in `mark()`, exactly as before - `WORKSTATE=`
in the verdict is unchanged and still describes the tree at completion, so
`gate-status`'s existing staleness check keeps working). If both resolved
(neither is the `unknown` fallback `working_state_fingerprint()` returns
when it cannot compute a digest at all) and they differ, the verdict gains
a new line:

```
EDITED-DURING-RUN: the working tree changed while this measurement was in
progress (before=<hash> after=<hash>) - this verdict does not stand
```

This is deliberately the same shape as the existing `CONTENDED` marker -
an explicit, checkable line inside the verdict itself, not a silent
omission - so a proof that quotes the verdict carries the invalidation
with it.

## Reviewing a change against this

- **`unknown` never triggers the flag on its own.** A host where the
  fingerprint genuinely cannot be computed (not a git checkout, or some
  other resolution failure) already reports that state through
  `working_state_fingerprint()`'s own `unknown` value; treating two
  `unknown`s as "different" would fire on every such run for an unrelated
  reason.
- **`WORKSTATE=` (the after-value) is unchanged in meaning.** Nothing
  reading that single field - `gate-status`'s own staleness comparison
  included - needed to change; the new check is additive.
- **The fingerprint covers the same scope it always did**: uncommitted
  tracked work (`git status --porcelain`, `git diff HEAD`) plus every file
  under `.claude/tools/` by path and content. A committed change mid-run
  moves `HEAD`, not this fingerprint - that is `TREE=`'s job, recorded
  separately in the same verdict.

## Related

- `docs/bounding-a-poll-loop-by-time-not-count.md` - a different
  before-vs-after gap in this same tooling family (wall-clock deadline
  loops vs. poll counts), for the same reason this one exists: a value
  read only once, at the wrong moment, cannot tell you what happened while
  it wasn't looking.
