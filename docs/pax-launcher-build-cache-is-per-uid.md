# The pax launcher build cache is namespaced per uid

`Developer::Dashboard::Pax::StandaloneImage::_compile_launcher` compiles a
standalone launcher binary (the small C stub embedding the packaged code,
runtime, asset and native payload blobs) as part of `dashboard pax build`.
While doing so it writes several intermediate artifacts — `code.pkg`,
`runtime.pkg`, `assets.pkg`, `native.pkg` and their `objcopy`-produced `.o`
counterparts — to a build cache directory sitting next to the requested
output path.

## Why it is a directory at all, and why it is cached

Each `.pkg` blob can be tens of megabytes. Recompiling the same target
repeatedly (a normal development loop) would otherwise re-serialize and
re-`objcopy` all of that on every run. The build cache directory exists so
that repeated builds against the **same output location, by the same
invoking user**, can reuse/overwrite the same intermediate files rather than
starting from nothing each time.

## Why it is namespaced per uid

The build cache directory sits **inside the parent of the requested output
path** — commonly a shared, throwaway location such as bare `/tmp`, which
both host-side (non-root) builds and container-run builds (which run as
`root` by default inside a `developer-dashboard:latest` container) may use
for the same logical output target.

The directory name therefore includes the invoking user's real uid (`$<`):

```
.pax-launcher-build-<uid>
```

rather than a bare, unqualified `.pax-launcher-build`. Two different uids
building against the same output parent directory never read or write the
same cache directory, so:

- a **root-owned** build (typically from inside a container) can never leave
  files that a later **non-root** build cannot overwrite, and vice versa;
- each uid still gets the full caching benefit described above for its own
  repeated builds, because the same uid always derives the same path.

This is the same technique Perl's own `File::Temp` uses to avoid the
identical class of collision when multiple users share `/tmp`.

## What this fixes

Before this namespacing, the cache directory was a single literal path
(`.pax-launcher-build`, no uid component) shared by every user building
against the same output parent. The first process to create it "won"
ownership of every file inside it; any later build by a **different** uid
against the same parent failed outright with `Permission Denied` while
trying to write into it, and — because a non-root user cannot delete
root-owned files without `sudo` — the failure did not self-clear. It
recurred on every subsequent build sharing that output parent, on any
machine mixing root-run containers with non-root host builds of this
project (fixed under DD-926).

## What did not change

The compile/link pipeline itself (the `objcopy` and `cc` invocations, the
manifest embedding, the launcher source generation) is unchanged. Only how
the one cache directory's *name* is derived changed.
