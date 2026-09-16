# `dashboard of`/`open-file`: a failed editor exec must never look like success

## What this page describes

The error-handling contract for `Developer::Dashboard::CLI::OpenFile`'s final
step: launching the resolved editor on a single matched file.

## The contract

When `dashboard of`/`open-file` resolves to exactly one file (or the user
picks one from a multi-match chooser) and `--print` was not given, it builds
an editor command (`_default_editor` plus any `-p`/`+N` flags) and hands it to
`_command_exec`, which replaces the current process via Perl's `exec`.

`exec` only returns if it **fails** - a missing binary, a non-executable
file, a `PATH` problem, or any other reason the OS refuses to run the
command. `_command_exec` treats that return as a hard failure: it dies with
`Unable to run editor '<command>': $!`, naming the exact command that could
not be launched and the OS-level reason (`$!`).

This matters because Perl's own `exec` semantics make the silent case easy to
reach: `exec` returning false is not an exception, so code that calls it as
its last statement and does nothing afterward completes normally. Without the
explicit `die`, a broken `$EDITOR`, a typo in `--editor`, or a `--editor` path
that stops existing would make `dashboard of` exit 0 having opened nothing -
indistinguishable from success except for a warning line on stderr that `use
warnings` produces only because `exec` itself was told to warn, not because
this module asked it to.

## Why it exists

This project's own convention is that errors are never silently suppressed.
A file-opening command that "succeeds" without opening anything is exactly
the shape of bug that convention exists to prevent - discovered live (DD-910)
by reproducing a bad `--editor` value and observing exit 0 with only an
easy-to-miss Perl warning as the only signal anything went wrong.

## When to use

Read this page when changing `_command_exec`, `_default_editor`, or anything
else in the editor-launch path at the end of `run_open_file_command` - the
invariant to preserve is: **a failed launch must always be a non-zero exit
with a message naming what failed to run**, never a silent fall-through.

## How to use

Nothing to call directly - this is the internal contract `_command_exec`
implements. A test exercising it calls the private sub directly with a
nonexistent binary and asserts the die message, since a real successful
`exec` would replace the test process itself.

## What uses it

`run_open_file_command`'s final step (both the direct single-match path and
the multi-match chooser's resolved selection) call `_command_exec` as their
last action. `t/98-cli-openfile-coverage.t` asserts the failure-path
contract directly.
