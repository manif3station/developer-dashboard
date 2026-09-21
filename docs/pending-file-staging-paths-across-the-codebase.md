# Every pending-file staging path uses a per-process monotonic counter, not just pid+time

This distribution has seven independent places that write a file atomically
via a stage-then-rename sequence: build a "pending" path, write and secure
it while it is still invisible under an unpredictable name, then rename it
into its real, predictable destination.

DD-848 fixed the first one found - `Zipper::_pending_ajax_file` - and is the
canonical writeup of the defect and the fix
(`docs/ajax-staging-paths-are-collision-safe-by-a-counter-not-timing.md`).
DD-850 found and fixed the same defect, byte-identical, in five more:

| module | function |
|---|---|
| `RuntimeManager.pm` | `_pending_collector_supervisor_state_file` |
| `RuntimeManager.pm` | `_pending_web_state_file` |
| `CollectorRunner.pm` | `_pending_loop_state_file` |
| `Auth.pm` | `_pending_user_file` |
| `Collector.pm` | `_pending_path` |
| `SessionStore.pm` | `_pending_session_file` |

DD-989 found and fixed a **worse variant** of the same shape, missed by both
sweeps, in `IndicatorStore::set_indicator`:

| module | function |
|---|---|
| `IndicatorStore.pm` | `_pending_indicator_file` |

**Why both sweeps missed it.** DD-848/DD-850 both searched specifically for
the `sprintf '%s.%s.%s.pending', $file, $$, time` shape (pid+time, no
counter). `IndicatorStore::set_indicator` did not match that shape at all -
it used the bare literal `"$file.pending"` with **no uniquifier whatsoever**,
not even pid+time. A search anchored on "does this call `sprintf` with `$$`
and `time`" finds nothing here, because there is no `sprintf` call to find.
The defect is the same shape one level down: not "the staging name can
collide within the same second" but "the staging name is the same file,
every single call, forever" - which additionally made it exploitable by a
pre-planted symlink rather than only a same-process race, since the path
never depends on runtime state at all.

**The review lesson (see "Reviewing a change against this" below, sharpened):
search for the *absence* of a uniquifier, not just a weaker one.** A sweep
built to catch "the counter is missing" will not catch "there was never
anything here to be missing a counter from."

## The shared defect

All six built their staging path the same way:

```perl
sprintf '%s.%s.%s.pending', $file, $$, time;
```

`$$` is fixed for a process's entire lifetime and `time()` has one-second
resolution, so **two calls from the same process, for the same destination,
within the same second, produced an identical staging path.** Two of the
`RuntimeManager.pm` sites and `CollectorRunner.pm`'s site did not even
expose the staging path as a separate, testable function - the `sprintf`
was inlined directly into the writer, which is why none of their existing
tests exercised the real path-generation logic at all (every one of them
either called the full writer against a real fixture, where the bug cannot
be observed from a single sequential caller, or overrode the path generator
entirely for an unrelated write-failure test).

## The fix

The same per-process monotonic counter DD-848 established:

```perl
my $_some_state_seq = 0;

sub _pending_some_state_file {
    my ( $self, $file ) = @_;
    return sprintf '%s.%s.%s.%s.pending', $file, $$, time, ++$_some_state_seq;
}
```

For the three sites that inlined the `sprintf`, DD-850 also **extracted a
named helper sub** - matching the pattern already used by the other three
sites (`Auth.pm`, `Collector.pm`, `SessionStore.pm`, and `Zipper.pm`) - so
the path-generation logic is directly callable and testable in isolation,
rather than only reachable through a full write that also touches the
filesystem.

## Reviewing a change against this

- **A fix landing in one instance of a shared shape does not fix the other
  instances.** DD-850 exists because DD-848's fix was searched for and found
  to be incomplete by an hourly bug-hunt pass that specifically looked for
  the same `sprintf`/comment pair elsewhere in the tree - not because anyone
  set out to audit every pending-file writer.
- **An inlined `sprintf` that builds a staging path is a sign the function
  has never been tested directly.** If a test needs the write's side effect
  and a test needs the path-generation logic separately, extracting a named
  helper (as this project already does at all seven sites now) is what
  makes the second kind of test possible without duplicating the write.
- **A sweep for this defect class must also grep for pending-file writers
  that build NO staging-path variation at all** - `"\$file.pending"` or
  equivalent bare-literal concatenation, not just a weaker `sprintf`. DD-989
  was exactly that case: no counter to be missing because there was no
  `sprintf` to search for in the first place. Grep for every call site that
  opens a path ending in a literal `.pending` string, not only for the
  known-buggy `sprintf` pattern.
- **Write-then-secure is a second, independent defect from a predictable
  path**, and the two compound. `Developer::Dashboard::PathRegistry::atomic_write_secure`
  is the one call that fixes both at once (chmod-before-rename, and it
  requires the caller to pass an already-unpredictable `$tmp`) - every
  writer in the table above calls it. A reviewer should treat any new
  stage-then-rename write in this codebase that does NOT call
  `atomic_write_secure` as a finding, not as a style preference.
