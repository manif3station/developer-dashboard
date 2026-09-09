# Per-skill Java dependency resolution

`Platform.pm`'s `command_argv_for_path` resolves and runs a `cli/foo.java`
file via `_exec_java_source`. As shipped, this path is dependency-free: it
compiles the single file standalone with `javac` into a temp directory and
execs it with `java` - no classpath, no external library resolution at all.
Any `cli/*.java` script needing a third-party library (a JSON library, an
HTTP client, etc.) fails to compile.

## The mechanism

Each DD-OOP-LAYERS layer (the project root, and each installed skill
directory) may carry its own `config/pom.xml`, treated as one independent
Maven module - the same isolation boundary skills already use for Node
dependencies via their own `local/` tree.

When `command_argv_for_path` resolves a `.java` file:

1. It walks the file's own DD-OOP-LAYERS layer (reusing the existing layer
   walk - the same mechanism that already resolves `config/`, `collectors`
   and path aliases; no new top-level convention).
2. If that layer has a `config/pom.xml`, the file is built and run through
   `mvn` (which resolves the pom's declared dependencies from Maven
   Central), instead of plain `javac`.
3. If no `config/pom.xml` exists at that layer, resolution falls back to
   exactly today's behavior: plain `javac` into a temp dir, then `java`.

A skill needing a different dependency, or a different version of the same
dependency, becomes a new skill folder - matching how skills are already
meant to be narrow, single-purpose, isolated units. Two skill layers may
declare conflicting dependency versions with no interference between them,
because each is its own Maven module.

## What does not change

The plain-`javac` fallback path (no `config/pom.xml` present) is byte-for-
byte unchanged. This is the primary regression risk and the reason the
design is additive rather than a rewrite of `_exec_java_source`.

## Origin

Michael asked whether Java is supported on the `cli`/`hook` folders
(2026-09-08). Answer: yes, for dependency-free scripts only. He proposed a
`pom.xml` at `~/.d2/pom.xml` or `$PWD/.d2/pom.xml`; refined during discussion
to one `pom.xml` per DD-OOP-LAYERS skill layer, so each skill is its own
Maven module. Approved 2026-09-08 ("Ok, go for it"). Tracked as DD-823.
