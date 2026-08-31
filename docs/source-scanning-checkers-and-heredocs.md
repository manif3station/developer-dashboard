# Source-scanning checkers can't see heredoc boundaries

Several standing checks in this project — `t/159`'s `$?` guard sweep, and
`hunt-monitor`'s `doc-sub-comments` and `bug-verdict-unusable` checks — work by
reading a `.pm` file's raw text and pattern-matching against it (a `sub NAME {`
line, a `$?` mention, a `waitpid(` call) rather than by parsing real Perl
syntax. This page is system-scoped: it names the recurring failure shape, not
any one instance of it.

## The shape

A heredoc (`<<'PERL' ... PERL` or `<<"PERL" ... PERL`) embeds Perl SOURCE TEXT
as a string literal — commonly used here to build a bootstrap script that gets
written to a temp file or `eval`'d in a child process. To a text-based checker,
that embedded text is indistinguishable from real code in the enclosing file:

```perl
sub _saved_ajax_perl_wrapper {
    return <<'PERL';
sub stash {
    ...
}
PERL
}
```

`sub stash { ... }` here is a string, not a definition in this package. A
checker that greps for `sub \w+ {` will report it as a real sub anyway - and
if that sub happens to be missing a purpose/input/output comment (because it's
prose describing behaviour to a *different* interpreter's package, not this
file's own convention), the checker files a false positive.

## Two distinct heredocs, two distinct answers

`PageRuntime.pm` has both kinds in the same file, which is what makes this
worth documenting rather than fixing once and forgetting:

- `_saved_ajax_perl_wrapper`'s `<<'PERL'` (single-quoted, non-interpolating):
  a bootstrap script for the Ajax launcher child process. Its `stash`/`hide`/
  `void`/`stop`/`params` subs are text for that OTHER process - not real subs
  in `Developer::Dashboard::PageRuntime`, and `doc-sub-comments`' hits against
  them are false positives, correctly left uncommented.
- `_new_sandpit`'s `<<"PERL"` (double-quoted, interpolating): a per-page
  throwaway package template that IS `eval`'d by `__run_code`, in this same
  process, as real executable code. Its `__add_error`/`__errors`/`stash`/etc.
  subs are real and do need the comment - and because the heredoc
  interpolates, any `$` or `@` written into a comment there must be escaped
  (`\$`, `\@`) exactly like the surrounding code, or `perl -c` fails
  immediately with an "unintended interpolation" warning.

## A third instance: an assertion PROVING absence read as an instance

`hunt-monitor`'s `imp-todo` check (a bare `\bTODO\b` regex over every line
under `lib/`, `bin/`, `script/`, `t/`) hit the same family from a third
direction (DD-704). `t/15-release-metadata.t` carries `Test::More` assertions
whose entire purpose is proving a pattern does NOT appear:

```perl
unlike( $auth_hunt_pod, qr/\bTODO\b/, 'auth regression POD no longer cites a TODO block' );
```

The word `TODO` appears on that line twice - once in the regex being tested
for, once in the human-readable test description - and both are matched by a
checker that cannot tell "this line contains the token" from "this line
asserts the token is absent." The finding recurred four times (DD-636, DD-698,
DD-708, DD-704) because each occurrence was discarded as a false positive
without the checker itself being fixed - the root cause was correctly named on
the first discard (DD-636) and only implemented on the fourth. `check_todo()`
now skips a `.t`-file match sitting inside an `unlike()`/`isnt()` call, and the
one remaining hit (a comment that merely *described* the assertion) was
reworded to drop the bare word rather than taught to the checker, matching the
project's existing precedent (DD-678) of rephrasing prose a raw-text sweep
cannot parse rather than building it a parser.

## How to apply

Before accepting a source-scanning checker's finding as real, ask which of
three things it might actually be reading: code-shaped text inside a heredoc
string (not real code in this file), a comment describing a construct rather
than using it (`t/159`, DD-693 - the same family from the opposite direction:
a checker seeing a comment and reading it as code), or an assertion proving a
pattern's ABSENCE rather than containing an instance of it (`imp-todo`,
DD-704). In every case the fix is either to narrow the checker with a real
discriminator, or to reword the source so the checker's blind spot no longer
matters - never to keep discarding the same finding by hand.
