# The .d2 directory alias

How the Developer Dashboard recognises `.d2` as a shorter name for
`.developer-dashboard`. This page describes the system, not any one ticket.

## What this is

`.developer-dashboard` is DD-OOP-LAYERS' runtime layer directory name, used at
every layer from `~` down through the cwd's parents. It is also long to type
repeatedly. `.d2` is a shorter alias for the same directory, recognised at both
the home layer (`~/.d2`) and any project layer (`$PWD/.d2`).

This is a naming alias, not a second runtime concept: a layer resolved through
`.d2` behaves identically to one resolved through `.developer-dashboard` in
every other respect — config merging, hooks, collectors, local/lib/perl5, all of
it. Only the directory name recognised at each layer changes.

## Precedence when both names exist

A single layer can in principle hold both `.d2/` and `.developer-dashboard/`
side by side — nothing prevents a user from creating one after already having
the other. When that happens:

> **`.developer-dashboard` is checked first. `.d2` is used only when
> `.developer-dashboard` is absent.**

This is a **read-order fallback**, not a merge and not a refusal: the two
directories' contents are never combined, and having both present is not an
error. Whichever one resolution finds first at a given layer is the one that
layer uses, in full.

## Fresh writes

A layer that does not yet exist at all — the first time `dashboard init` or an
equivalent write touches that directory — is created as `.developer-dashboard`,
following the same precedence: nothing exists yet to prefer between, so the name
checked first is the name written.

## Where it is decided

Resolution goes through the same layer-discovery code that already owns
`.developer-dashboard` — `PathRegistry`'s home-runtime and project-layer
resolution (`home_runtime_path`, `_ancestor_runtime_layers`, and the
`config_root`/`runtime_root` family built on top of them). The alias is
recognised at the same point every one of those already checks for
`.developer-dashboard`, so no caller of `PathRegistry` needs to know the alias
exists — one point of change makes every consumer alias-aware.

## What this page does not cover

Whether the main gate script (`d2`/`dashboard`) itself grows a matching short
hook-folder convention (`.d2/hooks/`) is a separate feature — see DD-810.
