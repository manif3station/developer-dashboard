# Measuring coverage inside a PAX-compiled standalone binary

`dashboard pax build` produces a self-contained binary that, at runtime,
execs a bundled copy of perl with its own extracted code tree spliced onto
`PERL5LIB` before the exec (see `StandaloneImage.pm`'s C launcher,
`extract_runtime`). That exec target is a genuine, ABI-compatible perl
process - not a foreign runtime - but by default Devel::Cover cannot see
any of the code it runs, and the coverage report for
`lib/Developer/Dashboard/Pax/*.pm` comes back with **zero rows**, not
merely low coverage (DD-929).

## Why coverage is normally invisible here

Two separate mechanisms combine to hide it:

1. **The child process starts uninstrumented.** `prove`'s own
   `Devel::Cover` instrumentation belongs to the parent `prove` process.
   Nothing propagates it into a plain `exec()`'d child by default - the
   child needs its own `PERL5OPT=-MDevel::Cover=...` to be instrumented at
   all.
2. **Even once instrumented, the extracted files are ignored by
   default.** Devel::Cover snapshots `@INC` very early at startup and
   silently treats any file loaded from a path already on `@INC` at that
   point as "library code" to skip. The PAX launcher splices its
   extraction root onto `PERL5LIB` (which perl folds into `@INC` before
   any `-M` module gets a chance to run), so every one of the launcher's
   own `Pax/*.pm` files looks exactly like ordinary library code to
   Devel::Cover - even with `PERL5OPT` correctly propagated, the resulting
   report has zero file rows for them.

## What does NOT need fixing: the extraction path is already stable

It would be easy to assume the fix has to make the extraction path
predictable so a coverage run can target it - but `StandaloneImage.pm`
already does this. The launcher computes a content-addressed `source_hash`
(a SHA-256 over every packaged file's logical path and digest, sorted for
determinism - see `_source_hash`) and extracts to
`$TMPDIR/pax-standalone-cache-<source_hash>/`, reusing that same directory
across every run of an unchanged binary (verified live: the extraction
directory's mtime is unchanged across two consecutive runs of the same
binary). Nothing about the path is random per invocation.

## The actual fix: `-select` overrides the default ignore

Devel::Cover's `-select PATTERN` option explicitly marks matching files as
wanted, which overrides the default "ignore everything already on `@INC`"
behavior. Since the extraction root is already stable and can be computed
in advance from the binary's own reported `source_hash`, a coverage-gate
driver can:

1. Build the binary normally (`dashboard pax build`).
2. Ask it for its manifest via `--pax-standalone-inspect` and read
   `source_hash` back out.
3. Compute the extraction root the same way the C launcher does:
   `$TMPDIR/pax-standalone-cache-<source_hash>/`.
4. Set `PERL5OPT=-MDevel::Cover=-db,<path>,-select,<quotemeta'd root>/`
   before running the binary.

`Developer::Dashboard::Pax::CoverageSelect` (this repo,
`lib/Developer/Dashboard/Pax/CoverageSelect.pm`) implements exactly these
four steps as four small, independently tested functions -
`pax_binary_source_hash`, `pax_coverage_extract_root`,
`pax_coverage_select_pattern`, and `pax_coverage_perl5opt`. Its own test,
`t/200-pax-coverage-select.t`, includes a live integration assertion that
builds a real PAX binary, runs it under the computed `PERL5OPT`, and
confirms Devel::Cover actually collects a run - not merely that the
binary still executes.

## Using it

```perl
use Developer::Dashboard::Pax::CoverageSelect qw(
  pax_binary_source_hash pax_coverage_extract_root pax_coverage_perl5opt
);

my $hash = pax_binary_source_hash($binary_path);
my $root = pax_coverage_extract_root($hash);
local $ENV{PERL5OPT} = pax_coverage_perl5opt($db_path, $root);
system($binary_path, @args);
# $db_path now carries real per-line coverage for the binary's own
# extracted Pax/*.pm files.
```

Set `PERL5OPT` only for the exact `system`/`exec` call that runs the
binary under measurement - this is a per-invocation coverage concern, not
a standing environment change for every PAX binary run.

## What this does not yet cover

This closes the *mechanism* gap - Devel::Cover can now genuinely collect
data from a PAX-compiled binary's own code. It does not, by itself, wire
every existing test (`t/182`/`t/183`/`t/184`) into the main coverage-gate
run, nor does it claim `lib/Developer/Dashboard/Pax/*.pm` is at 100%
coverage - that is separate follow-up work, tracked on DD-929's own card.

## Related

- `uncoverable-annotations.md` - what an `# uncoverable` annotation
  asserts; this page is the alternative to reaching for one when a gap is
  actually measurable with the right mechanism instead.
