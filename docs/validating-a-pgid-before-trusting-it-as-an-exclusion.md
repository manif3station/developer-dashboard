# Validating a pgid before trusting it as an exclusion (DD-772)

## The pattern

`coverage-run` and `run-suite` each gate a long-running child (`prove`/`cover`)
under `setsid`, so the child leads its own process group and a kill can signal
the whole group. To stop `.claude/tools/host-ready`'s foreign-process sampler
from counting that gated child as a foreign competitor, both tools capture the
child's own process-group id and export it as `DD_HOST_READY_EXCLUDE_PGIDS`:

```sh
cov_child_pgid=$(ps -o pgid= -p "$child" 2>/dev/null | tr -d ' ')
[ -n "$cov_child_pgid" ] && export DD_HOST_READY_EXCLUDE_PGIDS="$cov_child_pgid"
```

## The gap

`[ -n "$cov_child_pgid" ]` only rejects an *empty* capture. It says nothing
about whether the value is actually a valid process-group id. `ps` can return
a malformed or stray token, and in a race where `$child` has already exited
and its pid was recycled, `ps -o pgid= -p "$child"` can return the pgid of a
*different, unrelated* process - one that may currently be a genuinely
foreign competitor for the host.

Because pgids are small integers reused constantly on a busy machine, a
wrong-but-non-empty capture can coincide with a real foreign process's group.
`host-ready`'s `dd_foreign_now()` then treats that pgid as "ours" and skips
every process in it when counting - silently suppressing the very
contention the sampler exists to detect, and producing a false "host is
clear" verdict.

## The fix

Validate the capture is a plausible positive integer before exporting it,
using the exact numeric-only guard `host-ready` already applies to
`DD_HOST_READY_PROBE`'s own output (`host-ready:66-70`):

```sh
case "$cov_child_pgid" in
  ''|*[!0-9]*) unset cov_child_pgid ;;
esac
[ -n "${cov_child_pgid:-}" ] && export DD_HOST_READY_EXCLUDE_PGIDS="$cov_child_pgid"
```

A malformed or non-numeric capture is now treated exactly like an empty one:
discarded, never exported, never trusted as an exclusion. A valid numeric
pgid still excludes correctly (DD-750's original fix is unchanged).

## Why this belongs in both files

`coverage-run` and `run-suite` implement the identical pattern independently
(they predate `host-ready` being the shared definition, per DD-729's own
history of duplicated readiness logic). A fix applied to one and not the
other leaves the second carrying the same defect with no comment marking it
as known - the exact "workaround in one instance is evidence for a defect,
and makes the others look deliberate" trap this project's board contract
already names (§35). Both files got the identical fix in the same change.
