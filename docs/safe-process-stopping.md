# Stopping a foreign process safely

How an operator or agent working this repository stops a stray gate or
coverage process without risking a process belonging to another project. This
page describes the tool, not any one ticket.

## The problem this solves

A gate that must be abandoned (contended, hung, or launched by mistake) needs
something stopped. The obvious approach — match a pattern against
`/proc/*/cmdline` and kill whatever matches — is unsafe, because a cmdline
substring cannot tell a process **performing** an operation from a process
whose **arguments merely mention it**.

That distinction bit for real: a coverage gate was stopped by matching
`*Devel::Cover*` against every process's cmdline, and the same pattern matched
a codex code-review process in an unrelated project, because its review prompt
discussed `Devel::Cover` as text. The review died; the coverage run was not
even the same kind of process.

## The rule

> **Selection for a stop is by `/proc/<pid>/comm` — the actual running
> executable — never by a cmdline substring.** A candidate whose ownership
> (`/proc/<pid>/cwd`) cannot be established is excluded, not assumed either
> way. Every kill target is re-verified against the same criteria at the
> moment of the kill, never trusted from an earlier listing — a PID can be
> reused between a report and an action taken on it.

## The tool: `.claude/tools/safe-stop`

Operator tooling (`.claude/tools/` is not part of this repository's git
history — see `docs/docs-vault-vs-doc-directory.md` for that distinction), so
this is documented here for anyone reading the vault, but shipped only on this
machine.

```sh
# Report only - never kills anything
safe-stop --comm 'prove|cover' --report

# Stop specific, already-reported PIDs
safe-stop --comm 'prove|cover' --pid 12345 --pid 12346 --confirm
```

`--pid` without `--confirm` is a refusal, not a guess: it stops a caller from
wiring a report's output straight into a kill without a deliberate second
step. Every candidate the report lists carries its full cmdline for a human to
read — cmdline is still useful information, it is simply never the thing
`safe-stop` decides on.
