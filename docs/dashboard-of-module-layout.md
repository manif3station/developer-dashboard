# `dashboard of` module layout

## What this is

`dashboard of` (the file-open/navigation CLI command) is implemented across
four Perl modules under `lib/Developer/Dashboard/CLI/`, split by concern
rather than living in one file:

- **`OpenFile.pm`** — the command entrypoint (`run_open_file_command`),
  direct-path/`file:line` resolution, scope-regex search and ranking
  (`_scope_match_rank`, `_ordered_scope_matches`, `_resolve_open_file_matches`),
  Perl-module-name resolution, and editor invocation (`_command_exec`,
  `_editor_supports_tabs`). This is the module every caller and test targets
  by name.
- **`OpenFileChooser.pm`** — the interactive multi-match chooser
  (`_select_open_file_matches`, `_stdin_has_pending_input`). Split out because
  it is a self-contained interactive-selection concern with its own
  STDIN-readiness handling (see `dashboard-of-non-interactive-stdin-contract.md`).
- **`OpenFileJavaSource.pm`** — Java-class resolution: archive extraction,
  Maven Central search/download, and the `--online` network gate
  (`_java_archive_source_matches`, `_candidate_java_source_archives`,
  `_java_source_archive_roots`, `_extract_java_sources_from_archive`,
  `_download_java_source_matches`, `_maven_search_documents`,
  `_download_maven_source_jar`, and related helpers). Split out because it has
  no dependency on the rest of the file-search logic and was, on its own,
  roughly 200 lines.
- **`OpenFileUtil.pm`** — small shared helpers used by more than one of the
  above (currently directory-list dedup helpers), kept separate rather than
  duplicated in each split module or left in `OpenFile.pm`.

## Why it's split this way

`OpenFile.pm` originally held all of this in one 823-line file, exceeding
this project's 500-line-per-module guideline. The Java-source machinery and
the interactive chooser were the two natural, low-risk seams: each is a
self-contained concern with no reverse dependency back into the rest of the
file's search/ranking logic.

## How the split preserves the existing contract

Every sub moved out of `OpenFile.pm` is exported from its new module and
re-imported into `OpenFile.pm`'s own namespace. External callers, and this
project's test suite (`t/98-cli-openfile-coverage.t`, whose `oc()` helper
resolves everything under the `Developer::Dashboard::CLI::OpenFile::`
namespace), see no change: `Developer::Dashboard::CLI::OpenFile::_select_open_file_matches`
still resolves and behaves exactly as it did before the split, even though
its body now lives in `OpenFileChooser.pm`.

## When to use / how to use

Add new file-search/ranking/path-resolution logic to `OpenFile.pm`. Add new
Java-archive or Maven-download logic to `OpenFileJavaSource.pm`. Add new
interactive-selection logic to `OpenFileChooser.pm`. Add a helper only to
`OpenFileUtil.pm` once at least two of the other three modules need it —
don't pre-emptively generalize a single caller's helper into it.

## What uses it

`bin/dashboard`'s command dispatch (`dashboard of ...`), staged via
`share/private-cli/of`; `t/98-cli-openfile-coverage.t` covers all four
modules' behavior through `OpenFile.pm`'s re-exported namespace.
