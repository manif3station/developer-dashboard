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
| `<checkout>/.claude/state/gate2-suite.log` | `.claude/tools/run-suite` | the suite's own output, plus a `SUITE_EXIT=N` marker on **every** exit path |
| `<checkout>/.claude/state/gate2.log` | `.claude/tools/coverage-run` | the coverage gate's output, plus a `SUITE_EXIT=N` marker |
| `<checkout>/.claude/state/gate2-verdict.txt` | `.claude/tools/coverage-run` | `GATE_EXIT=N` and `TREE=<tree-ish>` |

**These logs used to be the SAME file (DD-695).** `run-suite` and
`coverage-run` both defaulted to `gate2.log`, and each truncates its log at
startup - so the standard gate chain, `run-suite && coverage-run`, silently
destroyed the suite's own `Files=`/`Tests=`/`Result:` report the moment the
coverage run started, leaving only its exit status (and only if the caller
had captured it). `run-suite` now defaults to its own file; `DD_SUITE_LOG`
still overrides for anyone who set it explicitly, and `gate-status` (which
reads `coverage-run`'s artifacts specifically) is unaffected.

`.claude/tools/gate-status` is the reader. All three derive that directory from
their own location on disk, so the reader and the writers cannot disagree about
where to look. `DD_SUITE_LOG`, `DD_GATE_LOG`, `DD_COV_LOG` and `DD_COV_VERDICT`
override the defaults and keep precedence.

**A fourth consumer, `.claude/tools/hunt-monitor`, missed this move (DD-702).**
Its default paths were left pointing at the old fixed `/tmp/dd-gate2.log` and
`/tmp/dd-gate2-verdict.txt` names, which nothing has written since the move to
per-checkout state. Neither file existed, so hunt-monitor filed cards reporting
a "verdict predates log" finding that was really a "these files do not exist"
non-finding (DD-697). It now derives `DD_GATE_LOG`/`DD_GATE_VERDICT` from the
same `STATE_DIR` the other three use, and picks up the same override variables.

**The guard for this class of bug is `.claude/tools/t-gate-artifact-paths`.**
It no longer iterates a hardcoded three-tool list (the gap that let hunt-monitor
go unnoticed): it discovers every tool under `.claude/tools/` that references
the gate2 artifact pair or a `DD_GATE_*`/`DD_SUITE_*`/`DD_COV_*` variable, and
asserts on the discovered set. A fifth consumer is therefore covered by
construction the day it is added, not by someone remembering to extend a list.

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

## A verdict must say what the HOST was doing, not just what the tree was

`TREE=` fixes the verdict to a tree. Nothing fixes it to the conditions it ran
under — and on a shared machine those conditions decide whether the number means
anything.

Contention makes timing-sensitive tests misread. That produces false **failures**,
not false passes, so the asymmetry is usable: a PASS under load is valid evidence,
a FAIL under load is not believable either way and must be re-run. **The direction
has to be fixed before the number exists**, or it is not a rule — a result accepted
when it reads green and rejected when it does not is just preference wearing a
process.

### What the wrappers know, and what they do not

`run-suite` and `coverage-run` record the exit status, the tree and the timing.
Neither records whether anything else was competing for the machine. A verdict can
therefore be produced by a run that spent half its time behind another project's
coverage suite, and nothing in the artifact says so.

Stating conditions by hand in the log header — which is what a careful operator
does — records them **at launch only**. A run that becomes contended after it starts
looks identical to one that never was.

### Why load average is the wrong signal

Two independent reasons, and the second is the one that surprises:

1. A busy machine differs qualitatively from a competing **coverage** suite. Load
   conflates them.
2. **Load cannot distinguish the measurer's own work from anyone else's.** Measured
   on this host: two leaked containers belonging to the measuring session pushed
   loadavg to 11.81. A wrapper refusing to start on that number would have been
   refusing on its own leaked work.

So the signal is a count of **foreign** coverage processes — and "foreign" must
exclude self, determined by *checking* (own pid, own process group, own container
id) rather than by how a process looks. Identifying a running suite as another
project's from its test filename has already been wrong here; the discriminator
that works is `git cat-file -e <master-sha>:<path>`.

### The constraint that decides the design

The documented failure of contention reporting is that **people stop reading it**.
This host is busy most of the time — three readiness attempts once found no clear
window in ninety minutes. A detector that marks nearly every run CONTENDED carries
no information and gets skimmed, which is the fate of any guardrail that is always
red.

So the mark has to distinguish contention that **invalidates** from contention that
merely **slows**. That is not a refinement of the feature; it is the thing that
keeps the feature worth having.

### The rule, and how it was got wrong first

**More than a quarter of the sampled windows invalidates. At or below that, the
run was slowed and its verdict stands.**

The measure is the *fraction of the run that competed*, not whether competition
ever occurred, because that fraction is the quantity deciding how much of the
measurement is compromised. A run that shared the host for one twenty-second
window out of a twelve-minute suite was slowed by an amount too small to change
a pass into a failure; a run that shared it for a third of its length was not
measuring what it claimed to measure. `SLOWED` is recorded rather than
suppressed — the fact is kept, only its verdict changes.

Strictly-greater is deliberate: it keeps a single hit in a four-sample run on
the SLOWED side, so the classification cannot turn on how long a test stand-in
happened to sleep.

**The paragraph above this one was written before the rule existed, and the code
agreed with it in a comment while doing something else.** The condition shipped
as `peak > 0` — any foreign process at any single instant — directly beneath a
comment reading *"Reserved for contention that INVALIDATES. A mark on nearly
every run carries no information and gets skimmed, which is the fate of any
guardrail that is always red."* The comment described a discriminator; the code
implemented a boolean.

It was caught by using the tool, not by reviewing it. Two real runs on the
morning of 2026-09-01:

| run | peak | windows | of samples | fraction | truth |
|---|---|---|---|---|---|
| 09:02 | 12 | 15 | 50 | 30% | genuinely invalidating |
| 09:24 | 2 | 1 | 39 | 2.6% | transient, on a host verified quiet at launch |

Both were marked identically, and the second was the run that had been launched
*deliberately* on an idle host to earn a clean verdict. Two runs, two marks, is
already the "always red" the comment warned about — and the checklist item
covering the threshold had been ticked.

The general shape is the one this project keeps paying for: **a stated mechanism
inside work that is otherwise correct.** The sampler was right, the self-exclusion
was right, the signal handling was right, and every assertion passed — because
nothing asserted the distinction the comment promised. A test suite confirms the
behaviour someone thought to describe; a comment describing behaviour nobody
tested is a claim, and claims are what the next person reuses. The guard now in
place asserts the arithmetic rather than the presence of a variable name, and was
falsified by reverting the condition and watching it go red in both tools.

### A verdict sentence must state what was LOOKED FOR, not what was concluded

The classification above decides whether a run stands. The sentence it prints is
what everybody actually reads, and it is a separate thing that can be wrong on its
own.

The message said, for years:

    CONTENDED: a foreign coverage run held the host for N of M sampled windows

Two claims in one line, and neither is what the instrument establishes.

**"A foreign COVERAGE run" names a different set from the one counted.** While the
pattern matched `Devel::Cover` only, the sentence claimed *more* than the grep
looked for — a competing plain `prove` was invisible, and a run reporting no
foreign coverage was read as a quiet host. Once the pattern widened to cover the
harness, the same sentence began claiming *less* than the grep looks for: a plain
`prove` is now counted and then described as something the message says was not
there. **The defect reversed rather than disappeared**, which is worth noticing
because widening the instrument felt like fixing it.

**"HELD THE HOST" is an inference, not a measurement.** What was measured is that
a matching process was *seen in a sample*. It may have been idle, blocked on IO,
or a leftover nobody reaped. The verdict is still right to distrust the run — a
competing process usually is competing — but the sentence should not assert a
mechanism nobody looked at.

So the line now reads:

    CONTENDED: a foreign test or coverage process was seen in N of M sampled windows (peak P)

#### The figure must carry its own definition

A contention percentage is meaningless without knowing what was counted, and this
is not hypothetical: eleven figures recorded on this page were gathered under the
narrow definition, the definition then changed, and **nothing in any log said
which one produced which number.** A later reader comparing a fresh percentage
against them is comparing two different measurements and has no way to tell.

The marker line therefore names the pattern it used:

    FOREIGN_PEAK=N FOREIGN_SAMPLES=M WINDOW_SAMPLES=W FOREIGN_PATTERN=<pattern>

That makes every figure self-describing, so two eras are distinguishable by anyone
reading the artifact, without needing to know which release wrote it.

#### The bound is real: argv matching is defeatable

Detection is by command line, and **a process can rewrite its own argv** — measured
here, where a perl process reported itself as `innocent-looking-daemon`. The specs
depend on exactly that to build stand-ins, so the same mechanism is available to
anything that would rather not be counted.

The obvious fallback does not rescue it. It is widely repeated that overwriting
`argv[0]` cannot defeat identification because `ps` reads `/proc/PID/comm`, a
separate mechanism. **That is false for perl**, which sets both: measured on this
host, argv read `innocent-looking-daemon` and `comm` read `innocent-lookin` — a
15-character truncation of the same fake name, not a surviving original.

`/proc/PID/cgroup` was considered as a more robust signal and rejected. It cleanly
separates containerised work from host work and is immune to argv rewriting, but
it cannot see a bare host-side `prove` belonging to no container — which is the
case the widening existed for. It would swap one partial signal for another.

**Hence the wording rather than a better detector.** The honest response to a
bound you cannot remove is a sentence that states it, so the number is read with
the caution it deserves.

### What such a detector must not do

It must not kill anything — not its own run, and not another project's process.
Killing a contended run loses the work and frees nothing once the run is nearly
done. And it must not reach across projects: their containers are out of bounds and
their locks are not ours to take. We are a **tenant** on this machine, not its
operator, which is precisely why detect-and-annotate is the only available remedy
rather than one option among several.

### The pre-run WAIT and the in-run SAMPLER are two mechanisms, and they must share one definition

Everything above describes the sampler that runs *during* a gate and classifies
the result afterwards. There is a second, earlier decision: whether to launch at
all. On a host that is busy most of the time, waiting for a quiet window is what
makes a clean verdict obtainable, and that wait is a different piece of code
running at a different moment.

**The hazard is not that the two are separate. It is that they can disagree about
what "foreign" means**, and then a run is launched as clear by one definition and
classified against the other. Measured on 2026-09-02:

| | mechanism | what it counts as foreign |
|---|---|---|
| the in-run sampler | a `ps` pipeline | a `Devel::Cover` process |
| the pre-run waits | walks `/proc` | `Devel::Cover` **or** a foreign workspace path |

Neither of those is the right definition, and finding out which cost a shipped
defect. The *diagnosis* behind the wider one is sound: a foreign coverage suite
running in a container spends part of its life between individual test files,
where no `Devel::Cover` process exists at that instant but the machine is still
committed to that work, and a definition sampling only for `Devel::Cover` reads
those gaps as a quiet host.

**The path-based remedy did not follow from that diagnosis, and it was shipped
before anyone ran it against the real process table.** Measured on this host:

| pattern | matches |
|---|---|
| `Devel::Cover` or a `/workspace/` or `/skills/` path | **19** |
| `Devel::Cover` or `prove` or `cover` as a command | **2** |

Eighteen of the nineteen were a policy bridge, a `tail -F` on a log, and another
project's watcher — none of them competing for the machine. A wait using that
definition would **never** launch, which is a worse failure than the narrow
pattern it replaced, and a harder one to recognise: a too-wide detector fails
*closed*, so it presents as a permanently busy host rather than as a matching bug.

What actually spans the gaps is the **harness**, not a path. `prove` forks one
child per test file and the parent persists for the whole run, so it is visible
in the gaps the wide pattern was reaching for. Observed directly: a foreign
`prove` parent stayed alive while its child moved from one test file to the next.

Two lessons, and the second is the one that generalises past this file:

- **A widening is a claim about a population nobody has counted.** Run the
  matcher against the real population and read the *members*, not the total — a
  count of 19 looks like a busy host, while the member list is what shows most of
  them are a log tailer.
- **The requirement is stronger than "do not duplicate the code": one definition,
  obtained from one place by both callers.** Two copies of a rule that agree
  today are two rules tomorrow, which is why the operator-tool spec asserts that
  the two fingerprint expressions elsewhere in this system are textually
  identical rather than merely both present.

### Self-exclusion by process group is not enough when the gated run leads its own group

`run-suite` starts `prove` under `setsid`, deliberately, so that a kill can signal
the whole test process group rather than just the wrapper. That is the same
mechanism the negative-PID kill depends on — and it puts `prove` in a *different*
process group from the sampler measuring it.

Self-exclusion is by process group. So the sampler excludes itself and **not the
run it exists to measure.**

While the definition matched only `Devel::Cover` this was invisible, because a
plain `prove` never matched it. Widening the definition to cover the harness
exposed it immediately:

| | FOREIGN_PEAK | verdict |
|---|---|---|
| before the fix | **2** | CONTENDED, 14 of 14 windows |
| after | **1** | the ambient baseline — one genuinely foreign run present |

A peak of 2 with exactly one real foreign run on the host is the whole finding.
The consequence was not a wrong number: `CONTENDED` means *the verdict does not
stand*, so every gate on this machine would have been invalidated against itself
and **no run could produce a usable verdict at all**.

The fix is for the caller to name the group it is gating — `run-suite` reads its
child's pgid from `ps` after launching and passes it as an additional exclusion.
Read from `ps`, not assumed equal to `$!`: `setsid` forks when it is already a
process group leader, and then `$!` is the `setsid` process rather than `prove`.

**Two things about how this was found are worth more than the fix.**

The existing spec had a self-exclusion case, and it passed throughout. It sets the
probe override, so it exercises the probe seam and never the real pattern — *the
test written to cover this property could not see it.* That is this project's own
rule about a spec overriding the default it is meant to test, met from the other
side.

And the first attempt to confirm the regression got it wrong in the reassuring
direction: a stand-in named `prove-standin` does not match the pattern, so the
peak of 1 it reported was a genuinely foreign suite running elsewhere, read as
proof of self-counting. The discriminating question is never *is the count
non-zero* — it is *is it one more than the ambient baseline*, which requires the
stand-in's argv to actually match. The replacement assertion avoids the ambient
baseline entirely by using a pattern unique to the run, so the expected count is
exactly zero and nobody else's suite can move it.

#### It recurred in the second producer, and the reason was a private copy

The fix above was applied to `run-suite`. `coverage-run` has the same shape — it
starts its gate under `setsid` too — and did **not** get it, because it was
carrying its own copy of the whole predicate rather than sourcing the shared one.

There the defect is worse. `run-suite`'s only appeared when the pattern widened to
include a bare `prove`, since a plain `prove` had never matched `Devel::Cover`. A
**coverage** gate's children *are* `Devel::Cover` processes — that is what coverage
means — so the count is inflated in every window of every real run. With
"more than a quarter of windows invalidates", that makes **every coverage verdict
on this host CONTENDED against itself**, which is not a slow afternoon: it is a
gate that cannot produce admissible evidence at all.

Measured with a control pair at identical ambient load — a stand-in gate spawning
no `Devel::Cover`-shaped child gave `FOREIGN_PEAK=6`, one spawning a single child
gave `7`. A delta of exactly +1 for exactly one added child.

**The copy had missed four protections**, not one, counted occurrence by
occurrence against the shared definition: the process-group exclusion list, the
quoted-pattern grep, the pattern-compile check, and the empty-process-table check.
Three were live defects; the fourth — an unreadable process table read as an empty
one — is latent and nobody has hit it.

> **A private copy does not merely fail to improve. It diverges further with every
> fix applied to the original**, and each divergence is invisible because the copy
> still looks like the thing it was copied from.

#### Why the guard that was supposed to prevent this did not

The card that consolidated the definition asserted, in its own acceptance
criteria, *"one definition of foreign, sourced not copied"*. Its spec checked
`run-suite` and `host-ready`.

**There were three files.** A grep that names its own subjects is not a search — it
is a restatement of the author's mental model, and it passes *precisely when that
model is incomplete*. The copy it could not see was the one carrying the defect.

So the assertion now enumerates the tools directory and requires the pattern to
appear in exactly one file, whatever files exist. A fourth copy added later goes
red on its own, without anyone remembering to add it to a list.

### A single clear sample is not permission

A wait that launches on the first clear reading will eventually launch into a gap
between a foreign suite's test files. The counter-intuitive consequence:
**sampling more often makes this more likely, not less**, because each additional
look is another opportunity to land in a gap.

The fix is confirmation, not frequency — re-check after a delay and require both
readings to be clear. Observed doing its job on 2026-09-02 at 23:36:08, where a
transient clear reading was refused and the real window arrived 106 seconds later:

    CLOSED on confirm (first=0 confirm=1)

Two samples taken inside one quiet gap are one observation, so the confirm delay
has to exceed the target's quiet phases to be worth anything.

### A closed window resumes the wait; it does not end it

When confirmation fails, the wait continues. Two properties follow, and both have
been got wrong here:

- **Do not abort.** A wait given a two-hour budget that gives up nineteen minutes
  in has discarded the reason it was given a budget.
- **Do not report a limit you have not reached.** A message reading *"host never
  became ready"* printed directly beneath a line saying it had is worse than
  silence: it travels with a direction, and sends the next reader to investigate
  the foreign work instead of the wait. Name which condition failed
  (`first=0 confirm=1`) so a reader can tell a sibling holding a lock from a busy
  machine.

Deciding whether to give up or resume is what forces the checker to know *which*
condition is unmet. A checker that only ever aborts can carry one message for
every path, so its vagueness is structural and no rewording fixes it.

### The detector must exclude itself, by checking rather than by appearance

A bare pattern match over the process table counts the searching process. During
one evening's measurement that produced phantom foreign counts of four, five and
six on a quiet host. Exclusion is by own pid and own process group, and a foreign
process is identified by *checking* — `git cat-file -e <master-sha>:<path>` on a
test file it is running — never by whether its filename looks unfamiliar. That
guess has been wrong here, and it propagates.

**"Own process group" is narrower than "ours", and the section above is the
reason.** A caller that gates a run which leads its own group must name that
group as well, or it excludes itself and counts the thing it is measuring. Read
the two together: exclusion is by group *membership you have declared*, not by
the group you happen to be in.

### What the window data does and does not settle

Nine full-suite launches on 2026-09-02/03, as a percentage of sampled windows in
which foreign work was seen:

    0.0   0.0   0.0   2.2   |   55.8   77.3   77.8   86.0   86.4

Seven of the nine were discarded. Within *that* sample the distribution is
bimodal, with nothing between 5% and 50%, so no threshold chosen anywhere in that
range would have classified those nine runs differently.

**That is a fact about those nine runs, and it does not generalise into a claim
that the threshold is unimportant.** The table earlier on this page records a run
at 30% of windows — squarely inside the gap tonight's sample happens to have — and
a 25% cut and a 50% cut classify that run oppositely. The honest statement is
narrower than it first appeared: *this sample cannot discriminate the threshold*,
which is a reason not to tune it from this data, not evidence that tuning it would
change nothing.

The distinction matters because the wider sentence is the one that would have been
quoted later, and it would have retired a live question using evidence that never
addressed it.

**AND THESE FIGURES ARE NOT COMPARABLE TO ANY MEASURED AFTER THIS PAGE'S OTHER
CHANGES.** All eleven runs above were sampled under the previous, narrower
definition — foreign meant a `Devel::Cover` process and nothing else. Under the
definition now in force, which also counts a foreign `prove` or `cover`, the same
afternoons would have reported *higher* fractions, because runs that were
invisible then are counted now. Nothing about the numbers is wrong; they answer a
question that has since been redefined.

So a later reader comparing a fresh percentage against this table is comparing two
different measurements, and the threshold question (`DD-749`) has to be settled on
figures gathered under one definition. Record which definition produced any
contention figure you intend to reuse — a percentage with no definition attached
is not a measurement anyone can act on.

## Exclusivity between gate runs is ASYMMETRIC, and only half of it is enforced

The project rule is that full-suite and coverage verification are host-exclusive
— only one `prove -lr t` or coverage pass at a time. **The tools implement that
rule unevenly, and the uneven half is the one nobody notices.**

| tool | takes a lock? | how |
|---|---|---|
| `coverage-run` | yes, indirectly | execs `script/coverage-gate`, which takes `flock LOCK_EX\|LOCK_NB` and refuses naming the holder |
| `run-suite` | **no** | execs `prove` directly and inherits nothing |

So coverage runs serialise against each other, and nothing serialises suite
runs — against another suite, or against a coverage pass. Measured rather than
inferred: two full suites started twelve seconds apart both ran, and the second
printed no refusal of any kind.

**Why this is easy to miss.** The lock is real, it is in this repository, and a
reader who greps for `flock` finds it — in `coverage-gate`. Concluding "the
gates lock" from that is correct about the file you happened to open and wrong
about the system. The asymmetry only shows up if you ask which *caller* reaches
that code: `coverage-run` does, by delegation; `run-suite` never does.

### SUPERSEDED 2026-09-03 — `run-suite` DOES take a lock now, and the gap moved

**The table above described the state before DD-696 and is no longer true.** It
is kept because a superseded claim is the record of what was believed, and
because the shape of the gap it describes survived the fix in a form that is
easy to miss.

DD-696 gave `run-suite` its own host-wide lock. Measured on 2026-09-03 by
reading what each tool opens:

| tool | lock path | what it protects |
|---|---|---|
| `run-suite` | `/tmp/dd-gate-host.lock` (`DD_SUITE_LOCK`) | the **host** |
| `script/coverage-gate` | `.<db>.lock` beside its database | the **database** |
| `coverage-run` | none of its own — delegates to `coverage-gate` | — |
| `gate-status`, `host-ready`, `check-all-metric-coverage` | none | they are readers |

**So both halves now lock, and they still do not exclude each other** — because
they lock *different files*. `coverage-gate` contains zero references to
`dd-gate-host`; `run-suite`'s only lock is its own. Two `flock`s on different
paths cannot interact, on every code path rather than the one that happened to
run.

Which pairs actually exclude, as of this writing:

| pair | excluded? | |
|---|---|---|
| suite vs suite | **yes** | one host lock (DD-696) |
| coverage vs coverage, same database | **yes** | one database lock |
| coverage vs coverage, different `--database` | no | **correct** — see below |
| **suite vs coverage** | **no** | the remaining gap |

#### Why `coverage-gate` locks its database and not the repository

Not an oversight, and the reason constrains any fix. A repository-wide lock was
tried and removed: the suite's own tests *drive* `coverage-gate`, so the gate
held the lock for the whole run and then **refused its own tests** (DD-526). A
gate given its own `--database` contends for nothing, so a fixed lock also
refuses runs that conflict with nothing.

Any host lock added here must therefore keep two properties, or it reintroduces
the failure it is meant to prevent:

1. **two gates on different `--database` paths must still not refuse each
   other**; and
2. **the host lock path must be injectable**, exactly as `run-suite`'s is, so
   the gate can still pass the suite that is running it.

A third detail blocks the obvious cheap test: `--dry-run` returns *before* the
lock is taken, deliberately, so describing the chain never blocks. It cannot be
used to observe locking; a falsification has to start a real gate.

#### A lock cannot exclude what never takes it

The sharper limit, and the one that decides how much a lock is worth here. On
2026-09-03 three of four consecutive full-suite runs were invalidated by
contention, and the interfering work was **another project's containerised
coverage run** — a different uid, its own container, its own interpreter. No
lock in this repository would have excluded a second of it.

That is not an argument against the lock. It is the boundary between the two
mechanisms this page describes: **a lock coordinates tools that agree to take
it; detection is the only thing that sees everything else.** A design that has
one and not the other is half-covered in a way that looks complete — which is
exactly how the pre-DD-696 state read to anyone who grepped for `flock` and
found one.

### The consequence is a verdict, not just a slow afternoon

A suite starting mid-coverage invalidates the coverage verdict, and a second
suite invalidates both. Because neither announces itself, the contention is
invisible to any check keyed on coverage processes — which is what the
contention sampler described earlier on this page is keyed on. **A verdict can
therefore be contended by something the contention detector is structurally
unable to see.**

### If a lock is added, its SCOPE is the whole question

Two locks already exist on this host and they are not the same thing:

- **`script/coverage-gate`'s lock** — per coverage run, released when it ends.
- **`/tmp/dd-host-verify.lock`** — a session-level wrapper lock, in practice
  held across an entire gate chain rather than the host-exclusive step. One
  session held it for 2529 seconds while its `prove` child had already exited,
  and the other session's suite waited forty minutes for twelve minutes of work.

The obvious repair for the missing half — "give `run-suite` a lock" — makes the
second problem worse if it reaches for the wrapper lock, because it adds another
long-held claim on a contended machine. **The exclusive window should be the
length of the run, not the length of the session's sequence.**

### Sharing one lock file does not deadlock, and the reason is worth stating

`flock` locks survive `execve`, and descriptors duplicated by `fork`/`dup` are
multiple references to *one* lock rather than separate instances — so an
inherited descriptor cannot block itself. A *separate* `open()` of the same path
does contend.

Applied here: `run-suite` taking `coverage-gate`'s lock file is safe, because
`run-suite` execs `prove` and never invokes `coverage-gate`. The hazard is one
level over, and it is the symmetric-looking change: giving **`coverage-run`** a
lock on that same path would self-block, since it then execs `coverage-gate`,
which opens the path independently. *Make both tools lock* is the intuitive fix
and the broken one.

### Refusing and waiting are different contracts

`coverage-gate` refuses immediately and names the holder. A waiter is friendlier
between two cooperating sessions, but it has a failure mode a refuser does not:
**a queued run inherits a host it never measured**, and its own door-check
readings are stale by the time it starts. Whichever is chosen, the choice
belongs in the tools' documentation rather than in their behaviour alone.

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

## What a tree hash cannot see, and why that matters here

The sentence above — *the second is open* — is the whole of this section. A tree
hash answers **which commit** a verdict describes. It does not answer **what was
on disk** when the gate ran, and the gap between those two has exactly two shapes
on this project. Both are ordinary here rather than exotic, which is why the limit
is worth stating rather than filing away.

**Uncommitted tracked work.** `HEAD^{tree}` is computed from the commit, not the
workspace. Edit a tracked file and do not stage it, and the hash does not move —
so a verdict recorded before the edit still validates after it. Every ticket on
this board is worked in a sandbox where uncommitted edits are the *normal* state
for hours at a time, so the case where the fingerprint is blind is the case that
occurs all day, not an edge one.

**Git-ignored operator tooling.** A large amount of the gate machinery —
everything under `.claude/tools/`, including the wrappers that produce these
verdicts and the specs `t/158` executes — is git-ignored by deliberate decision.
Editing any of it changes what the suite actually exercises while moving no
tracked byte at all. The tree hash is not merely imprecise here; the change is
invisible to it by construction.

The two shapes need saying separately because they fail differently. The first is
a *staleness* problem: the right files are being compared, at the wrong moment.
The second is a *scope* problem: the files are not being compared at all.

**The practical rule, until a fingerprint covers them.** Editing anything under
`.claude/tools/` invalidates the current suite verdict, and you must invalidate it
by hand, because nothing will do it for you — no rerun is triggered, no marker
goes stale, and the tree hash still matches. The same applies to an unstaged edit
of a tracked file that the suite reads.

**And what a fingerprint must not do, learned by rejecting the obvious answers.**
It must not mutate the tree it measures: `git add -A && git write-tree` produces a
correct hash and writes the index of a checkout somebody else may be committing
from. It must not be `git stash create` either, which is non-destructive but
captures tracked modifications only — blind to precisely the git-ignored tooling
that is half the problem. And it must not fingerprint the whole working tree,
which would invalidate on every unrelated edit and become the over-eager detector
that gets switched off. A guard that is always red is not a guard.

### And a filename can defeat the fingerprint, which is not obvious

The fingerprint walks the operator directory to hash what each file contains. The
first version read `find -print` into `read -r`, which is newline-delimited — so a
file whose **name** contains a newline split into two lines, neither of which is a
real path. Both hashed as `unreadable`, the file's content was never read, and it
could therefore change without moving the fingerprint.

That is the same blindness this whole section is about, reached by name instead of
by staging, and it is worth stating because nothing about the symptom points at the
cause: the walk reports a value, the value looks fine, and only a file nobody would
create by accident is invisible. The walk now uses `find -print0 | sort -z` with
`read -r -d ''`.

Two properties were measured rather than assumed when that changed. On ordinary
filenames the old and new walks produce **byte-identical** digests, so the fix
invalidates no verdict recorded before it. On a directory containing a
newline-named file, the old walk returned the same digest before and after a
content edit while the new one moved — which is the discriminating test, and the
one that would have failed silently had only the first property been checked.

The general point outlives this detail: **a guard that reads a set of files is only
as trustworthy as its enumeration of that set.** Ask what a filename can do to the
walk before trusting what the walk says about the contents.

## Per-subroutine counts vary between runs; the four-metric verdict does not

Two `Devel::Cover` passes over a byte-identical tree (verified `git status
--porcelain` empty plus per-file sha256, not merely "nothing changed") can report
different per-subroutine execution counts - measured on
`RuntimeManager.pm`, where every `BEGIN` block moved from 79 to 80 executions
between two runs on the same commit (DD-663). The full suite's own total test
count does the same thing across otherwise-identical trees, by more than a
handful of tests (DD-646, DD-634).

**This is ambient, not a regression, and DD-646 already fixed the part that
matters:** before that fix, the variation could reach the four-metric verdict
itself (statement/branch/condition/subroutine), because `RuntimeManager.pm`'s
copy of `_read_process_env_marker` had no test for an empty environ, so its
condition coverage depended on whether the suite happened to meet a process
with a readable-but-empty environ during that run. After the fix, three
consecutive runs reported 100.0 on all four metrics regardless of the
underlying count drift - **the stability is a property of the metric, not of
the measurement**. The counts beneath the metric still move; the metric that
gates a release does not.

**If you see a per-subroutine count differ between two coverage runs on the
same tree, this is why**, and it is not by itself evidence of anything wrong.
Confirm the four-metric total is still 100.0 on both runs before treating a
count difference as a finding.

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

## The writer and its readers must share ONE override name (DD-721)

`coverage-run` (the writer) and `gate-status`/`hunt-monitor` (its readers) each
default their log/verdict paths to the same literal path
(`$DD_STATE_DIR/gate2.log` / `gate2-verdict.txt`). That agreement held only
because none of them had ever been overridden at the same time - the writer's
override was named `DD_COV_LOG`/`DD_COV_VERDICT`, while the readers' were
named `DD_GATE_LOG`/`DD_GATE_VERDICT`. Set one and not the other and a reader
silently starts describing a different file than the one the writer is
filling - exactly the shape this page's "does it write where a second
workspace could also be writing?" question exists to catch, one level up:
here the divergence isn't two writers sharing a path, it's a writer and a
reader sharing a path *by naming coincidence* rather than by contract.

Found because `hunt-monitor`'s bug profile reported "no recorded suite
verdict to read" while a verdict genuinely existed (`gate2-verdict.txt`, a
real tree object, `GATE_EXIT=0`) but its paired log did not - debris from a
one-off manual test run earlier the same night, not reproducible, and not
worth chasing on its own. What *is* worth fixing is that nothing prevented it:
two components describing "the same file" by two different override names is
one edit away from silently not being the same file at all.

