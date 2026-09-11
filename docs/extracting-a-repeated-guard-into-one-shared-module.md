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

## Related

- `lib/Developer/Dashboard/DirEntries.pm` - the first instance of this
  exact shape (DD-762), and the template this page's naming/POD structure
  follows.
- `lib/Developer/Dashboard/PathsRegistryArg.pm` - the second instance
  (DD-785), notable for the corrected-scope lesson above.
