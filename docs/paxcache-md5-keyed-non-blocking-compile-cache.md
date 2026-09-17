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

## DD-930: a SECOND, independent self-compile defect, found minutes after DD-922 re-enabled the exec side

DD-922's fix and re-enable were correct for the defect they addressed, but
`bin/dashboard`'s self-exec-on-cache-hit had been off since DD-905 - the
whole time between DD-905 and DD-922 landing - so nothing had ever actually
run a real compiled `dashboard` binary against genuine project config until
DD-922 turned self-exec back on. Within minutes, a real self-compiled
`dashboard` invocation from inside this project's own checkout (a command
that reaches `EnvLoader`'s `_load_env_pl_file` path with real config
present - `dashboard version` alone does not trigger it) crashed with:

```
Can't locate object method "record" via package
"__PAX_RUNTIME_LEGACY_NAMESPACE__::EnvAudit" (perhaps you forgot to load
"__PAX_RUNTIME_LEGACY_NAMESPACE__::EnvAudit"?)
```

**Root cause (different mechanism from DD-905/DD-922's `$/` scope leak):**
`Developer::Dashboard::Pax::CodeUnitCompiler` has a narrow, pattern-matched
special case (source-text shape matching, not semantic analysis) that
detects `EnvLoader.pm`'s `_load_env_pl_file` sub and substitutes a custom
`env_load_env_pl_file` runtime op instead of compiling it normally. That
op is interpreted in `StandaloneRuntime.pm` as
`__PAX_RUNTIME_LEGACY_NAMESPACE__::EnvAudit->record(...)`, but the compiled
binary's "legacy namespace" bridging never actually loads or registers a
usable `EnvAudit` class there, so the call fails at runtime. Confirmed the
cached binary was not stale - its recorded MD5 matched the exact current
(DD-922-fixed) `bin/dashboard` source byte-for-byte.

**Mitigation (DD-930):** `bin/dashboard`'s self-exec-on-cache-hit disabled
again - the resolve() call still runs (keeping a background compile warm),
but a cache hit is never acted on, matching DD-905's original disable
shape exactly. Root-cause fix tracked separately as DD-931, per this
project's own disable-is-not-done rule (a mitigation is not done until the
real fix's ticket is filed in the same breath).

**The generalizable lesson:** a mitigation that re-enables a previously-off
code path can surface a SECOND, entirely independent defect the first
fix never touched, simply because the path had never been genuinely
exercised before. Verifying "the known defect is fixed" is not the same
claim as "this code path is safe to turn back on" - the two were
conflated here, twice, on the same day.

## DD-931: DD-930's root cause, fixed - but self-exec STAYS disabled

**DD-931 (2026-09-17) root-caused DD-930.** `EnvAudit` is never added to
`CodeUnitCompiler`'s `compiled_packages`, because its only literal source
reference sits inside `EnvLoader.pm`'s `_load_env_file`/`_load_env_pl_file`
subs - and those subs are special-cased by `CodeUnitCompiler.pm` (matched by
source-text shape around line 10880-10988): their ENTIRE body is replaced
with a hardcoded `env_load_env_file`/`env_load_env_pl_file` runtime op
*before* the compiler's own dependency-discovery pass (which walks literal
source text) ever sees the `EnvAudit->record(...)` call inside them. So
`EnvAudit` never joins `compiled_packages` and never gets a
`__PAX_RUNTIME_LEGACY_NAMESPACE__::` alias installed by
`_install_namespace_compat()`.

**Fix:** both runtime op implementations in `StandaloneRuntime.pm` now
`require Developer::Dashboard::EnvAudit;` directly and call the real class
(`Developer::Dashboard::EnvAudit->record(...)`) instead of going through the
never-populated legacy-namespace alias. Safe because `_install_require_hook`
already overrides `CORE::GLOBAL::require` to fall back to a normal
filesystem `require` for any non-embedded unit.

**Verified with a real compiled binary** (`share/private-cli/pax build`,
113/113 units): `EnvAudit` string-table references went from 0 (pre-fix,
confirmed by grepping every cached `.pax` binary in DD-930's own
investigation) to 51 (post-fix), and the binary no longer crashes on
`EnvAudit->record(...)`.

**Self-exec was NOT re-enabled.** Attempting genuine end-to-end verification
(not just checking the narrow EnvAudit fix in isolation) surfaced three
further, independent, more severe defects in the compiled binary, each filed
separately rather than silently absorbed:

