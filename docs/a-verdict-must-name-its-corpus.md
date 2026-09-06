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

## The signal usually already exists, and is merely not fatal

The first instinct on finding a verdict that rests on an unnamed corpus is to
build the missing check. Run the tool's `--help` first. On this occasion the
check already existed:

```
cpan-audit --fresh|f    check the database for freshness (CPAN::Audit::FreshnessCheck)
```

Installed, with a documented threshold and an environment knob. **What it does
not do is the point.** Measured both ways, without a pipe to launder the status:

| invocation | exit | freshness warning |
|---|---|---|
| `cpan-audit --fresh installed <root>` | 91 | STDERR |
| `cpan-audit installed <root>` | 91 | none |

Upstream **emits the signal and deliberately declines to make it observable to a
caller.** That is the right decision for an interactive audit, where a human reads
STDERR, and the wrong one for a release gate, where a machine reads a status.

So the work was never to invent an age policy. It was to escalate a signal
somebody had already decided was worth emitting, from an advisory line into the
verdict. That reframing matters for three reasons:

- it is a far narrower claim to defend;
- it **inherits upstream's definition** of the thing being measured rather than
  asserting a private one;
- it lets both behaviours share one knob, so they cannot silently disagree later.

**The general question to ask of any missing check is therefore two questions.**
First, does the signal exist? Second — and this is the one that gets skipped —
*does it change anything a caller can observe?* A warning on a stream nobody
captures, or a log line beside an unchanged status, is invisible to every
automated consumer. Finding the feature is not the end of the search; finding out
whether it reaches a verdict is.

### A trap while implementing the remedy

Two tools doing the same kind of job, in the same directory, with the same name
prefix, need not share an exit vocabulary. Here one gate used `2` for *unusable*
while its sibling used `2` for *the caller made a usage error*, reserving `4` for
*could not run*. A decision taken by reading one and applied to "the gates" would
have told CI something false about the caller, in the exact vocabulary the project
had already paid to separate. **Partial agreement between two tools is what makes
the disagreement invisible** — read each one's own definition, and assert per tool
rather than through a shared helper.

### And the corpus check is itself a consumer

Adding this made both gates invoke `cpan-audit --version`, which broke every test
double that had modelled the binary only as far as it was previously used —
twenty-two assertions across two files. The doubles were not wrong before; they
were complete for the surface that existed. **Widening what you ask of a
dependency widens what every stand-in for it must provide**, and the stand-ins
fail in a way that looks like your change being broken.

The honest repair is to make the doubles model the binary, not to loosen the
assertions around them. Two doubles here model a *broken* tool and were
deliberately left unable to answer `--version`, because a tool that cannot load
its own dependencies cannot answer that either: detecting it at the corpus probe
is more faithful, not a workaround.

## Choosing the staleness limit: measure the publisher, not your host

A freshness limit is a number someone picks, and picking it from intuition
produces a gate that either misses the case it was built for or blocks for
reasons nobody can act on. There is a measurable rule.

**The limit must exceed the largest real gap between publications.** Below that,
the gate will eventually refuse during an ordinary quiet spell when no newer
corpus exists to install — and a gate that blocks with no available fix does not
get fixed, it gets routed around.

Measured from the CPAN index on 2026-09-06, across 40 `CPANSA-DB` releases
spanning 223 days:

| median gap | mean | maximum | gaps > 14d | gaps > 30d |
|---|---|---|---|---|
| 4 days | 5.7 | **18** | 1 of 39 | 0 of 39 |

So 21 days: above the observed maximum with margin, and still well below the 30
that hid a live advisory here. **The measurement is the reason, not the
constant** — if a longer gap ever appears upstream, that is the number that
moves, and a reader who has the table can decide that without re-deriving it.

**Measure the publisher, not your own machine.** The gap that started this
investigation looked like a 30-day publication drought and was nothing of the
kind: it was this host's *install* history. Nobody had updated the box for a
month while upstream published seven times. A cadence inferred from one
machine's installed versions measures that machine's habits, and reads exactly
like a fact about the world.

## A refusal that names a fix must name one that works

The first version of this refusal ended `refresh it with 'cpan -D CPANSA::DB'`.
`-D` **describes** a distribution; it refreshes nothing. The wording came from
upstream's own message — which correctly says *check for updates with* — and was
silently promoted from a check into a fix. Measured on the host, `cpan -D` also
drops into `CPAN.pm`'s interactive configuration dialog, so a reader following the
instruction would land in a prompt and still hold a stale corpus.

**A plausible-looking wrong instruction is worse than no instruction**, because it
spends the reader's trust before it wastes their time, and it is only ever
discovered by someone who is already blocked.

The replacement also has to respect shared state. On a machine where one CPAN
tree serves every project, refreshing it in place changes the corpus under
somebody else's running gate. A contained snapshot placed first on the library
path shadows the stale copy for one process and leaves the shared tree alone —
which is what the refusal now prints.

The contained-snapshot commands themselves are not repeated here. They live in
`docs/dependency-floors-and-advisory-freshness.md`, under *"So: state the database
version beside the verdict"*, which arrived from the other half of the same
incident — a dependency floor declared so the chain could not permit the advisory
this gate could not see. **The two halves are worth reading together:** a manifest
that cannot exclude a vulnerability and a gate that cannot report its own blindness
produced one clean verdict between them, and fixing either alone would have left
that verdict looking exactly as trustworthy as it did before.

## The same question, one level down: does your test constrain anything?

A verdict is only as good as the corpus behind it. An *assertion* is only as good
as its power to fail — and a passing suite cannot tell the two apart. A green
assertion means either "this constrains the code" or "this would have passed
whatever the code did", and nothing in a passing run distinguishes them.

**Mutation is what separates them, and the useful signal is which assertions
survive.** Verifying the date arithmetic behind this gate, the century correction
was removed deliberately, expecting red. Four of seven assertions fell:

| case | on the mutation |
|---|---|
| 1970-01-01, 1969-12-31, 2000-02-29, 1900-03-01 | **red** |
| 2024-02-29, 2026-09-06 | **green** |

For a year in the current era the era-offset is 26, so `int(26/100)` is zero and
the century correction is a **no-op on contemporary dates**. A spec containing only
recent dates would have passed a broken century rule and proved nothing whatever.

The reflex on seeing red is to record the guard as falsified and move on. **The
value was in asking why the other three stayed green** — that answer is what
revealed which cases carry the discrimination, and it is not obtainable from a
passing run in either direction.

### And an oracle must be independent of the author

The same check, written first with expected values worked out by hand, had **one of
eight wrong** — the code was right and the expectation was not. Values derived from
the same reasoning that produced the code demonstrate only that the reasoning is
self-consistent. `Time::Local` is a separate implementation of the same calendar,
which is what makes it an oracle rather than a second opinion from the same source.

This is the corpus problem again, wearing test clothing: **name what your result
was checked against, and confirm that thing could have disagreed.**
