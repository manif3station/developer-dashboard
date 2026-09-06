# When a spec's `@INC` depends on the machine

How a test file in this repository can resolve modules differently on a
developer's box than in CI, what the class actually is, and why no cheap search
finds it. This page describes the system, not any one ticket.

## The class

> **A spec is machine-dependent when what it puts on `@INC` — or fails to keep
> off it — differs between this host and a fresh one.**

Two mechanisms, opposite in direction, both producing the same kind of surprise:

| mechanism | what it does | where it hurts |
|---|---|---|
| **inherits** | prepends a shadow to the *existing* `PERL5LIB`, so the real modules behind it stay reachable | the spec passes locally on modules it never provided; fails where they are absent |
| **manufactures** | hardcodes a path that exists only on one machine | the spec passes locally *because of* the entry; elsewhere it is inert, so a missing dependency cannot be reported |

The second is the subtler half. An inert entry breaks nothing — it **masks**.
A spec that cannot fail for a missing dependency cannot report one.

## Why the hardcoded path gets written in the first place

It is not carelessness, and knowing the reason is what stops it recurring:

```perl
local $ENV{HOME}     = tempdir(CLEANUP => 1);        # correct hermetic practice
local $ENV{PERL5LIB} = join ':', '/home/<user>/perl5/lib/perl5', ($ENV{PERL5LIB} || ());
```

**The isolation creates the need for the machine-specific value.** Localising
`HOME` to a tempdir is the convention this repo teaches, and it destroys any
`$HOME`-relative resolution of the module path — so the literal is added to
compensate. The two lines are always adjacent, and the second only looks
arbitrary if you have not read the first.

Capture the real `HOME` *before* the localisation, or drop the entry and let the
caller's environment supply the deps.

## No cheap proxy identifies the population

Five were tried against a known instance, and every one of them produced a
tidy, publishable-looking list:

| proxy | why it fails |
|---|---|
| in-process fakery (`%INC`, glob localisation, mock modules) | misses filesystem shadowing entirely — writing a real `.pm` and putting its directory on the path |
| prepend-vs-replace of `PERL5LIB` | a prepend is safe when the shadow is written to `die`: nothing behind it is reachable |
| guarded-vs-unguarded (`skip_all`, `eval { require }`) | split a sample cleanly and looked like a finding — the known instance **carried two guards and failed anyway** |
| the word "hermetic" in the file's prose | in this repo "hermetic" almost always means **hermetic HOME** — tempdir plus `chdir` — which is a *different subject* and a correct convention. It finds the files doing it right. |
| "writes a `.pm` and touches `PERL5LIB`" | misses every spec that shadows nothing and merely fabricates a path |

**The reason is structural, not a missing regex: the defect is a RELATIONSHIP
between a spec and its subject.** No property of either file alone expresses it,
so no single-file search can express it either.

## What does work

For each candidate, read what the **code under test** requires and compare it
against what the **spec supplies**. The gap is the finding.

That ordering matters. Reading the spec's own fakes cannot find a module the
spec never mentions — and in the known instance, the module whose absence broke
it appears nowhere in the spec. **Absence is not findable by searching for what
is present.**

## Checking a candidate

Run it where the machine-specific condition is absent — a container with no
such user directory — and read the result:

| outcome | meaning |
|---|---|
| passes | the entry is **inert**: a masking risk, not a breakage |
| fails | a hard dependency on the host |

**Do not use a bare `env -u PERL5LIB` as the discriminator.** Most specs here
legitimately need the product's dependencies, so clearing the path fails them
for a reason that has nothing to do with machine-dependence — a false positive
on nearly every file.

And **report the named list with each member's mechanism, never a total.**
Counts derived by pattern have been wrong in both directions here: one file
counted as writing a module when it only reads one, another missed as not
writing when it demonstrably does.

## Related

- `docs/a-claim-of-hermeticity-needs-a-check.md` — the *inherits* half, and why
  a claim of isolation needs a check that can go red. This page is the
  population question: which files to point that check at.
- `docs/absence-versus-parse-failure.md` — an empty search result reading as a
  clean board.
