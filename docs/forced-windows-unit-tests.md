# Forced-Windows unit tests — exercising Windows-only branches without real Windows

`Developer::Dashboard::Platform::is_windows()` decides Windows-vs-not by reading
one module-level package variable:

```perl
our $OS_NAME = $^O;   # captured once, at compile time

sub is_windows {
    return $OS_NAME eq 'MSWin32' ? 1 : 0;
}
```

Because `$OS_NAME` is an ordinary package variable rather than a hardcoded
read of `$^O` at each call site, a test can `local` it for the duration of one
block and make every `is_windows()` call inside that block answer as if the
process were running on Windows — no real Windows host, no QEMU guest, no
mocking framework:

```perl
{
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    # every is_windows() call in here now returns true
    ...
}
# outside the block, is_windows() reverts to the real answer
```

This is the established pattern across the suite (`t/07-core-units.t`,
`t/09-runtime-manager.t`, `t/84-platform-coverage.t`, `t/08-web-update-coverage.t`,
and others) for exercising `is_windows()`-guarded code paths in ordinary CI —
distinct from the real-guest QEMU E2E gate (`windev`/`macdev`, see
CLAUDE.md's "E2E cross-platform gate"), which is still required for anything
claiming release-grade Windows behavior. The forced-`OS_NAME` pattern is for
unit-level branch/line coverage of Windows-only code, not for proving the code
actually behaves correctly under a real Windows process/filesystem/shell.

## When a Windows-guarded branch is NOT annotated `# uncoverable`

Devel::Cover's `# uncoverable` annotation is a claim that a branch cannot be
reached by the test suite (see `uncoverable-annotations.md`). An
`is_windows()`-true branch is *not* automatically uncoverable-shaped: if it can
be reached by forcing `$OS_NAME`, as above, it should be tested directly rather
than excused. Annotate only the branches that stay genuinely unreachable even
under a forced `$OS_NAME` — for example, code gated on both `is_windows()` and
a real Windows-only filesystem/API call that a Linux host cannot satisfy even
with `$OS_NAME` forced.

## Related

- `uncoverable-annotations.md` — what an `# uncoverable` annotation asserts,
  and when it stops being true.
