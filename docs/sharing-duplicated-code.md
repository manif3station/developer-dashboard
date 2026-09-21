# Sharing duplicated code, and when not to

This page describes how this codebase decides whether code that *looks* duplicated
should be shared. It is about the product's structure, not about any one ticket.

The short version: **identical bodies are worth sharing; structurally parallel ones
usually are not.** The difference is not stylistic — sharing parallel code requires
inventing an interface (an accessor name, a callback, a flag), and that interface is
new surface which has to be understood, tested and kept correct. Removing ten lines
by adding a parameter that selects between two behaviours generally makes the code
harder to read, not easier.

## The test to apply

Ask what would have to be passed in to make one body serve both call sites.

- **Nothing, or one already-available value.** Share it. The bodies are the same
  computation and the duplication is an accident.
- **A value that selects between behaviours** — a method name to call, a callback to
  run afterwards, a boolean that switches a branch. Do not share it. Established
  refactoring practice names this case explicitly: structural differences cannot be
  passed as parameters, and *Replace Parameter with Explicit Methods* — keeping one
  method per behaviour — is a recognised technique rather than a failure to refactor.

A useful corollary: if the shared helper would need a comment explaining which caller
wants which behaviour, the helper is the wrong shape.

## Worked example: the alias cache key

`Developer::Dashboard::File` and `Developer::Dashboard::Folder` each carry their own
`_configured_alias_cache_key`. Folder's takes a paths object; File's takes a file
registry and derives the paths object from it as its first statement. After that one
unwrap the bodies are the same statement for statement — the same `blessed` guard, the
same eval-guarded root lookups, the same join. Nothing behavioural distinguishes them,
so one helper serves both.

## Worked counter-example: the alias loader, in the same two modules

`_load_configured_aliases` sits directly beside it, looks equally duplicated, and must
not be merged. The two versions differ in three ways that a parameter cannot carry:

- they read different configuration accessors;
- one registers what it loaded and the other does not;
- one constructs a registry the other already holds.

They also guard different package globals. Sharing them means passing an accessor name
*and* a post-load callback — more machinery than the handful of lines it removes.

## The counter-example that matters most: when merging would be a bug

The `AUTOLOAD` resolvers in those same modules are the strongest case, and the reason
is behavioural rather than economic. Folder's resolver calls `make_path` to **create**
the directory it resolves. File's must **not** create a file it resolves. A merged
resolver would either create files by accident or stop creating folders. The
duplication here is not drift — it is two deliberately different behaviours that happen
to be written in a similar shape.

This is the case the whole page exists for: **similar shape is not evidence of
duplicated intent.** A deduplication that papers over a behavioural distinction is
worse than the duplication, because the distinction stops being visible at the call
site and nothing fails until something creates a file that should not exist.

## What to record when you decline to share

State the reason on the record, next to the code or on the card, and be specific about
*which* difference blocks it. A future reader looking at two near-identical subs will
otherwise assume nobody noticed. Naming the blocking difference converts an apparent
oversight into a decision, and lets the next person re-open it if the difference ever
goes away.

The same applies to a partial fix. If one instance of a repeated shape is changed and
others are left, say so explicitly — otherwise the untouched instances read as
deliberate, and the fixed one supplies false evidence that the area was considered.

## Where this bites in practice

Repeated idioms are copied, not called. A directory-reading filter written the same way
in several modules is the common case here: each instance is correct, and the cost is
that a future change to what the filter should exclude has to find call sites that no
symbol connects. That is a real reason to share an identical body — and it is not a
reason to share a parallel one.

## Another worked example: the CLI table helpers

`CLI/Files.pm` and `CLI/Paths.pm` each carry `_aliases_table`, `_list_table`,
`_mutation_table`, `_removal_table` and `_render_table`; `_build_paths` is
also duplicated in `CLI/Which.pm`. Applying the test: nothing needs to be
passed in to make one body serve every call site - `_build_paths` is
byte-identical between `Files.pm` and `Which.pm`, and `_render_table`
differs only by a trailing blank line, not by behaviour. Share it (DD-773).

## Follow-up: the same table helpers, one file left behind

DD-773 above migrated `Files.pm`, `Paths.pm` and `Which.pm` onto the shared
`TableHelpers::render_table`, but `CLI/Skills.pm` kept its own private
`_render_table`/`_format_row` — not overlooked forever, just excluded from
that ticket's scope. Its version called one extra private helper,
`_plain_text`, that stripped ANSI colour escapes (`s/\e\[[0-9;]*m//g`) before
computing column widths, so a coloured cell would still pad correctly. That
looked at first like a genuine behavioural difference blocking the merge (per
the test above: "a value that selects between behaviours").

It was not, once checked. Applying the test properly means checking whether
that difference is ever *exercised*, not just whether it *exists*: grepping
every real call site into Skills.pm's table renderer showed the only two
content-producing helpers feeding cell values, `_enabled_text` and
`_boolean_text`, return hardcoded plain strings (`'enabled'/'disabled'`,
`'yes'/'no'`) — never ANSI. The only other ANSI-shaped code in the file was an
unrelated `color => (-t STDERR ? 1 : 0)` flag feeding a separate
`Developer::Dashboard::CLI::Progress` object, never touching the table
renderer at all. So the ANSI-stripping was dead weight, not a distinguishing
behaviour, and Skills.pm was migrated onto the shared helper directly (DD-986)
— confirmed byte-identical output for real skill-list-shaped tables before and
after.

**The lesson this adds:** a helper that does strictly more than the shared one
is not automatically a reason to keep it separate. Check whether the "more"
is ever reached by a real call site before treating it as a blocking
difference — an unreached capability is not a behaviour, it is unexercised
code wearing the shape of one.

## Another worked example: the config-loader constructor

`Housekeeper.pm` and `Doctor.pm` each carried a `_config` method that only
ever did one thing: `Config->new(paths => $self->{paths}, files =>
FileRegistry->new(paths => $self->{paths}))`, byte-identical between the
two (confirmed with `diff`, not just a body-hash match). Applying the test:
nothing needs to be passed in beyond what `Config` itself already has -
`paths`. Shared as `Config->for_paths($paths)`, a classmethod living on
`Config` itself since it is Config's own job to know how to build one
(DD-763). Both call sites became one-liners: `$self->{config} ||=
Developer::Dashboard::Config->for_paths($self->{paths})`.
