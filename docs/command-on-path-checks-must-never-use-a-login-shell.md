# A command-availability check must never shell out through a LOGIN shell

Several places in this test suite need to answer "is `<command>` on PATH?"
by shelling out to `command -v <name>`. Whenever that check is built as a
**login** shell invocation (`sh -lc "..."`, the `-l` flag), it can produce a
false negative for a command that genuinely exists.

## The mechanism

`-l` makes the shell behave as if it were a fresh interactive login: it
sources `~/.profile`, which on a normal Debian/Ubuntu install sources
`~/.bashrc`. If **anything** in that chain is not valid syntax for the
shell actually running it - and `/bin/sh` on this project's dev hosts is
`dash`, not `bash` - the shell dies with a syntax error **before the
command being checked ever runs**.

This host's own `~/.bashrc` carries exactly such a line:
`eval "$(SHELL=/bin/sh lesspipe)"`. `lesspipe`'s emitted code assumes a
bash-compatible `eval` target; under dash it produces
`Syntax error: "(" unexpected`. `sh -lc "command -v docker >/dev/null 2>&1"`
therefore exits non-zero **for every command name**, including ones that
are genuinely installed - `system()` cannot distinguish "the shell died
sourcing an unrelated profile line" from "the command is absent", so a
caller checking the exit code alone reports the latter.

## Why this is not a rare edge case

Bash-specific, interactive-only content in `~/.bashrc` (colour prompts,
`lesspipe`, completion hooks, an interactive alias) is the **norm** for a
real developer machine, not the exception. Any test or tool that shells
out with `-l` inherits every line of it, on every host it runs on, whether
or not that content has anything to do with the command being checked.

## The fix

Never use `-l`. A plain, non-login shell needs no profile at all, which is
both simpler and the portable, standard way to check command availability:

```perl
# WRONG - login shell, sources ~/.profile -> ~/.bashrc unconditionally
system( 'sh', '-lc', "command -v $name >/dev/null 2>&1" );

# RIGHT - no login, no profile, and $name passed positionally rather than
# interpolated into the command string (so it can never be read as shell
# syntax, regardless of what a future caller passes)
system( 'sh', '-c', 'command -v "$1" >/dev/null 2>&1', 'sh', $name );
```

## Reviewing a change against this

- **Grep for `'-lc'`/`-lc` in any `system()`/`` `backticks` ``/`open` shell
  invocation before adding a new one.** A login shell is almost never what
  a scripted, non-interactive check actually wants - it wants the same
  environment inheritance a plain `-c` already gives it, without the
  profile-sourcing side effect.
- **A "command not found"-shaped failure from a check like this is not
  proof the command is absent.** Reproduce the check directly
  (`sh -lc "echo test"`, no command name at all) before trusting its
  verdict - if that alone fails, the check's shell invocation is broken,
  not the thing it claims to be checking.
- **Prefer positional arguments (`$1`, `$2`, ...) over string
  interpolation whenever a shell command needs to receive a value that
  did not come from a hardcoded literal.** It costs nothing here and
  removes an entire class of injection risk for any future caller.
