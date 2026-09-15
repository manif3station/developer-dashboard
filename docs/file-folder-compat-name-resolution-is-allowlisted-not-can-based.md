# `File`/`Folder` compat-layer name resolution is allowlisted, not `can()`-based

What `Developer::Dashboard::File` and `Developer::Dashboard::Folder` (the
older bookmark-compatibility wrapper classes) actually do when resolving a
named alias, as distinct from what their `can()`-based lookup once did. This
page describes the current state of the system, not any one ticket.

## What changed

`File::_resolve_file` and `Folder::_resolve_path` both used to fall back to
`$obj->$where()` (or `$class->$where()`) whenever `$obj->can($where)` was
true - meaning ANY public method on the resolved object or class, not just
an intended path/file getter, could be reached by passing its name as an
alias. That is the same defect class already fixed in the sibling modules
`Developer::Dashboard::FileRegistry` (`resolve_file`) and
`Developer::Dashboard::PathRegistry` (`resolve_dir`).

Both `_resolve_file` and `_resolve_path` now check a fixed, compile-time
allowlist of the intended getter method names instead of `can()`. A name
that is not on the allowlist falls through to the class's own named-alias
table, its configured aliases, then an environment-variable override, in
that order - exactly as before, just without the open-ended `can()` step.

## Why this matters here specifically (and differently from DD-868/DD-870)

Unlike `FileRegistry::resolve_file` and `PathRegistry::resolve_dir`, which
are directly reachable from user input via `dashboard file resolve <name>`
and `dashboard path resolve <name>`, no call site in this codebase currently
passes a runtime-computed name into `File`/`Folder`'s dispatch - every
existing caller uses a static, hardcoded method name written in Perl source
(e.g. `Developer::Dashboard::Folder->all`).

What makes the fix worth doing anyway: `File`'s own POD SYNOPSIS documents
dynamic dispatch as an intended usage pattern for callers -
`my $numeric = Developer::Dashboard::File->$name();` - so this is a
documented public API surface that a future or external caller could
legitimately reach with a runtime-computed name. The fix is defense-in-depth
and consistency with the already-established sibling remedy, not a patch for
an actively-exploited path.

## How to use this page

If you are adding a new named alias to either class, add its accessor name
to the relevant allowlist rather than relying on `can()` to pick it up
automatically - that is the whole point of the fix. If you are investigating
whether a *different* module has the same `can()`-based dispatch defect,
check its actual call sites for a live user-input path before assuming
severity matches DD-868/870 - reachability, not just the code shape, decides
that.
