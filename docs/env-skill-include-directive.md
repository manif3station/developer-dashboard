# `.env`/`.env.pl` skill include: pulling in another skill's environment on request

`Developer::Dashboard::EnvLoader`'s normal layered env loading only ever walks
the ancestor-directory chain toward the current working directory - it never
reaches sideways or across the tree to a specific named skill. The include
feature (DD-979) is the deliberate, on-request counterpart: pull one named
skill's `.env`/`.env.pl` files in by its dotted path, from any `.env` or
`.env.pl` file, with the result kept clearly namespaced so it can never
silently collide with the including file's own variables.

## Two ways to trigger it

**From a plain `.env` file**, a comment-shaped directive line:

```
# include <foo.bar>
```

pulls in the nested skill `bar` under top-level skill `foo` - both its
`.env` and its `.env.pl`, if either exists. A trailing `.*`:

```
# include <foo.bar.*>
```

does the same, plus every sub-skill nested beneath `foo.bar`, recursively.
This directive is recognized *before* the generic `#`-comment stripper would
otherwise silently discard the line as an ordinary comment
(`EnvLoader::_include_directive`, checked ahead of `_strip_env_comments` in
`_load_env_file`'s per-line loop) - so it only works on its own line, exactly
as written, never combined with an ordinary comment on the same line.

**From a `.env.pl` file**, the same thing programmatically:

```perl
use Developer::Dashboard;
env->include('foo.bar');
env->include('foo.bar.*');
```

`env->include(...)` and the `# include <...>` directive both resolve through
the same engine, `Developer::Dashboard::EnvInclude->include(...)`, and behave
identically.

### Why `env` is a real package, not an exported sub like `d2`

`Developer::Dashboard` already exports `d2` as a plain sub
(`our @EXPORT = ('d2');`). `env->include(...)` cannot work that way: Perl
resolves a bareword immediately before `->` as a literal package name string
at *parse* time, regardless of whether a sub of that name exists or was
imported - `sub env { ... }` in scope does not make `env->include(...)` call
that sub, it dies with `Can't locate object method "include" via package
"env"`. So `env` is declared as a genuine second package inside
`lib/Developer/Dashboard.pm` (this project already keeps more than one
package in a single file elsewhere - see `Handle.pm`, `PageRuntime.pm`).
Loading `Developer::Dashboard` (`use Developer::Dashboard;`) is what makes
`env` available, the same practical effect as `d2`'s own export, even though
the underlying Perl mechanism has to be different.

## Namespacing: double underscore, not dot notation

An included variable is renamed to `<UPPERCASED DOTTED PATH, DOTS AS SINGLE
UNDERSCORES>__<original name>`. `foo.bar`'s own `BOB=1` becomes
`$FOO_BAR__BOB` in the including file's environment - never a bare `$BOB`,
and never `foo.bar.BOB`. A recursively-included sub-skill gets its own,
deeper prefix: `foo.bar.baz`'s own `QUX` becomes `$FOO_BAR_BAZ__QUX`.

This is a **separate, new convention** from the pre-existing single-underscore
skill-layer auto-load prefix (`EnvLoader::_normalize_skill_env_prefix`, used
when a *nested* skill layer overwrites a key its own parent layer already set
during ordinary ancestor-chain loading - see that function's own POD). The
two do not share code and are not meant to: auto-load prefixing preserves an
*overwritten* value as a fallback; include namespacing keeps an *on-request*
pull-in from ever colliding with anything in the first place.

## DD-OOP-LAYERS: every installed layer contributes, deeper wins

A named skill can be installed at more than one DD-OOP-LAYER (home, and one
or more deeper project/workspace layers). `include(...)` resolves the spec
against *every* layer that has it, from home toward the deepest layer, and
applies each layer's env files in that order - so a deeper layer's value for
a given key wins, exactly like the rest of this project's layered config
merge, but a key that only exists in a shallower layer is never dropped just
because a deeper layer also happens to define the same skill path.

## What `include(...)` actually does under the hood

`Developer::Dashboard::EnvInclude->include($spec)`:

1. Strips a trailing `.*` (recording whether recursive inclusion was asked
   for) and splits the remaining dotted path into segments.
2. For every DD-OOP-LAYER's `skills/` root (home toward deepest), walks
   `<root>/<first-segment>/skills/<next-segment>/skills/<next-segment>/...`
   - the same nested-skill directory shape `EnvLoader::_nested_skill_layer_specs`
   already assumes elsewhere in this codebase. A layer that does not have
   the full path installed contributes nothing for that layer; this is not
   an error.
3. For each matched directory (and, if `.*` was given, every sub-skill
   nested beneath it, found via `Developer::Dashboard::DirEntries::sorted_dir_entries`),
   loads its `.env`/`.env.pl` in **isolation** via
   `EnvLoader->load_files_into_hash` (the same primitive the ordinary
   skill-layer loader uses to compute an overlay diff) and merges only the
   resulting new-or-changed keys into the real process environment under the
   namespaced key, recording each in `Developer::Dashboard::EnvAudit` with
   `include:<dotted-name>` as its provenance source.

## Related

- `Developer::Dashboard::EnvLoader`'s own POD - the normal ancestor-directory
  layered env loading this feature deliberately does *not* replace or
  extend.
