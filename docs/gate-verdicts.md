# Gate verdicts: recording them, reading them, and the three states

How this project records the result of a full-suite or coverage run, how anything
downstream reads it, and the two obligations every reader has to preserve. This
page describes the system, not any one ticket.

## Why a verdict is recorded at all

Running a gate and reading its output are separated in time and usually in
process. A person runs the suite; a dashboard indicator, a sweep, or a monitor
wants to know the answer minutes or hours later. Something has to carry the
result across that gap, and the thing that carries it has to be honest about its
own limits.

Two artifacts do that:

| file | written by | carries |
|---|---|---|
| `<checkout>/.claude/state/gate2.log` | `.claude/tools/run-suite`, `.claude/tools/coverage-run` | the run's output, plus a `SUITE_EXIT=N` marker on **every** exit path |
| `<checkout>/.claude/state/gate2-verdict.txt` | `.claude/tools/coverage-run` | `GATE_EXIT=N` and `TREE=<tree-ish>` |

`.claude/tools/gate-status` is the reader. All three derive that directory from
their own location on disk, so the reader and the writers cannot disagree about
where to look. `DD_SUITE_LOG`, `DD_GATE_LOG`, `DD_COV_LOG` and `DD_COV_VERDICT`
override the defaults and keep precedence.

## The artifacts are PER CHECKOUT, and that is load-bearing

They were once a fixed pair of `/tmp` names. Every checkout, worktree and session
on the machine therefore shared one verdict file, and any two runs overwrote each
other.

**The overwrite is silent in the worst possible direction.** The reader finds *a*
verdict, so it reports a result rather than reporting that it could not look. A
coverage run completed with `WRAPPER_EXIT=0` and the verdict on disk was another
sandbox's, written seven minutes earlier; the run's own result was simply gone,
and nothing anywhere said so.

`TREE=` does not rescue this. It records **HEAD's** tree, and two sandboxes at the
same commit produce the same hash while carrying entirely different uncommitted
work — which is exactly what a sandbox gate grades. Two verdicts can be
byte-identical in their `TREE=` line and describe different code.

So the rule is: **an artifact shared by two workspaces is not an artifact, it is a
race.** Anything that records a result for later reading derives its path from the
workspace that produced it.

## The wrappers are not optional decoration

**Running `prove -lr t` or `cover` directly produces a result that no instrument
can verify.** The output is just as true, but it is unrecorded: nothing downstream
can tell that the run happened, what it concluded, or which tree it graded.

The wrappers exist for two specific failures, both recorded in their own headers:

- **`run-suite`** writes `SUITE_EXIT` on every exit path *including signals*, so
  "no marker" means genuinely still running. Without it a killed run is
  indistinguishable from a live one, and a suite stopped at 04:33 was reported
  RUNNING five minutes later.
- **`coverage-run`** records the verdict at all. Before it existed, the real gate
  could pass repeatedly while the indicator correctly said "no verdict was
  recorded" — because none was.

Neither wrapper is allowed to write a result the gate did not produce. A failing
run records a failure.

## `TREE=` is what makes staleness a fact

Within one checkout, the hard question about a recorded figure is *does it
describe the code in front of me?* Answering that from timestamps is guesswork: a
merge commit changes no files, so a verdict older than HEAD may describe HEAD byte
for byte, and a warning that fires after every merge is one people learn to scroll
past.

So the verdict records the tree it measured, and the reader compares tree hashes:

```
asked from a checkout whose HEAD tree is 420bf299d9  ->  FINISHED, GATE_EXIT=0, exit 0
asked from a checkout whose HEAD tree is 8b5b68442f  ->  STALE: it measured 420bf299d9, exit 2
```

Both are right. The figure is a verdict on a tree, not on a moment.

**Its limits, stated so nobody leans on it further than it goes.** `TREE=`
compares committed trees. It cannot distinguish two workspaces at one commit, and
it says nothing about uncommitted work. Per-checkout paths handle the first; the
second is open.

## The three states, which must never collapse into two

This is the part that matters most, and the part that is easiest to get wrong.

| state | what it means | how it must read |
|---|---|---|
| **PASS** | the gate ran and succeeded, on this tree | quiet |
| **FAIL** | the gate ran and failed | a finding naming what failed |
| **CANNOT LOOK** | no verdict, one about a different tree, or one older than the log beside it | a **distinct** finding, never silence and never a pass |

The third row is the one that gets lost. A reader that treats an absent verdict
as "nothing to report" turns a broken pipeline into a clean bill of health — and
it does so silently, which is the worst possible direction for the error to run.

This is not a local opinion. It is the same rule monitoring systems arrive at:
**zero and no-data are different states.** A zero means the collector observed a
value of zero; an absent series means there is no observation. Converting absence
into zero hides collector failures, vanished targets and misconfiguration.

`gate-status` encodes this in its exit codes rather than only in its prose:

```
0  a fresh verdict, and it passed
1  a run is in progress, or finished with no verdict recorded for it
2  a verdict exists but is not about this tree, or the run was invalidated
3  unusable - the tool could not resolve its own state directory, could
   not read an artifact's modification time, or there is no log at all
   and the gate has never run here
```

**A checker with no distinct "could not look" exit is a checker whose silence is
uninterpretable.** Any new reader of these artifacts inherits that obligation.

