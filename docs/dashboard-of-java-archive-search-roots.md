# `dashboard of` Java-archive search roots

## What this covers

How `dashboard of <Fully.Qualified.ClassName>`
(`Developer::Dashboard::CLI::OpenFile`) decides which directories to
search for Java source archives (`.jar`, `.war`, `-sources.jar`,
`src.zip`) when a dotted Java class name can't be resolved to a direct
`.java` file.

## How the root list is built

`_java_source_archive_roots` builds its candidate directory list from
two sources:

- Java-specific roots: `~/.m2/repository`, `~/.gradle/caches`, and
  `$JAVA_HOME`/`$JDK_HOME` when set.
- The general-purpose roots already resolved for Perl-module/plain-file
  lookup (`_open_file_roots`: cwd, the current project root, workspace
  roots, and `@INC`).

## Why `@INC` is excluded (DD-916)

`@INC` is Perl's own module search path. It can never contain a Java
source archive, so including it in the Java-archive walk only added
File::Find work over potentially large system Perl library directories
with zero chance of a match. `_java_source_archive_roots` now filters
`@INC` entries out of the incoming general-purpose roots by identity
before adding the Java-specific roots, so a Java-class lookup miss
walks only directories that could plausibly hold a Java archive.

cwd, the project root, and workspace roots are kept - a Java project
checked out alongside Perl code, or a monorepo, is a real and common
case for a source archive to live in one of those.

## What's deliberately out of scope here

A persisted, cross-invocation index of discovered archives (so a
lookup miss doesn't re-walk the filesystem every time `dashboard of`
runs) is a separate, larger change and was left for a future ticket
when the filesystem-walk cost still matters after this fix.
