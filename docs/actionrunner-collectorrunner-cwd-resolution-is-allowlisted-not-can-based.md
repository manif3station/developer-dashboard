# `ActionRunner`/`CollectorRunner` cwd resolution is allowlisted, not `can()`-based

What `Developer::Dashboard::ActionRunner::run_command_action` and
`Developer::Dashboard::CollectorRunner::run_once` actually do when a
config-supplied `cwd` value is not an absolute path, as distinct from what
their `can()`-based lookup once did. This page describes the current state
of the system, not any one ticket.

## What changed

Both subs used to fall back to `$self->{paths}->$cwd()` whenever
`$self->{paths}->can($cwd)` was true - meaning ANY public method on the
bound `PathRegistry` object, not just an intended no-arg directory getter,
could be reached by an action's or collector job's `cwd` config value
happening to collide with a method name. That is the same defect class
already fixed in `FileRegistry::resolve_file` (DD-868),
`PathRegistry::resolve_dir` (DD-870), and `File`/`Folder`'s compat-layer
resolution (DD-878) - reached here from the opposite direction: these two
callers dispatch *into* `PathRegistry` from external job/action config,
rather than `PathRegistry` dispatching into itself.

Both now check a local, compile-time allowlist of the intended getter
names instead of `can()`. A `cwd` that is not on the allowlist is left
unchanged and handled exactly as before: checked with `-d` and rejected
with a clear `does not exist` error if it is not a real, existing
directory.

## Why a local allowlist, not a shared call into `PathRegistry::resolve_dir`

`PathRegistry::resolve_dir` already does an equivalent allowlist check
internally, but it is not a safe drop-in replacement here: `resolve_dir`
also consults `named_paths` and **dies** on an unresolvable name, while
`run_command_action`/`run_once` need the opposite fallthrough - an
unresolved `cwd` must continue on as a literal (possibly relative) path
for the existing `-d` check to accept or reject, not raise an internal
`PathRegistry` error. Existing test coverage
(`t/81-actionrunner-coverage.t` and `t/103-collectorrunner-coverage.t`)
already pins this exact contract, including a `cwd` value that is neither
absolute nor a known accessor running as a literal relative directory - so
the fix keeps the local allowlist rather than widening behavior to match
`resolve_dir`'s stricter contract.

## How to use this page

If you are adding a new named `PathRegistry` accessor that a `cwd` value
should be able to reach through this path, add its name to the local
allowlist in whichever of these two files needs it - `can()` picking it up
automatically is exactly the shape this fix removes. If you are
investigating whether a *different* caller has the same `can()`-based
dispatch defect, check what object the dispatch target actually is and
whether the caller needs `resolve_dir`'s strict die-on-unknown contract or
a softer fallthrough like this one - the right fix differs by contract,
not just by defect shape.
