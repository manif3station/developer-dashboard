# `dashboard of` chooser selection syntax

## What this is

When `dashboard of`/`dashboard open-file` (implemented in
`Developer::Dashboard::CLI::OpenFile`) resolves more than one matching file
and `--print` was not given, it prints a numbered list and reads one
selection line from STDIN via `_select_open_file_matches` /
`_selection_matches`.

## Accepted syntax

- A single index: `2`
- A comma and/or whitespace separated list of indexes: `1,3` or `1 3`
- A range: `2-5`
- A range with whitespace around the dash: `2 - 5`, `2  -  5` (any amount of
  whitespace on either side of the dash is accepted)
- Any mixture of the above, separated by commas and/or whitespace:
  `1 - 2, 4`
- A blank line (just pressing Enter): selects every listed match
- Anything else (out-of-range index, reversed range, non-numeric input):
  rejected with `Invalid file selection '<input>'`

## Why whitespace around the dash is accepted, and why that mattered

The parser is two steps: a regex that decides whether the WHOLE input line
is well-formed, then a `split` that breaks it into individual chunks
(single indexes or `N-M` ranges) to act on. Both steps have to agree on
what counts as a separator between chunks, because whitespace has to mean
two different things depending on where it sits: *between* two chunks
(`1 3`) it is a separator; *inside* one range (`2 - 5`) it is not.

Before DD-908, the validation regex explicitly allowed the "inside a
range" case, but the chunk-splitting step split on `/[,\s]+/` - matching
*any* whitespace, including the whitespace inside a range's dash. So a
spaced range validated as well-formed and then got torn apart into
non-range pieces by the very next step, and was rejected as invalid.

The fix (`_selection_matches`) normalizes `\s*-\s*` down to a plain `-`
across the whole input *before* either validating or splitting it, so both
steps see the same, unambiguous string. This is the general shape to watch
for when adding to this parser: a two-step "validate, then act on" pattern
only stays correct if every character class treated specially by the first
step is treated the *same* way by the second.

## Where this lives

- Implementation: `lib/Developer/Dashboard/CLI/OpenFile.pm`,
  `_selection_matches` / `_select_open_file_matches`.
- Tests: `t/98-cli-openfile-coverage.t`.
