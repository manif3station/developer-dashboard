# `PaxCache`: an MD5-keyed, non-blocking, per-machine compile cache

What `Developer::Dashboard::PaxCache` is, why it exists, and the contract
it holds for any internal CLI tool wired into it. This page describes the
system, not any one ticket.

## What it does

`PaxCache::resolve($source_path)` answers one question for a given Perl
source file: "should this invocation run a cached PAX-compiled binary, or
run the source interpreted?"

- **Cache hit** (a compiled binary exists whose recorded MD5 matches the
  source file's current MD5): returns the cached binary's path. The
  caller execs that instead of interpreting the source.
- **Cache miss** (no cache entry, or the source's MD5 has changed since
  the cache was built): returns `undef`. The caller falls back to its
  normal interpreted path for **this** invocation, and `resolve` has
  already triggered a background compile so a **later** invocation can
  hit the cache.
- **PAX not installed**: always returns `undef`, and never touches the
  filesystem cache or attempts a compile. This is checked first, before
  anything else, so a machine without PAX behaves identically to how the
  tool behaved before this module existed.

The cache is **per-machine only** (owner decision, DDS-001 Q-158) - it
lives under `PathRegistry::home_cache_root()`, which already exists for
exactly this kind of artifact (a per-user cache a fixed external consumer
can rely on at one well-known path, independent of which project layer
the current working directory happens to be under).

## The one rule that makes this safe: never block, never duplicate

Two properties are non-negotiable, both owner-specified:

1. **A compile never blocks the invocation that discovers the cache is
   stale** (Q-157). The user always gets an answer at roughly the
   interpreted-path's speed on the first (or any post-edit) run; the
   speed win only shows up on a *later* invocation, once the background
   compile has finished.

2. **Overlapping invocations of the same stale source must never each
   spawn their own compile** (owner correction, 2026-09-15, msg #1975:
   *"if the first time trigger the compile at the background and when
   run the same command again but the compilation still running, will
   the second run starts another compilation process, 3rd will get 3rd
   compilation... make sure to prevent this disaster"*). N concurrent
   cache-misses on the same source must produce **exactly one** compile
   process, not N racing, duplicate, wasteful compiles.

The second property is enforced with a **PID-stamped lock file**, created
with `sysopen(..., O_CREAT|O_EXCL)` - the standard race-free Perl idiom
for "exactly one caller wins." A plain `-e $lockfile` check-then-write
would have a race window (two processes both see no lock, both write
one, both spawn); `O_EXCL` makes the filesystem itself the arbiter, so
only the process whose `sysopen` call actually succeeds may proceed to
spawn. A stale lock (its recorded PID no longer alive) is detected and
cleared before a fresh attempt, mirroring `script/coverage-gate`'s own
lock-holder check (a self-contained PID-in-file comparison, no `/proc`
dependency, so it works identically across the platforms this project
already ports to).

## Cache layout

Under `home_cache_root()/pax/`, per source file (keyed by a hash of its
absolute path, to keep filenames filesystem-safe and collision-free):

- `<key>.md5` - the source MD5 the currently-cached binary was built from
- `<key>.pax` - the compiled binary itself
- `<key>.compiling` - the PID-stamped lock, present only while a compile
  is genuinely in flight

## What this does NOT do (yet)

This module is deliberately scoped narrow for its first real caller
(`dashboard ps1`, wired in via `bin/dashboard`'s `_exec_switchboard_command`
immediately before its existing `command_argv_for_path` resolution). It
does not vendor PAX's own source into this repository, does not touch
`bin/dashboard`/`bin/d2` themselves (DD-871/872 already proved those
compile cleanly on their own), and does not reach the web server or
collector processes (explicitly out of scope, DDS-001 Q-160). Extending
it to more internal CLI tools is future work under epic DDE-002, once
this proof of concept is proven correct end to end.
