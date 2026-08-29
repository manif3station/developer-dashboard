# Standing instruments — what watches this project, and how it fails

This page is about the instruments that run continuously and report on the project
without being asked: what each one watches, how it is scheduled, and — the part that
matters most — how each one behaves when it cannot do its job.

It is system-scoped. It describes the instrumentation layer as it stands, not any
ticket that changed it.

## The two scheduling mechanisms, and why the choice is not cosmetic

An instrument here runs one of two ways, and the difference is a safety property
rather than a preference.

| | **systemd user timer** | **session Monitor** |
|---|---|---|
| Lives in | `~/.config/systemd/user/*.timer` | the live Claude Code session |
| Survives session exit | yes | no |
| Survives a reboot | yes (if enabled) | no |
| **Visible when dead** | **no** | **yes** |
| Stops when | disabled, masked, or failed | the session ends, or `TaskStop` |

The row in bold is the whole argument. **A disabled timer and a timer with nothing to
report produce identical silence.** On 2026-08-20 both `dd-bughunt.timer` and
`dd-blocked-resolver.timer` were found to have been disabled for **nine days**. Nothing
reported it. Their logs were quiet, and a quiet log reads exactly like a healthy one.
The gap was found only by someone asking "is this loop actually still scheduled?"
rather than trusting the absence of complaints.

A Monitor cannot fail that way. If the session is gone, every Monitor is visibly gone
with it; if one dies, its absence is in the session's own task list. You cannot be
misled into thinking a Monitor is watching when it is not.

**So: anything whose silence would be mistaken for good news belongs in a Monitor.**
Timers remain appropriate for work that must survive a reboot and whose absence would
be noticed by other means.

## The exit-code contract

Every instrument in `.claude/tools/` uses the same four codes. This is not a
convention for tidiness — each code exists because conflating two of them has cost
this project real time.

| code | means | why it is separate |
|---|---|---|
| `0` | ran, nothing to report | — |
| `1` | ran, **found something** | a work list, not a status line |
| `2` | usage error | a typo must refuse, not run silently and find nothing forever |
| `3` | **could not look** | the one that matters |

**`3` is the load-bearing code.** Every checker on this project has, at some point,
reported "nothing wrong" when the truth was "I could not look":

- a credential that was never read sent an empty auth header; the server returned 401,
  byte-identical to a revoked token
- a sweep whose cron line failed before the script was ever reached — a redirect
  cannot report its own failure
- a board query that timed out and returned nothing, which parsed as an empty board

In each case the instrument was *silent*, and silence was read as *clean*. An
instrument that cannot distinguish those two states is worse than no instrument,
because its clean report gets believed.

## The standing hunters

Three hunters run from one engine, `.claude/tools/gap-hunter`, each as its own Monitor.

| hunter | label | interval | looks for |
|---|---|---|---|
| `doc` | Routine Doc Check | 180 min | POD missing any of the seven required headings; `README.md` drifted from the POD that generates it; undocumented commands; `.md` filenames inside POD; shipped work with no `Changes` entry |
| `bug` | Hourly Bugfix | 60 min | unchecked `system()`/`exec` returns; error paths that swallow failures; checkers that cannot tell clean from could-not-look; pipes that launder exit status; process and resource leaks; the security audits |
| `improvement` | Hourly Improvement | 120 min | near-identical logic in two modules; hand-rolled code where a dependency already does it; functions that outgrew their purpose comment; branches no test reaches |

### The engine schedules; it does not hunt

`gap-hunter` emits a directive and nothing else. It does not scan, judge, or create
cards. The session that receives the directive does the hunting and files the card.

That split is deliberate. The hunting worth having on this project is a judgement —
it is what found the crontab weekday-token defect, the missing `admin-done` hop, and
the DockerCompose path traversal. A deterministic grep would have found none of them.
Reducing the hunt to something the engine could compute would trade the findings that
matter for the findings that are easy.

What the engine *does* guarantee is that the directive is actionable without further
lookup: it names the scan scope and carries the literal `tira.ticket.create` command,
including `--label standalone`, because every card a hunter files is parentless by
construction and an unlabelled parentless card is reported as `missing: parent`.

### Findings become cards, not remarks

A finding that stays in a session transcript is lost when the session ends. Every
hunter directive ends by filing into `backlog` — and equally, by saying that finding
nothing is a valid outcome that files nothing. A card raised to look busy costs more
than the silence it replaces.

## Falsifying an instrument

**A clean report from an instrument never seen to go red proves nothing.** Every
instrument here is deliberately broken, confirmed red, and restored — and the
falsification itself must be checked, because a substitution that silently fails to
apply produces a green run that looks like proof.

That is not hypothetical. While falsifying `gap-hunter`, one break was written as a
`sed` expression inside double quotes; the shell collapsed `\$` to `$`, the pattern
became "an empty line followed by a literal", it matched nothing, and the engine was
never modified. The spec passed. **The green measured only that the break had
failed.** Re-run correctly, it went red.

So the rule is two-sided: confirm the instrument goes red, *and* confirm the thing you
did to it actually happened.

## Where they live

| instrument | path | scheduled as |
|---|---|---|
| the three gap hunters | `.claude/tools/gap-hunter` | 3 Monitors |
| policy bridge | `d2 tira.policy.bridge` | Monitor |
| outstanding-violation gate | `.claude/tools/police-outstanding` | Monitor, 30 min |
| idle watcher | `d2 is-agent-sleeping` | Monitor |
| FT99 board sweep | `.claude/tools/ft99-sweep` | cron |
| policy-set sweep | `.claude/tools/policy-sweep` | cron |

Specs for the tools live beside them as `t-<name>` and are executed by the suite
through `t/158-operator-tool-specs.t`, which **discovers** them rather than listing
them. That file exists because thirteen specs once sat in that directory with nothing
running any of them: a spec nobody runs cannot fail, so it protects nothing while
looking like protection.
