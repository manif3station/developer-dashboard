# Board write attribution: who actually wrote this

How `--author` is resolved for a board write in this project, why a fixed
value is not enough once more than one actor can write, and what a resolved
name promises a reader. This page describes the system, not any one ticket.

## Why attribution is layered, not flat

Every Tira write on this project takes `--author`, and it is free text - the
board trusts whatever string it is given. Two collapses of that trust have
happened here, at two different granularities:

- **Person vs. bot (DD-527).** Every human and automated actor once wrote as
  the same literal string, `DD Bot`. A comment and a contradicting comment
  about the same event were indistinguishable, because both wore the same
  name. The fix was `.claude/tools/tira-author`: a resolver that refuses the
  shared name outright and picks an actor identity from the environment.
- **Session vs. session (DD-662), one level down.** Two interactive Claude
  sessions can run against this board at once (owner-confirmed deliberate,
  Q-063). The first version of the resolver fixed the person/bot collapse but
  reintroduced the identical failure one layer down: it asked only *whether*
  a session-id environment variable was set, never *which* session it named,
  so both sessions resolved to the same fixed string, `dd-session`. Every
  comment, gate entry and required-action proof from either session was
  indistinguishable from the other's for days.

The lesson generalises: fixing a collapsed identity at one layer does not
protect the layer beneath it. Whatever discriminated the outer failure has to
be re-examined for the inner one, not assumed to still hold.

## How resolution works now

`.claude/tools/tira-author` resolves a name in this order:

1. **`DD_TIRA_AUTHOR`**, if set - trusted but validated: it must match the
   `--author`-safe pattern (letters, digits, hyphen, underscore only) and must
   not be the shared name. This is how automation declares itself explicitly
   (the cron line sets it), and it always wins over anything derived below.
2. **A session id**, checked in order `CLAUDE_CODE_SESSION_ID` then
   `CLAUDE_SESSION_ID`. The first is preferred because on this host
   `CLAUDE_SESSION_ID` is sometimes a project label ("developer-dashboard"),
   not a per-process value, and would collapse sessions exactly like the bug
   this page exists to describe. When a session id is present, the resolved
   name is `dd-` followed by its first 8 lowercased alphanumeric characters -
   deliberately the same slice the board already stores in a card's
   `agent_session` field, so a reader can correlate a comment's author with a
   card's `agent_session` by eye, without a lookup table.
3. **`dd-hourly`**, the automation fallback, when neither the above applies -
   the cron/monitor/collector shape, which carries no session id at all.

A session-derived name is **auto-registered** the first time it resolves
(`tira.project.people.add`, idempotent - a call that fails only because the
person already exists is treated as success). Without this, the fix would
trade one failure for another: a distinguishable name that every subsequent
card write rejects with "Unknown project person."

## What a resolved name promises, and what it does not

**It promises**: two different session-id values, or a declared vs. an
undeclared identity, are recorded as two different authors. A reader
comparing two comments' authors can tell whether they came from the same
process.

**It does not promise**: recovery of authorship for writes made before this
fix existed. Every write recorded under the old resolver still reads
`dd-session` regardless of which of the two sessions made it - DD-654 already
established that ownership is recoverable per-*card* (via the separate
`agent_session` field, set once when a card is claimed) but not per-*write*,
and that gap is permanent. This page's fix stops the collapse going forward;
it does not repair the record behind it.

## How to apply

Before trusting a resolver (this one or any other) to have fixed an identity
collapse, ask whether it discriminates on the *value* that actually varies,
or only on the *presence* of something that happens to correlate with it in
today's environment. `-t STDIN` correlated with "interactive" until an agent
tool-shell broke it; "a session-id var is set" correlated with "one session"
until a second session existed. The fix that lasts is the one keyed on the
value itself - here, the session id - not on a proxy for it.

## The registration step has its own layer collapse (DD-719)

`ensure_registered()` (step 2 above, the auto-registration call) shells out to
the board. Which `d2` that reaches is not fixed by the resolver's own logic -
it depends on the caller's current working directory, and this project's own
rule is that real work happens inside a per-ticket git worktree
(`~/Sandbox/ddd/<ref>`), not the main checkout.

A worktree carries no `.developer-dashboard` runtime layer, so a bare `d2`
cannot resolve the project's selector (DD-545's exact defect, one layer
below the author-identity problem this page otherwise describes).
`.claude/tools/board` exists to solve exactly this: it locates the main
checkout via `git --git-common-dir` (which resolves correctly from any linked
worktree) and `chdir`s there before execing the real `d2`.

`ensure_registered()` was not using it - it called a bare `d2` directly. From
a worktree that call fails, `ensure_registered()` `die`s, and the standard
calling idiom `AUTH="$(.claude/tools/tira-author)"` is a bash command
substitution that captures **only stdout**: the `die()` message on stderr is
silently discarded, leaving `AUTH=""` with no visible error at the call site.
A worktree caller - every real ticket's own working directory - got an empty,
unusable author name instead of the loud failure the code was written to
produce.

Fixed by routing `ensure_registered()`'s call through `.claude/tools/board`,
resolved relative to `tira-author`'s own script location (the same pattern
`board` uses to resolve itself, rather than depending on `PATH` or `cwd` -
which is exactly the class of dependency that caused the bug).

**The generalisation, matching this page's own closing lesson above:** a
resolver can get the *identity* layer right and still depend on something
environment-sensitive one step further down - here, "which `d2` a bare
invocation reaches." Fixing one layer does not audit the layers it calls into.

## A fixed identity does not retroactively fix the field that reads it (DD-717)

DD-662's own key_details predicted this before it happened: *"A session that
begins writing under a new id would fire card-changed-by-owner on every card
it touched... The actor id and the assignee convention have to move
together, or this trades an attribution gap for a violation flood."* It
landed within the hour - two cards fired `card-changed-by-owner` repeatedly
(up to URGENT) because their `assignee` field still held the pre-fix shared
literal (`dd-session`) while every write from that point on was correctly
authored under the new per-session derived name. The rule compares the
newest change's author against the `assignee` field, and a resolver fix
changes only the author side.

**Two separate populations, easy to conflate:**

- **Cards claimed before the fix**, whose `assignee` still holds the old
  literal - a one-time population, correctable by a sweep.
- **`ticket.create`'s own `reporter` default**, found separately by the peer
  session: it defaults to the same stale literal regardless of `--author`,
  so every NEW card is born with the mismatch too. This is a standing
  defect, not a one-off population - "fix forward and let old ones drain"
  does not converge, because the population is continuously replenished.
  Not fixed here; recorded so the shape is not mistaken for the first one.

Owner-authorized (Q-088, option A): correct assignee on every already-
claimed card whose `agent_session` field already names the true claiming
session, matching it there rather than guessing. One card (a standing
special case with its own explicit, unrelated owner-deferral history) was
left untouched pending a separate question - the sweep's own authorization
did not have that card's special status in view when it was granted, and
extending it there without asking would have been a different decision
wearing the same clothes.

## How to apply, one layer further

Fixing WHO writes does not fix WHOSE NAME IS ALREADY ON RECORD. Any
identity-resolution fix should be checked against every field that already
stores a copy of the old value, not just the point that produces new ones -
and each such field may have its own population dynamics (one-time backlog
vs. continuously replenished) that call for different remedies.
