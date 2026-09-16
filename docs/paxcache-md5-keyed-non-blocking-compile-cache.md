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

## What this does NOT do

Does not reach the web server or collector processes (explicitly out of
scope, DDS-001 Q-160). Extending it to more internal CLI tools beyond the
two callers below is future work under epic DDE-002.

## Callers, and one caller's cache-hit action is deliberately disabled

Two callers currently invoke `resolve()`:

- **`dashboard ps1`** (`_pax_cached_binary_for` in `bin/dashboard`, DD-877's
  proof of concept, small allowlist by design): on a cache hit, execs the
  cached compiled binary directly. Unaffected by the issue below.

- **`bin/dashboard`'s own self-check** (`_maybe_exec_self_compiled_dashboard`,
  DD-882 vendored the whole PAX library and wired this in so the dashboard
  entrypoint itself could self-compile). **DD-905 (2026-09-16) disabled the
  exec side of this caller specifically**, after finding that a REAL
  PAX-compiled binary of `bin/dashboard` silently corrupts `%ENV` loading on
  startup: `Developer::Dashboard::EnvLoader`'s `_load_env_file` (a plain
  line-by-line `<$fh>` read of `.env`) dies with `"Invalid env line ...
  line 1: <the whole file concatenated as one line>"` when run inside the
  compiled binary's own execution environment - even though the
  byte-identical source runs `.env` loading cleanly under normal interpreted
  Perl. The root cause is somewhere inside the vendored Pax
  `StandaloneRuntime`'s own runtime (not yet found, in a ~15,000-line
  module) - some real, non-embedded-asset filesystem file read behaves
  differently there than under plain Perl. Because this ran unconditionally
  on every real invocation, and `resolve()` triggers its background compile
  automatically with no explicit opt-in, the corruption was silent and
  invisible to `prove -lr t` (the test harness sets `HARNESS_ACTIVE`, which
  this caller explicitly skips on) - it only ever surfaced in live
  interactive/production use, once a background compile happened to finish.

  **Current state:** this caller still calls `resolve()` (so the background
  compile keeps happening - harmless, and lets a future fix pick up a warm
  cache immediately) but never acts on a defined cache hit to exec into it;
  `bin/dashboard` always falls through to its own interpreted body. **Do
  not re-enable the exec side of this specific caller** until the
  `StandaloneRuntime` file-I/O divergence above is properly root-caused and
  fixed - re-enabling it blind would silently reintroduce the corruption.
