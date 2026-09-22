# PAX CI's shared functional-parity harness

## What this is

`script/pax-functional-parity-check` is the one shared implementation
every DDE-006 platform build job (Linux, macOS, Windows) in
`.github/workflows/pax-release.yml` uses to answer one question: does the
compiled PAX standalone binary this job just built genuinely behave the
same as the source-Perl CLI it was built from?

Before this existed (DD-1016), each platform's "smoke-verify" step
duplicated its own ad hoc comparison - and every one of them only ever
compared the `version` command's output. That could never catch a real
functional divergence anywhere else, and a fix to the comparison logic
itself would have needed applying in three separate places.

## Why a shared harness, not per-platform checks

The owner's explicit acceptance bar for DDE-006 is that the compiled
binary is *"100% functional matching to the source Perl script"* - not
just "the build succeeded". A single-command check cannot support that
claim. A shared harness:

- runs the same representative command set on every platform, so a
  regression caught on Linux is guaranteed to also be checked on macOS
  and Windows, rather than each platform's check silently drifting apart
  over time;
- reports which SPECIFIC check diverged, with its actual and expected
  output, rather than a generic pass/fail - so a CI failure is
  immediately actionable;
- is unit-tested on its own (t/221), independent of any real PAX build,
  so its comparison logic itself is verified cheaply and often, not only
  during a full multi-minute CI matrix run.

## The representative command set

Three checks today, each exercising a different kind of CLI surface:

| check     | what it exercises                          |
|-----------|---------------------------------------------|
| `version` | a static value                               |
| `--help`  | an informational command (first line only, to avoid brittleness against unrelated help-text wording changes) |
| `jq`      | a real data-processing command against a small fixed JSON fixture |

Adding a new representative check means adding one entry to
`_representative_checks()` in `script/pax-functional-parity-check` - it
then automatically runs against every platform's build, with no
per-platform wiring needed.

## How it is invoked

```
perl script/pax-functional-parity-check \
    --compiled pax-output/d2 \
    --source-perl perl \
    --source-script bin/dashboard \
    --lib lib
```

Exits `0` if every check matched; exits `1` and prints one `PASS`/`FAIL`
line per check (with `expected`/`actual` shown on any `FAIL`) otherwise.
`--list-checks` prints the check names without running anything, useful
for confirming what a given harness version actually covers.

Each platform's step in `.github/workflows/pax-release.yml` invokes it
identically in substance - only the shell syntax differs (bash for
Linux/macOS, PowerShell for Windows), since the harness itself is a
portable Perl script that behaves the same everywhere it runs.

## Verification

`t/221-pax-functional-parity-harness.t` proves the harness's own
comparison logic - both that it passes cleanly when everything agrees,
and that it genuinely catches and names a real divergence - using two
small fixture "fake CLI" scripts
(`t/fixtures/parity-fake-correct.pl`/`parity-fake-wrong.pl`) rather than
paying for a real `pax build` in a unit test (that is already proven
separately by t/183/t/184 and friends).

`t/222-pax-release-shared-parity-harness-wiring.t` proves
`.github/workflows/pax-release.yml`'s three platform smoke-verify steps
actually call this harness, and that the old per-platform duplicated
comparison logic is gone, not left dangling alongside the new call.
