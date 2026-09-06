# What actually reconciles the board, and what used to

A record of which scheduled job covers which job, so the next reader does not
have to re-derive it from source the way DD-661 had to. Two silent nine-day
outages (DD-587, then again the window DD-661 investigated) happened because
"disabled" and "covered by something else" look identical from the outside.

## The current picture

| job | what it does | how it runs | covered since |
|---|---|---|---|
| **hunt-monitor** (bug/doc/improvement profiles) | scans the codebase and files findings as cards | a session-owned `Monitor`, not a systemd timer - dies when the session that started it exits | replaces `dd-bughunt.timer` |
| **`.claude/tools/ft99-sweep`** | reads every parked card and reports whether its named blocker is terminal or its RELEASE TRIGGER has fired (`blocked-by-dependency`, `blocked-by-michael`) | `systemd`-independent: a plain crontab line, `7 * * * *` | has done this since DD-563/DD-571 (2026-08-16/17) - independently of, and BEFORE, `dd-blocked-resolver.timer` was ever questioned |
| **`.claude/tools/policy-sweep`** | checks the declared policy set still matches what the project decided | crontab, hourly | - |

## What used to exist and no longer does

`dd-bughunt.timer` and `dd-blocked-resolver.timer` (plus their paired
`.service` units) are retired as of DD-661 - backed up to
`/home/mv/dd-tg-systemd-backup/` and removed from `~/.config/systemd/user/`,
not merely disabled. `dd-blocked-resolver.timer`'s name suggested it was the
reconciler; reading `dd-blocked-run.sh` showed it was actually **six
autonomous Claude rounds an hour** with the reconciliation as a side effect of
one of those rounds, not a small standalone check. That distinction cost a
withdrawn recommendation on DD-661 (CMT-002) before it was caught.

## A third mechanism: board jobs (`JOB-NNN`)

The table above predates them. Tira's own job executor was wired in 5.81
(TKT-944) and monitor output widened to carry command output in 5.82
(TKT-945), so the board now schedules commands itself, alongside crontab and
session-owned `Monitor`s:

```sh
d2 tira.job.list          # id, last_due_at, last_output_at, the recent output buffer
```

**Read all three stamps, and know which absence means what.** As of 5.84
(TKT-963) a job records three facts that come apart in exactly the cases that
were unreadable before:

| stamp | means |
|---|---|
| `last_due_at` | the window came round |
| `last_run_at` | the command was run |
| `last_output_at` | it said something |

A manual **Run now** has the second without the first — it never comes due. A
command exiting 0 in **silence** has the second without the third. Before 5.84
that silent success had *neither*, so it and a mere due-window were the same
reading, on the scheduled path as well as the manual one.

A job that is genuinely working and talkative looks like this:

```
last_due_at:    2026-09-06T14:30:56+0100
last_output_at: 2026-09-06T14:30:57+0100
```

> **This guidance inverted on 2026-09-06 and the earlier version is worth
> knowing about.** Through 5.80–5.83 the advice here was *"never read health
> from `last_run`"*, because `last_run` was a field nothing ever wrote — one
> assignment of `undef` at creation and no other in the engine — so it read
> `null` on a healthy job and a dead one alike. That was true, and 5.84 replaced
> it with a real `last_run_at`. **The page said the opposite of this for about
> two hours.** If you are reading a claim about what a Tira field means, check
> which version it was written against.

### What a job's command must be, and why a bare command is not enough

**A board job does not run in the checkout.** Getting this wrong produces
three different failures that each look like a different bug — measured on
JOB-005 (DD-782), from `/tmp`, which is the neutral cwd a job actually
resembles:

| command | what happens | why |
|---|---|---|
| `d2 tira.police.outstanding` | `exec ... failed: No such file or directory` | `PATH` carries a **relative** `bin` entry, which only resolves while standing in the checkout |
| `/home/mv/perl5/bin/d2 tira.police.outstanding` | `Cannot resolve project selector 'tira-ddd'` | an absolute path fixes **which** `d2` runs, not **where** it runs; the layered runtime resolves config from the deepest `.developer-dashboard` above the cwd, and only the main checkout has one |
| `<repo>/.claude/tools/board tira.police.outstanding` | the real list | the wrapper anchors on its own file location and prepends `~/perl5/lib/perl5` to `PERL5LIB` before exec — both added by DD-545 for schedulers exactly like this |

The middle row is the trap, and it is worse than the bug it replaces: it
turns a loud `exec` failure into a quiet resolution failure on a job whose
output nobody reads, so the schedule still *looks* healthy. Prefer the failure
that announces itself.

The wrapper needs `HOME` — without it `PathRegistry` refuses with *"Missing
home directory"*. Whether a given runner supplies it is not answerable by
reasoning about the runner; JOB-005 settled it empirically by producing real
output on a scheduled tick.

**The generalisation, which is this page's existing lesson one level down:** a
command that works when you type it is not evidence it works when something
else runs it. The variable is rarely the binary — it is the working directory,
the environment, and the `PATH` that the *scheduler* provides.

## The lesson that generalises

**A tool's name is a claim about what it does, not evidence of it.** Before
recommending anything be restored, re-enabled, or treated as covering a gap,
read the source of the candidate AND the thing it might replace, not just
their unit files or their names. `dd-blocked-resolver` sounded like exactly
what was missing; it wasn't, and `ft99-sweep` - which nobody suspected because
its own name is about column drift, not blocked cards - already was.

## The disabled-vs-clean gap is now covered (DD-723)

`.claude/tools/schedule-health` checks this project's own crontab entries
(the ones in the table above) against a declared manifest and reports
DISABLED, STALE, or CANNOT-LOOK distinctly from CLEAN. It is deliberately
NOT added to crontab by DD-723 itself - run it manually
(`.claude/tools/schedule-health`) until its own behaviour has been trusted
for a while, matching this project's own caution against recommending a
tool's permanent installation the day it lands.

**A checker built by scanning what crontab currently contains cannot see a
line that has been REMOVED** - nothing remains to iterate over, so a scan-only
design silently reduces its own checked count instead of reporting a finding.
`schedule-health` learned this the direct way: its own first draft had exactly
that bug, caught by deliberately removing a real crontab line and watching the
matched-schedule count drop from 8 to 7 while still exiting 0 - the DD-587
shape reappearing one level up, in the tool meant to catch it. The fix is to
check presence against a declared manifest (`EXPECTED_SCHEDULE` in the tool's
own source), never against what a scan happens to find.
