# Why a `.env.pl` same-value assignment needs its own audit path

## What the audit is for

`Developer::Dashboard::EnvAudit` records, for every environment key a
dashboard-managed env layer sets, which file set it and what value it set.
`EnvLoader::_load_env_file` (plain `.env` files) records every declared key
unconditionally - the file's own text names exactly which keys it declares,
so there's nothing to infer.

`.env.pl` files are different: they are real, executable Perl, not a
declarative key=value list, so `_load_env_pl_file` has to *infer* which keys
a given file actually set by capturing `%ENV` before `require`ing the file
and diffing it against `%ENV` after.

## The gap a pure value-diff misses (DD-1044)

A before/after value diff can only ever detect a key whose **value**
changed. It cannot tell "this file didn't touch this key" apart from "this
file assigned this key the exact value it already had" - both leave the
value identical across the diff.

That second case is real and common: a `.env.pl` re-asserting a value it
inherited from the OS environment or an earlier layer (a defensive pin, or
simply coincidence) genuinely set that key - `DEVELOPER_DASHBOARD_ENV_AUDIT`
should say so - but a pure value-diff silently drops it, and the key
disappears from the audit even though a real dashboard-managed file
explicitly declared it.

## The fix: union a static source scan with the value-diff

`_env_pl_assigned_keys($file)` reads the `.env.pl` file's own source text
and extracts every literal `$ENV{KEY} = ...` assignment target via regex.
`_load_env_pl_file` unions that set with the existing value-diff when
deciding which keys to record - so:

- a key the static scan finds is recorded even if its value didn't change
  (closes the DD-1044 gap)
- a key the value-diff finds but the static scan can't see (a computed key
  name, a loop over a key list, anything past what a literal-text regex can
  match) is still recorded exactly as before - the static scan is additive,
  never a replacement for the value-diff

This is deliberately a heuristic union, not a full static analysis of the
file: `.env.pl` is arbitrary Perl, and no static scan can enumerate every
key a sufficiently dynamic file might touch. The value-diff remains the
catch-all for anything the literal-assignment regex can't see; the static
scan only adds back the one specific case a value-diff structurally cannot
detect at all - same-value re-assignment.

## Where this lives

`lib/Developer/Dashboard/EnvLoader.pm` - `_load_env_pl_file` and
`_env_pl_assigned_keys`. Tests: `t/87-envloader-coverage.t`, the DD-1044
section.
