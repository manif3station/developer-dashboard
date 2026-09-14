# `FileRegistry::resolve_file`'s name-to-method dispatch is allowlisted, not `can()`-based

What `resolve_file` actually checks before turning a logical name into a
method call, and why `->can($name)` alone was never a safe enough guard
for a name that can arrive as raw CLI text. This page describes the
system as it now stands, not any one ticket.

## The four ways a name can resolve

`Developer::Dashboard::FileRegistry::resolve_file($name)` tries, in
order:

1. **Absolute path** - `$name` is returned unchanged if
   `File::Spec->file_name_is_absolute($name)` is true.
2. **Explicitly registered alias** - `$self->{named_files}{$name}`,
   populated by `register_named_files`.
3. **Config-declared alias** - `$self->{configured_named_files}{$name}`,
   lazily loaded from the layered config the first time any lookup
   reaches this point.
4. **A known no-arg accessor** - one of exactly eight names:
   `prompt_log`, `collector_log`, `dashboard_log`, `global_config`,
   `dashboard_index`, `auth_log`, `web_pid`, `web_state`.

Anything else dies with `Unknown file name '$name'`.

## Why step 4 is an allowlist, not `$self->can($name)`

Before DD-868, step 4 read `return $self->$name() if $self->can($name)`.
`can()` answers "does this class have a method by this name" - and
`FileRegistry` has 23 public/private methods, not 8. `can()` said yes to
every one of them: `new`, `paths`, `register_named_files`,
`unregister_named_file`, `named_files`, `all_files`, `all_file_aliases`,
`locate_files`, `locate_files_under`, `resolve_file` itself, and the five
file-mutating methods `read`/`write`/`append`/`touch`/`remove`.

That mattered because `resolve_file` is reached directly from raw,
unsanitized CLI text: `dashboard file resolve <name>` and
`dashboard file locate <root-or-alias> <term>`
(`lib/Developer/Dashboard/CLI/Files.pm`) pass whatever the user typed
straight in. A name that happened to match any other method name on the
class got dispatched to it - `resolve_file('all_files')` returned a raw
`HASH` reference instead of a path string (a contract violation visible
to a CLI user as a `HASH(0x...)` string), and the argument-taking
mutators only failed to do real damage by accident: calling
`read($self)`/`write($self)`/`remove($self)` with no further arguments
recursed into those methods with an undef target and died on an
unrelated guard, not because anything stopped the dispatch itself.

**The fix is a fixed allowlist checked before `can()`, not instead of
it:**

```perl
my %RESOLVABLE_ACCESSOR = map { $_ => 1 } qw(
  prompt_log collector_log dashboard_log global_config
  dashboard_index auth_log web_pid web_state
);
...
return $self->$name() if $RESOLVABLE_ACCESSOR{$name} && $self->can($name);
```

`can()` alone answers "is this callable"; the allowlist answers "is this
one of the eight names this fallback was ever meant to expose". Both
checks matter: the allowlist bounds *which* names are eligible, and
`can()` still guards against a name that is in the allowlist text but
somehow absent from the live class (a defensive belt-and-braces, cheap to
keep).

## The general shape, for the next accessor added to this class

Adding a ninth no-arg path-getter to `FileRegistry` means adding its name
to `%RESOLVABLE_ACCESSOR` explicitly - it is deliberately **not**
inferred from a naming convention (no `_log$`/`_path$` suffix match),
because a convention is exactly the kind of implicit rule a future method
can violate without anyone noticing. Any method that takes a required
argument, or mutates state, must never be added here regardless of its
name - this fallback exists only for cheap, safe, no-arg lookups.

## Related

`lib/Developer/Dashboard/CLI/Files.pm` is the only shipped caller of
`resolve_file` with genuinely external (CLI-typed) input; every other
caller in the tree passes a name it already controls (a registered alias,
a config-declared name). If a new CLI surface starts passing external
text into `resolve_file`, it inherits this same allowlist - no change is
needed there.
