# PAX special-cased op dependencies must be required directly, never through the legacy-namespace alias

What `CodeUnitCompiler.pm`'s source-text special-casing does to dependency
discovery, why a class can silently vanish from a compiled entrypoint's
closure, and the convention that fixes it.

## The mechanism

`CodeUnitCompiler.pm` special-cases certain subs: it matches a sub's body
against a fixed SOURCE TEXT SHAPE (a regex over the literal Perl text) and,
on a match, substitutes the whole body with a hardcoded runtime "op"
descriptor instead of compiling the sub normally. `StandaloneRuntime.pm`
executes those ops at runtime, installing a hand-written implementation in
place of the original sub.

Separately, the compiler's dependency-discovery pass decides which classes
belong in a given compiled entrypoint's `compiled_packages` closure by
**walking literal source text** for class references (`SomeClass->method`,
`SomeClass::sub(...)`, `use SomeClass`, etc.). Only classes it finds this way
get a `__PAX_RUNTIME_LEGACY_NAMESPACE__::<Class>` alias installed for that
build.

**The gap:** if a class is referenced *only* inside a sub body that gets
substituted by the special-casing step, that reference is gone from the
literal source the dependency-discovery pass ever sees (the pass runs over
what's on disk/in the source tree, not over the runtime op descriptors), so
the class is never added to `compiled_packages` and never gets its legacy
alias. Any OTHER runtime op (a different special-cased sub's hardcoded
implementation) that then calls
`__PAX_RUNTIME_LEGACY_NAMESPACE__::<Class>::<method>(...)` hits an
**undefined subroutine** the moment it runs, for that entrypoint's build,
even though the exact same code works fine in an entrypoint whose closure
happens to reference the class some other way too.

## Confirmed instances

- **EnvAudit** (DD-931): `StandaloneRuntime.pm`'s `env_load_env_file` /
  `env_load_env_pl_file` op implementations called
  `__PAX_RUNTIME_LEGACY_NAMESPACE__::EnvAudit->record(...)`. EnvAudit's only
  literal-source reference in the affected entrypoint's closure was inside
  the `_load_env_pl_file` sub body that CodeUnitCompiler.pm itself
  substitutes - so the walk never saw it.
- **JSON** and **SeedSync** (DD-933, generalizing DD-931's finding):
  `StandaloneRuntime.pm` calls `__PAX_RUNTIME_LEGACY_NAMESPACE__::JSON::
  json_decode`/`json_encode` (~20 call sites) and
  `__PAX_RUNTIME_LEGACY_NAMESPACE__::SeedSync::same_content_md5`/
  `content_md5` (4 call sites) from inside OTHER special-cased ops' hardcoded
  implementations - the same shape, a different pair of classes.

## The fix (the established convention)

Do not rely on the legacy-namespace alias for a class a special-cased op
needs as a helper. Instead, `require` the real class directly inside the op's
implementation and call it by its real package name:

```perl
# DD-931 / DD-933: <Class> is never itself referenced by name in any sub
# body PAX statically discovers in some entrypoints' closures (its only
# real-code call site can be inside a special-cased sub whose body the
# compiler substitutes entirely with a runtime op before the compiler's own
# dependency walk ever sees the literal reference) - so it is never added to
# compiled_packages and never gets a __PAX_RUNTIME_LEGACY_NAMESPACE__ alias
# installed for that build. Load the real class directly (falls through the
# existing CORE::GLOBAL::require hook to a normal filesystem require when,
# as here, it is not an embedded compiled unit) rather than going through
# the legacy-namespace alias, which was never populated for it.
require Developer::Dashboard::<Class>;
...
Developer::Dashboard::<Class>::<method>(...);
```

This was chosen over reworking the dependency-discovery pass itself (having
it also scan substituted-body source text) as the lower-risk fix on a
13,000+-line vendored compiler: it is mechanically verifiable per call site,
matches a precedent already reviewed and shipped once, and does not risk
changing dependency-discovery behavior for every other special-cased op in
the file.

## How to apply

- Any time a special-cased op's hardcoded `StandaloneRuntime.pm`
  implementation needs another class as a helper, call it via
  `require Developer::Dashboard::<Class>;` + a direct package-qualified
  call, never via `__PAX_RUNTIME_LEGACY_NAMESPACE__::<Class>::`.
- When adding a NEW special-cased op that calls a helper class, check
  whether that class is already required elsewhere in the same op's
  reachable code path before assuming the legacy alias will be populated -
  it depends on the ENTRYPOINT's specific closure, not on the codebase as a
  whole, so a working case in one build proves nothing about another.
- Verify with a real compiled `.pax` binary, not by reading source: an
  entrypoint whose closure happens to reference the helper class some other
  way will mask the bug, exactly as `version`'s C-level fast-path masked
  DD-932's premise.
