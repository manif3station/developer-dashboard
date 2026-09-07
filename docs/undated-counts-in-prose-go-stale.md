# An undated count in prose goes stale silently

Why narrative documentation should describe a state rather than store a
number, and what to write instead when a number is tempting.

## The problem this solves

A sentence like *"the product was clean across the 81 distributions in its
declared closure"* records a measurement inside prose. The measurement is
real when written, and nothing marks the moment it stops being true - the
declared closure grows as dependencies are added, and the number in the
doc does not grow with it.

The cost is not that the number is wrong. It is that a reader who runs the
gate today and gets a different number cannot tell whether the
documentation is stale or their own invocation is wrong - the two look
identical. `doc/security.md` carried exactly this (81 written, 83 measured;
DD-768).

This is the same shape CLAUDE.md already names for card titles: a count is
a measurement of the codebase at an instant, put in the one place that
never gets updated.

## The rule

> **When a sentence's point is a state ("the product was clean") rather
> than a specific historical measurement ("that one run found 24
> advisories"), write the state without the count.** A number that could
> change without changing the sentence's meaning does not belong in it.

Two different things sound similar and are not:

- *"...exited 88 with twenty-four advisories across seven distributions"*
  describes ONE specific historical run, anchored to a named incident. The
  number is the fact being reported and correctly stays.
- *"...clean across the 81 distributions in its declared closure"*
  describes an ongoing property using a number that only happened to be
  true when written. The number is decoration on a claim that needs none -
  *"clean across every distribution in its declared closure"* says the
  same thing and cannot go stale.

## How to apply

Before writing a count into prose, ask: if this number changes next month,
does the sentence's point change with it? If not, drop the number. If the
sentence is instead reporting what one specific run found, keep the number
and anchor it to that run by name - the two are different claims and only
one of them ages.
