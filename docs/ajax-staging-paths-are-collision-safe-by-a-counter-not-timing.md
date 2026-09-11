# The saved-ajax-handler staging path is collision-safe by a monotonic counter, not by timing

`Developer::Dashboard::Zipper::_saved_ajax_url_and_store` writes a saved
ajax handler's code through a secure-then-rename sequence (DD-601): the
handler is written to a **staging path**, secured (`chmod 0700`) while it
is still invisible under that unpredictable name, and only then renamed
into its real, predictable destination. `_pending_ajax_file` builds that
staging path.

## The gap DD-848 fixed

Before DD-848, the staging path was built from the process id and the
current wall-clock second alone:

```perl
sprintf '%s.%s.%s.pending', $path, $$, time
```

`$$` is fixed for a process's entire lifetime, and `time()` has one-second
resolution. So **any two calls from the same process within the same
second, for the same destination, produced the identical staging path** -
directly contradicting the comment above the function, which claimed the
mix of pid and wall-clock time made the path "deliberately unpredictable
... so two writers can never collide on it."

The consequence was not merely two failed writes. Two concurrent saves
sharing one staging path race through the same open/print/close/chmod/
rename sequence: one writer's `rename` moves the shared staging file into
*its own* destination - which happens to contain the *other* writer's
handler code, since both writers were appending to the same file handle -
while the second writer's own `rename` then dies with "No such file or
directory" because the file it expected to rename has already been moved
away. **A saved ajax handler could silently end up running someone else's
code**, with no error raised on the writer whose content actually landed.

## The fix

A per-process monotonic counter, incremented on every call, is appended to
the existing pid+time components:

```perl
my $_pending_ajax_seq = 0;

sub _pending_ajax_file {
    my ($path) = @_;
    return sprintf '%s.%s.%s.%s.pending', $path, $$, time, ++$_pending_ajax_seq;
}
```

This guarantees no two calls **from the same process** ever produce the
same path, regardless of how close together in time they land - the
counter alone is sufficient for that half. Cross-process collision remains
impossible the way it always was: two live processes never share a pid.

## Reviewing a change against this

- **A "no two writers can ever collide" claim in a comment is a testable
  property, not a description.** It was wrong here for years because
  nothing ever called the real, unoverridden function to check it - every
  existing test pinned the staging path to a fixed value instead (a
  deliberate, correct technique for forcing specific write-stage failures,
  but one that never exercises the real path-generation logic at all).
- **`time()` resolution matters whenever a path or identifier claims
  timing-based uniqueness.** A counter, not finer timing (`Time::HiRes`),
  is the fix here specifically because the collision space is bounded by
  a single process's own call rate, which a counter eliminates completely
  rather than merely shrinking.
- **This does not change `_pending_ajax_file`'s signature or its callers.**
  `_saved_ajax_url_and_store` still calls it with one path argument and
  gets one staging path string back.
