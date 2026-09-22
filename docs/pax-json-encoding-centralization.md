# Pax module JSON encoding goes through the shared wrapper

This page describes the current behavior of the system, not any one
ticket. Every `lib/Developer/Dashboard/Pax/*.pm` module that needs to
serialize a Perl value to JSON does so through
`Developer::Dashboard::JSON`'s `json_encode` or `json_encode_with_options`,
never by constructing `JSON::XS->new->...->encode(...)` directly - the one
documented exception is `Pax::Capture`'s isolated child-probe script,
explained below.

## Why this matters

`Developer::Dashboard::JSON` exists specifically so the whole project uses
one consistent JSON backend and output style. Before this change, at least
nine call sites across the Pax subsystem hand-rolled their own
`JSON::XS->new->...->encode()` chains, and their option sets had already
drifted from each other - some ASCII-safe, some not; some pretty-printed,
some compact; two call sites even encoded the same kind of payload (a build
manifest) with different options. That kind of drift is exactly what a
shared wrapper is supposed to prevent, and nothing had stopped it from
recurring in this particular subsystem.

## `json_encode_with_options`

```perl
use Developer::Dashboard::JSON qw(json_encode_with_options);

json_encode_with_options($value);                          # canonical only
json_encode_with_options($value, pretty => 1);              # canonical + pretty
json_encode_with_options($value, ascii => 1);                # canonical + ascii
json_encode_with_options($value, ascii => 1, pretty => 1);   # canonical + ascii + pretty
json_encode_with_options($value, ascii => 1, utf8 => 1);      # canonical + ascii + utf8
```

`canonical` is always on - every call site in this codebase needs stable
key ordering, and there is no known case that doesn't. Every other option
(`ascii`, `pretty`, `utf8`) defaults off, matching `JSON::XS`'s own
defaults, so a caller only names what it actually needs. `json_encode`
itself is unchanged - it remains the fixed `utf8+canonical+pretty` encoder
it always was, for the common case that doesn't need to differ.

## The one documented exception: `Pax::Capture`

`Pax::Capture::_probe_source` returns the literal source text of a
standalone Perl script that gets piped to a **child process** via
`open3($^X, '-', $entrypoint, $mode)` - with no `-I` lib path. That child
process's `@INC` has no guaranteed way to find
`Developer::Dashboard::JSON`, because it may run in exactly the
packaged/installed scenarios the Pax subsystem exists to support, where
this project's own `lib/` tree is not necessarily present at all.

That one line (`print JSON::XS->new->ascii(1)->canonical(1)->encode($result);`
inside the probe script) is deliberately left constructing `JSON::XS`
directly, with the reason documented in a comment immediately above it in
`Pax::Capture` itself.

## Verification

`t/208-json-centralization.t` proves two things: that
`json_encode_with_options` reproduces every option combination the nine
original call sites used, byte-for-byte identical to constructing
`JSON::XS` directly with the same options; and that no
`lib/Developer/Dashboard/Pax/*.pm` module (excluding `StandaloneRuntime.pm`,
which is self-contained by design and cannot depend on `lib/` modules at
all, `CodeUnitCompiler.pm`'s own regex-recognition of `json_encode`/
`json_decode`'s source text during self-compilation, and `Pax::Capture`'s
documented exception above) constructs `JSON::XS` directly any more.
