# Capture::Tiny's `capture { system(...) }` returns the raw wait-status, not the exit code

## What this part of the product is

Several places in this codebase run an external command and capture its
stdout/stderr with `Capture::Tiny::capture`, where the block's last
statement is a bare `system(@argv)`:

```perl
my ( $stdout, $stderr, $exit ) = capture {
    system(@argv);
};
```

## How it behaves

`Capture::Tiny::capture()` returns the coderef's own return value(s) as its
trailing list elements — it does not modify or interpret them in any way.
Perl's `system()` builtin, in turn, always returns the raw wait-status
(the same value `$?` holds afterward): the low byte is the signal number
(if the process was killed by a signal), and the exit code the child
process actually returned sits in the *next* byte up.

So `$exit` above is `$?`, **not** the exit code. A child that calls
`exit(1)` produces a raw wait-status of `256`, not `1`. Using `$exit`
directly as an `exit_code` value is wrong for any exit code other than 0
(where both readings happen to agree).

**The fix is the same one-line shift used everywhere else in this codebase
that reads `$?` after `system()`:**

```perl
my ( $stdout, $stderr, $exit ) = capture {
    system(@argv);
};
my $exit_code = $exit >> 8;
```

## Why it bites specifically here

Perl's `exit()` builtin truncates its own argument to 8 bits at the OS
boundary — `exit(256)` becomes OS exit status `0`. So a raw wait-status
value, if later handed straight to `exit()` (directly or via a chain of
hash lookups reaching a top-level dispatcher), silently reports **success**
for a process that genuinely failed. This is not a cosmetic bug: it
produces a false-positive exit code at the process boundary, which is
exactly the boundary automation (CI, scripts, other callers) checks.

## When to use this

Any time a `capture { ... system(...); }` block's trailing value is read as
an exit code — not just the moment of writing the code, but every code
review of a diff that touches one. Grep for
`capture\s*\{[^}]*system\(` and confirm the exit-code use downstream of it
shifts by 8, exactly like a direct read of `$?` would.

## What uses it / historical instances

- `Developer::Dashboard::SkillDispatcher::run_command` (single-command
  dispatch path) and its `execute_hooks` multi-hook loop both had this bug
  — DD-883, 2026-09-16. A third call site in the *same file* already used
  the correct `$? >> 8` pattern, which is what made the inconsistency
  visible: one file, one convention, two of three sites wrong.
- The broader "a query must not decide its caller's exit status" lesson
  (guarding `$?`/`local $?` around any code whose *own* exit status must
  not leak into a caller that later reads `$?` for something else) is a
  related but distinct concern, established earlier as DD-585/589-593/597
  and DD-670 and documented in `docs/process-supervision.md`. That lesson
  is about **isolating** `$?`; this page is about **reading it correctly**
  once it is the value you actually want.

## Examples

```perl
# WRONG - reports the raw wait-status as the exit code
my ( $stdout, $stderr, $exit ) = capture { system(@argv); };
return { exit_code => $exit };   # exit(1) in the child -> 256 here

# RIGHT
my ( $stdout, $stderr, $exit ) = capture { system(@argv); };
return { exit_code => $exit >> 8 };   # exit(1) in the child -> 1 here
```
