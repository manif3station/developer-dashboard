# PAX is vendored into this repository as `Developer::Dashboard::Pax::*`

What `Developer::Dashboard::PaxCache` and the internal `pax` command actually
compile against, as distinct from the earlier design that shelled out to an
external `pax` binary discovered via `PATH`. This page describes the current
state of the system, not any one ticket.

## What changed

PAX (a sibling adaptive Perl compiler/standalone-binary packager, originally
a separate project at `~/projects/pax`) is vendored into this repository
under `lib/Developer/Dashboard/Pax/*`, with every package renamed from the
bare `PAX::*` namespace to `Developer::Dashboard::Pax::*` and every internal
`use`/`require` reference updated to match. A real `pax` command is staged
at `share/private-cli/pax` (reachable as `dashboard pax` / `d2 pax`, and
internally as `~/.developer-dashboard/cli/dd/pax` once staged), dispatching
to the vendored library directly - no external process, no `PATH` lookup.

`Developer::Dashboard::PaxCache::_pax_bin` resolves the vendored/staged
`pax` command first, so the whole MD5-cache-then-compile flow works on any
machine that has this project installed, with zero dependency on whether a
separate PAX checkout exists or is discoverable on the caller's shell
`PATH`.

## Why this matters

Before vendoring, `PaxCache::resolve()` correctly and safely fell back to
"run interpreted, never attempt a compile" whenever `pax` was not on
`PATH` (see `docs/paxcache-md5-keyed-non-blocking-compile-cache.md`,
AC-4) - that fallback is honest and was working exactly as designed. The
owner's correction was that "pax isn't on PATH" should never be a reason
the compile flow silently never engages in the first place on a properly
installed system: PAX is now part of the Developer Dashboard ecosystem
itself, shipped and staged the same way every other internal tool is
(`share/private-cli/*`), not an optional external dependency the operator
has to separately install and remember to put on `PATH`.

## How to use this page

If you are updating PAX's own compiler logic, edit the vendored copy under
`lib/Developer/Dashboard/Pax/*` directly - there is no longer a live link
back to `~/projects/pax`; changes there do not propagate here automatically
and vice versa. If you are investigating why a PAX compile did or did not
happen, check `PaxCache::_pax_bin`'s resolution order first (vendored/staged
`pax`, not `PATH`) before assuming an installation problem.
