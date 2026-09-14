# The Data Query Commands ship seven formats, not four

What `dashboard`'s built-in data-query CLI commands actually cover, as
distinct from what the architecture-overview prose once said. This page
describes the current state of the system, not any one ticket.

## The seven commands

`dashboard <cmd> [path] [file]` — read from `file` or stdin, decode the
structured input, then either extract a dotted `path` or evaluate a Perl
expression against the decoded document through `$d`:

| command | format |
|---|---|
| `jq`    | JSON |
| `yq`    | YAML |
| `tomq`  | TOML |
| `propq` | Java properties |
| `iniq`  | INI |
| `csvq`  | CSV |
| `xmlq`  | XML |

All seven share the same contract: order-independent file path and query
text, canonical JSON for a hash/array result, a bare scalar (plus newline)
for a scalar result, and `$d` inside a Perl expression evaluates against
the whole decoded document. `xmlq` additionally decodes attributes under
`_attributes` and mixed text under `_text`, with repeated sibling tags
becoming arrays.

## Where this was previously wrong

Two places in `lib/Developer/Dashboard.pm`'s POD independently undercounted
this set to four commands (`jq`/`yq`/`tomq`/`propq`), omitting `iniq`,
`csvq`, and `xmlq` — both the architecture-overview `Data Query Commands`
item and the detailed `=head2 Data Query Commands` section's itemized
list. Both are real, shipped commands (`share/private-cli/` carries all
seven command bodies, and `bin/dashboard`'s own usage text already listed
all seven correctly) — the POD prose alone had drifted from the shipped
CLI surface. Fixed under DD-869, alongside DD-867 (a related-but-opposite
drift: a POD claim describing a capability the code didn't actually
support).

## How to use this page

Before editing either Data Query Commands POD section again, check this
page's table against `ls share/private-cli/ | grep -E '(jq|q$)'` (or
equivalent) to confirm the command set hasn't grown or shrunk since this
page was written — POD prose drifting from the real command set is exactly
the failure mode this page exists to make cheap to catch.
