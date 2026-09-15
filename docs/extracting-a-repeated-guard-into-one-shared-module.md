# Extracting a repeated guard into one shared module

Several `lib/` modules have, at different times, hand-rolled the same small
piece of logic - a literal string, a guard, a filter - independently rather
than sharing one definition. This page names the pattern this project uses
to fix that shape, once it is confirmed to be duplication and not a
coincidence.

## The recognised shape

- **Byte-identical bodies** across multiple files (or identical up to
  whitespace/a trailing comma) are the strongest signal: nothing about each
  site's context required it to diverge, so nothing will notice when a
  correction to one copy needs making in the others too.
- **A literal string repeated as the payload of a `die`, an error message,
  or a comparison** - a future change to the wording has to find every
  site by hand, and a grep for the old wording is the only thing that
  would catch a missed one.
- **The repeated part need not be the whole function.** `DirEntries.pm`
  (DD-762) extracted one line - a `sort grep` idiom - out of six otherwise
  different call sites. `PathsRegistryArg.pm` (DD-785) extracted one guard
  line out of seven constructors that were each otherwise doing something
  different with the result.

## The shape of the fix: a flat exported function, not a base class

This codebase has no `use parent`/role pattern anywhere in `lib/`, so the
fix for this shape is a plain module exporting a plain function via
`Exporter 'import'` and `@EXPORT_OK` - matching `DirEntries.pm`'s own
precedent exactly:

```perl
package Developer::Dashboard::SomeSharedThing;
use Exporter 'import';
our @EXPORT_OK = qw(the_shared_function);
sub the_shared_function { ... }
1;
```

Callers `use` it with an explicit import list and call the function
directly. This keeps every call site's own control flow exactly as it was
- a duplicated **line**, not a duplicated **class hierarchy** - which
matters when (as with `FileRegistry.pm`/`Prompt.pm`, DD-785) some
call sites need extra fields the others do not: they call the shared
guard for the part that is genuinely shared, and keep everything else of
their own.

**Do not force divergent call sites into one shared function with an
open-ended argument list to make them "fit".** That trades several honest,
readable copies for one abstraction nobody can read - worse than the
duplication it was meant to remove. The test of a correct extraction is
whether the genuinely-identical sites collapse cleanly; if a site needs a
special case to fit, it should stay outside the extraction and call the
shared piece only for the part it does share.

## Verifying the extraction actually happened

**Count occurrences of the literal string/logic BEFORE deciding the scope,
not after.** `PathsRegistryArg.pm`'s subject card initially assumed "seven
modules" from a search of one class of file (constructors); a full grep
of `lib/` found the same literal string 31 times across 11 files, the other
24 inside unrelated per-function argument guards in CLI action handlers -
a different call shape (multiple required keys, not one) with a much
larger blast radius than the constructor duplication the card actually
meant to fix. **A narrowing filter (searching only constructors) reports a
floor, not a total** - state which population the fix actually covers, and
scope the ticket to what was actually found duplicated in that population,
not to every occurrence the same words happen to match elsewhere.

After the fix, the check is a count: the old literal string/logic should
appear in **exactly one place** among the sites the ticket scoped in - the
new shared module - never zero (nothing calls it) and never more than one
(a site was missed, or kept its own copy by mistake).

## An extraction can itself miss a site

Even a correctly-scoped extraction can leave a site un-migrated: DD-762
extracted `DirEntries::sorted_dir_entries` out of what was measured as six
call sites, but `RuntimeManager.pm` carried a seventh, byte-identical
inline copy of the same `sort grep { $_ ne '.' && $_ ne '..' && ... }
readdir($dh)` idiom that the original hunt's non-recursive grep missed
(DD-865, found by the hourly improvement hunt). The fix was the same
"verifying the extraction actually happened" check above, run again later:
grep `lib/` recursively for the old literal pattern and confirm zero
copies remain outside the shared module. `RuntimeManager.pm` now composes
`sorted_dir_entries($dh)` with its own `.pid`-specific `grep` stage rather
than re-implementing the dot-filter a third time.

**So the verification step is not one-time.** A module added or edited
after the extraction can reintroduce the pattern it was meant to
eliminate, and the only way to know is to re-run the same grep, not to
trust the original count.

## A third instance: a whole function, not just a line (DD-891)

