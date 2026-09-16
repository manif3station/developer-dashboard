# `dashboard of`'s network lookup is opt-in (`--online`)

## What this is

`dashboard of`/`dashboard open-file` (`Developer::Dashboard::CLI::OpenFile`)
resolves a dotted Java class name (e.g. `javax.jws.WebService`) to a source
file by checking, in order: a live `.java` file under known source roots,
then a local Maven/Gradle source-jar cache (`~/.m2/repository`,
`~/.gradle/caches`, `$JAVA_HOME`/`$JDK_HOME`), then — **only when `--online`
is passed** — a live search against Maven Central (`search.maven.org`) and a
downloaded, cached source jar (`repo1.maven.org`).

## Why it's opt-in (DD-914)

Before this, the Maven Central fallback fired automatically and silently on
any Java-class lookup miss. `dashboard of` otherwise looks and behaves like a
purely local file-search command — nothing else in it touches the network —
so a developer working offline, on a metered connection, or simply not
expecting this command to reach the internet got a surprising side effect
with no way to turn it off and no indication it had happened (beyond
whatever the extracted source file itself implied).

Without `--online`, a lookup that would have needed the network instead
prints a clear notice to STDERR and returns no matches:

```
'com.example.Foo' was not found locally; pass --online to search Maven Central.
```

## Where the flag threads through

```
run_open_file_command (parses --online, matching --print/--line/--editor)
  -> _resolve_open_file_matches (online => ...)
    -> _named_source_matches (online => ...)
      -> _java_archive_source_matches (online => ...)
        -> only calls _download_java_source_matches when online is true
```

Every intermediate layer just forwards the flag — the actual gate is the
single `if ( !@matches && $online )` / `elsif ( !@matches )` branch in
`_java_archive_source_matches`, right after the local-archive search and
right before the network fallback would have run.

## What is NOT gated

- Direct file paths, `file:line` targets, configured aliases, Perl module
  resolution (`Foo::Bar` -> `@INC` lookup), and local Java source-archive
  search all remain fully local and unconditional — only the Maven Central
  HTTP calls are behind `--online`.
- `--online` has no effect on any lookup that already found something locally
  (the network path is only ever reached on a genuine local miss).

## Testing this contract

`t/98-cli-openfile-coverage.t` asserts both directions with a mocked
`LWP::UserAgent::get`:

- without `online => 1`: the mock is set to `die` if called at all, proving
  the network is never touched, and the STDERR notice text is asserted;
- with `online => 1`: the existing mocked-network behavior is unchanged.

A third test exercises `online => 1` threaded through
`_resolve_open_file_matches` itself (not just the lower-level
`_java_archive_source_matches` call) — this closed a condition-coverage gap
the first version of the fix left, since a unit test that only calls the
innermost function never exercises the boolean actually being true at each
intermediate hand-off.
