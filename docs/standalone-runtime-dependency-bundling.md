# How a PAX standalone binary decides which modules to bundle

This page describes the current behavior of the system, not any one
ticket. A PAX standalone build walks every compiled unit's source text
looking for `use Module;`/`require Module;` declarations
(`_declared_modules` in `StandaloneImage.pm`) and bundles each declared
module's real `.pm` file into the binary's `runtime/inc/` payload
(`_pure_perl_dependency_units`), recursing into each bundled module's
own declarations so the whole transitive closure ends up inside the
binary. This is what makes the result genuinely standalone: at runtime
the binary never needs an external Perl install, because every module
it can reach was copied in at build time.

## The skip list, and what it is actually for

Not every `use X;` names a real, loadable file worth bundling.
`_skip_dependency_module` excludes a short list of names -
`strict warnings utf8 lib parent base constant feature vars integer
bytes mro overload if open re` - from the walk. The list exists because
several of these are effectively **compile-time-only**: `strict` and
`warnings` set compiler pragmas and carry no meaningful runtime state:
by the time the program is actually running, whether their `.pm` file
is physically present or not makes no observable difference to program
behavior, since the pragma's effect already happened at compile time.

## `overload` does not belong on that list (DD-1022)

`overload` is not compile-time-only. `use overload '""' =>
"STRINGIFY", ...;` installs real, callable subroutines
(`STRINGIFY`/`NUMIFY`/etc.) that Perl invokes **later, at runtime**,
whenever the overloaded object is stringified or numified - exactly
the same kind of ongoing runtime dependency as any ordinary module
call. Treating it like `strict`/`warnings` was a categorization error:
a module that installs runtime-invoked overload magic must be bundled
the same way any real CPAN dependency is, or any code that later
triggers the overload crashes at that point with `overload.pm` missing
from `@INC`.

This was found live: `File::Temp` (bundled because `Capture::Tiny`
depends on it) itself does `use overload '""' => 'STRINGIFY', '0+' =>
'NUMIFY', fallback => 1;`. With `overload` on the skip list, the
compiled binary's runtime payload never contained `overload.pm` at
all - confirmed by downloading a real GitHub Actions CI artifact and
running it in a fresh container with no host Perl reachable:

```
Can't locate overload.pm in @INC (you may need to install the overload
module) ... at .../runtime/inc/NNN/File/Temp.pm line 169.
BEGIN failed--compilation aborted at .../File/Temp.pm line 169.
Compilation failed in require at .../Capture/Tiny.pm line 11.
```

Any subcommand whose code path reaches `File::Temp`/`Capture::Tiny`
crashed at `BEGIN` time. `dashboard version` happened not to touch that
path, which is why the existing release smoke-check (`dashboard
version` only) never caught this - see the lesson below.

**The fix**: `overload` was removed from `_skip_dependency_module`'s
skip list, so it is walked and bundled exactly like any other real
dependency.

## A one-subcommand smoke check proves almost nothing

`pax-release.yml`'s smoke-verify step ran only `dashboard version`
before publishing an artifact. That subcommand's own code path never
happens to load `File::Temp`, so a completely broken binary - unable
to run the large majority of its own subcommands - still passed the
release gate. **A smoke check's coverage is defined by which code
paths it actually exercises, not by whether it exits 0** - the same
"verify the subject actually ran" lesson this project applies
elsewhere, here applied to a release gate rather than a test.

## A second, separate bundling path exists for `hybrid_compiled_pcu_v1` modules, and it silently dropped 46 of them (DD-1035)

The sections above describe `_pure_perl_dependency_units`'s walk-and-bundle
path. A completely different code path exists for modules packaged as
`hybrid_compiled_pcu_v1` - compiled into the binary's own PCU closure
machinery *and* also needed as a plain, `require`-able source file at a
normal `@INC` path (because a bundled *runtime helper* module, like
`StandaloneRuntime.pm` itself, calls them with an ordinary `use Module ();`
that goes through the real Perl `require` mechanism, not the compiled-unit
dispatcher). `_runtime_manifest` builds `@force_runtime_source_files` from
every dependency the scan classified this way, specifically so each one
gets bundled as a real file too.

**Two coupled defects meant that force-list was structurally unable to do
its job:**

