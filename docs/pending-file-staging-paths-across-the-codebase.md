# Every pending-file staging path uses a per-process monotonic counter, not just pid+time

This distribution has six independent places that write a file atomically
via a stage-then-rename sequence: build a "pending" path, write and secure
it while it is still invisible under an unpredictable name, then rename it
into its real, predictable destination.

DD-848 fixed the first one found - `Zipper::_pending_ajax_file` - and is the
canonical writeup of the defect and the fix
(`docs/ajax-staging-paths-are-collision-safe-by-a-counter-not-timing.md`).
DD-850 found and fixed the same defect, byte-identical, in the other five:

| module | function |
|---|---|
| `RuntimeManager.pm` | `_pending_collector_supervisor_state_file` |
| `RuntimeManager.pm` | `_pending_web_state_file` |
| `CollectorRunner.pm` | `_pending_loop_state_file` |
| `Auth.pm` | `_pending_user_file` |
| `Collector.pm` | `_pending_path` |
| `SessionStore.pm` | `_pending_session_file` |

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
  helper (as this project already does at three of the six sites) is what
  makes the second kind of test possible without duplicating the write.
