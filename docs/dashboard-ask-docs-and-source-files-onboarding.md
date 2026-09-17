# `dashboard ask --docs` and `dashboard source --files`: onboarding a blank agent to Developer Dashboard

What these two commands are for, why they exist, and the design constraint
that shaped them. This page describes the system, not any one ticket.

## The problem (DD-938, owner request via Telegram, 2026-09-17)

A blank agent - one with no prior context about this project - has no fast
way to become genuinely aware of Developer Dashboard's own conventions
(the DD-OOP-LAYERS runtime stack, `.env`/docker-compose layering, where a
disposable helper script belongs). The obvious answer - inject the full
`CLAUDE.md` (~4000+ lines) into every `dashboard ask` call, or drop a new
`.md` file into the user's workspace - was explicitly ruled out by the
owner: too expensive per call, and pollutes a workspace that should stay
clean of DD's own operator files.

## Automatic onboarding, not even one injected line

The first design (still available) was `dashboard ask --docs`, an explicit
flag an agent has to be told to call - the owner clarified mid-implementation
that even that one instruction line is more friction than intended. Since
`dashboard ask`'s conversation memory is already scoped **per workspace**
(one transcript file per `WORKSPACE_REF`), the natural zero-instruction
trigger already exists: **a workspace's first-ever plain `dashboard ask
<question>` call** (empty transcript, no prior turns) silently prepends the
curated docs context to that turn's prompt before sending it to the backend.
Every subsequent call in the same workspace sees it already sitting in
conversation history and does not repeat it. No flag, no injected setup
line, no per-call cost after the first turn.

## `dashboard ask --docs`

Prints the same curated, purpose-built onboarding context directly to
stdout on demand - short enough to be cheap on every call, focused on
making an agent DD-*aware* rather than DD-*expert*. It never writes a file
anywhere; it is pure stdout output the calling agent reads and holds in its
own context for that session. Useful for re-reading the context explicitly,
or outside a real `ask` conversation entirely.

**What it covers:** the DD-OOP-LAYERS inheritance stack (`~` down through
the cwd's parents), `.env`/docker-compose layering, and - the single most
actionable piece - where a disposable helper script an agent writes on the
fly belongs: `$PWD/.d2/cli/<name>`, `$PWD/.developer-dashboard/cli/<name>`,
`~/.d2/cli/<name>`, or `~/.developer-dashboard/cli/<name>` - DD's own
dot-notation `skills/cli`/`cli/` convention, never scattered ad hoc into
the workspace root or `/tmp`.

**Onboarding a new workspace is one line:** tell the agent to run
`dashboard ask --docs` first. Nothing else needs injecting - no CLAUDE.md
copy, no new markdown file checked into the workspace.

## `dashboard source --files`

A fallback reference for when the curated `--docs` context doesn't cover
something specific: lists every file Developer Dashboard installed on the
system, under `~/perl5/{lib,bin}` (the CPAN-installed tree an agent can
`grep`/`Read` directly for the real, current implementation of anything
`--docs` only summarizes).

## Design constraint that shaped both

**Never CLAUDE.md, never a new file in the user's workspace.** The owner
was explicit: this is not "give the agent CLAUDE.md" restructured, it is a
smaller, purpose-built, cheap-per-call onboarding path that keeps the
distinction between "operator-local project rules" (CLAUDE.md, which stays
private to this checkout) and "what a Developer Dashboard user's own agent
needs to know to use the product" (this page's subject) - the two are not
the same audience and should not be conflated.
