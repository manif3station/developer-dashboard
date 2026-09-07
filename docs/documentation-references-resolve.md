# Documentation references to test files must resolve

## What this is

Prose across this project names test files by path — `prove -lv t/136-upgrade-cli.t`
in `doc/upgrade.md`, the `EXAMPLES` section of a shipped helper's POD, a
`WHAT USES IT` line in a module. Those references are instructions a reader is
expected to run verbatim, and nothing about a file rename updates them: `git mv`
rewrites the index, not the sentences that point at the old name.

`t/15-release-metadata.t` therefore carries a guard: **every token of the form
`t/NN-name.t` or `t/NNN-name.t` found in the project's documentation must exist at
that exact path.** A stale reference fails the suite, naming the document and the
token, in the same run that would otherwise ship it.

## Where it looks

The population is fixed, not configurable, so a wrong root cannot silently read
as clean:

| source | why it is in the population |
|---|---|
| `doc/*.md`, `docs/*.md` (when present), `README.md` | the operator and user documentation |
| every file `_perl_doc_paths()` walks — `lib/`, `t/`, `share/private-cli/`, `updates/`, `integration/`, `app.psgi`, `bin/dashboard` | POD `EXAMPLES` / `WHAT USES IT` sections and comments that cite tests by path; the private helpers ship and are staged into the user's runtime, so their POD is user-facing |

The token pattern is `t/[0-9]{2,3}-[A-Za-z0-9_.-]+\.t`. The guard asserts the
population is non-empty before asserting anything about it — an empty population
is a broken guard, not a clean result.

## What counts as resolved

Only the exact path. Test prefixes are reused after renumbering (the file once
numbered 122 (`upgrade-cli`) is `t/136-upgrade-cli.t`, and `t/122-` now belongs
to an unrelated test), so a prefix match would send the reader to the wrong
test while the guard stayed green. The test carries a control pair for this: the
resolver must report the old `122` name unresolved even though a `t/122-*`
file exists, and must report `t/136-upgrade-cli.t` resolved.

## How to cite a test so the guard stays green

- Cite the **full filename**. A bare prefix (`t/15`) is not checked by this guard
  and can become ambiguous when prefixes collide.
- When renaming a test, `git grep -n '<old name>'` across `doc docs README.md lib
  t share bin integration` in the same change. The guard will fail the suite if
  a reference is missed, but the grep is cheaper than the round trip.
- A reference inside a fenced example or a POD verbatim block is still a
  reference — the guard reads whole files, because those are exactly the lines a
  reader copies.

## What it does not cover

Bare-prefix references and colliding prefixes are a separate property with a
separate guard (tracked under the test-prefix collision work). References to
paths outside `t/` are not checked; none were found unresolved when this guard
was introduced.

## Running it

```
PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/15-release-metadata.t
```

The failure message names the document, the token and the number of documents
scanned, so the fix is the rename's missing half rather than a search.

## A note on the guard's own text

The guard scans `t/` too, so `t/15-release-metadata.t` cannot spell the stale
control token as a literal without failing itself, and this page cannot either.
The test assembles it from parts at runtime; this page describes it as "the old
`122` name". That is deliberate: a guard that grants itself an exemption has a
hole exactly where the next person will copy from.
