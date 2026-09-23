# The coverage gate's tree-fingerprint check, and what it deliberately ignores

## What this is

`script/coverage-gate` brackets its instrumented suite run with a fingerprint
of everything under `t/` and `lib/` (`_grading_identity()`): a SHA-256 of
every file's path, size and mtime. If the fingerprint taken before the suite
differs from the one taken after, the gate refuses to report a coverage
number at all - a run that graded two different states of the tree cannot
honestly describe either one.

## Why it deliberately excludes `t/tmp-sow03/`

`t/tmp-sow03/` is a real, `.gitignore`-documented test-artifact directory:
`t/183-pax-cli-build-run-contract.t` and its PAX-build sibling tests write
real compiled binaries and `.c` intermediates into it during a normal
`prove -lr t` run, and (per `.gitignore`'s own comment) only clean it up
**before** each run, never after. That is expected, deliberate churn from
the suite's own tests - not evidence that anything external touched the
tree, which is the only thing this check exists to catch.

Before this exclusion existed (DD-1036), that churn alone made the gate
refuse on **every real CI run**, confirmed on 5 consecutive Test-workflow
runs across 5 unrelated commits, on a fully isolated GitHub Actions runner
where nothing else could possibly have been touching the checkout. The
coverage gate had never gone green on a real full-suite CI run.

`_excluded_artifact_dirs()` names the directories to prune from the
fingerprint scan. Add a new test-artifact directory here if a future test
needs one under `t/` and legitimately writes to it during a normal run -
but prefer a real `File::Temp::tempdir()` **outside** `t/` entirely
instead, which needs no exclusion at all (see below).

## A structural fix worth preferring over a new exclusion

`t/220-native-shape-bitwise-ops.t` had the same latent defect independently:
it wrote real compiled native binaries to a fixed path,
`t/tmp-t220-native/`, under `t/`. Rather than adding a second name to
`_excluded_artifact_dirs()`, it was fixed to use a real
`File::Temp::tempdir(CLEANUP => 1)` instead - a path genuinely outside
`t/`, so it can never trip this fingerprint check and needs no special-casing
here. **This is the preferred fix for any NEW test that needs its own
build/artifact output directory** - `t/tmp-sow03/` stays as the one
grandfathered exception because it is shared infrastructure ported from
PAX's own upstream fixture corpus, not something safe to relocate casually.

## A second, independent bug this investigation also caught

While adding the `t/tmp-sow03/` exclusion, its very first implementation
had zero effect at runtime despite being syntactically correct and present
in the file: it was written as a top-level `my @EXCLUDED_ARTIFACT_DIRS = (...)`
statement positioned textually **after** `script/coverage-gate`'s own
`exit main(@ARGV);` line. That `exit` unconditionally ends the process
before control flow ever reaches a statement below it - subs defined below
it remain callable (Perl compiles the whole file first), but a top-level
assignment statement is a *runtime* action that line ordering genuinely
gates. Caught immediately by the RED test written for the exclusion itself
(t/149) - the assertion failed with the exclusion silently empty. Fixed by
computing the list inside its own sub, called fresh each time
`_grading_identity()` runs, rather than as a module-level constant.

## Verification

`t/149-coverage-gate-moving-target.t` proves both directions: a real change
under `t/` or `lib/` still trips the refusal (the check's whole purpose),
and a write confined to `t/tmp-sow03/` does not (the exclusion this page
documents).
