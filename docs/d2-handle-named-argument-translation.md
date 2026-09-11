# d2()'s chained calls translate named arguments to CLI flags

`Developer::Dashboard::Handle::Proxy` gives in-process Perl code a way to
call any `dashboard`/`d2` subcommand as a chain of bareword method calls,
terminated by a call: `d2()->collector->list->()` shells out to `dashboard
collector.list`. DD-739 extends that convenience to arguments: a call like
`d2()->somecmd(arg1 => 1)->()` now shells out as `dashboard somecmd --arg1
1`, instead of the literal, un-flagged `somecmd arg1 1` it produced before.

## Why arity is the only rule that can exist

Perl has no way to distinguish `('arg1' => 1)` from `('arg1', 1)` at
runtime - the fat comma (`=>`) is purely a parse-time stand-in for a plain
comma, and both spellings produce the identical two-element list once the
method is actually called. So the translation layer cannot ask "was this
written as a named-argument pair" - that information does not survive
into the call. It can only ask a question the list itself can answer:
**does it divide evenly into pairs?**

- An **even-length** argument list is treated as a complete set of
  `key => value` pairs, and each pair becomes `"--$key", $value` in the
  shelled-out argv.
- An **odd-length** argument list (including a single argument) can never
  be a complete set of pairs, so it is passed through unchanged as
  positional arguments instead.

This means a command that genuinely needs two or more positional
arguments cannot be spelled through the named-argument convenience form -
`Handle::run()` remains the verbatim escape hatch for that case, exactly
as it already was before this card (see `d2()->run('collector', 'list')`
in the module's own POD, which takes its words as plain positional argv
with no translation applied).

## Where the translation lives, and where it does not

The translation is implemented once, in `Handle::Proxy::_cli_args`, called
from `_execute` - the point where a chain's accumulated arguments (from
every bareword call in the chain) and the terminator's own arguments (from
the final `->(...)` call) are joined into one list and handed to
`Handle::run`. **`Handle::run` itself is completely untouched.** It
remains a thin, verbatim wrapper around `system('dashboard', @args)` with
no argument interpretation of its own - which is what makes it the correct
tool for a caller that already has CLI-ready argv, translated or not.

## Reviewing a change against this

- **A single positional argument must never be translated.** `d2()->path
  ->del('myalias')->()` has to keep meaning `dashboard path.del myalias`,
  not `dashboard path.del --myalias` (which would be nonsense - there is
  no value for that flag). The arity rule exists specifically so this case
  stays correct.
- **Do not try to special-case "looks like a flag name" heuristics.**
  Nothing about the argument values themselves can safely disambiguate a
  pair from two positionals; arity is the only signal that does not depend
  on guessing intent.
- **`run()` gets no translation, deliberately.** A caller reaching for
  `run()` already has full control over the exact argv it wants to send;
  adding translation there would make it a second, inconsistent way to
  spell the same thing the proxy chain already covers.

## Related

- The module's own POD (`lib/Developer/Dashboard/Handle.pm`, `HOW TO USE`
  and `EXAMPLES` sections) carries the same examples this page describes,
  since this is primarily an API-usage contract rather than an
  infrastructure concern.
