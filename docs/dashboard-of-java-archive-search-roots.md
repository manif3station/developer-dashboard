# dashboard of: Java source-archive search roots

## What this covers

How `dashboard of`/`open-file` picks which directories to search for Java
source archives (`.jar`/`.war`/`-sources.jar`/`-src.jar`/`src.zip`/`source.zip`)
when a dotted Java class name (e.g. `javax.jws.WebService`) isn't satisfied by
a direct `.java` file on disk.

## How it behaves

`_java_source_archive_roots` (`Developer::Dashboard::CLI::OpenFile`) builds
its candidate root list from two sources:

1. The general-purpose lookup roots already assembled by `_open_file_roots`
   for Perl-module/general file resolution: `cwd()`, the current project
   root, workspace roots, and project roots.
2. Java-specific roots: `~/.m2/repository`, `~/.gradle/caches`, and
   `$JAVA_HOME`/`$JDK_HOME` when set.

**`@INC` entries are deliberately excluded from source (1)** (DD-916).
`_open_file_roots` includes `@INC` because it also serves Perl-module lookup,
where `@INC` is exactly the right search path - but `@INC` structurally
cannot contain a Java source archive, so including it here only meant every
Java-class lookup miss walked the system Perl library tree via
`File::Find` for no possible benefit. `_java_source_archive_roots` filters
`@INC` entries out by identity before adding the Java-specific roots, so a
caller building its roots from `_open_file_roots` still gets a Java-relevant
search set.

## Why it exists

Before DD-916, a Java-class lookup miss (e.g. because no local `.jar`
satisfied it) triggered a full recursive filesystem walk of every entry in
`@INC` - which can include large system Perl library directories - purely to
confirm, every single time, that none of them contain a Java archive. The
walk cost scaled with the size of the Perl install, not with anything
relevant to the Java lookup.

## When to use / extend this

If `dashboard of`'s Java-class lookup needs a new candidate root (another
build-tool cache directory, for instance), add it inside
`_java_source_archive_roots` alongside `~/.m2`/`~/.gradle`, not by widening
what `_open_file_roots` passes in - that list is shared with Perl-module
resolution and should stay scoped to what Perl lookup actually needs.

## What is *not* covered here

A persisted cache of the archive walk across invocations (so a `dashboard of`
process doesn't re-walk `~/.m2`/`~/.gradle` from scratch on every miss) was
considered as a second, larger improvement in the same finding and
deliberately left out of DD-916's scope - `dashboard of` is a one-shot CLI
process with no natural place to persist a cache between invocations without
a separate design decision (an on-disk index keyed by root mtime, most
likely). Left for a future ticket if the walk cost still matters after the
`@INC` exclusion.

## Related

- `_open_file_roots` - the general-purpose root list this one filters.
- `_unique_existing_dirs` (DD-913) - the shared dedup+existing-directory
  filter both root-builders use.
- `docs/dashboard-of-network-opt-in.md` - the `--online` flag gating the
  separate Maven Central network fallback that runs only when no local
  archive (searched using these roots) satisfies the lookup.
