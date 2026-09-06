# Containing a CI dependency install

A CI job that runs `cpanm --installdeps .` with no target **mutates the perl
tree the runner shipped with**. That tree is not empty — `actions-setup-perl`
arrives with modules already installed at whatever versions its image was built
against — so the install is not a clean resolution. It is an edit to somebody
else's state.

## The rule

> **Install into a contained root, and export the path to it in the same
> change.** Either half alone is worse than neither.

```yaml
- name: Install Perl dependencies
  run: cpanm --installdeps --notest -L local .

- name: Something that runs perl
  env:
    PERL5LIB: ${{ github.workspace }}/local/lib/perl5
  run: ...
```

`test.yml` has done this for a long time and carries **8** references to
`PERL5LIB`. `fuzz-js.yml` had **0**, and installed with a bare `cpanm`.

## Why the second half is not optional

`-L local` puts the modules in `local/lib/perl5`, which is **not on `@INC`**.
Anything that then runs perl must be told where to look.

That is easy to miss when the consumer is not obviously a perl program.
`t/fuzz/scorecard-fast-check.mjs` is a Node script; it spawns perl with `-Ilib`,
the dashboard script path, and a command name. `-Ilib` supplies *the project's
own lib directory* and nothing else — none of the dependencies.

So adding `-L` on its own converts a **rare** failure into a **permanent** one.
Read the consumer before moving anything it depends on.

## What a bare install actually breaks

Mutating a pre-populated tree turns a version bump into an **upgrade**, and
cpanm verifies the result against a version scan taken **before** it installed
anything. From one real run, two lines and one second apart:

```
Successfully installed URI-5.37 (upgraded from 5.35)
! Installing the dependencies failed: Installed version (5.35) of URI is not in
  range '5.36', Installed version (5.35) of URI::Escape is not in range '5.36'
```

The install succeeded. The check reported the version that was there before it.

**The tell that identifies the cause is the second module.** `URI` and
`URI::Escape` ship in the *same distribution*, and both were reported stale by
exactly the same amount. A "verified against a different tree" explanation has
to account for both being present at 5.35 somewhere else; a single stale
pre-install scan predicts precisely this, because both readings came from it.

That distinction matters because the fixes differ, and the wrong one is
plausible.

## Containment fixes it, but not directly — and say so

Against a fresh `local/`, the module is **absent**. The install is a first
install rather than an upgrade, so there is no earlier version for a stale scan
to report. The upstream defect in cpanm is untouched; the *condition that
triggers it* is gone.

Worth stating plainly on any card that does this: we are not fixing cpanm. Its
post-install check is upstream behaviour. The substantive gain is
reproducibility — an install that depends only on the cpanfile and not on what
the runner happened to ship.

## The failure is invisible until a version moves

This is the part that keeps it alive. A bare install works perfectly for as long
as no declared version changes. It broke here on the day a floor was declared
(`URI >= 5.36`, [dependency floors and advisory freshness]) — which is to say,
the workflow was always wrong and simply had no constraint to be wrong about.

So "it has always passed" is not evidence that a CI install is contained. The
question is what happens the first time a dependency has to move, and the answer
is only visible on that day.

## Related

- `docs/dependency-floors-and-advisory-freshness.md` — declaring floors, and the
  same contained-install trick used for a different purpose (auditing against a
  current advisory database without mutating the shared `~/perl5` tree).
- `docs/ci-step-conditions.md` — what happens *downstream* when a step like this
  one fails. Note the difference: there, a gate was skipped behind an
  environmental failure and needed `if: always()`. Here the steps skipped behind
  an install that genuinely failed, which is correct. **Do not reach for
  `always()` because the symptom rhymes** — running tests whose dependencies are
  missing is worse than not running them.
