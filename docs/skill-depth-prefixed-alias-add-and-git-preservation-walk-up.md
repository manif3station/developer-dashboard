# `d2 path add`/`d2 file add` support dotted, arbitrarily-nested skill-depth alias names, with a git-preservation write-location walk-up (DD-1004)

This page describes the current behavior of the system, not any one ticket.
It builds directly on `skill-local-path-aliases-are-now-visible-to-cdr.md`
(DD-977/DD-978), which made a skill's own `path_aliases`/`file_aliases`
**readable**. This page is the **write side**, plus a depth extension and a
data-preservation correction neither DD-977 nor DD-978 needed to consider.
`path_aliases` (directories) and `file_aliases` (individual files) are two
parallel registries with identical mechanics throughout - everything below
applies to both unless a section says otherwise.

## The gap this closes

Before this ticket, `d2 path add <name> <path>` and `d2 file add <name>
<path>` always called `Config::save_global_path_alias`/
`save_global_file_alias`, which writes flat into the top-level global
`config.json`. Nothing inspected whether `<name>` contained dots, so there
was no way to *write* a skill-local alias from the CLI at all - DD-977/978
only ever made a skill's own hand-edited `config/config.json` readable.
There was also no code path that resolved a skill-in-skill nesting like
`skills/foo/skills/bar/` - `installed_skill_roots`/`skill_layers` only ever
enumerated one level under each `skills_root`.

## The alias-name grammar

`Config::split_skill_alias_name($name)` parses a dotted CLI alias name into
a skill-depth segment list plus a trailing alias name:

```
"foo.something"        -> (["foo"],        "something")
"foo.bar.something"    -> (["foo","bar"],  "something")
"plainalias"            -> ()   # undotted - not a skill-prefixed alias at all
```

An undotted name returns an empty list and is unaffected by anything below:
`save_path_alias`/`save_file_alias` (the new top-level dispatchers CLI::Paths
and CLI::Files now call instead of the global save methods directly) route
it straight to the existing `save_global_path_alias`/`save_global_file_alias`
- byte-for-byte the same behavior as before this ticket. `remove_path_alias`/
`remove_file_alias` mirror the same routing for `del`/`rm`.

## Resolving the nested skill directory

`PathRegistry::nested_skill_dir_chain(\@segments)` resolves a skill-depth
segment list to the chain of on-disk directories it names, recursing into
each skill's own nested `skills/` subdirectory arbitrarily deep:

```
["foo"]        -> skills/foo
["foo","bar"]  -> skills/foo, skills/foo/skills/bar
```

