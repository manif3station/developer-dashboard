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

## How to apply

Before accepting a source-scanning checker's finding as real, confirm the
matched line is not inside a heredoc string - and if it is, check whether that
heredoc is interpolating (any edit inside it needs the same escaping
discipline as the code around it) or not (edits there are free-form text, but
still need to compile as valid embedded Perl if the heredoc is ever `eval`'d).
`t/159`'s comment-matching bug (DD-693) is the same family from the opposite
direction: a checker seeing a comment and reading it as code, rather than
seeing code-shaped text and reading it as a comment.
