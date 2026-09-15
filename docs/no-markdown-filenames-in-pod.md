# Perl POD never names a repo-internal `.md` file, and `t/15` enforces it

Every `.pm`/`.pl`/`.t` file's POD (under `__END__`) must describe this
project's markdown documentation without ever writing out its literal
filename - "the generated README", never "README.md"; "the operator
checklist", never "internal-operating-checklist.md".

## Why

`README.md` is generated from `lib/Developer/Dashboard.pm`'s own POD via
`script/sync-readme-from-pod` - never hand-edited. A POD block that names
`README.md` literally invites a reader (or a future edit) to treat that
filename as something to open and edit directly, defeating the
generate-don't-hand-edit contract. More generally, `*.md` files at the repo
root are operator-local (`MISTAKE.md`, `ELLEN.md`, `CLAUDE.md`,
`SCORECARD_ACTIONS.md`, ...) and deliberately excluded from the shipped
tarball; naming one inside shipped POD risks a reader assuming it ships or
is reachable in an installed distribution, when it is neither.

## The gate

`t/15-release-metadata.t` reads every `.pm`/`.pl`/`.t` file's POD and fails
if any mentions a `.md` filename by name. It is what makes this a checked
convention rather than a style preference nobody enforces - see DD-893 for
an instance where one new test file's own explanatory POD violated it
(`t/187-no-stray-update-command.t` wrote "its generated README.md"),
breaking `prove -lr t` on master until reworded.

## How to write around it

Describe the artifact by what it is, not by its path:

- "the generated README" (not "README.md")
- "the project's operator checklist" (not "internal-operating-checklist.md")
- "this project's mistake log" (not "MISTAKE.md")

If a POD block genuinely needs to point a reader at a specific vault page
under `docs/`, name the page's *subject* rather than its filename, or, if
the exact path is unavoidable, keep that reference in a code comment above
`__END__` rather than inside the POD itself - `t/15`'s check is POD-scoped.