The first segment is resolved the normal layered way (`skill_layers`,
deepest participating DD-OOP-LAYER wins - the same directory
`installed_skill_roots`' own deepest-first dedup already picks). Every
segment after that is a single directory lookup inside the previous
segment's own `skills/` subdirectory, because a nested skill-in-skill is not
independently layered across DD-OOP roots the way a top-level skill is - it
lives wherever its parent skill's own tree put it. An unresolvable segment
(no matching directory) makes the whole chain resolve to nothing.

`PathRegistry::nested_skill_entries(%args)` is the read-side counterpart:
starting from every `installed_skill_roots()` entry, it recursively walks
into each skill's own `skills/` subdirectory, returning every reachable
`{segments, dir}` pair at every depth. Discovery and resolution share no
duplicated logic - `nested_skill_entries` finds what exists on disk;
`nested_skill_dir_chain` resolves a specific requested path against the same
on-disk shape.

## Owner's git-preservation correction: walking UPWARD before writing

Michael's exact words, folded onto DD-1004 mid-implementation: *"but if the
skills has .git folder. that path config will be stored at the parent or
parent parent level that has no .git - if that has .git folder. when d2
skill install, the config will be gone. to preserve it, that is the way."*

A skill directory that carries its own `.git` is a **separately git-managed
skill repository**, installed/updated via `d2 skill install`. That command
overwrites the skill directory's working tree on install/update. Writing a
new alias directly into `skills/foo/skills/bar/config/config.json` when
`bar` is such a repository would be silently destroyed the next time `bar`
is reinstalled or updated - invisibly, with no error, discovered only when
the alias mysteriously stops resolving.

**Generalized to unconditional (Q-182).** A follow-up from the owner
sharpened this further: *"If the paths inside the skill config.json is
already exists then do not change them if user use d2 add the same path or
file - save to non .git parent and that will override the ones in skills
but keep the config.json inside skill unchanged."* Read together with the
worked examples that followed, this is **not** conditional on `.git` at the
target itself - a skill's own `config/config.json` is **never** the write
target, at any depth, whether or not that specific skill carries a `.git`.
The reason generalizes past data-loss prevention: it is the general
mechanism for a user customizing a skill's shipped defaults without ever
touching that skill's own tracked files, so the same rule has to hold
whether or not git happens to be involved for that particular skill.

`PathRegistry::skill_config_write_location(\@segments)` is the single
resolver both the write side and the read side use. It walks the resolved
chain from **one level above the deepest (target) segment** - never the
target itself - down to the first segment, looking for the nearest ancestor
directory that does **not** itself contain a `.git` directory:

- **Case A - the nearest ancestor STRICTLY ABOVE the target without its own
  `.git` is a skill directory.** Returns `{kind => 'skill', dir => <that
  directory>, remaining => <segments below it>}`. Example: `foo.bar.something`
  - the walk never even considers `bar` (the target); it starts at `foo`.
  If `foo` has no `.git`, the walk stops there regardless of whether `bar`
  itself has one or not - `remaining` is `['bar']` either way.
- **Case B - every ancestor above the target carries its own `.git`, or
  there simply is no ancestor (a depth-1 target has no parent skill at
  all).** Returns `{kind => 'global', remaining => <the full segment
  list>}` - the write (and read) falls all the way through to the global
  `config.json`. **Every depth-1 dotted alias lands here unconditionally** -
  `d2 path add foo.something /x` always writes to the global fallback,
  never into `skills/foo/config/config.json`, even when `foo` has no `.git`
  and ships no colliding default.

## The storage shape: nested, never a flattened dotted string

Owner's further precision, also folded onto the card before any code was
written: *"so if d2 path add foo.bar.something /foobar and bar skill got
.git and foo not, then the store will be in foo config.json will be nested
structure and if foo also got the .git then back to ~/.developer-dashboard
config.json with nested structure foo => { ... bar => ... }"*

Whatever ancestor `skill_config_write_location` stops at, the alias is
stored as a **nested hash** mirroring the `remaining` segments below that
stopping point - never a flattened `"bar.something"` string key:

Case A (`foo` is the stopping point, `remaining = ['bar']`), written into
`skills/foo/config/config.json`:

```json
{ "bar": { "path_aliases": { "something": "/foobar" } } }
```

Case B (global fallback, `remaining = ['foo','bar']`), written into the
global `config.json` under the **`skills`** top-level key - confirmed by the
owner on the card (Q-181) after searching for and finding no existing
global-config convention namespacing skill-owned data (the `_<skillname>`
underscore prefix used by `_skill_config_fragments` is a merge-time runtime
fragment produced by *reading* skill `config/config.json` files; it is never
itself written to or read from the global `config.json`, so it was not
reusable here):

```json
{ "skills": { "foo": { "bar": { "path_aliases": { "something": "/foobar" } } } } }
```

A depth-1 alias (per the Q-182 generalization above) always lands in the
global `skills` fallback, under its own name, with an empty `remaining`
below it: `{ "skills": { "foo": { "path_aliases": { "x": ... } } } }`.

## Overriding a skill's shipped default without ever touching its file

A skill can ship its own hand-authored `path_aliases`/`file_aliases` block
in its own `config/config.json` (this is exactly DD-977/978's original
scenario - see the companion page). `d2 path add`/`d2 file add` must never
edit that file, even to override an alias name the skill already defines
there - the shipped file is a **read-only source** as far as `add` is
concerned, always.

`Config::_nested_skill_alias_entries($alias_key)` is the shared read-side
walker that makes an override actually shadow a shipped default, in two
priority-ordered passes over `nested_skill_entries`' full result:

1. **Pass 1 (lower priority) - shipped defaults.** For every depth-2-or-deeper
   skill, its own `config/config.json` is read **directly**, regardless of
   `.git` (reading it is always safe; only writing to it is forbidden),
   qualified by its full dotted segment path. Depth-1 shipped defaults are
   deliberately left to the pre-existing `_skill_config_entries`/
   `_skill_path_aliases` path (DD-977/978), which merges a skill's own
   config across *every* participating DD-OOP-LAYER via `skill_layers` - a
   guarantee pass 1 does not attempt to reproduce for a single resolved
   directory.
2. **Pass 2 (higher priority) - user overrides.** For every entry at every
   depth including 1, it calls the *exact same* `skill_config_write_location`
   a write of those segments would have used, reads whichever location that
   returns (an ancestor skill's `config.json`, or the global config's
   `skills` section), and merges the result **after** pass 1 - so it
   overwrites, in the returned hash, whatever pass 1 already put there for
   the same qualified name.

Write and read never duplicate the walk-up decision: an alias written by
`save_skill_path_alias`/`save_skill_file_alias` is always readable back from
wherever it was actually, physically stored, and it always wins over
whatever the skill's own file separately says for that name - which stays
completely unmodified on disk.

## What is deliberately out of scope

`lib/Developer/Dashboard/Pax/StandaloneRuntime.pm` - the hand-maintained
duplicate CLI implementation used only by the self-compiled standalone
binary - was **not** updated to mirror this routing. Self-exec has been
disabled since DD-905 (a corrupted `.env`-parsing defect) and is unreachable
in normal usage; no test asserts byte-parity between the two
implementations. If self-exec is ever re-enabled, syncing
`StandaloneRuntime.pm`'s `path add`/`file add`/`del` ops to call the same
`save_path_alias`/`save_file_alias`/`remove_path_alias`/`remove_file_alias`
dispatch is separate follow-up work, tracked on DD-1004's card rather than
silently left as an undocumented gap (per this project's own
"a mitigation is not done until the real fix's ticket is filed" rule -
though note this is a scope decision, not a mitigation for a defect: the
duplicate simply keeps its pre-existing, already-disabled behavior).

## Related

- `skill-local-path-aliases-are-now-visible-to-cdr.md` - the read-only
  precursor (DD-977/DD-978) this ticket's write side and depth extension
  build directly on.
- `skill-api-fragments-merge-below-project-layers.md` - the companion
  `{ _<skillname> => {...} }` namespacing mechanism for the *runtime-merged*
  view, distinct from (and not reusable for) the on-disk global-config
  fallback shape this ticket introduces.
