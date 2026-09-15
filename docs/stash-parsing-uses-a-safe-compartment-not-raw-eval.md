# Legacy STASH text is parsed inside a Safe compartment, never via raw eval

`Developer::Dashboard::PageDocument::_decode_stash_section` decodes a saved
bookmark's legacy STASH section - a Perl-hash-literal-like text body such as
`foo => 1, bar => 'baz', nested => { a => 1 }` - into a real hash reference.
It does this by evaluating the text inside a `Safe` compartment carrying a
minimal, explicitly-permitted opcode set, never via a raw string `eval`.

## Why this matters (DD-896)

STASH text is not trusted input. `PageDocument->from_instruction()` is
reachable from six call sites, including directly from an HTTP body/query
parameter in `Web::App::root_response` - any authenticated user with the
ordinary "can edit a page" permission (not an elevated tier) can submit a
page's raw instruction text, and that text's STASH section is parsed on
every load, not only on save.

The original implementation evaluated STASH bodies with a raw string
`eval "+{ $text }"`. A STASH body of

    1}; system('touch', '/tmp/pwned'); {

closes the anonymous-hash constructor early, executes an arbitrary
statement, then reopens a hash literal to keep the surrounding Perl
syntactically valid - live-reproduced, this created the marker file with
no web server involved, confirming the vulnerability lived in the parser
itself, independent of any particular call site's auth gate.

## The fix: an explicit, minimal opcode allowlist

`_safe_eval_stash_literal` creates a fresh `Safe` compartment per call and
calls `permit_only` with an explicit list, rather than starting from any
broad tag like `:base_core` or `:default` and trying to deny the dangerous
parts:

    our @STASH_SAFE_OPS = qw(
      padany const stub null pushmark list lineseq leaveeval scope
      anonhash anonlist undef rv2gv
    );

**Deliberately excludes `entersub`.** `:base_core` includes it, and
permitting it would not merely allow "safe" subroutine calls - Safe's
opmask restricts only code *compiled inside* the compartment; a
permitted `entersub` lets sandboxed code call *any* subroutine already
compiled elsewhere in the process, with that subroutine's own full,
unrestricted privileges. This is Safe.pm's own documented caveat, and
it is the reason a broad tag-minus-deny approach is the wrong shape for
this problem: the STASH grammar needs zero subroutine calls (it is pure
data-literal construction), so the correct mask has zero entersub-family
ops in it at all, not a deny-list trying to subtract every dangerous
consequence of having permitted it.

**`rv2gv` is required for Safe's own bootstrap, not for STASH syntax.**
Perl 5.38.2 (this project's bare-host interpreter) needs it to create the
compartment's private namespace; Perl 5.40.1 (the `developer-dashboard:
latest` container) does not. Verified empirically on both - permitting it
alone (without `gv`, `sassign`, or `srefgen`) does not reopen a path to
dangerous functionality; nine distinct attack shapes (`system`, backtick/
`qx`, `open`, `require`, calling an arbitrary already-compiled sub via
`entersub`, and two glob-based symbolic-reference tricks) all remain
blocked with it present.

## Verifying a change to the opcode list

Before adding any op to `@STASH_SAFE_OPS`, verify on **both** Perl
versions this project runs on (bare-host and the `developer-dashboard:
latest` container - they can differ, as `rv2gv` did) that:

1. Every legitimate STASH shape `_legacy_value`/`_legacy_stash_text`
   produce still parses (nested hash/array, quoted strings with
   backslash-escapes, bare numbers, `undef`).
2. `t/192-stash-eval-injection.t`'s full attack-shape set still blocks -
   `system`, backtick/`qx`, `open`, `require`, an `entersub` call to an
   arbitrary sub, and glob-based symbolic-reference tricks.

A new op that makes a legitimate shape parse is not automatically safe to
add merely because it fixes that one test - check what else that opcode
unlocks in combination with what is already permitted (the glob-tricks
above are exactly this kind of combination risk, not a single op in
isolation).

## Safe.pm needs the FULL `perl` package, not a minimal `perl-base`

Debian/Ubuntu container base images ship a `perl-base` binary (needed by
`dpkg`'s own scripts) without `perl-modules` - and `Safe.pm` lives in
`perl-modules`, not `perl-base`. A guard shaped like `command -v perl ||
apt-get install perl` sees the pre-installed `perl-base` binary, concludes
nothing is needed, and skips installing the package that actually carries
`Safe.pm` - `Can't locate Safe.pm in @INC` at require time, even though
`perl` itself runs fine. This project's own `aptfile` lists the bare
`perl` metapackage unconditionally (no `command -v` guard), which pulls in
`perl-modules` correctly - confirmed directly: `apt-get install perl` on a
clean `ubuntu:24.04` installs `perl-modules-5.38` and `Safe.pm` loads. The
trap is specific to ad-hoc install guards, not this project's own
bootstrap path.

Verified end to end on both distro families this project's blank-host
bootstrap targets: `ubuntu:24.04` (glibc, apt) and `alpine:3` (musl, apk)
both parse every legitimate STASH shape correctly and block the live
exploit payload, using an unconditional (never `command -v`-guarded) full
`perl` install.

## Related

- `docs/html-escaping-convention.md` - the equivalent discipline for
  HTML/JS-string output (DD-892, DD-895): this page is the same idea
  applied to structured-data *input* parsing rather than output escaping.
