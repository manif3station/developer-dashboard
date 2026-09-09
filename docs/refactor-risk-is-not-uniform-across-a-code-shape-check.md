# A code-shape check flags a shape, not a risk level

Why "6 subs over 120 lines" is not 6 equally-cheap refactors, and how to
triage before starting one.

## The problem this solves

`imp-long-subs` (and similar shape checks - long files, deep nesting,
duplicated blocks) reports every match with the same severity: it counts
lines, not consequences. Extracting a helper out of
`Developer::Dashboard::CLI::Paths::run_paths_command` and extracting one
out of `Developer::Dashboard::CollectorRunner::start_loop` look identical
in the check's output - one line each, same threshold crossed - but they
are not the same task. The second is process-lifecycle code: a mistake in
the extraction can change fork/reap/signal timing in ways `prove -lr t` on
this host will not catch, and this project's own rule already says so -
the E2E cross-platform gate applies "whenever the change touches
OS/distro-sensitive behavior (process/signal handling, ..., collectors,
path resolution)".

DD-637 (six subs over 120 lines) is the case: four sites are ordinary CLI
dispatch, template rendering, and config resolution; two
(`CollectorRunner::start_loop`,
`RuntimeManager::_supervise_collectors_once`) are exactly the collector/
process-lifecycle class the E2E rule names.

## The rule

> **Before starting a refactor drawn from a code-shape check's list,
> classify each item by what kind of code it touches, not just by the
> metric that flagged it.** Process/signal/collector/path-resolution code
> needs the cross-platform E2E gate re-run after the change; everything
> else needs the ordinary suite and coverage gates. Treat the check's
> output as a worklist to triage, not a queue to work in the order given.

## How to apply

- Read each flagged site before touching any of them. A shape check has no
  opinion on what the code does - only a human (or an agent) reading it can
  tell "CLI argument dispatch" from "supervises a forked collector loop".
- Sequence lower-risk items first when a list mixes risk levels: the cheap
  wins land sooner, and the expensive ones get the verification budget they
  actually need instead of being rushed to match the pace of the easy ones.
- This generalises past subroutine length: file-size checks, duplication
  checks, and cyclomatic-complexity checks all report a shape with no idea
  what the shape is made of. The check earns you a worklist; the triage is
  still yours.
