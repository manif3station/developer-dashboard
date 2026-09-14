# A saved page's CODE sections run in numeric order, not lexicographic order

`Developer::Dashboard::PageDocument::from_instruction` parses a saved page's
raw `=== CODE<N> ===` sections into `meta.codes`, an ordered array that
`Developer::Dashboard::PageRuntime::run_code_blocks` later executes
sequentially, one block at a time, against a single shared sandpit.

## The rule

The CODE-section keys (`CODE0`, `CODE1`, ..., up to `CODE1000` per
`@LEGACY_KEYS`) are ordered **numerically** by the digits after `CODE`, not
by a plain string comparison. `CODE2` always resolves before `CODE10`.

## Why

A page author writes numbered code blocks expecting them to run in that
numbered order - block 2 before block 10 is the obvious reading of "step 2"
and "step 10". A bare Perl `sort` compares strings character-by-character,
so it places `"CODE10"` before `"CODE2"` (`'1' < '2'`) the moment a page
reaches ten or more code blocks. `@LEGACY_KEYS` already declares
`CODE0` through `CODE1000`, so multi-digit section numbers are squarely
within the module's own contract, not a hypothetical edge case.

This is not cosmetic: `run_code_blocks` builds one sandpit per page and runs
every code block against it in array order, carrying state forward from
block to block. With the string-sort bug, `CODE10`/`CODE11` would run
immediately after `CODE1` and see `CODE1`'s state but not `CODE2`-`CODE9`'s,
while `CODE2` would then run afterward and see `CODE10`/`CODE11`'s side
effects instead of `CODE1`'s - silently wrong or stale execution state for
any page with ten or more sequential code blocks, which is the natural
authoring pattern this feature exists to support.

## How it works

```perl
for my $section ( sort { ($a =~ /(\d+)/)[0] <=> ($b =~ /(\d+)/)[0] }
                   grep { /^CODE\d+$/ } keys %sections ) {
    push @codes, { id => $section, body => ... };
}
```

The comparator extracts the digit group after `CODE` from each key and
compares those numerically (`<=>`), rather than comparing the whole key as a
string (the default `sort` with no block).

## What uses it

`Developer::Dashboard::PageDocument::from_instruction` is the only place
this ordering is produced. `Developer::Dashboard::PageRuntime::run_code_blocks`
is the consumer that depends on the order being correct, since it executes
each block sequentially against one shared sandpit.

Two other `sort keys %$value` call sites in `PageDocument.pm` (used for
stash/state hash-key display ordering, not CODE-section execution order)
are deliberately unaffected by this rule - they format arbitrary
user-supplied hash keys for display, where there is no numeric contract to
honor and lexicographic order is the correct, expected behavior.