**Fix:** renamed the readers' override variables to match the writer's exactly
(`DD_COV_LOG`/`DD_COV_VERDICT` everywhere). A caller who wants to redirect the
gate's artifacts now has exactly one name to set, and reader/writer cannot
structurally diverge again.

**A separate, deliberately unresolved question from the same investigation:**
the verdict that triggered this read `GATE_EXIT=0` alongside `coverage gate:
no summary line was produced` - a run that produced no recognizable summary
exited zero anyway. `coverage-run`'s `mark()` records the real child exit
status honestly (`status=$?`), so forcing it non-zero when the underlying
`script/coverage-gate` genuinely exited 0 would violate this tool's own
documented invariant ("never write a result the gate did not produce") in the
opposite direction. Whether `script/coverage-gate` can legitimately exit 0
with no summary line needs its own investigation before this is touched -
left as a known, named gap rather than guessed at under time pressure.

## Could-not-look must say WHY, not just THAT (DD-722)

`ci-health`'s UNUSABLE state (the fourth state above) used to report only a
fixed sentence - *"could not read the Actions API"* - regardless of cause.
The subprocess calls behind it (`curl` for the API, `git ls-remote` for the
head SHA) both discarded their own stderr (`2>/dev/null`) and, on `curl`'s
side, the response body too. A network failure, an expired credential, a
rate limit, and a malformed JSON response were all reported identically,
which is the same shape this page's own "never write a result the gate did
not produce" rule protects against, one layer earlier: the diagnostic that
would answer the question was generated by the subprocess and then thrown
away before anyone could read it.

