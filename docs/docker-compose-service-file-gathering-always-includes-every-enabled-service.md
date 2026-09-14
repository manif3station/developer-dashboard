# `dashboard docker compose` always merges every enabled service's compose file

`Developer::Dashboard::DockerCompose::resolve()` builds the `-f` file stack
that gets passed to (or, via `run()`, materialized into one file for) the
real `docker compose` invocation. Which compose files end up in that stack
does **not** depend on which service name was typed on the command line.

## The rule

Every enabled service's own `compose.yml` (declared in the project's docker
config, or auto-discovered under a `config/docker/<service>/` layer) is
always included in the merged file set - whether the caller ran
`dashboard docker compose up`, `dashboard docker compose up claude`, or
`dashboard docker compose config`. The requested service name (`claude`)
only ever reaches Compose as a **passthrough argument**, filtering which
container Compose actually starts - it is never used to decide which
compose *files* get merged.

## Why

Docker Compose supports `depends_on`, and its own engine will start a
`depends_on` service automatically **once both service definitions are
present in the merged config it was given**. But Compose can only do that
if dashboard actually hands it every relevant file. Before this fix,
`_gather_service_files` only pulled files for the services literally named
in the request (or, with no name at all, fell back to
`_discover_enabled_services`, the full set) - so naming exactly one service
that depends on another dropped the dependency's file from the merge
entirely, and Compose failed with `service "X" has neither an image nor a
build context specified`, even though `X` was fully defined one directory
over.

Concretely: with `claude`'s compose file declaring
`depends_on: [ollama]`, `dashboard docker compose up claude` used to
resolve `files` to `[project overlay, claude/compose.yml]` - never
`ollama/compose.yml`. `dashboard docker compose config` (no service name)
resolved all three files correctly, because the no-name path always used
the full enabled-service set. The fix makes the named-service path use that
same full set.

## Reviewing a change against this

- **Never narrow `_gather_service_files`'s input by the requested service
  list again.** If a future change needs to distinguish "files for what's
  running" from "files for what Compose might need to know about", that
  distinction belongs in a new, explicitly-named parameter - not in
  silently re-narrowing this one.
- **The requested service name still narrows what actually starts.** This
  fix does not make `up claude` start every enabled service - it makes the
  *file set* complete so Compose's own `depends_on` resolution can work;
  `claude` (and whatever it depends on) is what runs.
- **Composes with `run()`'s materialize-to-temp-file step (a separate,
  earlier fix) with no changes needed there** - that step already just
  merges whatever files `resolve()` hands it.
