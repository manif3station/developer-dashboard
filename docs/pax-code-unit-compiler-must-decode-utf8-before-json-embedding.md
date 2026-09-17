# PAX's CodeUnitCompiler must UTF-8-decode source text before embedding it in JSON records

## The defect (DD-923)

`Developer::Dashboard::Pax::CodeUnitCompiler::compile()` reads `.pm`/`.pl` source
files with `_slurp()`, which opens them `:raw` — a deliberate, correct choice for
content-addressed hashing (`sha256_hex`) and for `eval`-ing the source directly,
since Perl's own `require`/`do FILE` also read source files without an explicit
decode layer, relying on the source's own `use utf8;` pragma to interpret literal
multi-byte characters at *compile* time.

That raw byte string is safe as long as it is only ever `eval`'d as Perl code. The
bug was that the SAME undecoded raw bytes were also used as the value embedded
directly into JSON records — the compiled-unit's `source_bytes`/`script_source`
field, and any `our $X = '<literal>';` value captured by `compile()`'s regex-based
initializer extraction — via
`JSON::XS->new->ascii(1)->canonical(1)->encode($record)`.

JSON::XS's `ascii(1)` mode escapes every non-ASCII character in the OUTPUT as
`\uXXXX`, but it does this per **Perl character**, not per **byte**. A Perl string
without the internal UTF8 flag set (a byte string — exactly what `_slurp`/`:raw`
produces) is treated by JSON::XS as a sequence of Latin-1 codepoints, one per byte.
So a 4-byte UTF-8 sequence for one emoji character (e.g. `f0 9f 9a a8` for 🚨,
U+1F6A8) got escaped as FOUR separate `\u00XX` codepoints (`ð¨`)
instead of the correct single (surrogate-paired) `🚨`. When that
corrupted text was later `eval`'d back into a Perl string and printed through a
`binmode STDOUT, ':encoding(UTF-8)'` layer, each of those four wrong Latin-1-range
characters got independently UTF-8-re-encoded, producing the observed mojibake
(`c3b0 c29f c29a c2a8` — a classic double-encoding signature).

This only manifested in a **PAX-compiled binary**, never in interpreted execution,
because interpreted `require`/`do FILE` never JSON-round-trips the source text at
all — the corruption is specific to the compile-time JSON-embedding step.

## The fix

Immediately after `_slurp($abs_path)` in both of `compile()`'s code paths
(`kind eq 'entrypoint'` and the library-module path), decode the raw bytes as
UTF-8 before using them further:

```perl
my $source = decode( 'UTF-8', _slurp($abs_path) );
```

`_slurp()` itself is left untouched (still `:raw`) — it is also used by
`_fallback_unit()` for genuinely byte-for-byte binary-asset embedding, where
content-hash integrity requires the exact original bytes, not decoded text.

JSON::XS's own documentation (ENCODING/CODESET FLAG NOTES) confirms this is the
correct mental model: the `utf8()` method controls whether `encode()`'s OUTPUT is
a byte string or a Perl-internal string — it does NOT retroactively decode an
already-byte-string INPUT. Adding `->utf8(1)` to the six `ascii(1)->canonical(1)`
encode call sites (an earlier, incorrect attempt at this fix) changes nothing when
the input lacks Perl's internal UTF8 flag; it was left in place afterward as
harmless, correct-intent documentation, but the actual fix is the `decode()` call
at the source.

## Why the existing test gate could not have caught this

`t/184-d2-self-compile.t` (DD-882's own self-compile dispatch test) seeds a fake
sentinel script as the "cached binary" rather than a real PAX-compiled one — it
verifies dispatch, never a real compiled binary's actual internal mechanics. See
DD-924 for the general lesson. The regression test for this defect,
`t/196-codeunitcompiler-utf8-round-trip.t`, performs a REAL `pax build` (matching
`t/183-pax-cli-build-run-contract.t`'s precedent) against a minimal fixture module
containing a literal non-ASCII character in a top-level `our $VAR = '...';`
initializer — the exact shape of `Developer::Dashboard::IndicatorStore`'s status
icons, which is what `dashboard ps1` renders.

## How to use this

Any future code that embeds Perl source text (or any string extracted FROM raw
`:raw`-read source bytes) into a JSON structure must UTF-8-decode it first if that
JSON will ever be re-materialized as text (printed, displayed, or re-parsed as a
Perl string literal) rather than only ever being `eval`'d directly as code.

## What uses this

`bin/dashboard` and `bin/d2`'s PAX self-compile mechanism (`_maybe_exec_self_compiled_dashboard`/
`_maybe_exec_self_compiled_d2`), and every command dispatched through a compiled
binary that reaches a required library module carrying a literal non-ASCII string
constant — `dashboard ps1`'s status icons (`Developer::Dashboard::IndicatorStore`)
being the concrete case that surfaced this.
