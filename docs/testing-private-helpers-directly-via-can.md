# Testing a module's private helpers directly via `$M->can('_helper')`

The pattern this project's coverage-heavy test files use to reach an
internal branch the module's public interface cannot exercise on its own,
and when to reach for it instead of constructing an elaborate end-to-end
scenario.

## The problem

A module's public entrypoint (e.g. `Developer::Dashboard::CLI::Ask`'s
`run_ask`) often composes several private helper functions, each with its
own internal branches. Some of those branches are only reachable through a
narrow combination of public-interface inputs; others are not reachable
through the public interface **at all**, because the public entrypoint
itself always supplies a value the private helper's own fallback exists to
handle only when called some *other* way (a different caller, a future
caller, defensive code).

Chasing 100% branch/condition coverage purely through the public interface
in that second case means either accepting a real coverage gap, or
constructing an artificial end-to-end scenario so contrived it obscures
what is actually being tested.

## The pattern

Call the private helper directly, the same way `$M->can('run_ask')` is
already used for the public entrypoint:

```perl
my $M = 'Developer::Dashboard::CLI::Ask';
is( $M->can('_resolve_api_key')->( { api_key => '' }, {} ), '',
    'an empty-string config api_key is treated the same as absent' );
```

Perl's symbol table does not enforce privacy - a sub prefixed `_` is still
reachable via `->can('_name')` from outside the package. This is
deliberate access to the module's real, unmodified implementation (not a
mock, not a reimplementation), so it stays exactly as trustworthy as the
public-interface tests around it.

`t/48-ask.t` already established this convention before DD-942
(`_workspace_key`, `_load_transcript`, `_run_cli`, `_emit`) - DD-942
extended it to eleven more helpers to close a real branch/condition
coverage gap (89.4%/77.7% -> 98.5%/96.8% on `lib/Developer/Dashboard/CLI/Ask.pm`).

## How to apply

- Prefer the public interface (`run_ask` / the module's real entrypoint)
  whenever a scenario is reachable through it - that is the code path a
  real caller actually exercises, and it is the stronger test.
- Reach for a direct `$M->can('_helper')` call only when the specific
  branch is provably unreachable through the public interface with any
  combination of its own inputs (confirmed by reading the caller's source,
  not assumed) - not merely inconvenient to construct.
- Before concluding a branch is unreachable through the public interface,
  read every call site of the private helper, not just the one the
  investigation started from - `_ask_claude`'s own model resolution
  (DD-942) turned out to always supply a value for the 'claude' backend,
  which was only found by reading `run_ask`'s own model-resolution line
  directly, not by assuming the helper's `defined $a{model}` check meant a
  caller could omit it.
- If a helper's branch is unreachable through EVERY caller, real and
  private-call alike (confirmed by reading the actual source that would
  have to produce the triggering value, e.g. `PathRegistry::project_root_for`
  can never return an empty string - only `undef` or a genuine path), that
  is a genuine `# uncoverable` case, not a testing gap - annotate it with
  the concrete reasoning, per this project's own coverage-gate convention.
