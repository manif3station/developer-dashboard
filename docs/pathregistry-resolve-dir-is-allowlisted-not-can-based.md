# `PathRegistry::resolve_dir`'s name-to-method dispatch is allowlisted, not `can()`-based

What `resolve_dir` actually checks before turning a logical name into a
method call, and why `->can($name)` alone was never a safe enough guard
for a name that can arrive as raw CLI text. This page describes the
system as it now stands, not any one ticket. See also
`file-registry-name-resolution-is-allowlisted-not-can-based.md` - `FileRegistry`
carried the identical defect (DD-868), fixed with the same shape one
ticket earlier.

## The three ways a name can resolve

`Developer::Dashboard::PathRegistry::resolve_dir($name)` tries, in order:

1. **Absolute path** - `$name` is returned unchanged if
   `File::Spec->file_name_is_absolute($name)` is true.
2. **A known no-arg path getter** - one of 26 allowlisted names (see
   below).
3. **An explicitly registered alias** - `$self->{named_paths}{$name}`,
   populated by `register_named_paths`, with `~` expanded via
   `_expand_home`.

Anything else dies with `Unknown directory name '$name'`.

## Why step 2 is an allowlist, not `$self->can($name)`

Before DD-870, step 2 read `return $self->$name() if $self->can($name)`,
checked *before* the named-paths lookup. `PathRegistry` has dozens of
public methods, not 26: `can()` said yes to the constructor
(`new`/`new_from_all_folders`), the mutators (`register_named_paths`,
`unregister_named_path`), every hash/list-returning inventory method
(`all_paths`, `all_path_aliases`, `named_paths`, every `*_roots`/`*_layers`
plural), and every method that takes a required argument (`skill_root`,
`project_root_for`, `resolve_dir`/`resolve_any` themselves, and more).

That mattered because `resolve_dir` is reached directly from raw CLI
text: `dashboard path resolve <name>` and `dashboard path add <name>
<path>` (`lib/Developer/Dashboard/CLI/Paths.pm`, the latter using it as a
name-collision pre-check) pass whatever the user typed straight in.
Confirmed live before the fix: `resolve_dir('all_paths')` returned a raw
`HASH` reference instead of a path string - the identical contract
violation DD-868 found in `FileRegistry`.

**The fix is a fixed, compile-time allowlist, checked instead of
`can()`:**

```perl
my %RESOLVABLE_ACCESSOR = map { $_ => 1 } qw(
  home runtime_root home_runtime_root home_runtime_path project_runtime_root
  state_root state_base_root cache_root home_cache_root logs_root
  dashboards_root bookmarks bookmarks_root cli_root skills_root
  collectors_root indicators_root sessions_root temp_root config_root
  auth_root repo_dashboard_root users_root current_project_root
  current_working_directory cwd
);
...
return $self->$name() if $RESOLVABLE_ACCESSOR{$name};
```

The `can()` check is dropped entirely (not kept alongside the allowlist):
every one of these 26 names is an always-defined method in this same
file, so a redundant `can()` guard would only ever be true and adds
nothing - the same reasoning DD-868's commit used to drop it there.

## How the 26-name list was derived

Not guessed: every public, self-only-arg (`my ($self) = @_;`, no further
parameters) method in `PathRegistry.pm` that returns a single scalar path
string was extracted mechanically, then cross-checked against
`t/07-core-units.t`'s own pre-existing `resolve_dir` assertions (lines
827-830: `home`, `bookmarks`, `bookmarks_root`, `cli_root`,
`sessions_root` must keep working) to confirm nothing already relied-upon
was left out. Plural/hash-returning methods (`*_roots`, `*_layers`,
`all_paths`, `all_path_aliases`, `named_paths`) and underscore-prefixed
internals (`_state_root_user`, `_ancestor_runtime_layers`, etc.) were
excluded even though they are technically no-arg and `can()`-matchable,
because they were never the intended surface for this fallback.

## The general shape, for the next accessor added to this class

Adding a 27th no-arg path getter means adding its name to
`%RESOLVABLE_ACCESSOR` explicitly - deliberately not inferred from a
naming convention (no `_root$` suffix match), because a convention is
exactly the kind of implicit rule a future method can violate without
anyone noticing. Any method that takes a required argument, mutates
state, or returns a list/hash must never be added here regardless of its
name.

## Related

`lib/Developer/Dashboard/CLI/Paths.pm` is the only shipped caller of
`resolve_dir` with genuinely external (CLI-typed) input, at both `path
resolve` and `path add`'s collision pre-check. If a new CLI surface
starts passing external text into `resolve_dir`, it inherits this same
allowlist - no change is needed there.