1. `$PAX_OWN_LIB_ROOT` (computed once, module scope - "this checkout's own
   `lib/`, so a build never accidentally embeds the vendoring project's own
   dev tree wholesale") was built with `File::Spec->catdir(dirname($this_file),
   updir, updir, updir)` and never passed through `abs_path()`. `catdir`
   only concatenates path segments - it does not resolve `..`/`.` - so the
   resulting string carried literal unresolved `..` segments and could
   never equal or prefix-match a real, `abs_path()`'d `@INC` entry. The
   exclusion this variable exists for (`_runtime_inc_dirs`) was silently a
   no-op: this checkout's own `lib/` was never actually excluded from the
   normal by-`@INC`-directory bundling path, despite the code's own comment
   saying it is.
2. Because of (1), a `hybrid_compiled_pcu_v1` dependency living under
   `$PAX_OWN_LIB_ROOT` (every one of them does - that is where this
   project's own modules live) still got bundled *by accident*, via the
   normal path, as long as nothing else interfered. `_file_list_payloads`'
   own `$force_include_files` parameter was written to **only protect an
   already-selected file from exclusion** - `next if $exclude{$abs} &&
   !$force{$abs}` - it never *added* a path that the normal by-`@INC`-dir
   selection (`_runtime_selected_files`, resolving each module name via a
   bare `@INC` walk) failed to find in the first place. So the moment
   anything broke that accidental path - or, correctly, the moment (1) is
   fixed and the deliberate exclusion starts actually excluding
   `$PAX_OWN_LIB_ROOT` - every `hybrid_compiled_pcu_v1` dependency's
   "force include" protection turned out to be inert.

**Real, observed impact**: `Developer::Dashboard::SeedSync` is one of
**46** modules classified `hybrid_compiled_pcu_v1` in this project's own
manifest (`Auth`, `Config`, `CollectorRunner`, `SessionStore`,
`RuntimeManager`, most of the `Pax::*` JIT-machinery modules, and 41
others). Confirmed live on two separate GitHub Actions CI runs
(`35925321625`/`e6bd0729` and `35900440588`/`55623daa`): the compiled
binary's `--help` and `jq` subcommands crashed at `BEGIN` time with
`Can't locate Developer/Dashboard/SeedSync.pm in @INC`, because
`StandaloneRuntime.pm`'s own `use Developer::Dashboard::SeedSync ();`
(a runtime-helper module calling a hybrid dependency by plain `use`)
found nothing on `@INC` for it - the file genuinely was not bundled.
Never reproduced on any local or containerized build this ticket tried,
including the project's own `developer-dashboard:latest` test image -
every one of them happens to carry an installed copy of this project's
own package somewhere else on `@INC`, which papers over the gap by
accident. A genuinely clean GitHub Actions runner (Perl set up fresh,
only declared CPAN *dependencies* installed, never this project's own
package) has no such accidental fallback.

**The fix**: `$PAX_OWN_LIB_ROOT` is now wrapped in `abs_path()` so its
exclusion genuinely works, and `_runtime_manifest` bundles every
`hybrid_compiled_pcu_v1` dependency directly from its own already-known
`source_path` in a dedicated pass, independent of whether the normal
by-`@INC`-directory selection also happens to find it. Both changes landed
together deliberately: (1) alone would have newly broken every hybrid
dependency's bundling (closing the accidental loophole that was
compensating for (2)'s dead force-list); (2) alone leaves (1)'s inert
exclusion in place, doing nothing until (1) also lands.

## Where to look

- `lib/Developer/Dashboard/Pax/StandaloneImage.pm::_skip_dependency_module`
  - the skip list itself.
- `lib/Developer/Dashboard/Pax/StandaloneImage.pm::_pure_perl_dependency_units`
  - the recursive dependency walk that consults it.
- `lib/Developer/Dashboard/Pax/StandaloneImage.pm::_runtime_manifest`,
  `_runtime_selected_files`, `_locate_module_runtime_file`,
  `_file_list_payloads` - the separate `hybrid_compiled_pcu_v1`
  force-bundling path (DD-1035).
- `.github/workflows/pax-release.yml` - the smoke-verify step. Widening it
  to exercise more than `dashboard version` was implemented and then
  **reverted**: doing so uncovered DD-1035 (documented above, now fixed)
  before the widening itself had landed. Re-widening the smoke check to
  cover more real subcommand code paths (this page's own recurring lesson)
  remains a separate, open gap.
