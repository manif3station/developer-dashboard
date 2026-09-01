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

## The lesson that generalises

**A tool's name is a claim about what it does, not evidence of it.** Before
recommending anything be restored, re-enabled, or treated as covering a gap,
read the source of the candidate AND the thing it might replace, not just
their unit files or their names. `dd-blocked-resolver` sounded like exactly
what was missing; it wasn't, and `ft99-sweep` - which nobody suspected because
its own name is about column drift, not blocked cards - already was.

## What is NOT yet covered (DD-723)

Nothing currently distinguishes *"this scheduled job is disabled/missing"*
from *"this scheduled job ran and found nothing"* for the crontab lines and
any remaining systemd timers this project depends on. That is the shape both
DD-587 and DD-661 hit, and it recurs until something checks liveness, not
just output.
