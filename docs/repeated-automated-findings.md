# How a repeated automated finding is identified

A scheduled checker that files tickets has to answer one question every time it
runs: **is this the same finding I filed last time, or a new one?** Getting that
wrong does not look like a bug. It looks like a busy board.

## What went wrong here, measured

Three hunt profiles sweep this repository on timers and file a card per finding.
Counted across every card they have filed:

| | |
|---|---|
| cards filed | 28 |
| distinct findings | 11 |
| **redundant refs** | **17** |

One finding — *modules over 1500 lines* — was filed **seven times in three
days**. Another was filed three times despite the first having been verified a
false positive and discarded, so a finding already adjudicated wrong came back
under new refs.

Nothing was broken in the detection. Every one of those sweeps looked, and
mostly looked correctly. What failed was identity.

## Identity must be per ITEM, not per SET

The checker hashed the whole item set to decide whether it had seen a finding
before. That is the intuitive choice and it is wrong, because the set changes
for reasons the individual findings do not care about:

    before   lib/A.pm (1600 lines)   lib/B.pm (2000 lines)
    after    lib/A.pm (1611 lines)   lib/B.pm (2000 lines)   lib/C.pm (1502 lines)

One new module crossed the threshold. A set-level hash changes, so the whole
finding refiles — re-reporting `A.pm` and `B.pm`, which were already on the
board and which nobody needed to hear about again.

**Fingerprint each item; report the difference.** A membership change should
file the member that changed. That is also the established answer outside this
project: analysis tools carry a stable per-finding fingerprint precisely to
avoid re-reporting across runs.

An earlier fix had already made each item stable by stripping digits from it,
so `(1600 lines)` and `(1611 lines)` hash alike. That was correct and
insufficient — it stabilised the *items* and left the *set* volatile.

## A count does not belong in the title

The title carried the number of items: *Subroutines over 120 lines (6)*. Three
consequences, and the third is why the pile grew unnoticed:

1. **It is unfalsifiable.** An independent count gave 7. Neither number can be
   checked against the other, because no method is recorded — the disagreement
   can only be replaced by a third count.
2. **It ages instantly.** The number is true of one instant and lives in the one
   field nobody updates.
3. **It defeats deduplication by humans.** `(6)` and `(7)` are different titles.
   No search, no glance down a column, and no exact-match check can see they are
   one finding.

The count belongs in the body, where a reader wants it and where it misleads
nobody. **The title is an identity; identities do not carry measurements.**

## Migrating an identity scheme is its own hazard

Changing how findings are identified invalidates every record written under the
old scheme. Here, treating "no per-item data" as "nothing reported yet" would
have refiled *every* finding in full on the first run — the fix producing one
last duplicate wave.

The old records carried the old set digest, which is enough to decide safely:
if it still matches, the set is provably unchanged and suppressing is correct
with nothing lost; if it differs, something changed and the previous behaviour
is preserved exactly.

The first attempt suppressed on old-format alone, and **silently swallowed a
checker's cannot-look finding** — the one result that must never be silent. Four
existing assertions caught it. The lesson is narrow and worth keeping: when you
change what identity means, the migration must be decided from evidence the old
records actually carry, not from a blanket assumption about them.

## How to apply

- Fingerprint the **item**, not the collection it arrived in.
- Report the **difference** between runs, not the current state.
- Keep measurements out of identities — titles, keys, filenames.
- When changing an identity scheme, ask what the existing records still tell you,
  and prove the migration cannot either refile everything or silence anything.
- Detection accuracy is a separate concern with its own failure modes; see
  *Source-scanning checkers can't see heredoc boundaries*, including the case of
  an assertion proving a token's absence being read as an instance of it.

## A reproduce command that the tool's own bookkeeping silences

Recording the difference between an item and its collection is only half of
making a finding checkable. The other half is that the reader can *re-run* it —
and that is easy to get wrong in a way every test still passes.

A finding filed here carries a `Reproduce:` line naming the command that
produced its number. The obvious command is the sweep itself:

    hunt-monitor --profile improvement --once --dry-run

Run by a reader, that prints `0 card(s) raised`. The sweep consults its ledger
and stays deliberately silent about a finding it has already filed — which is
correct for a scheduled hunt and useless for reproduction. So the card sent its
reader to a command that answers nothing about whether the finding still holds,
and a reader would reasonably conclude it had been fixed.

The code beside it claimed the command *"reproduces the number exactly by
construction"*. Every assertion around that comment passed. Only the stated
mechanism was false, and a stated mechanism is what the next person reuses.

**A reproduce path must ignore the state that makes ordinary operation quiet,
and must therefore write nothing.** The fix is a separate mode — here
`--report-all` — that empties the ledger for the run and forces the no-write
path, so reproducing is a read:

    ledger sha before  fe68cdac989a
    ledger sha after   fe68cdac989a      (verified behaviourally, not by reading the code)

**Two rules worth keeping beyond this tool.**

*Perform the reproduce step, do not review it.* This was found by working the
card's own test step — "re-run the recorded command by hand and assert it
produces the number the card claims" — rather than by reading the code that
emits it. Reading it produced a plausible command; running it produced nothing.

*A flag named only inside a printed string is text, not an interface.* Assert
that the option **exists** on the parser, which is why the parser is built by a
factory the spec can call. A test that greps a help string for a flag name
passes just as happily when the flag was never wired up.
