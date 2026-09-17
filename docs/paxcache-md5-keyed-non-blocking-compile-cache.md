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

## Callers

Two callers currently invoke `resolve()`, and both now exec directly into a
cache hit:

- **`dashboard ps1`** (`_pax_cached_binary_for` in `bin/dashboard`, DD-877's
  proof of concept, small allowlist by design): on a cache hit, execs the
  cached compiled binary directly.

- **`bin/dashboard`'s own self-check** (`_maybe_exec_self_compiled_dashboard`,
  DD-882 vendored the whole PAX library and wired this in so the dashboard
  entrypoint itself could self-compile): on a cache hit, execs the cached
  compiled binary directly, guarded against re-exec via
  `DEVELOPER_DASHBOARD_PAX_SELF_EXECED`.

## DD-905/DD-922: the %ENV-corruption defect this cache hit into, root-caused and fixed

**DD-905 (2026-09-16)** temporarily disabled `bin/dashboard`'s exec side
after finding that a REAL PAX-compiled binary of `bin/dashboard` silently
corrupted `%ENV` loading on startup: `Developer::Dashboard::EnvLoader`'s
`_load_env_file` (a plain line-by-line `<$fh>` read of `.env`) died with
`"Invalid env line ... line 1: <the whole file concatenated as one
line>"` when run inside the compiled binary's own execution environment -
even though the byte-identical source ran `.env` loading cleanly under
normal interpreted Perl.

**DD-922 (2026-09-16, same day) root-caused it.** The defect was inside the
vendored Pax `StandaloneRuntime`'s own entrypoint dispatch, not anything
specific to `bin/dashboard` or `EnvLoader.pm`: four sibling dispatchers -
`_run_service_dispatch_unit`, `_run_cli_router_unit`,
`_run_dispatch_script_unit`, `_run_script_unit` - each open one small JSON
metadata file and do `local $/;` to slurp it whole, but that `local $/;`
spans the *rest of the sub*, including a *later* `eval $wrapped` in the
same sub that runs the entrypoint's own compiled source (bootstrap code,
or the user script itself). `eval STRING` does not open a fresh dynamic
scope - it shares its caller's - so every real-file `open+<$fh>` read the
entrypoint's own running code performed (EnvLoader.pm's `.env` parser
included) silently inherited the still-active `$/ = undef` and slurped the
whole file as one "line". Confirmed with an isolated 8-line reproduction
script: reads a 4-line file correctly when interpreted, reads the whole
file as one "line" when self-compiled and run directly, entirely
independent of `bin/dashboard`'s own complexity.

**Fix:** each of the four dispatchers' `local $/;` + JSON-metadata read is
now confined to its own bare block, so `$/` is back to its normal default
before any later `eval` of user/bootstrap source runs. `bin/dashboard`'s
exec side is re-enabled - a cache hit is executed again, exactly as DD-882
originally shipped it. `dashboard ps1`'s narrower self-compile path shares
the identical dispatch mechanism and is fixed by the same change (verified
live: no crash, no content corruption on `Prompt.pm`'s real-file git
HEAD/branch reads).

A separate, unrelated finding surfaced while verifying `ps1`: its compiled
binary's UTF-8 emoji output renders as mojibake (no crash, no wrong data -
a STDOUT encoding difference, not a `$/` issue). Filed as DD-923, not part
of this fix.
