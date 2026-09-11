# Text-matching a process is spoofable; `/proc/PID/exe` is not (DD-770)

## The pattern

`.claude/tools/host-ready`'s foreign-process sampler (`dd_foreign_now()`)
decides whether the host is busy by matching each process's command-line
**text** against the pattern `Devel::Cover|(^|/)(prove|cover)( |$)`, read from
`ps -eo pgid,args`.

That is a text match against `args` - and `args` is not a fact about what a
process *is*, it is a string the process itself chose to display.

## The gap

Perl's `$0 = "..."` assignment is the classic Unix `setproctitle` mechanism.
Verified live this session with:

```sh
setsid perl -e '$0 = "fake prove Devel::Cover thing"; sleep 30' &
```

then reading the same process four different ways:

| source | value |
|---|---|
| `ps -o args=` / `ps -eo pgid,args` | `fake prove Devel::Cover thing` (rewritten) |
| `/proc/PID/cmdline` | rewritten identically - same underlying kernel buffer |
| `/proc/PID/comm` | rewritten too, via `prctl(PR_SET_NAME)`, truncated to 15 chars |
| `readlink -f /proc/PID/exe` | `/usr/bin/perl` - **untouched** |

`$0 =` rewrites the process's argv buffer in place, and every one of
`ps args`, `/proc/PID/cmdline`, and `/proc/PID/comm` reads from that same
rewritten buffer. **All three are spoofable by the process itself, with one
line of Perl.** `/proc/PID/exe` is a symlink to the inode of the binary the
kernel actually `exec()`'d; nothing a running process does to its own argv or
title touches it.

So `dd_foreign_now()`'s current text match has a false-positive shape it was
never designed to resist: **any process that merely mentions the pattern
text** - a wrapper, a log line, a decoy, or (originally motivating this card)
an unrelated command whose arguments happen to contain the string
`Devel::Cover` - is counted as foreign contention, whether or not it is
actually running `prove` or `cover`.

## What this is *not*

This is unrelated to `DD_HOST_READY_EXCLUDE_PGIDS` (DD-750/DD-772,
`validating-a-pgid-before-trusting-it-as-an-exclusion.md`), which excludes a
tool's *own* `setsid`-gated child by its process-group id. That mechanism is
a **negative** exclusion of a specific pgid the caller already knows is
theirs, and it is unaffected by this finding - it was verified in this same
session to already be present in both `run-suite` and `coverage-run`.

This finding is about the **positive** match step that decides a process
counts as foreign in the first place, before any exclusion is applied.

## The fix: a positive-only veto, never a could-not-look exclusion

Any exe-based check added to `dd_foreign_now()` must be **asymmetric**:

- If `/proc/PID/exe` resolves and is **not** a perl/prove/cover binary,
  exclude the match - it was a decoy.
- If `/proc/PID/exe` is unreadable (permission denied across a container's
  mount namespace, or the process has already exited), **do nothing** -
  leave the match counted exactly as it is today.

The second branch matters more than the first. DD-729's whole reason for
existing is detecting a genuinely foreign, containerised test suite, and
`/proc/PID/exe` across a container boundary is frequently unreadable by
design. Treating "could not verify" as "therefore not foreign" would silently
disable the detector for the exact case it was built for - the same shape as
`validating-a-pgid-before-trusting-it-as-an-exclusion.md`'s warning against
letting an unverifiable capture become a trusted exclusion, applied to a scan
step instead of an export step.

## Why this belongs in `host-ready` alone

`dd_foreign_now()` is the single shared definition of "is anything foreign
running" (DD-729's consolidation of previously-duplicated readiness logic).
`run-suite` and `coverage-run` both call it rather than re-implementing the
scan, so the fix lives in one place and both callers inherit it.
