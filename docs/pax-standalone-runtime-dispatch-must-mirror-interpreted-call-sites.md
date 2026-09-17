# Pax standalone runtime dispatch must mirror interpreted call sites exactly

What `StandaloneRuntime.pm`'s hand-written dispatch functions are for, why
they exist separately from `bin/dashboard`'s own interpreted top-level code,
and the failure mode when the two drift out of sync.

## The problem

`bin/dashboard` is compiled into a standalone binary as an entrypoint unit
whose dispatch logic is generated as a `dashboard.cli-router.json` manifest
entry (a `bootstrap_source` string, eval'd under a `#line` remap so runtime
errors report against a virtual `entrypoint.pl` path rather than the real
generated source). `StandaloneRuntime.pm`'s `_run_cli_router_unit` is the
code that actually *executes* that dispatch: it re-implements the same
top-level sequence `bin/dashboard` runs when interpreted directly - loading
runtime env, priming command-result state, resolving the command to a
built-in helper, a layered custom command, or a skill's dotted dispatch.

Because this is a **second, hand-written implementation** of the same
sequence rather than a shared code path, nothing enforces that its function
calls stay argument-for-argument identical to the real interpreted call
sites they mirror. A signature that gains, loses, or reorders a parameter
in one place and not the other compiles cleanly - Perl does not check
call-site arity against a sub's `my (...) = @_;` unpacking - and only
fails at runtime, on whichever code path the mismatched argument actually
reaches.

## The failure shape (DD-934)

`bin/dashboard`'s real top-level code:

```perl
my $main_gate_results = _run_main_gate_hooks( $cmd, @ARGV );
_prime_command_result_env( $cmd, $main_gate_results, @ARGV ) if $cmd ne '';
```

`StandaloneRuntime.pm`'s `_run_cli_router_unit`:

```perl
_code_for('main::_prime_command_result_env')->($cmd, @ARGV)
    if $cmd ne '' && _code_for('main::_prime_command_result_env');
```

The standalone call site omits `$main_gate_results` entirely. `@ARGV`
shifts left into that slot, so `_prime_command_result_env`'s own
`my ( $cmd, $main_gate_results, @argv ) = @_;` silently binds the first
real argv token (e.g. `--help`) to `$main_gate_results` instead of a
hashref. The function's body already tolerates an absent/undef value
(`%{ $main_gate_results || {} }` falls back to an empty hash cleanly) -
which is exactly why a **bare command name with no trailing argv** never
crashed. The moment any argv token follows the command, that fallback
dereferences a plain string instead, and Perl's `strict refs` fatally
rejects it.

## Why this was hard to find

The reported error names a virtual, placeholder path
(`.../code/virtual/entrypoint.pl`) that is not the real generated source -
that placeholder exists on disk as a literal 2-line stub
(`# PAX compiled unit placeholder ...\n1;`). The actual executing text is
JSON-embedded as `bootstrap_source` inside the entrypoint's own manifest
file under the build's cache directory
(`code/entrypoint/dashboard.cli-router.json`), reachable only by reading
that JSON directly and counting lines from `#line 1` - a debugger or a
plain `grep -n` against the checkout finds nothing, because the crashing
source does not exist as a checked-in file at all until a real build
generates it.

## How to apply

- When adding or changing a call to any function `bin/dashboard` and
  `StandaloneRuntime.pm` both invoke, update **both** call sites in the
  same change, and verify by building a real compiled binary and
  exercising it - not by reading the source alone, since arity mismatches
  are invisible until runtime.
- When a standalone-binary crash names a `virtual/*.pl` path, the real
  source is the corresponding entrypoint's own manifest JSON's
  `bootstrap_source` (or `script_source`, for `.script.json` units) under
  that build's `pax-standalone-cache-*/code/entrypoint/` directory - read
  it directly, do not search the checkout for the named virtual path.
- A crash that only reproduces with certain argv shapes (present vs.
  absent, one token vs. none) is a strong signal of an arity mismatch
  between a call site and the function it calls, not a data-content bug -
  check the argument COUNT at each call site before investigating the
  values.
