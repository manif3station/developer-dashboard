# Path/file alias lazy creation with `-c`/`--create`

This page describes the current behavior of the system, not any one ticket.
`d2 path add` and `d2 file add` accept an optional `-c`/`--create` flag that
marks a saved alias as lazily creatable: the first time anything resolves
that alias and its target is missing on disk, the target is created rather
than the resolution failing.

## Adding a lazy-create alias

```
d2 path add foo.bar.bob.something /tmp/something -c
d2 path add foo.bar.bob.something /tmp/something --create
d2 path add foo.bar.bob.something /tmp/something --create 0777
d2 path add foo.bar.bob.something /tmp/something --create=0777
d2 path add foo.bar.bob.something /tmp/something -c 0777
```

`--create`/`-c` takes an OPTIONAL octal mode argument. Given bare, the
created path uses whatever default mode `File::Path::make_path` applies
under the process's current umask - today's existing implicit behavior,
unchanged. Given a mode (space-separated, `-c 0777`, or `--create=0777`),
the path is created with parents as needed and then `chmod`'d to that exact
octal value.

A plain `d2 path add <name> <path>` with no `-c`/`--create` flag behaves
exactly as before this feature existed: the alias is stored with no create
marker, and resolving it against a missing target fails with today's
existing not-found handling. This feature is strictly opt-in per alias.

## Where auto-create fires

The create-on-missing check lives in `Developer::Dashboard::PathRegistry`'s
shared resolver (`resolve_dir`/`resolve_file`), not duplicated per caller.
Every consumer that resolves a named alias gets the same behavior for free:

- the `cdr <alias>` shell navigation helper
- workspace/browser-route path resolution
- any Perl caller resolving the alias directly through PathRegistry's own
  API

If the alias was marked lazy-create and its target does not exist at
resolve time, the resolver creates it (with parent directories, mirroring
`mkdir -p`) - and chmods it to the stored mode, when one was given - before
returning the resolved path to the caller. If the alias was NOT marked
lazy-create, resolution behaves exactly as it always has.

## `d2 file add` and file targets

`d2 file add` supports the same `-c`/`--create`/mode syntax as `d2 path
add`. Because a file alias points at a file rather than a directory, "lazy
create" for a file alias means creating the file's PARENT directory chain
(so a caller can safely open/write the target path), not fabricating an
empty file at the target itself - the target file's own existence is left
to whatever the caller intends to do with it.

## Storage shape

The create marker (and mode, when given) is stored alongside the alias
entry, composing with the nested skill-depth alias storage shape this
project's `d2 path add`/`d2 file add` dotted-name support already
establishes - a lazy-create marker on a nested alias is stored exactly
where that alias's own entry would be stored, with no separate tracking
structure.

## Usage strings (DD-1011)

Both commands' own usage errors reflect the flag:

```
Usage: dashboard file add <name> <path> [-c|--create[=MODE]] [-o json|table]
Usage: dashboard path add <name> <path> [-c|--create[=MODE]] [-o json|table]
```

A test asserting the exact usage text (`t/43-explicit-coverage-qa.t`) went
stale when this flag was added and had to be corrected separately (DD-1011)
- worth noting here because any FUTURE change to either usage string must
update both the real string above and that test's regex together, or the
same drift recurs.
