# The lib/ coverage gap is almost entirely the Pax subsystem

## What this is

DD-1041 found that CI's coverage gate (`script/coverage-gate`) reported a
real number for the first time ever immediately after DD-1036 fixed a
tree-fingerprint false positive that had silently refused every prior CI
run. The real, CI-measured `lib/` total came back at 52.4% statement,
49.9% branch, 29.0% condition, 69.8% subroutine - far below this project's
standing "100% on all four Devel::Cover metrics" invariant.

## Where the gap actually is

Pulling the real CI job's own per-file coverage table (job
`107060018763`, run `35823444473` - the run DD-1036's fix unblocked) and
splitting it by subsystem:

- **61 non-Pax `lib/` files: every one is 96.5% total or higher**, most
  exactly 100.0/100.0/100.0/100.0. This is the near-100% baseline this
  project has believed applied to the whole tree, and for non-Pax code it
  is genuinely true and CI-confirmed.
- **40 files under `lib/Developer/Dashboard/Pax/`: range from 0.4% total
  (`CodeUnitCompiler.pm`) to 100%**, with the bulk sitting in the 10-60%
  band (`StandaloneRuntime.pm` 4.5, `CLI/Progress.pm` 4.9, `CLI.pm` 7.3,
  `StandaloneAnalysis.pm` 9.9, `Gatekeeper.pm` 12.7, `StandaloneImage.pm`
  12.3, `InlineCache.pm` 12.9, `Paxfile.pm` 11.5, `AppImage.pm` 14.4,
  `DeoptEngine.pm` 14.5, and roughly 30 more). Only a handful
  (`CoverageSelect.pm`, some `Backend/` tiers) already reach 100%.

The ~48-53 point aggregate gap is almost entirely arithmetic: ~40
low-coverage Pax files dragging the `lib/`-wide average down while ~61
other files are already at standard. It is one bounded, nameable
subsystem gap, not a diffuse project-wide testing shortfall.

## What was ruled out

The obvious alternative explanation - CI's Perl 5.44 differing from the
operator's local 5.38.2/5.40.1 in a way that changes which code paths
execute - was tested directly: a full-suite Devel::Cover run under a
container pinned to Perl 5.44.0 (matching CI exactly) measured `lib/` at
53.8/50.7/29.5/70.9, within ~1.4 points of CI's real figures on every
metric. The Perl version is not the explanation. Under CI's own Perl
version, the local tree measures the same ~50% CI does.

## Why this also explains the release outage

CI's `Verify all-metric lib coverage` step is the gate that pushing a
`vX.XX` tag depends on to fire the signed GitHub Release. Every tag from
v4.32 through v4.88 (57 tags) has failed at that exact step since v4.31 -
the release pipeline has been silently broken this entire time, not just
the coverage metric.

## What this does NOT mean

Bringing `lib/Developer/Dashboard/Pax/*` to 100% is separate from, and not
blocked by, the standing multi-month plan to rewrite Pax's compilation
architecture from source-pattern-matching to a real IR-driven native
compiler (see the project's own PAX architecture plan). Michael answered
this explicitly (Q-189 on DD-1041): remediate coverage on the current code
now, as its own independent track, rather than deferring it to or
interleaving it with that rewrite.

## Where the actual remediation lives

DDE-008, "Bring lib/Developer/Dashboard/Pax/\* to 100 percent
Devel::Cover on all four metrics" - the epic spun out to carry the
file-by-file test-writing work. DD-1041 remains the investigation/root-
cause record; it produced no code change of its own.

## Per-file remediation status

One ticket per file (or small group), each verified via
`cover -report -select_re '^lib/Developer/Dashboard/Pax/<FILE>$'` inside a
container matching CI's Perl 5.44, never a local bare-host approximation.
Baselines are all from the same CI job/run named above.

| File | Baseline | Ticket | Status |
|---|---|---|---|
| `CLI/Progress.pm` | 4.9% | DD-1056 | open |
| `CLI.pm` | 7.3% | DD-1057 | WIP - 11/51 subs covered (helpers + run() dispatch), ~40 diagnostic-subcommand subs remain |
| `StandaloneAnalysis.pm` | 9.9% | DD-1058 | open |
| `Paxfile.pm` | 11.5% | DD-1059 | open |
| `StandaloneImage.pm` | 12.3% | DD-1060 | open |
| `Gatekeeper.pm` | 12.7% | DD-1061 | open |
| `InlineCache.pm` | 12.9% | DD-1062 | open |
| `AppImage.pm` | 14.4% | DD-1063 | open |
| `DeoptEngine.pm` | 14.5% | DD-1064 | open |
| `CodeUnitCompiler.pm` | 0.4% | not yet filed | pending Q-194 (sequencing against DD-927's decomposition) |
| `StandaloneRuntime.pm` | 4.5% | not yet filed | pending Q-194 (sequencing against DD-988's decomposition) |
| remaining ~29 files | 15-90% band or already 100% | not yet filed | to be ticketed in further batches |

Update this table's Status column (and add new rows as further batches are
ticketed) as each remediation ticket closes - do not let it go stale, since
this is the one page a stranger can read to answer "is the Pax coverage gap
closed yet, and if not, what's left."
