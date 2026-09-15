# Docker compose env-path expansion

## What this is

`Developer::Dashboard::DockerCompose::_expand_env_path` resolves
`${VAR}`/`$VAR` placeholders inside a configured docker compose file path
(for example a configured `DASHBOARD_COMPOSE_ROOT`) against the current
process's environment. This is how an operator points the docker-compose
integration at a compose file whose location is only known at runtime.

## Single-pass expansion, and why it matters

Expansion runs as a **single combined regex pass** over the original path
string, matching both the `${VAR}` and bare `$VAR` forms together. It does
**not** run as two sequential passes (one for each form) - a sequential
approach would re-scan the OUTPUT of the first pass as input to the
second, meaning any environment variable whose own VALUE happens to
contain a `$NAME`-shaped substring would get that substring expanded a
second time, using a completely unrelated variable.

That shape (DD-887) is a real correctness and security hazard, not just a
style concern: if `DASHBOARD_COMPOSE_ROOT` happens to contain the literal
text `$SECRET_TOKEN` (as plain text, not intended as a placeholder - it
originated as-is inside that variable's own value) and a `SECRET_TOKEN`
environment variable also happens to be set, a two-pass expansion would
silently substitute `SECRET_TOKEN`'s value into the resolved compose path,
even though nothing in the original configured path ever named
`SECRET_TOKEN`.

## The contract

- Expand `${VAR}` and bare `$VAR` forms together, in one substitution pass
  over the *original* input string.
- An expanded value is never itself re-scanned for further placeholders.
- An undefined environment variable expands to the empty string (matching
  shell parameter-expansion convention for an unset variable).
- A path containing no placeholders at all is returned unchanged.

## Where this is exercised

`t/*-dockercompose-*.t` covers `_expand_env_path` directly, including the
specific double-expansion collision shape DD-887 fixed (two env vars where
one variable's value contains a `$NAME`-shaped substring naming the
other).