- **DD-932** - the compiled binary silently never even *opens* any
  `.developer-dashboard/.env` runtime-layer file at all (confirmed via
  `strace`: zero `.env`-related syscalls, vs. the interpreted `dashboard`
  which opens and correctly validates the same file). Worse than DD-905's
  original corruption bug: no symptom at all to notice it by.
- **DD-933** - the "special-cased op body invisible to dependency discovery"
  pattern DD-931 root-caused for `EnvAudit` is not unique to it:
  `JSON::json_decode` and `SeedSync::same_content_md5` crash the identical
  way in the same test binary. DD-931's fix closes only one instance of a
  systemic pattern; the durable fix belongs in `CodeUnitCompiler.pm`'s
  dependency-discovery pass itself (or a documented require-your-own-deps
  convention for every special-cased op), not in one-off patches per class.
- **DD-934** - the compiled entrypoint (`entrypoint.pl`, itself a
  PAX-generated virtual file, not a source file in this repo) crashes with
  `Can't use string ("<token>") as a HASH ref` on almost any subcommand that
  carries a trailing argv token - which is most real `dashboard` invocations.

**So `bin/dashboard`'s self-exec-on-cache-hit guard stays disabled**
(DD-930's mitigation shape unchanged) until DD-932, DD-933 and DD-934 are
also resolved. DD-931 fixed the one defect its own title named; it
deliberately did not claim the broader "re-enable self-compile" goal, which
is now tracked across four tickets instead of one.

**The lesson, one layer further than DD-930's own:** even *"the specific
crash this ticket named is fixed, verified with a real binary"* is not the
same claim as *"this code path is safe to turn back on"* - the same
conflation DD-930's section above already named, caught a second time by
insisting on genuine end-to-end verification rather than a narrow
before/after check of the one symptom the ticket was filed against.

## DD-935/DD-936: background compile is opt-in now (`DD_PAX=on`), off by default

**DD-935 (2026-09-17)** measured, in a live container, exactly why `pax
build` is a heavy background operation: compiling the 113 application units
of `bin/dashboard` takes under 4 minutes *combined*, but one single file -
`lib/Developer/Dashboard/Pax/CodeUnitCompiler.pm`, the compiler's own
~13,000-line source, compiling itself - took over 4.5 minutes alone and was
still running when last observed (confirmed independently: even compiling
that ONE file in isolation, outside the whole `pax build` pipeline, exceeded
a 2-minute timeout). Root cause: for a file this size, `compile()`'s per-sub
path (`_compile_sub`/`_compile_declared_sub_from_source`) runs several
regex-based extraction passes (`_extract_sub_body` and siblings) over the
*entire* source string, once per declared sub - O(subs x file_size) of
regex scanning against a ~400KB source, with 100+ subs in this one file.
Not yet fixed (DD-935 tracks the actual algorithmic fix); this section
documents the mitigation that shipped first.

**DD-936 (2026-09-17), same day, owner-specified live:** *"can PAX be a opt-in
function. by default is opt-out and disabled... to enable pax, user will
need to have enviro variable DD_PAX=on... by default is off, the user does
not need to specify it."* `bin/dashboard`'s self-exec was already disabled
(DD-930) - stopping a cached binary from being *executed* - but
`PaxCache::resolve()` still unconditionally spawned a real background `pax
build` process on every cache miss regardless, which is exactly the CPU cost
the owner observed live (`docker exec <container> ps -ef` showing two `pax
build` processes each pinned at ~66% CPU for 90+ seconds, triggered merely
by running `dashboard init`/`d2 init`). Disabling self-exec stopped the
*result* being used; it did nothing to stop the wasteful compile itself from
running.

**Fix:** `PaxCache::resolve()` now checks `$ENV{DD_PAX}` first, before any
other logic - if it is not exactly `'on'`, `resolve()` returns `undef`
immediately (the same shape as its other early-exit paths, e.g. a missing
source file), spawning nothing and touching no cache state. The default
(the variable unset) is fully disabled; nothing needs to be set to keep it
off. Setting `DD_PAX=on` restores the pre-DD-936 behavior unchanged.

**This is independent of DD-935.** DD-936 is a pure kill switch, not
contingent on DD-935's algorithmic fix landing first - it stops the CPU cost
immediately, and the owner's own stated intent is to reconsider the default
once DD-935 is verified (compile time well under a minute, not
CPU-intensive), as a separate later decision.
