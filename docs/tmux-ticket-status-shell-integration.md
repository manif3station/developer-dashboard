# tmux ticket-status shell integration

## What it is

`share/private-cli/_dashboard-core` emits a shell function,
`_dd_apply_tmux_ticket_status`, into every interactive shell's init (zsh,
bash, sh, and a separate PowerShell block for Windows). When running inside
a tmux session, this function sets tmux's `status-format[0]`/`status-format[1]`
options to reflect the current workspace's ticket status, so the tmux status
bar shows live ticket context without the user doing anything.

## How it behaves per shell

The function body is near-identical across the POSIX-family blocks
(zsh/bash/sh) and calls `tmux set-option -g status-format[N] "..."` for each
status line. The PowerShell block implements the same behavior using
PowerShell's own argument-passing convention and is not affected by the
issue described below - PowerShell does not glob-expand bare arguments to
native commands the way POSIX shells do.

## The zsh glob-quoting requirement

**Every `status-format[N]` literal in the zsh/bash/sh blocks must be quoted.**

zsh treats an unquoted `[...]` word as a filename glob pattern (a character
class), and zsh's default `NOMATCH` option aborts the whole command when
that pattern matches no file in the current directory - which a literal
tmux option name like `status-format[1]` never will, since it is not a
real path. Unquoted, this crashes any interactive zsh shell that sources the
function with:

    _dd_apply_tmux_ticket_status:12: no matches found: status-format[1]

This is **not a shell syntax error** - `zsh -n` passes an unfixed file
cleanly, because the syntax is valid; it is a *runtime word-expansion
failure* specific to zsh's default glob behavior. bash and POSIX `sh`
silently leave a no-match unquoted glob as the literal word instead of
erroring, which is exactly why an unquoted `status-format[N]` ships unnoticed
on every host except a real interactive zsh session - the majority of CI and
container environments use bash or sh and never surface the bug.

## The regression guard

`t/224-tmux-status-format-zsh-glob-quoting.t` guards this two ways:

1. **Static scan (AC-1):** every `status-format[N]` literal in the extracted
   zsh/bash/sh blocks must be quoted (`(?<!['"])status-format\[[0-9]\](?!['"])`
   must match zero times).
2. **Live execution (AC-2/AC-3, SKIP-guarded per shell availability):** the
   real emitted zsh/bash/sh function bodies are extracted from the actual
   file and sourced under a real shell with a fake `tmux` stub on `PATH`,
   confirming the function actually runs clean - this is the assertion that
   would have caught the original bug, since the static scan alone only
   guards against regressing the fix in the exact shape it happened to fail,
   not against a differently-punctuated unquoted use elsewhere.

## When to update this page

Whenever `_dd_apply_tmux_ticket_status` or the tmux status integration in
`share/private-cli/_dashboard-core` changes - in particular, if a new
`status-format[N]`-shaped literal is added to any POSIX-family shell block,
it must be quoted from the start.
