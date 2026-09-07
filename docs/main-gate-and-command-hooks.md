# Main-gate hooks and per-command hooks

The `dashboard` / `d2` switchboard runs two kinds of operator hook before a
command executes. They share one input/output contract and differ, on purpose,
in two places: the order layers are visited, and what `[[STOP]]` does. This page
describes what each stage IS and how it behaves; it is not a record of any one
change.

## The two stages

| stage | directory, per layer | fires | order across layers | `[[STOP]]` |
|---|---|---|---|---|
| main gate | `<layer>/.developer-dashboard/hooks/` | once per invocation, before command resolution | **deepest layer first, home LAST** | **aborts**: remaining hooks skipped, command does not run, exit 1 |
| per-command | `<layer>/.developer-dashboard/cli/<cmd>.d/` | once per invocation of `<cmd>`, after resolution, before exec | **home first, deepest LAST** | stops the remaining hooks in that chain; the command still runs, exit 0 |

Both stages walk the DD-OOP-LAYERS stack: every `.developer-dashboard/`
directory from `$HOME` down through the working directory's parents contributes
its hooks. A layer without the directory is skipped silently. Within one layer
the files run in lexical order (`10-gate.sh` before `20-mark.sh`), which is the
only ordering the product offers — there is no registry and no config-declared
hook list.

## The shared contract (identical in both stages)

- **argv.** Every hook receives the full command line, command word first. For
  `d2 version --json` the hook's `@ARGV` is `('version', '--json')`. A hook
  cannot rewrite the arguments the command will receive.
- **stdout.** Streamed to the terminal as the hook produces it, through the same
  streaming runner the per-command chain uses, so a slow hook shows progress
  rather than a pause.
- **RESULT / LAST_RESULT.** Each hook's captured stdout, stderr and exit code are
  recorded under the same keys the per-command chain writes, so a later hook —
  or the command itself — can read what an earlier one did.
- **stderr is the control channel.** A hook asks to stop by printing the literal
  marker `[[STOP]]` on stderr. Nothing on stdout is interpreted.
- **Recursion guard.** A hook that itself runs `dashboard` or `d2` does not
  re-fire the main gate; the guard is the same one the per-command chain uses,
  and `d2`'s re-exec of its sibling `dashboard` fires each stage exactly once.
- `dashboard which <cmd>` lists every hook that would run for `<cmd>`, both
  stages, one `HOOK` line each, in the order they would run.

## The two deliberate differences

### Order is reversed

Per-command hooks run **home first**: the widest layer sets defaults and the
deepest layer, nearest the work, gets the last word before the command.

Main-gate hooks run the other way: **deepest first, home last**. The main gate
is where a *gate* lives — "is there a ticket for this?", "is the board
reachable?" — and the layer closest to the work knows most about whether this
invocation should proceed at all, so it speaks first. Home speaks last, as the
outermost check that sees the invocation after every project-level hook has
had its turn.

Worked example: `~/.developer-dashboard/hooks/foo.pl` and
`$PWD/.developer-dashboard/hooks/bar.pl` (PWD inside HOME), each printing its
own name. `d2 version` prints `bar.pl`, then `foo.pl`, then the version line.
Run from a directory whose stack has no project-level `hooks/`, only `foo.pl`
prints. The same two files placed under `cli/version.d/` would print
`foo.pl` then `bar.pl`.

This reversal is intentional and is asserted by the test suite; a change to
either order is a design change, not a fix.

### `[[STOP]]` aborts at the main gate, and only there

In the per-command chain, `[[STOP]]` ends the remaining hooks of that chain and
the command then runs normally with exit status 0. The chain is advisory
preparation for the command, and stopping it early is a way of saying "the rest
is not needed".

At the main gate, `[[STOP]]` is a refusal. When a main-gate hook prints the
marker:

- the remaining main-gate hooks are skipped;
- **the command does not run** — no per-command chain, no dispatch, no exec;
- `dashboard` exits **1**;
- the hook's stderr, marker included, is left visible so the operator sees why.

Worked example: `hooks/10-gate.sh` prints `blocked: no ticket` and then
`[[STOP]]` to stderr and exits 0. `dashboard version` prints nothing on stdout,
its stderr carries both lines, its exit status is 1, and a later
`hooks/20-mark.sh` leaves no marker file. Remove the `[[STOP]]` line and the
same invocation exits 0, prints the version, and `20-mark.sh` runs.

So there is no single STOP contract across the two stages, and that is the
design: a gate that let the command run after refusing it would not be a gate.
The per-command behaviour is unchanged and remains what it always was.

## Why a hook goes in one stage rather than the other

- Something that must hold for **every** command — a ticket check, an
  environment sanity check, an audit line — belongs in `hooks/`.
- Something that prepares or observes **one** command — staging a file before
  `build`, recording a timestamp after `push` — belongs in `cli/<cmd>.d/`.
- Something that must **prevent** a command from running belongs in `hooks/`,
  because only the main gate can refuse.

## Checking what will run

```
dashboard which version
```

prints the resolved command and a `HOOK` line for each hook in each stage in
execution order. If a hook you expect is missing, the layer is not in the
stack for the current directory (the stack is discovered from `$PWD`, not from
the location of the hook file).

## Where this is decided

Order, layer participation, the shared contract and the STOP semantics were
decided on the board (questions Q-142, Q-143, Q-144, Q-149 on DD-810) and are
pinned by `t/05-cli-smoke.t`, `t/49-d2-entrypoint.t` and
`t/166-dashboard-d2-handle.t`. The POD in `bin/dashboard` carries the same
contract for the installed product; this page is the vault's system-level view.
