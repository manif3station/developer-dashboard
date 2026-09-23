# PaxCache's md5 cache marker is written atomically (rename-based)

This page describes the current behavior of the system, not any one
ticket. `Developer::Dashboard::PaxCache::_run_compile_and_install` installs
a freshly-compiled PAX binary and writes the source digest that
`resolve()` later compares against to decide whether that cached binary is
still fresh.

## Why this matters

Both writes in this function need the same guarantee: a reader must never
observe a partially-written file. The binary install already had it -
`_run_compile_and_install` builds the output at a temp path and
`rename()`s it into place, and `rename(2)` on the same filesystem is
atomic. The digest marker (`md5_file`) did not have this guarantee before
this fix: it was written with a plain `open('>', $md5_file)` (which
truncates the file to zero bytes the instant it opens, before anything is
written), then a separate `print`, then `close`.

If the writing process is interrupted anywhere in that window - the OOM
killer, `kill -9` on a stuck compile, a container restart, a host reboot -
`md5_file` is left on disk as a real, existing, zero-byte file. It is not
missing (which `resolve()` would correctly treat as "no cached digest
yet"); it exists and reads back as an empty string, which can never equal
a real 32-character MD5 hex digest. The binary next to it, meanwhile, was
already renamed into place and is perfectly valid. The net effect is a
cache entry permanently wedged as "stale" beside a binary that is not
stale at all - every future invocation re-triggers a full PAX compile,
forever, for a file that never actually needed rebuilding again.

## The fix

`md5_file` is now written the same way `bin_file` already was: to a
sibling temp path (`"$md5_file.tmp.$$"`, matching the pid-scoped naming
this same function already uses for `bin_file`'s own temp path one line
above), then `rename()`d onto the real path. A reader can only ever see
the complete previous content or the complete new content - never a
truncated file in between. If the process dies before the rename, the
temp file is simply orphaned (harmless - the next compile attempt writes
its own uniquely-pid-named temp file) and the real `md5_file` is untouched,
so a pre-existing valid digest from an earlier successful compile is never
destroyed by an interrupted later one.

## Where this pattern is used elsewhere

This is the same rename-based atomic-write discipline already established
across this codebase - `PathRegistry::atomic_write_secure` is the shared
helper used identically by `SessionStore.pm`, `Auth.pm`, `Collector.pm`,
`Zipper.pm`, `CLI/Ask.pm`, and `IndicatorStore.pm` (the last one fixed for
the same truncate-then-write defect class this page describes). PaxCache's
own `bin_file` write already followed it; this fix brings `md5_file` into
line with the rest of the codebase rather than introducing a new pattern.

## Verification

`t/206-paxcache-md5-atomic-write.t` proves this directly: it forks a
child, forces a `SIGKILL` in the exact truncate-then-write window the old
code exposed, and asserts the resulting file content - confirming the
unfixed pattern destroys a pre-existing valid digest (reproduced), and
that the fixed code path never leaves `md5_file` in a truncated state
regardless of when it is interrupted.

## A third instance of the same defect class (DD-1009)

`Developer::Dashboard::Pax::ArtifactCache::write_artifact` had the exact
same shape: a plain `open('>', $path)` followed by `print`/`close` for its
per-artifact metadata JSON, truncating the cache entry to zero bytes the
instant `open` succeeded, well before the JSON content was written. Worse
than this page's own `md5_file` case: `read_artifact` calls
`decode_json(<$fh>)` with no eval guard, so a truncated file left by an
interrupted write does not read back as merely "stale" - `decode_json` on
an empty or partial string throws a hard exception, and any caller of
`read_artifact` against a corrupted entry crashes outright.

Fixed the same way: write to a sibling temp path (`"$path.tmp.$$"`), then
`rename()` onto the real path - the third module in this codebase to adopt
this exact pattern for this exact defect class, after `IndicatorStore.pm`
(DD-989) and this page's own `PaxCache.pm` (DD-1003, above).
`t/216-artifactcache-atomic-write.t` proves it with a real fork-based
interruption test, matching this page's own verification approach.
