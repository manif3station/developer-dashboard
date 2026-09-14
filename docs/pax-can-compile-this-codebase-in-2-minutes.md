# PAX can compile `bin/dashboard` into a standalone binary in ~2 minutes

Whether the sibling PAX project (`~/projects/pax`, a Perl-native adaptive
compiler and standalone-binary packager) can actually compile this
codebase, and what it costs - measured directly, not assumed. This page
describes a capability of the product's build tooling, not a ticket.

## What was measured (DD-871, 2026-09-14)

A real `pax build bin/dashboard -o <out>` run, in a `perl:5.42.0`
container (PAX's own target Perl version), against a full writable copy
of this checkout:

- **Compile time: 2m12.174s real** (1m56.953s user CPU). Not the >1 hour
  the owner named as a risk going in.
- **Output: a 133,417,496-byte standalone ELF executable**, dynamically
  linked, `bundled_perl` runtime mode (embeds `libcrypto`, `libssl`,
  `libz`, `libzstd`, `libgdbm`, `libperl.so` as payloads - the source
  tree and host CPAN installation are not needed to run it afterward).
- **Zero code adjustments needed.** All 63 discovered Perl source units
  (62 application files + the entrypoint), all runtime dependencies (37
  packaged), and all 17 bundled XS modules compiled cleanly on the first
  attempt. This includes code this project already knows uses dynamic
  method dispatch (`Handle::Proxy`'s AUTOLOAD chain, the allowlisted
  `$self->can($name)` fallbacks fixed in DD-868/DD-870) - PAX's
  explicit-fallback-to-interpreted-Perl design absorbed all of it without
  a compile-time failure.
- **Correctness verified**: the compiled binary's `version` subcommand
  printed `4.31`, matching the source checkout's actual version exactly.

## What was NOT tested

- Only the `version` subcommand was run against the compiled binary. Most
  of `bin/dashboard`'s command surface is lazily staged at runtime from
  `share/private-cli/` (the LAZY-THIN-CMD architecture) rather than
  statically `use`'d - PAX's static analysis may not see code paths only
  reached through that staging mechanism. Whether the FULL CLI surface
  (`docker compose`, `collector`, `ask`, etc.) works identically through
  the compiled binary is still open.
- Only `bin/dashboard` was targeted. `bin/d2` is a 15-line exec-wrapper
  that re-execs `bin/dashboard` and has nothing meaningful to compile on
  its own.
- The web server (`Web::Server`/Starman) and collector processes were
  explicitly out of scope (owner decision, DDS-001/Q-160) - not attempted.
- Compile time was measured on a `perl:5.42.0` container with the base
  image already cached; a cold pull adds a few minutes on top (not part
  of the compile-time figure itself).

## How this fits the wider PAX-integration effort

This page records a capability measurement, not the implementation. The
actual "compile-once, cache, run the binary" wrapper (a version-aware
cache-miss-triggers-background-compile design, per SOW DDS-001's recorded
owner decisions) is separate, later work under epic DDE-002 - this page
exists so that work starts from a measured baseline instead of repeating
this spike.
