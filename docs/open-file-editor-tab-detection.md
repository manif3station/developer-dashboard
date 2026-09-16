# `dashboard of` / `open-file`: editor tab-support detection

## What this covers

When `dashboard of`/`open-file` opens more than one file at once (or a single
match with `-p` support), it decides whether to pass the resolved editor
command the `-p` (open-in-tabs) flag. That decision lives in
`Developer::Dashboard::CLI::OpenFile::_editor_supports_tabs`.

## How it decides

The resolved editor command's basename (after stripping any leading path,
e.g. `/usr/bin/nvim` -> `nvim`) is matched case-insensitively against the
vim family: `vim`, `nvim`, `vi`, `gvim`, `view`. Any other editor (e.g.
`code`, `emacs`, `nano`) never receives `-p` - it is passed to `exec` as-is.

`view` is vim's own read-only-mode entrypoint (a standard part of the
`vim`/`vim-common` package family on every common distribution) and is
recognized exactly like `vi`/`vim`/`nvim`/`gvim`.

## History

Originally the vim-family list wrongly included a bogus `iv` token instead
of `view` (DD-909) - `iv` matches no real editor anywhere, so that branch
was permanently dead, and a user running with `EDITOR=view` never got the
`-p` flag they should have. Fixed by correcting the pattern to the real
editor name.

## Where the logic lives

`lib/Developer/Dashboard/CLI/OpenFile.pm`, `_editor_supports_tabs`. Covered
by `t/98-cli-openfile-coverage.t`.