**Fix:** both call sites now go through `Capture::Tiny` and populate a
`$LAST_API_ERROR` package variable with the subprocess's real exit code,
stderr, and (for the API call) either the response body's error message or
a preview of an unparseable one. Every UNUSABLE message includes it.

Falsified directly against three real failure modes before writing the
spec - a 404 API path (`$LAST_API_ERROR` names the actual "Not Found" body),
an unresolvable host (names curl's real "Could not resolve host"), and a
malformed URL - rather than asserting the shape of the fix without checking
it against a genuine failure.

**The generalisation:** could-not-look is not one state, it is a state whose
reader deserves the same specificity as the clean and failed states get.
Reporting "unusable" with no cause is only marginally better than reporting
nothing, because a reader who cannot tell "expired token" from "GitHub is
down" from "the JSON changed shape" cannot act on the report any faster than
if it had said nothing at all.

## A CANCELLED run is not an ABSENT run (DD-731)

`ci-health`'s `%IS_VERDICT` set (`success`, `failure`, `timed_out`,
`startup_failure`, `action_required`) exists to keep `cancelled` out of the
red/green judgement - correctly, for the branch-history question
`latest_completed()` answers: a run cancelled by the push after it means "we
stopped asking", not "it is broken", and reporting it as a failure would
alarm on every ordinary rapid sequence of pushes.

