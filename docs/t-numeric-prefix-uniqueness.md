# Every t/ file's numeric prefix must be unique

Why two spec files can never share a leading number, and how that is
enforced.

## The problem this solves

Files under `t/` are numbered (`t/15-release-metadata.t`,
`t/158-operator-tool-specs.t`, ...). CLAUDE.md and several docs vault pages
cite tests by that bare prefix - `t/15`, `t/158` - trusting it to resolve
to exactly one file.

Parallel sessions working different tickets pick numbers independently, and
nothing stopped two of them landing the same prefix on different files.
`d1a6053b` renumbered one such collision away once; without a standing
guard, the same pattern reintroduces it - ten pairs were found sharing a
prefix on 2026-09-07 alone (DD-816).

The damage is silent by construction: `prove -lr t` runs every `.t` file
under `t/` regardless of its name, so a collision changes nothing about
which tests execute. What breaks is every reader who trusts a bare-prefix
citation - it now resolves to two files, and nothing says so.

## The rule

> **No two files under `t/` may share the same leading numeric prefix.**
> A suite-level test enumerates every `t/*.t` file, groups by its
> `\A(\d+)-` prefix, and fails naming both files whenever a group holds
> more than one.

## Why this is a different guard from the citation-resolution one

`docs/documentation-references-resolve.md` (DD-786) checks that every path
a doc or POD *cites* resolves to exactly the file it names. It says
nothing about two files that nobody has cited yet - the population it
walks is documentation text, not the `t/` directory itself.

This guard's population is the directory: every `t/*.t` file, whether or
not anything currently cites its prefix. The two are complementary, not
redundant - a fresh collision on a prefix nothing cites yet is invisible to
the citation guard and caught only by this one.

## Choosing which file keeps a contested number

When a collision is found, the number stays with the file that documentation
already cites by that bare prefix, if either does; the other file is
renamed to the next free prefix. When neither is cited, the older file (by
first-added date, `git log --diff-filter=A --follow`) keeps the number, and
the newer one moves - matching the direction a reader's expectation already
points, since an established citation or an older file is the one more
likely to already be assumed stable.
