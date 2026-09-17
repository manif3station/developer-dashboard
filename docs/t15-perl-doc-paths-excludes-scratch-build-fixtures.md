# t/15's Perl-file POD sweep must exclude every test's own scratch/build fixture directory

What `_perl_doc_paths()` in `t/15-release-metadata.t` walks, why a test that
creates its own throwaway `.pm`/`.pl` fixtures under `t/` needs to be
excluded from it explicitly, and where the exclusion list lives.

## The mechanism

`_perl_doc_paths()` walks `lib/`, `t/`, `share/private-cli/`, `updates/`,
and `integration/` via `File::Find`, collecting every `.pm`/`.pl`/`.t` file
(plus `app.psgi` and `bin/dashboard`) as a file this project's own
`FULL-POD-DOC` rule applies to - full POD, NAME/PURPOSE/WHY IT
EXISTS/WHEN TO USE/HOW TO USE/WHAT USES IT/EXAMPLES.

That is correct for every file actually checked into the repository. It is
**not** correct for a file a *test* creates at runtime as a throwaway
fixture - several tests build a scratch directory under `t/` (e.g.
`t/183-pax-cli-build-run-contract.t`'s `t/tmp-sow03/`, gitignored,
deliberately left on disk after the test finishes rather than cleaned up at
the end - see that file's own header comment) containing intentionally
minimal or POD-less `.pm`/`.pl` files as inputs to whatever build/compile
pipeline the test is exercising. `File::Find` cannot distinguish "a real
project file" from "a fixture a sibling test wrote a moment ago" - both are
just `.pm` files under `t/` by the time `_perl_doc_paths()` walks it.

**The failure only shows up when file order puts the fixture-creating test
before t/15 in the same `prove` process.** Both tests pass in isolation;
the combination is what surfaces it, and `prove -lr t`'s default file order
is not something t/15 controls.

## How to apply

- Any test that creates its own `.pm`/`.pl` fixture files under `t/` (as
  build/compile-pipeline test input, not as real project code) must have
  its scratch directory added to `_perl_doc_paths()`'s exclusion list in
  `t/15-release-metadata.t` - `next if $_ =~ m{/t/<your-scratch-dir>/};`
  inside the `File::Find` `wanted` callback (around line 924-938).
- This is a **separate** exclusion list from the retired-internal-wording
  sweep elsewhere in the same file (`_test_citation_population` and
  neighbors) - each sweep walks independently and each needs its own
  exclusion; adding a path to one does not exempt it from the other.
- Prefer a scratch directory name that is unlikely to collide with a real
  package/script name, and gitignore it (it should never be committed).
- When adding a new fixture-creating test, run the fix's verification the
  way DD-943 did: create a stray fixture with intentionally broken/missing
  POD under the new scratch dir, run t/15, confirm it does NOT fail on that
  path (and still fails correctly on a real project file's missing POD -
  the exclusion must not become too broad).
