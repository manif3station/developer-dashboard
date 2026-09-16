# GetOptions/GetOptionsFromArray's return value must be checked

## What this covers

Every CLI entrypoint in this project that parses `@ARGV` via `Getopt::Long`
(`GetOptions` or `GetOptionsFromArray`) must check the boolean it returns and
`die` with a clear usage message when it is false, rather than letting
execution continue silently.

## Why it exists

`Getopt::Long` returns a false value and prints `Unknown option: <name>` to
STDERR when it encounters a flag it does not recognize - but it does **not**
die, and it does not stop the caller's own flow. If the caller ignores the
return value, an unrecognized or mistyped flag (`--pint` instead of
`--print`, `--editr` instead of `--editor`) is silently dropped: the option
variable it would have set keeps its default, the rest of `@argv` is
otherwise unaffected, and the command proceeds as if nothing were wrong. The
only signal the user gets is a single, easy-to-miss `Unknown option: ...`
line on stderr - no non-zero exit, no clear message pointing at what went
wrong.

Found on `dashboard of`/`dashboard open-file`
(`Developer::Dashboard::CLI::OpenFile::run_open_file_command`, DD-911):
the function already had a correct `die "Usage: ...\n" if !@argv;` for the
"no arguments at all" case two lines below the `GetOptionsFromArray` call,
but never applied the same discipline to a parse failure - so a typo'd flag
silently used defaults and fell through to a confusing, unrelated error
later in the command instead of the clear usage message the caller
clearly intended for exactly this kind of user mistake.

## How to apply

```perl
my $options_ok = GetOptionsFromArray(
    \@argv,
    'print!'   => \$print,
    'line=i'   => \$line,
    'editor=s' => \$editor,
);

die "Usage: <command> [--print] [--line N] [--editor CMD] <file|scope> [pattern...]\n"
  if !$options_ok;
```

Place the check immediately after the `GetOptions*` call, using the same
usage message the command already gives for its other "the caller asked for
something the command cannot honor" cases, so a mistyped flag and missing
arguments read as the same class of user error rather than two different
failure modes.

## What uses it

`Developer::Dashboard::CLI::OpenFile::run_open_file_command` (DD-911). Any
other CLI entrypoint in this project that calls `GetOptions`/
`GetOptionsFromArray` and does not yet check the return value carries the
same latent defect and should be checked against this page.
