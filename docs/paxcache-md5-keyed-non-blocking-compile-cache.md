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

## DD-935/DD-936: pax build's compile-time/CPU cost, and stopping it by default

**Both found the same underlying problem, from opposite ends, the same day
(2026-09-17), after the owner observed it live** via a `dd-pax-test`
container (`docker exec dd-pax-test ps -ef` showing two `pax build`
processes pinned at ~66% CPU for 90+ seconds from nothing more than
`dashboard init`/`d2 init`).

### DD-935: the algorithmic fix

Measured directly in a real container build's progress log: the "Compile
application units" phase compiled 112 of 113 files in under 4 minutes
combined, then stalled on unit 64/113 -
`lib/Developer/Dashboard/Pax/CodeUnitCompiler.pm`, the compiler's own
~13,000-line source, compiling itself - for over 4.5 minutes, still running
when last observed. Confirmed independently: compiling that one file in
isolation, entirely outside the `pax build` pipeline, exceeded a 2-minute
timeout with no other overhead at all.

**Root cause, isolated via `Devel::NYTProf` and targeted
`Time::HiRes`-wrapped instrumentation:** `CodeUnitCompiler.pm`'s own
`_extract_sub_body`/`_extract_sub_source` (its per-sub source-extraction
helpers, used to classify every declared sub in a file being compiled) walk
brace depth with a Perl-level `while ($i < length($source)) { my $char =
substr($source, $i, 1); ...; $i++ }` loop - one `substr()` call per
character of the file. Measured on this exact file self-compiling: two such
lines alone accounted for ~650 of the profile's ~660 total measured seconds,
called 3,025,200 times combined across 201 extraction calls. A single
isolated call extracting `compile()`'s own ~7.5KB body cost 1.4 seconds.

The precise Perl-internals mechanism (why per-character `substr()` against
this file's particular `decode('UTF-8', ...)`'d string is this expensive)
was not fully isolated - ruled out: scattered multi-byte content (this file
is confirmed pure ASCII, zero non-ASCII bytes). The fix does not depend on
knowing why.

**Fix:** both extractors now use a `\G`-anchored regex scan
(`/\G[^{}]*([{}])/gs`) instead of the manual per-character loop - the C
regex engine skips every non-brace character in one native step per match,
so the Perl level only ever touches the braces themselves. Same semantics,
verified byte-identical output on the same real extraction: **1.4s -> 0.0005s**
per call, and the full `compile()` call against `CodeUnitCompiler.pm` itself
went from a 2-minute-plus timeout to **0.12 seconds**.

**Secondary, independent fix:** `StandaloneImage.pm`'s `_compile_launcher`
dropped its `cc` invocation from `-O2` to `-O0` - the generated launcher is a
thin bootstrap stub with no hot loops of its own, so `-O2`'s optimization
passes bought zero runtime benefit while costing real wall-clock compile
time on the large generated C source. Verified: 2.7s clean launcher compile.

**Not yet obtained: a single trustworthy full end-to-end wall-clock number.**
This host ran under severe, sustained multi-tenant contention throughout this
investigation (load average 13-24, never genuinely quiet) - three separate
full-pipeline measurement attempts on the fixed code landed at 890s, a
contended run discarded outright, and 926s, against a 959s baseline - only
1-4% improvement despite the dramatic isolated win. This is the documented
host-contention trap this project's own rules warn about repeatedly, not a
defect in the fix - the underlying per-file compile cost is confirmed fixed
via isolated, uncontended function-level measurement, which contention
cannot distort the way it distorts a whole-pipeline wall-clock comparison.

**A second, architecturally distinct contributor was found and filed
separately as DD-939**, rather than left unexplained: `Capture.pm`'s
`capture()` (called via `_capture_live_unit` for any file that doesn't take
the fast "declared subs" shortcut) spawns a real, separate Perl subprocess
per file via `IPC::Open3`, to introspect that file's compiled optree.
Subprocess fork/exec+scheduling overhead is disproportionately sensitive to
host contention in a way a tight CPU loop is not, which is consistent with
the gap between the isolated win and the contended full-pipeline numbers -
not yet confirmed as the actual explanation, tracked in DD-939.

### DD-936: the opt-in kill switch

**Owner-specified live:** *"can PAX be a opt-in function. by default is
opt-out and disabled... to enable pax, user will need to have enviro
variable DD_PAX=on... by default is off, the user does not need to specify
it."* `bin/dashboard`'s self-exec was already disabled (DD-930) - stopping a
cached binary from being *executed* - but `PaxCache::resolve()` still
unconditionally spawned a real background `pax build` process on every
cache miss regardless, which is exactly the CPU cost the owner observed
live. Disabling self-exec stopped the *result* being used; it did nothing to
stop the wasteful compile itself from running.

**First implementation gated the WHOLE of `resolve()`** behind
`$ENV{DD_PAX} eq 'on'`, checked before anything else. This was found to be
too broad during verification: it also blocked reporting an
ALREADY-EXISTING, valid cache hit, not just spawning a new compile - which
silently broke `bin/d2`'s own designed self-exec feature (DD-882):
`t/184-d2-self-compile.t` seeds a real, valid cache entry directly (no
compile involved) and expects it reported/used, and with `DD_PAX` unset that
now returned `undef` even for a hit that required no new work at all.
Confirmed real and deterministic: passed on clean master, failed
identically on the DD-936 branch in isolation.

**Corrected (Q-167, owner-answered same day, option A):** the `DD_PAX` gate
moved to immediately before the `_maybe_spawn_compile` call, AFTER the
existing cache-hit check - an already-existing valid cache hit is reported
normally regardless of `DD_PAX`; only spawning a brand NEW background
compile requires `DD_PAX=on`. Default (the variable unset) is fully
disabled for new compiles; nothing needs to be set to keep it off.
Re-verified: `t/184` 12/12 PASS (the regression genuinely fixed), `t/181`
49/49 PASS including a new test covering the cache-hit-regardless-of-DD_PAX
scenario directly.

**This is independent of DD-935.** DD-936 is a pure kill switch on new
compiles, not contingent on DD-935's algorithmic fix landing first - it
stops the CPU cost of a fresh compile immediately, and the owner's own
stated intent is to reconsider the default once DD-935 (and DD-939, if
confirmed) are verified, as a separate later decision.
