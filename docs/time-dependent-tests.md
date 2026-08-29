# Tests that depend on time, and how they rot

A test whose outcome depends on *when* it runs will eventually report something
other than what it names. This page describes the failure and how to write
around it. It is about the system, not any one ticket.

## The shape

A test fixture sets something up "in the past" — an aged file, an old
timestamp, a stale record — and then asserts that the code under test treats it
as old. The fixture picks that age as a **constant**:

```bash
touch -d "@$(( $(date +%s) - 144000 ))" "$log"     # 40 hours ago
```

That works, until the thing it is being compared *against* moves. If the code
decides "old" by comparing against the newest commit, then a 40-hour-old fixture
is only old while the repository has been committed to within the last 40 hours.
Let the repository go quiet for a weekend and the fixture's "old" artifact is
now *newer* than HEAD. The code correctly declines to call it stale. The
assertion fails. Nothing changed except the calendar.

**The fixture stopped testing what it names, and said nothing.**

## Why it is worse than an ordinary flaky test

Three properties make this class expensive:

- **It fails in the quiet periods.** Exactly when nobody is watching, and
  exactly when a red suite is least likely to be attributed to a real cause.
- **CI cannot see it.** CI runs seconds after a push, when HEAD is fresh, so the
  window never elapses there. A green remote and a red local are then *both
  correct*, about different repository ages — and the disagreement reads like a
  local environment problem.
- **It accuses the wrong component.** The test names a tool; the tool is
  behaving correctly; the fixture is the liar. The natural first move is to
  "fix" the tool, which either breaks it or weakens the assertion until it
  passes.

## The rule

**Age a fixture against the same reference the code compares against, never
against the wall clock.**

If the code asks *"is this older than HEAD's commit?"*, the fixture must be
built from HEAD's commit time:

```bash
head_ct=$(git log -1 --format=%ct 2>/dev/null || echo 0)
if [ "$head_ct" -gt 0 ]; then base=$(( head_ct - 3600 )); else base=<fallback>; fi
touch -d "@$base" "$artifact"
```

Make the caller say which it means, so the intent is in the call rather than in
a number the next reader has to decode:

```bash
run_with older-than-head "$verdict"   # computed, cannot rot
run_with 5 "$verdict"                 # genuinely "5 seconds ago", and means it
```

Keep a fallback for the case where the reference is unavailable — no git, no
commits — and make the fallback build something *old*, not something new. A
fallback that silently produces a fresh artifact turns an unavailable reference
into a passing test.

## Where else this bites

The same reasoning applies to anything a fixture ages against a moving target:

| the code compares against | so the fixture must be built from |
|---|---|
| the newest commit | `git log -1 --format=%ct` |
| another file's mtime | that file's mtime, not `now` |
| a recorded run's timestamp | that record, read back |
| a rolling retention window | the window's own boundary |

And one that is not about time at all but fails identically: a fixture that
hard-codes a count — "skip 20" for a block containing twenty assertions — starts
lying the moment somebody adds the twenty-first.

## Reviewing a change against this

1. Does this fixture manufacture a "past" or a "future"?
2. What does the code under test actually compare that against? Find the
   comparison, do not assume it is `now`.
3. Is the fixture built from that same reference, or from a constant?
4. If the reference is unavailable, does the fallback fail safe — building
   something that still exercises the branch under test?
5. **Would this test still be testing what it names if the repository sat
   untouched for a month?** If you cannot answer yes, it will eventually go red
   for a reason nobody will look for.

Point 5 is the one that catches it, and it costs nothing to ask.
