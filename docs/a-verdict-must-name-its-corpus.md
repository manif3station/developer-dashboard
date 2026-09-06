# A checker that consults a corpus must report which corpus, and how old

When a tool's answer depends on a dataset it did not produce — an advisory
database, a licence list, a rule set, a dependency manifest — its verdict is
only as good as that data. **If it does not say what it read, a clean answer
from stale data is indistinguishable from a clean answer from current data.**

That is not a hypothetical. It happened here, and it hid a real CVE.

## What it cost

Both CVE gates load `CPAN::Audit::DB` and report a verdict without ever naming
or checking it. Measured 2026-09-06, with the database as the *only* variable —
same closure, same root, same 83 distributions:

```
CPAN::Audit::DB 20260807.001  (30 days old)  ->  EXIT 0
   "No distribution in the declared runtime closure permits a version
    inside an advisory range."

CPAN::Audit::DB 20260906.002  (current)      ->  EXIT 1
   "URI permits 1.59 which has advisory CPANSA--2026-19953"   (affected <5.36)
```

The stale run was not unlucky. **URI is not in the older database at all**, so
that run was structurally incapable of reporting the finding. It did not fail to
notice; it had nothing to notice with.

The consequence is larger than one run: every CVE-clean record taken on this
host that day — including **v4.30's own release gate** — was taken against the
stale database. None of them is false about what executed. None is evidence of
what it claims.

## The shape, which is this project's most expensive one

An instrument that cannot see the thing reports clean, with the same confidence
and the same words it would use if it had looked and found nothing. Nothing in
the output distinguishes the two.

Both gates already know how to say "I could not establish an answer" — they exit
`2` for unusable, distinct from `0`. **Database age is a third state that was
being reported as the first.** The vocabulary existed; the case was missing.

## What to do about it

- **Print the corpus identity on EVERY run, including clean ones.** A version
  reported only on refusal leaves every green already in the archive as
  ambiguous as it was. The clean path is the one that needs the stamp, because
  the clean path is the one people believe.
- **Refuse on staleness through the existing unusable exit**, not a new code. A
  gate that cannot see current data has not found nothing — it has not looked.
  Splitting one concept across two exit codes teaches readers that the codes
  don't mean anything in particular.
- **Falsify the age guard in both directions.** Stale must refuse; the same data
  with a widened threshold must pass *and still print*. A guard only ever seen
  to fire proves it can fire, not that it discriminates.
- **Keep reporting separate from judging.** Changing what a gate says about
  itself must not change what it treats as a finding — assert that explicitly,
  or a later reader cannot tell which half moved.

## Where else this applies

Anywhere a verdict rests on data fetched from outside: CVE and licence scanners,
dependency resolvers reading a registry snapshot, policy engines loading a rule
set, spell and lint checkers with dictionaries. **The question to ask of any such
tool is not "did it pass" but "what did it read, and when was that current".**

If the tool cannot answer the second question, the first one has no meaning.
