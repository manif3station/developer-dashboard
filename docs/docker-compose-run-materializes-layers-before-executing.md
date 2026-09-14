# dashboard docker compose's real command runs against a pre-merged file, not raw layers

`Developer::Dashboard::DockerCompose` resolves a stack of layered compose
files - a project's own `compose.yml`, service/addon/mode overlays, and
files contributed by installed skills - and builds one `docker compose`
invocation from them. `resolve()` still builds that full multi-file plan
(one `-f <file>` flag per layer) for display and dry-run purposes. `run()`,
the path that actually executes a command, no longer hands that multi -f
list to `docker` directly.

## Why: the multi -f list makes execution depend on Compose's own merge

Passing every layer as its own `-f` flag means the *operational* command's
correctness depends on `docker compose` correctly merging every one of
those files, in whatever order they were resolved, every time the command
runs. A service whose definition is split across two layers - a complete
base in one, a partial override in another - has to be re-merged
identically on every invocation for that service to resolve at all.

## How: materialize once via `config`, then run against one file

`run()` calls a new private helper, `_materialized_command`, before
executing:

1. If `resolve()` named no compose files at all, there is nothing to
   merge - the original command runs unchanged.
2. Otherwise, it runs `docker compose -f <layer1> -f <layer2> ... config`
   - Compose's own documented way to print the fully merged
   configuration - and captures the output.
3. That merged YAML is written to one file in a fresh temp directory.
4. The actual command that was requested (e.g. `run --rm web echo test`)
   is re-issued against that single file: `docker compose -f
   <merged-file> run --rm web echo test`.

Whatever Compose would have merged from the layer stack is now sitting in
one already-resolved file before the operational command ever touches it.
A service defined only by the combination of several partial layers
cannot come out "not found" because one layer was looked up in the wrong
place or merged in the wrong order at execution time - that resolution
already happened, once, in step 2.

If step 2 itself fails (a genuinely broken layer, an unparseable
override), `run()` dies immediately with that failure's own exit code and
stderr - the operational command never gets a chance to run against a
config that never validly merged in the first place.

## Reviewing a change against this

- **`resolve()`'s returned `command` field is still the multi -f plan.**
  Anything that only *inspects* a resolution (dry-run output, `dashboard
  docker compose` listings) keeps seeing the real layer stack, which is
  what makes it useful for debugging. Only `run()`'s actual execution
  substitutes the materialized single-file command.
- **A materialize failure must surface before anything else runs.** If a
  future change to `_materialized_command` ever lets a merge failure fall
  through silently, the real command would run against an empty or
  stale file instead of failing loudly.
- **Zero resolved files must skip materialization entirely**, not run
  `docker compose config` with no `-f` flags at all (which would read
  whatever `compose.yml` happens to exist in the current directory,
  something no layer in this system actually claimed).
