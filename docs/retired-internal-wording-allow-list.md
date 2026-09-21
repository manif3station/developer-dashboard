# The retired-internal-wording gate, and its allow-list

What `t/15-release-metadata.t`'s ban on the bare word "legacy" actually checks,
where it applies, and exactly what is exempt from it. This page describes the
system's current behavior, not any one ticket.

## What the gate does

`t/15-release-metadata.t` runs a case-insensitive `unlike( $doc, qr/\blegacy\b/i, ... )`
assertion against every file in `@doc_paths` (README.md, SKILL.md, FIXED_BUGS.md,
MISTAKE.md, CONTRIBUTING.md/.pod, SECURITY.pod, SOFTWARE_SPEC.md, TEST_PLAN.md,
and everything under `doc/`) and against the extracted POD of every file in
`@pod_paths` (the main module plus a handful of others). The intent is to keep
shipped documentation and POD from mentioning retired internal wording that
would confuse a reader.

`\b` is a plain Perl word-boundary: it requires a transition between a `\w`
character (letters, digits, underscore) and a non-`\w` character (or a string
edge). Because the underscore is itself a word character, `\blegacy\b` never
matches inside an all-word-character run like `__PAX_RUNTIME_LEGACY_NAMESPACE__`
- there is no boundary on either side of the embedded `LEGACY` substring. It
**does** match "legacy" inside a hyphenated phrase like "legacy-namespace",
because a hyphen is not a word character and so a boundary exists there.

## The allow-list (DD-941, owner decision Q-179)

`__PAX_RUNTIME_LEGACY_NAMESPACE__` is a real, current, shipping identifier
(see `Developer::Dashboard::Pax::CodeUnitCompiler` and its runtime ops) - not
retired wording. FIXED_BUGS.md's append-only 4.37 (DD-931) and 4.42 (DD-933)
entries legitimately describe it, and DD-931's entry does so in prose as a
"legacy-namespace alias" on a line that does not contain the literal
identifier string. Since FIXED_BUGS.md is append-only, that entry can never be
reworded to avoid the word.

So the test file strips two exemptions from a copy of the text before running
the `\blegacy\b` check (never from the text that is actually compared for
anything else):

- the literal identifier `__PAX_RUNTIME_LEGACY_NAMESPACE__` (case-insensitive)
- the phrase `legacy-namespace` (case-insensitive), independent of the
  identifier being present on the same line

Both are stripped by `_strip_legacy_namespace_mentions()` in
`t/15-release-metadata.t`, used just before the two `unlike(qr/\blegacy\b/i)`
assertions (one for `@doc_paths`, one for `@pod_paths`).

**This is the only exemption.** Any other bare, case-insensitive "legacy"
mention in a checked doc/POD path still fails the gate - the allow-list
matches the specific real technical term, not the word "legacy" in general.
A genuinely retired feature or wording must still avoid the word, or be
reworded (for a file that is not append-only) to avoid it.

## Where this does NOT apply

The gate only inspects `@doc_paths` and `@pod_paths` - shipped documentation
and extracted POD. Plain Perl source outside POD (comments, identifiers,
string literals) is never checked by this gate, so code like
`Folder.pm`'s `%legacy_aliases` or `Doctor.pm`'s `legacy_bookmarks` label is
untouched by it.

## If this needs to change again

If a third real technical term ever needs the same treatment, extend
`_strip_legacy_namespace_mentions()` with another `s///gi` stripping the new
term's literal text, rather than loosening the `\blegacy\b` pattern itself -
the pattern is what protects every other file, and the allow-list is what
should carry the exceptions.
