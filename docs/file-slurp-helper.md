# The shared file-slurp helper

`Developer::Dashboard::FileSlurp` is the single implementation for reading a
whole file into memory as a string. It exists because three independent
call sites (`Collector.pm`, `CollectorRunner.pm`, `CLI/Ask.pm`) each wrote
their own open/read loop, and the three had already drifted apart in
encoding mode and missing-file behavior before anyone noticed (DD-888) -
the same shape as the directory-listing duplication DD-762 fixed with
`DirEntries.pm`.

## What it provides

```perl
use Developer::Dashboard::FileSlurp qw(slurp_file);

my $text = slurp_file($path);                                  # text mode, dies on any open failure
my $raw  = slurp_file($path, raw => 1);                        # :raw mode
my $safe = slurp_file($path, on_missing => 'empty');            # '' instead of dying when the file is absent
my $msg  = slurp_file($path, missing_message => "Unable to read attachment %s: %s");
```

- `raw => 1` opens with the `:raw` layer (byte-for-byte, no encoding
  translation); the default is a plain text-mode open.
- `on_missing => 'empty'` returns `''` when the file does not exist, instead
  of dying; the default (`'die'`) dies on any open failure, including a
  missing file.
- `missing_message => $sprintf_template` (used with `%s` for the path and
  `%s` for `$!`) lets a caller keep its own historical die-message wording
  without duplicating the read loop that produces it.
- `normalize_undef => 1` returns `''` instead of `undef` when a read on an
  already-open handle yields `undef` (an I/O error after a successful open -
  observable by symlinking the target to a special file like
  `/proc/self/mem`). Off by default, matching `Collector.pm`'s and
  `CollectorRunner.pm`'s original behavior of returning whatever the read
  produced; `CLI/Ask.pm`'s original implementation explicitly normalized
  this case, so its call site passes `normalize_undef => 1`.

## Who uses it, and with what options

| call site | raw | on_missing | missing_message | normalize_undef |
|---|---|---|---|---|
| `Collector.pm` `_slurp` | yes | `'empty'` | n/a (never dies) | no |
| `CollectorRunner.pm` `_slurp` | no | `'die'` | `"Unable to read %s: %s"` | no |
| `CLI/Ask.pm` `_slurp` | yes | `'die'` | `"Unable to read attachment %s: %s"` | yes |

Each call site kept its own pre-existing contract exactly - this is a
behavior-preserving extraction, not a behavior change. A future fourth
caller should reach for `slurp_file` directly rather than writing a fourth
copy of the open/read loop.

## Why this exists

Three copies of the same six-line idiom, each written independently, is how
a bug gets fixed in one and never propagates to the others - exactly what
happened here before any bug was actually found: the three had already
diverged in raw-vs-text mode and missing-file handling, with nothing
connecting them by name. See DD-762 for the precedent (directory-entry
listing, `DirEntries.pm`) and DD-888 for this instance.

## An extraction can leave a stale reference in a TEST, not just in `lib/`

DD-897: `t/07-core-units.t` called `CollectorRunner`'s old private name
directly and fully-qualified - `Developer::Dashboard::CollectorRunner::
_slurp($target)` - to check `_overwrite_state_file_in_place`'s output. The
rename to `slurp_file` (via the shared import) missed this one call site,
so the file died with "Undefined subroutine" **after all of its own 717
assertions had already passed**, reporting FAIL with no failed assertion
anywhere in the output - the failure is only visible in the exit code and
the "no plan was declared" diagnostic, not in any `not ok` line.

**The general lesson, matching DD-891's precedent on `TimeUtils.pm`
(t/100/t/09 calling `RuntimeManager::_now_iso8601()` bare by its old
private name):** after renaming or relocating a private sub as part of an
extraction, grep the WHOLE test suite for the old fully-qualified name
(`Package::_old_name`), not only the call sites inside `lib/`. A test
poking a private sub directly by name is a call site the extraction has
to migrate too, and it is invisible to a `lib/`-only search.
