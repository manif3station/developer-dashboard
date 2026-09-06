# Runtime layer file permissions

What modes the Developer Dashboard gives the files and directories it writes
into a runtime layer, and where that is decided. This page describes the system,
not any one ticket.

## What a runtime layer is

DD-OOP-LAYERS makes every `.developer-dashboard/` directory from `~` down
through the cwd's parents part of one inherited runtime stack. **The deepest
layer is the write target.** So the same code, run from two different working
directories, writes the same file into two different places — and both are
runtime layers in the sense that matters here: they hold the product's own
state, not the user's documents.

## What lives there, and why the mode is a security property

A runtime layer is not a cache. It holds:

| file | what it is |
|---|---|
| `config/api.json` | machine-tier API key **secret digests**, and each key's `/ajax/` route allowlist |
| the session store | helper login sessions, bound to a remote address |
| the auth store | helper password records |
| `local/lib/perl5` | code the product loads |

Two of those are credentials at rest and one is executable. The mode on the
containing directory matters as much as the mode on the file:

- **Group-readable file** — another local account reads the API secret digests.
- **Group-writable directory** — another local account *replaces* the file
  outright, regardless of the file's own mode, and registers a key of their own.
  That is a machine-tier authentication bypass, and it is why fixing the file
  mode alone is not a fix.

CWE-732 states the rule the product follows: user permissions at least group's,
group's at least other's (`u >= g >= o`). `0600` inside `0700` satisfies it.

## The guarantee

> **Every file the product writes into ANY runtime layer lands `0600`, inside a
> directory that is `0700` — and a directory is CREATED at `0700` rather than
> tightened afterwards.**

"Any" is the load-bearing word, and it is the part that was historically wrong:
the securing helpers were gated on the *home* runtime only, so a project-local
layer — the write target whenever one exists — kept whatever the umask gave it.
Under the common `umask 002` that is `0664` inside `0775`.

## Where it is decided

One predicate, consulted by everything:

- `PathRegistry::is_runtime_layer_path` — does this path belong to a layer we own?
- `PathRegistry::runtime_layer_root_for` — which layer owns it?

`secure_file_permissions`, `secure_dir_permissions` and `_ensure_dir` all gate on
that predicate. **Fixing the gate is what makes the guarantee hold for every
writer**, including the ~40 call sites that do not go through
`atomic_write_secure`.

### Two implementation constraints that are not obvious

**`runtime_layer_root_for` must not call `runtime_layers`.** That accessor
resolves the home runtime *root*, which calls `_ensure_dir`, which calls
`secure_dir_permissions`, which calls back into the predicate — unbounded
recursion that hangs any process touching a runtime path. Build the candidate
list from the non-creating sources instead: the pure path computation, the
environment override, and the ancestor-layer walk, none of which create
anything.

**Nothing outside a runtime layer is chmodded at all.** The predicate is a gate
in both directions. A product that tightened arbitrary paths because they were
passed to it would be a different and worse bug.

## Checking it

The check is three lines and one trap:

```perl
umask 002;                       # PIN it. Do not inherit.
# ... write into a project-local layer ...
printf "%04o\n", (stat $file)[2] & 07777;
```

**Pin the umask.** Under a strict umask the file arrives at `0600` by accident
and the check passes while discriminating nothing.

**Assert that the layer was actually discovered.** This is the trap that has
produced false all-clears more than once: a probe whose synthetic project root
is not recognised as a layer reports `0600`/`0700` because *no securing code ran
at all*, which is indistinguishable from the secure result. So print a positive
marker —

```perl
my @layers = $reg->runtime_layers;
print "project_layer_discovered=", ( grep { index($_, $proj) == 0 } @layers ) ? 1 : 0, "\n";
```

— and treat a run without it as *could-not-look*, never as clean. A secure-
looking mode from an undetected layer is the same class of error as a green
suite that skipped the file under test.

**Run it in a container.** Creating runtime layers on the development host
writes into the checkout's own `.developer-dashboard`, so a probe that skips the
`chdir` into a scratch root pollutes the tree it is measuring.

## Related

- `docs/path-containment.md` — where a path may point. This page is the other
  half: what mode it gets once it is somewhere legitimate. A path can be
  perfectly contained and still world-readable.
- `docs/timing-side-channels-in-authentication.md` — the other finding from the
  same ASVS review pass, and a reminder that a function can be hardened against
  a fine channel while a coarser one beside it goes unaddressed.
