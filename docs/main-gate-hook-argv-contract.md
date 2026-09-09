# Main-gate hook argv contract

`bin/dashboard`'s main-gate hooks (files directly under a runtime layer's
`hooks/` directory - see `docs-vault-vs-doc-directory.md`'s sibling page on
per-command `<command>.d/` hooks for that mechanism) run before the top-level
command is even resolved. Every hook receives the exact same `@ARGV` the
target command itself would receive - the top-level command name is never
prepended.

## The mechanism

`bin/dashboard` reads its own `@ARGV` as `($cmd, @argv)` - `$cmd` is shifted
off first, so everything downstream of that point works with `@argv` alone.

1. `$ENV{DEVELOPER_DASHBOARD_COMMAND}` is set to `$cmd` *before* main-gate
   hooks run (moved from `_prime_command_result_env`, which only ran later
   for per-command hooks).
2. `_run_main_gate_hooks` invokes each hook with exactly `@argv` - not
   `($cmd, @argv)`.
3. The eventual command target is `exec`'d with the same `@argv` too (this
   was already true before DD-832 - only the hook side changed).

So for `d2 path list abc def`: `$cmd` is `path`, `@argv` is
`(list, abc, def)`. A main-gate hook sees `@ARGV = (list, abc, def)` - byte
for byte what the `path` command handler itself receives - and can read
`$ENV{DEVELOPER_DASHBOARD_COMMAND}` to learn which command is about to run,
since that information no longer travels through argv.

## What does not change

Per-command hooks (`cli/<command>.d/`, run once the command *has* been
resolved) already received the correct argv and are unaffected.

## Origin

Michael specified this directly (2026-09-09): a hook must always get the
same arguments as the main command. Confirmed the prior mismatch live in a
`developer-dashboard:latest` container before filing - the top-level command
name was being prepended to the hook's argv, unlike the target itself.
Tracked as DD-832.
