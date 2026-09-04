# How this project's policy set is decided, and how it stays decided

Tira ships rules. This project decides which of them police its work. That decision
has to live somewhere durable, because the board's live policy set can be changed by
anyone at any time and a rule that quietly vanishes leaves no evidence — police simply
stops mentioning it while continuing to speak about everything else, which reads as
compliance rather than as a missing check.

## The three parts, and which is authoritative

| part | what it is | authority |
|---|---|---|
| `.claude/policy-manifest.json` | the rules this project **decided** to have, each with its options and, for a decline, its reason | **desired state** — the authority |
| the Tira board's policy set (`d2 tira.policy.list`) | what is **actually** declared right now | actual state |
| `.claude/tools/policy-sweep` | compares the two, hourly | the reconciler |

The manifest is not a cache of the board. It is the record of decisions, and the board
is the thing that drifts away from it.

## The two drifts it exists to catch

**A policy disappears.** Something that was decided is no longer declared. The sweep
restores it, because re-declaring a rule the project already agreed to changes nothing
anybody has to think about.

**Tira gains a rule nobody here has judged.** A new release adds a rule; nothing tells
you about a capability you never had. The sweep **reports** it and refuses to declare
it — *"a rule declared by a robot polices work nobody agreed to police, and does so
wearing the appearance of a decision."*

## Passive by design, and what that obliges

Drift tooling generally comes in two modes: **passive**, which reports a difference
for a person to review, and **active**, which auto-applies a correction. `policy-sweep`
is deliberately passive on new rules and active on restorations.

That is a sound choice and it carries an obligation: **passive reconciliation only
works if somebody acts on the report.** An unacted report is not neutral — it
accumulates. Ten unacted reports every hour is the documented failure mode of noisy
alerting, where real drift stops being distinguishable from expected noise, and the
eleventh new rule arrives unnoticed inside a wall of the same ten lines.

So a report from this sweep is a to-do item, not a status line.

**And "a person" includes an agent.** Decided by the owner on 2026-09-04 (Q-123 on
DD-756): an agent may judge a newly-shipped rule, provided it records the decision
**with its reason** in the manifest — *"the safeguard is already there: the reason is
recorded in the manifest, so any judgement can be reviewed and reversed."*

That resolves a genuine contradiction rather than a wording preference. `policy-sweep`'s
own comment says new rules are "left for a person", while the board's `rules-undeclared`
rule says leaving one unconsidered is the single thing not allowed. Both were right
about their own concern and instructed differently, and an agent meets the tool's
comment first. The cost the owner accepted is stated plainly: a rule can begin policing
work before he has seen it.

## Recording a decision

Declaring on the board and recording in the manifest are **two steps**, and doing only
the first is the drift this page is about. A rule declared by an agent responding to
the board's own `rules-undeclared` finding is still an undecided rule as far as the
manifest — and therefore the sweep — is concerned.

    d2 tira.policy.add --rule NAME --action bridge-reminder    # actual state
    # then add the same entry to .claude/policy-manifest.json  # desired state

Two things worth knowing when you do:

- **Never pass `--message` without `{detail}` in it.** A custom message *replaces* the
  default, and the default is what carries the finding. Thirty-nine of forty policies
  here were once silently stripped of their findings that way.
- **Mirror the options the board actually carries**, not a minimal entry. Several rules
  are declared with an `age`, an `enter` column, or a column list, and a manifest entry
  that omits them describes a different decision from the one in force.

## Verifying, and the trap in verifying

    .claude/tools/policy-sweep > out 2>&1
    rc=$?          # read on the NEXT line, never through a pipe

Exit codes: `0` the set matches, `1` drift or a new rule needs judging, `2` usage,
`3` could not look, `4` could not write its log. The last two are deliberately not
zero, because *"the set is correct"* and *"I could not check the set"* must never look
alike.

> **Do not read that status through a pipe.** `policy-sweep | tail` then `$?` reports
> **tail's** status, which is almost always 0. That reading has already reported a
> clean sweep for a run that had exited 1 with ten findings — and the false value is
> the *flattering* one, so nothing prompts a second look.

And a green sweep is worth checking in both directions: remove one entry, confirm it
exits 1 naming exactly that rule, put it back. A checker never seen to go red proves
nothing about the set it just approved.

## Counting rules, and the filter that has to be stated

The manifest's `declared` is a **list of entries**, not a set of rules — several rules
are declared more than once, per column. So `len(declared)` and "how many rules are
judged" are different numbers, and a comparison that mixes them will find drift that
is not there. Compare **unique rule names** on both sides, and say which you counted.

A rule in the manifest's `declined` list is *supposed* to be absent from the board.
Reading the declined pair as "policies that disappeared" is the easiest wrong
conclusion available here, and it has been reached.
