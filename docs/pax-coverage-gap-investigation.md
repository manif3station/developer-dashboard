# Pax coverage gap: real numbers, investigation methodology, and what it means

## The finding

CI's Devel::Cover gate genuinely completed a full run for the first time ever
on 2026-09-23 (job 107060018763, run 35823444473, commit ed5336b6), after
DD-1036 fixed a false-positive in the tree-fingerprint check that had made
every prior CI run refuse to report at all ("the code being graded changed
while the suite ran"). The real, CI-measured result for `lib/`:

```
statement 52.4   branch 49.9   condition 29.0   subroutine 69.8
```

This is far below this project's standing "100.0 on all four Devel::Cover
metrics" standard (CLAUDE.md), and — because the gate had never previously
completed in CI — that standard had, as far as could be determined, never
actually been confirmed against a real, clean CI environment. It had only
been confirmed against local/bare-host runs on the operator's own machine,
scoped to specific files.

## Investigation: is this a genuine gap, or an instrument artifact?

Two live differences existed between CI and the local environment that
could plausibly explain a lower CI number without any real testing gap:
a different Perl version, and different code paths being exercised by
different installed module versions.

**Perl version comparison.** Local operator Perl was 5.38.2; CI's
`test.yml` pins Perl 5.44 explicitly. A perlbrew install of 5.44.0 already
existed locally (matching CI's version exactly), so the coverage gate was
re-run against the full `lib/` tree inside a container pinned to that same
Perl 5.44.0, using a genuine fatpacked `cpanm` fetched fresh from
cpanmin.us (the system `/usr/bin/cpanm` is not portable across
perlbrew-managed Perl versions — it fails resolving core modules like
`strict.pm`).

Result, lib/ total under Perl 5.44.0:

```
statement 53.8   branch 50.7   condition 29.5   subroutine 70.9
```

Compared to CI's actual figures (52.4/49.9/29.0/69.8), these are within
~1.4 points on every metric — essentially the same number. **The
Perl-version-difference hypothesis is refuted**: under CI's own Perl
version, the same tree measures the same ~50%, not the near-100% the
project believed applied to the whole tree.

## Where the gap actually is

Rather than accept "the whole of lib/ has a testing gap," the real CI
job's per-file coverage table was pulled directly (`gh api
/repos/.../actions/jobs/107060018763/logs`) and split by subsystem —
101 files total, 61 outside `lib/Developer/Dashboard/Pax/` and 40 inside it:

- **Non-Pax (61 files): every single one measures 96.5% total or higher**,
  most exactly 100.0/100.0/100.0/100.0. The near-100% baseline this
  project believed in is real and CI-confirmed for this set.
- **Pax (40 files, `lib/Developer/Dashboard/Pax/*`): ranges 0.4% to 100%**,
  with the bulk in the 10-60% band (e.g. `CodeUnitCompiler.pm` 1.3%,
  `StandaloneRuntime.pm` 4.5%, `CLI.pm` 7.3%, `AppImage.pm` 14.4%).

The ~48-53 point aggregate `lib/`-wide gap is almost entirely arithmetic:
~40 low-coverage Pax files dragging the tree-wide average down while ~61
files are already at standard. This is one bounded, nameable subsystem
gap, not a diffuse project-wide shortfall.

## Consequence: every release since v4.31 has been silently blocked

Because CI's "Verify all-metric lib coverage" step has failed on every run
since the gate first completed, every `vX.XX` tag pushed since v4.31
(57 tags, v4.32–v4.88) has failed at that exact step — CLAUDE.md's claim
that pushing a version tag "fires the signed GitHub Release" has been
false in practice for months. Closing the Pax gap also unblocks the
release pipeline.

## Disposition

- **DD-1041** is the investigation/root-cause record. It produces no code
  change of its own.
- **DDE-008** ("Bring `lib/Developer/Dashboard/Pax/*` to 100 percent
  Devel::Cover on all four metrics") is the epic carrying the actual
  remediation, scoped to exactly the 40 Pax files this investigation
  identified. Michael decided (Q-189, option B) that this proceeds now as
  its own track, independent of the separate standing Pax IR-rewrite plan
  — writing tests against current Pax code is not deferred pending that
  multi-month architectural rewrite.

## Technical notes for anyone repeating this kind of comparison

- A perlbrew Perl install mounted into a container must be mounted at the
  same absolute host path inside the container — perlbrew embeds absolute
  paths in its shebangs/config, and a different mount path breaks it.
- The system `/usr/bin/cpanm` is not portable across perlbrew-managed Perl
  versions; use a fresh fatpacked `cpanm` from cpanmin.us instead.
- A background task's "killed" notification can describe only the
  harness's own output-capture wrapper being torn down (e.g. citing low
  host memory) — the actual computation, once launched via `docker compose
  exec`, is an independent process tied to the docker daemon and can
  survive and complete after the harness stops tracking it. Verify by
  checking the process table / resulting artifact (here, the `cover_db`),
  not by trusting the notification alone.
