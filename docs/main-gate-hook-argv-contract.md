# Main-gate hook argv contract

`bin/dashboard`'s main-gate hooks (files directly under a runtime layer's
`hooks/` directory - see `docs-vault-vs-doc-directory.md`'s sibling page on
per-command `<command>.d/` hooks for that mechanism) run before the top-level
command is even resolved. Every hook receives the exact `@ARGV` the user
typed after `d2`/`dashboard` - the top-level command name IS included, as its
first element.

## The mechanism (current, DD-835)

`bin/dashboard` reads its own `@ARGV` as `($cmd, @argv)` - `$cmd` is shifted
off first for its own dispatch logic, but the hook is handed the command name
back:

1. `$ENV{DEVELOPER_DASHBOARD_COMMAND}` is set to `$cmd` before main-gate
   hooks run - an independent, additional signal (harmless, left in place
   from DD-832).
2. `_run_main_gate_hooks` invokes each hook with `($cmd, @argv)` - the exact
   sequence the user typed.
3. The eventual command target is `exec`'d with `@argv` alone (unchanged) -
   so the hook's argv and the target's argv differ by exactly the leading
   command name.

So for `d2 foobar a b c`: `$cmd` is `foobar`, `@argv` is `(a, b, c)`. A
main-gate hook sees `@ARGV = (foobar, a, b, c)` - the full invocation as
typed - and can also read `$ENV{DEVELOPER_DASHBOARD_COMMAND}` as a redundant
way to learn the same thing.

## What does not change

Per-command hooks (`cli/<command>.d/`, run once the command *has* been
resolved) receive `@argv` alone (no command name) and are unaffected by this
change - they were never in scope for either DD-832 or DD-835.

## Origin

DD-832 (2026-09-09) first implemented the *opposite* contract - hooks got
`@argv` alone, matching the target command exactly, per an earlier
description from Michael. He reversed that directly over Telegram
(msg #1834, 2026-09-10): `d2 foobar a b c` must give a main-gate hook
`@ARGV = (foobar, a, b, c)`, not just `(a, b, c)`, specifically so the hook
can tell which command is running from argv itself. Tracked as DD-835.
