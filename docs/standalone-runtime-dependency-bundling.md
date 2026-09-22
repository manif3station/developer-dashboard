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

## Where to look

- `lib/Developer/Dashboard/Pax/StandaloneImage.pm::_skip_dependency_module`
  - the skip list itself.
- `lib/Developer/Dashboard/Pax/StandaloneImage.pm::_pure_perl_dependency_units`
  - the recursive dependency walk that consults it.
- `.github/workflows/pax-release.yml` - the smoke-verify step, widened
  to exercise more than one subcommand after this finding.
