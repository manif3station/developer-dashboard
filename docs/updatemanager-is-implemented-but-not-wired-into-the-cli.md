# `UpdateManager` is implemented and tested, but not wired into the CLI

What `Developer::Dashboard::UpdateManager` actually does in the shipped
product today, as distinct from what its own POD narrative once implied.
This page describes the current state of the system, not any one ticket.

## What exists

`lib/Developer/Dashboard/UpdateManager.pm` is a complete, working module:
it runs ordered update scripts from an `updates/` directory and can restart
validated collector loops. It has a real constructor contract (it dies if
constructed without a config, a file registry, a path registry, or a
collector runner - see `t/08-web-update-coverage.t`'s `Missing ...` death
tests) and a dedicated unit-test suite (`t/04-update-manager.t`,
`t/62-updatemanager-coverage.t`, plus fixture coverage inside
`t/08-web-update-coverage.t` and `t/21-refactor-coverage.t`).

## What does not exist

**No code path in the shipped product ever instantiates it.** Grepping the
whole tree outside `UpdateManager.pm` itself and its own test files for
`UpdateManager` returns zero hits - not in `bin/dashboard`, not in
`bin/d2`, not in any `share/private-cli/*` command body, not in
`RuntimeManager.pm` or `InternalCLI.pm`, which are the two modules that
would plausibly call it during a bootstrap or upgrade flow.

So today: running `dashboard upgrade` (a real, different, documented
command - see its own usage line) does not touch this module at all. No
`updates/` directory is ever scanned by anything a user can trigger. No
collector loop is ever restarted through this path. The class is exercised
exclusively by its own tests, instantiating it directly.

## Why the module still exists this way

Confirmed with the project owner (DD-867, Q-155, answered 2026-09-14):
this is intentional, forward-looking groundwork for a bootstrap/upgrade
command that has not been cut over yet - not dead code to delete, and not
a wiring gap to close right now. The main distribution POD (in
`lib/Developer/Dashboard.pm`'s architecture overview) was corrected in the
same change to stop implying the module is an active part of the running
system's upgrade path, since that implication was false of the product as
shipped.

## A secondary, still-open observation

`UpdateManager::updates_dir` resolves its target directory via a bare
`cwd()` rather than through `Developer::Dashboard::PathRegistry`, which is
inconsistent with how every other layer-aware component in this codebase
resolves paths (see the `DD-OOP-LAYERS` architecture note). This was
deliberately left unchanged by DD-867 - the owner's decision was POD-only,
and `updates_dir`'s resolution strategy is explicitly out of that ticket's
scope. It remains true, and worth fixing whenever this module is actually
wired up.

## How to use this page

If you are about to wire `UpdateManager` into the CLI, or about to remove
it as dead code, read this page first: the "why it isn't wired up" answer
already exists (intentional groundwork, owner-confirmed), so the open
question is only ever "is it time to cut it over now", not "why wasn't
this done".