The same obligation binds the tools' own start-up. Each derives its state
directory from its own location, and if that derivation fails it says so and
exits 3 rather than continuing with whatever it managed to compute. That is not
defensive padding: the first cut of this code wrote

```sh
DD_STATE_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/state"
```

and a failed `cd` yields an **empty string**, so `DD_STATE_DIR` silently became
`/state` and the log `/state/gate2.log` - a path at the filesystem root, with the
`2>/dev/null` hiding the reason. A tool that guesses a path when it cannot
resolve one has converted "I could not look" into "here is an answer", which is
the single failure this page exists to prevent, occurring before the tool has
read anything at all.

## Ages are read portably, and an unreadable one is not zero

The verdict's age is part of how a reader decides whether to believe it, so the
mtime lookup carries the same obligations as everything else on this page.

**It must mean the same thing on every platform.** `stat -c %Y` is GNU coreutils;
BSD `stat`, which is what macOS ships, rejects `-c` outright. Run on a Mac, the
tool printed `stat: illegal option -- c`, threw a shell syntax error, and reported
an age of **496664 hours** — while exiting 0.

The obvious repair is worse than it looks. `stat -c %Y || stat -f %m` reads as
"try GNU, fall back to BSD", but on GNU `-f` means **file system** information —
a different operation, not the other spelling of the same one. If the first branch
fails for any unrelated reason, the second runs and answers a question nobody
asked, and its output is then treated as a modification time. So the lookup uses
Perl, which means the same thing everywhere and is already a hard dependency:

```sh
perl -e 'print((stat shift)[9])' "$file"
```

**And an unreadable mtime is not zero.** Two of the three original call sites
carried `2>/dev/null || echo 0`, which is precisely why a Mac reported 496664
hours rather than failing: the guard converted an error into a number, and a
number gets believed. Substituting an epoch is the same mistake as substituting a
verdict — it turns *could not look* into *here is an answer*, which is the one
thing this page exists to prevent.

An age that cannot be determined is reported as such, and the exit code says
unusable.

## A CI verdict must name the commit it describes

Everything above is about verdicts this project records for itself. The same
rule governs verdicts it reads from CI, and it is easier to get wrong there
because the answer arrives already formatted as a sentence about the branch.

`.claude/tools/ci-health` asks GitHub for recent workflow runs and answers "is
master green". A run carries a `head_sha`; the branch does not. So a verdict
phrased as *"all workflows are green on master"* is ambiguous by construction —
it is true of **some** commit, and nothing in the sentence says which.

That ambiguity is not academic. The project's standing rule is to re-check CI
**after** every push, because a green answer expires the moment you push. A
checker that reports the branch's last completed runs makes obeying that rule
produce the very false confidence it exists to prevent: you push, you dutifully
re-check, and you are told about a commit that is not yours.

**It fails in both directions**, which is the tell that the commit rather than
the conclusion is the missing piece:

- reported **green** from an earlier commit's runs — the false all-clear
- reported **red** from an earlier commit's runs — sends you investigating a
  failure you did not cause. Observed: a checker announced `Test is FAILURE on
  master` for a run whose `head_sha` was the *previous* commit, while the run for
  the just-pushed one was still queued.

### The fourth state

`TREE=` gives local verdicts three states — clean, failed, could-not-look. A CI
verdict for a specific commit needs a **fourth**:

| state | meaning |
|---|---|
| green | every workflow for THIS commit finished and passed |
| red | a workflow for THIS commit failed |
| could-not-look | the API, or the head SHA, could not be read |
| **not yet verified** | runs for THIS commit exist but have not finished |

The fourth is the one that matters immediately after a push, and the one most
easily folded into the others. Two ways it gets lost:

- **Folded into green by omission** — the in-flight run is skipped and an older
  completed run answers instead.
- **Folded into green by partial completion** — one of four workflows has
  finished, it passed, and the checker says green. Measured: `all 1 workflows
  are green on master@e1aec20 (3 still running)`, exit 0. The commit was right
  and the answer was still premature; a caller acting on that exit status
  proceeds on a quarter of the evidence.

**A failure still outranks pending.** Something that has already gone wrong does
not become unknown because something else is unfinished.

### Resolve the head from the server

The commit to judge is the branch head **as the server sees it**. A local
`origin/master` is a snapshot of the last fetch, so comparing against it can
report a confident zero difference for ever. `git ls-remote` asks the server and
cannot be fooled by a stale local ref — the same reasoning that governs "am I
behind" checks elsewhere in this project.

## Reviewing a change against this

1. Does this code decide whether a gate passed?
2. Can it tell "passed" from "did not run"? If those share a code path, it is
   already wrong.
3. Does it compare **trees**, or timestamps? Timestamps are a guess.
4. Where does it write, and could a second workspace be writing there too?
5. If the artifacts are missing entirely, does it say so loudly, or return
   quietly?
6. Has the missing-data case actually been *simulated*, rather than reasoned
   about? Delete the verdict and watch what it does.
7. Does it read a file's mtime? If so, does it work on BSD as well as GNU, and
   does an unreadable mtime report unusable rather than becoming zero?
8. **Does a test exercise the path chosen when nothing is configured?** A spec
   that sets `DD_COV_VERDICT` explicitly can never test the default it is
   overriding, and the shared-`/tmp` defect lived in exactly that blind spot for
   the whole life of the specs that were meant to cover it.

Points 6 and 8 are the ones that find the others. A reader that has never been run
against an absent verdict has not been tested; it has been read.