`Developer::Dashboard::TextUtils` (DD-891) extracts `_trim` - a complete
6-line whitespace-trim function, not merely one shared line inside a larger
function - out of `PageDocument.pm` and `Web/App.pm`, which each carried a
byte-for-byte identical private copy. This is the same recognised shape
(byte-identical bodies is the strongest signal) applied to a whole
function rather than a guard line, and it followed the same
verify-before-scoping discipline: the card's own description estimated 11
call sites (7 + 4); a live recursive grep found 9 (6 + 3) before the
extraction began, corrected on the card rather than trusted from the
filing automation's count.

Unlike `DirEntries.pm`'s dot-filter or `PathsRegistryArg.pm`'s guard,
`_trim` is a pure function with no dependency on its caller's other state
- the whole body moves verbatim into `TextUtils.pm`, and both call sites
become a plain `_trim($text)` call after the `use` line, with no argument
list changes needed at any of the 9 sites.

## A fourth instance: a parameterized function, not a fixed one (DD-894)

`Developer::Dashboard::TimeUtils` (DD-894) extracts `_now_iso8601` out of
7 files (5 producing a UTC/`Z`-suffixed timestamp via `gmtime`, 2 producing
a local timestamp with a numeric offset via `localtime` - documented as
deliberate in `lib/Developer/Dashboard.pm`'s own POD, so cron-scheduled
collector output lines up with the machine's local time across
daylight-saving transitions). Unlike `TextUtils.pm`'s single fixed
behavior, this extraction takes an explicit `tz => 'utc'|'local'`
parameter - the two groups are genuinely-identical-WITHIN-group but
different ACROSS group, and the fix must preserve both outputs exactly
rather than collapsing them into one format. This is the "explicit
options, not silent special-casing" principle from the shape-of-the-fix
section above, applied to a case where the two branches are not near
misses to be judged but two real, permanent, differently-purposed formats.

A prior card (DD-642) misread this same duplication as an unintentional
bug causing a shared-field mismatch and was correctly discarded once the
UTC/local split was found to be deliberate - worth naming here because the
two cards look, from their titles alone, like the same finding twice.

## A pattern can be REINTRODUCED deliberately, then still need fixing (DD-898)

`Developer::Dashboard::HtmlEscape` (DD-898) extracts `_escape_html` and
`_escape_html_attr` out of `Web/App.pm` and `Zipper.pm` - a case where the
duplication was created on purpose, not by accident: DD-892 explicitly
mirrored `Web/App.pm`'s existing pair into `Zipper.pm` as its own private
copy (rather than extracting a shared module at the time), and
`docs/html-escaping-convention.md` documented the duplication as "this
file's convention" without flagging it for later extraction. That is the
identical shape `TextUtils.pm` (DD-891) was in before its own fix - two
copies, not yet drifted, with nothing structural stopping a future edit to
one from silently not reaching the other. **A duplication being
intentional at the moment it is created does not mean it should stay
duplicated** - "deliberately mirrored" and "deliberately shared" are two
different decisions, and only a habit of extracting on sight distinguishes
them from each other later.

Unlike `TimeUtils.pm`, no call site needed its arguments changed - both
functions keep the exact signature every existing caller already uses, so
fully-qualified test calls (`Developer::Dashboard::Web::App::_escape_html(...)`)
resolve correctly with zero test-file changes, since Exporter installs the
imported sub into each importing package's own symbol table (the same
mechanism `t/160`'s own header comment documents, corrected earlier this
session).

## Related

- `lib/Developer/Dashboard/DirEntries.pm` - the first instance of this
  exact shape (DD-762), and the template this page's naming/POD structure
  follows. Now has 4 consumers: `SkillDispatcher.pm`, `DockerCompose.pm`,
  `CLI/Which.pm`, and `RuntimeManager.pm` (the last migrated after the
  fact by DD-865).
- `lib/Developer/Dashboard/PathsRegistryArg.pm` - the second instance
  (DD-785), notable for the corrected-scope lesson above.
- `lib/Developer/Dashboard/TextUtils.pm` - the third instance (DD-891),
  notable for being a whole function rather than one shared line.
- `lib/Developer/Dashboard/TimeUtils.pm` - the fourth instance (DD-894),
  notable for taking an explicit parameter to preserve two genuinely
  different, intentional output formats rather than one fixed behavior.
- `lib/Developer/Dashboard/FileSlurp.pm` - the fifth instance (DD-888).
- `lib/Developer/Dashboard/HtmlEscape.pm` - the sixth instance (DD-898),
  notable for the duplication having been created deliberately (DD-892
  mirroring rather than sharing) and still needing this same fix later.
