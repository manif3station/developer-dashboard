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
