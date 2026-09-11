# `decline-watch`'s triggers are a shared count-and-compare shape, plus a predicate that stays code

`.claude/tools/decline-watch` re-verifies every declined policy on the
board: a decline is only allowed to stand while its `RE-DECLARE TRIGGER:
<name>` clause names a condition that has not yet fired. `%TRIGGERS` maps
each declared name to the check that decides whether it has.

## The shared shape, extracted once (DD-780)

Both triggers that exist today - `checklists-adopted` and
`standalone-labelling-caught-up` - turned out to be the *same* shape with
different parameters:

1. export the board with a named set of fields,
2. count how many records match a predicate,
3. compare that count against a threshold with an operator (`>=` or `<=`).

`count_threshold(%opts)` is that shape, taking `fields`, `predicate` (a
coderef receiving one record and returning true/false), `op`, and
`threshold`. Both existing triggers are now a few lines each - the
predicate plus a call - instead of a fully duplicated closure carrying its
own export call, `ref` checks, and comparison.

```perl
'checklists-adopted' => sub {
    return count_threshold(
        fields    => 'ref,checklist',
        predicate => sub { ref $_[0]->{checklist} eq 'ARRAY' && @{ $_[0]->{checklist} } },
        op        => '>=',
        threshold => 3,
    );
},
```

A **third** trigger of this same count-and-compare shape now costs a
predicate closure and four named arguments, not a copy of the whole
export/count/compare block.

## Why the predicate itself was deliberately NOT parameterised

The two real predicates - "has a non-empty checklist array" and "has no
parent and carries no `standalone` label" - share no structure beyond
"takes a record, returns a boolean". Making the predicate *itself*
declarative (a small expression language: field equality, array
non-emptiness, boolean composition, and so on) would need real design work
to justify, and **two data points is not enough evidence that the
generality is worth it**. This project's own `CLAUDE.md` states the
principle directly: *"Don't add features, refactor, or introduce
abstractions beyond what the task requires... Three similar lines is
better than a premature abstraction."*

So a genuinely new predicate shape - one that cannot be expressed as "count
records matching X, compare against N" - still needs its own short Perl
closure, exactly as it always would have. That is inherent to the
problem, not a gap this change left behind.

## Reviewing a change against this

- **A new trigger of the count-and-compare shape belongs in
  `%TRIGGERS` as a `count_threshold(...)` call**, not a hand-rolled export
  loop - the duplication `count_threshold` removes would otherwise
  reappear immediately.
- **Do not reach for a declarative condition-type system on the strength
  of one more example.** The bar for that generality is a real, repeated
  need across several genuinely different predicate shapes, not "now
  there are three triggers instead of two."
- **`count_threshold` returns `undef` when the board could not be read**,
  matching both original closures' own behavior - a caller that treats
  `undef` as `0` would silently read "could not look" as "condition not
  yet met," which is the same class of error `judge()` elsewhere in this
  file explicitly avoids (`UNVERIFIED`, never `still-true`).