But `head_verdict()` answers a different question - "what is known about
THIS commit" - and reused the same filter, which drops a cancelled run for
HEAD out of the picture entirely rather than treating it as no-verdict. If
three other workflows for that commit finished green, the caller sees "all 3
workflows are green" with no trace that a fourth existed and produced
nothing. Observed live: master@386943e's Test run (the one running the suite
and coverage gate) was cancelled at 09:47:19; JS Fuzz, CodeQL and Package
GHCR were green; `ci-health` reported "all 3 workflows are green" and exited
0. The only tell was the count - three where there should have been four -
with nothing naming what was missing.

**This is DD-668's shape one step on.** That card fixed `ci-health`
attributing an *earlier* commit's verdict to the current one; this is the
same mechanism - an answer true about the subset examined and false about
the question actually asked - reached by dropping a record instead of
misattributing it. Both are cured by the same instinct: before trusting a
short list, ask whether something was filtered out of it, and say so if it
was.

**Fix:** `head_verdict()` tracks cancelled runs for HEAD in their own bucket,
separate from `%for_head` (verdicts) and `$pending` (still in flight) - a
cancelled run is neither. `main()` checks that bucket before the red-check
and the empty-verdict check, reporting NOT YET VERIFIED and naming which
workflow was cancelled, rather than letting the surviving green workflows
stand in for the whole picture.

**Why this matters more than an isolated bug:** cancellation is not rare on
this project - it is the normal consequence of pushing to a branch with a
concurrency group while an earlier push's run is still going, which happens
routinely when two sessions or a fast sequence of commits share one CI
pipeline. The situation that produces a cancelled run is the same situation
that produces an unverified commit, so a checker that turns "cancelled" into
"absent" turns exactly the moment CI needs to answer honestly into the
moment it answers confidently wrong.
