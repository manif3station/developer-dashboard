# The WORKSTATE fingerprint excludes `__pycache__`, not just tracked source

`coverage-run`'s `working_state_fingerprint()` (DD-787) hashes every file
under `.claude/tools/` by path+content, alongside the tracked tree's own
`git status`/`git diff HEAD`, so an edit to the project's git-ignored
operator tooling moves the fingerprint exactly like an edit to tracked
`lib/` would. That is deliberate: `.claude/tools/` is real, load-bearing
tooling that a tree hash alone cannot see.

## The gap DD-845 fixed

The `find .claude/tools -type f` in that function had no exclusion for
build-artifact directories. Any Python tool under `.claude/tools/`
(`hunt-monitor`, `question-speech`) regenerates its own `__pycache__/*.pyc`
on invocation, and Python's compiled-bytecode cache is **not** a fixed
function of the `.py` source alone — the confirmed live case showed a
`.pyc` changing content between two runs with the `.py` source completely
unchanged. Since the fingerprint hashes every file's *content*, that
regeneration moved the digest, and `coverage-run` reported
`EDITED-DURING-RUN` on a run that never touched a single real tool source
file — a false invalidation of an otherwise-valid gate verdict.

## The fix

```sh
find .claude/tools -type d -name '__pycache__' -prune -o -type f -print0
```

`-type d -name '__pycache__' -prune -o -type f -print0` excludes the whole
directory rather than filtering individual `.pyc` files by name, so it also
covers any future build-artifact subdirectory sharing that name anywhere
under `.claude/tools/`.

**`working_state_fingerprint()` is defined TWICE** - once in
`coverage-run` and once in `gate-status` - and DD-655 requires the two
copies to stay byte-identical (checked by `t-gate-status`'s own
cross-file diff assertion). The fix landed in `coverage-run` first and
initially missed `gate-status`'s copy, which `t/158-operator-tool-specs.t`
caught on a real DD-848 gate run (test 10, `t-gate-status` failing its
own consistency check) - both copies now carry the identical exclusion.
Any future change to this function must be applied to both files in the
same edit, or the two will diverge again and the next full-suite run will
catch it the same way.

## Why this loses no real signal

A `.pyc` under `__pycache__` is, per PEP 3147, a derived, invalidate-and
-regenerate cache keyed off its `.py` source — never a second source of
truth. The `.py` file itself is still walked by the same `find` and still
contributes its own path+content hash to the fingerprint. So excluding the
derived artifact removes exactly the noise this bug introduced and nothing
a source edit would have set.

## Reviewing a change against this

- **A fingerprint that walks a directory tree for "did anything change"
  must ask whether every file it visits is a primary source or a build
  artifact of one it already visits.** A build artifact regenerating with
  identical inputs is not guaranteed to be byte-identical (compiler/
  interpreter version, embedded timestamps, non-deterministic serialization
  all vary this in practice) — so "derived" alone is enough reason to
  exclude it, independent of whether that specific regeneration happened to
  produce different bytes.
- **The regression guard is as important as the fix.** A test that only
  proves the noise source is silenced, without a paired case proving a real
  source edit still moves the fingerprint, cannot tell "fixed" from "blinded
  the detector to everything."
