# `dashboard of` scope-search ranking

## What this covers

How `dashboard of <dir> <pattern...>` (`Developer::Dashboard::CLI::OpenFile`)
ranks the files a recursive scope search finds, and how the ranking
regexes are compiled.

## How ranking works

When a search scope resolves to a directory, `_resolve_open_file_matches`
walks it with `File::Find`, collecting every file whose relative path
matches every supplied pattern. The surviving files are then ordered by
`_ordered_scope_matches` / `_scope_match_rank`, which score each file so
that an exact basename hit outranks a partial substring match, which in
turn outranks a path-component match. Lower rank sorts first; ties fall
back to original discovery order.

## Pattern compilation (DD-912)

Each pattern is compiled into a regex once by `_resolve_open_file_matches`
(`@regexes = map { _compile_open_file_regex($_) } @patterns`) before the
`File::Find` walk even starts — that compiled array is what the walk uses
to filter candidates in the first place.

`_ordered_scope_matches` and `_scope_match_rank` accept that same
`regexes` array (parallel to `patterns`, same index) and use it directly
rather than recompiling. Before DD-912, `_scope_match_rank` recompiled
every pattern into a fresh `qr//` for every single candidate file it
scored — for a scope search matching hundreds of files, the same pattern
was compiled hundreds of times.

**A caller with only raw pattern strings still works.** `_scope_match_rank`
falls back to compiling on demand when the regex at a given index is
missing (`$regexes[$index] || _compile_open_file_regex($pattern)`), which
is what the module's own direct unit tests exercise — they call
`_scope_match_rank`/`_ordered_scope_matches` with `patterns` only, no
`regexes`, and get identical behavior to before.

## When to use

Read this before changing scope-search ranking, how patterns are compiled
or matched, or the tie-break rules between exact/partial/component
matches.

## What uses it

`dashboard of`/`open-file`'s scope-search mode (the fallback path when the
first argument is not a direct file, a resolvable module/class name, or an
exact relative path inside a resolved scope).
