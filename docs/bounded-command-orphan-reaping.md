# The bounded command runner and an orphan that only a container can hide

`Local::BoundedCommand::run_bounded` (`t/lib/Local/BoundedCommand.pm`) gives the
test suite a way to run an external program under a wall-clock bound: if the
program outlives its budget, it and everything it started are killed and the
caller is told, in words, what happened. This page is system-scoped: it
describes how that guarantee is actually kept, not a change to it.

## The guarantee is "everything it started dies", not just "the direct child"

The command is put in its own process group (`setpgrp(0,0)`) before it is
`exec`'d, and a timeout signals the whole GROUP, not the one pid — so a command
that spawns its own children (a browser, a server, a backgrounded shell job)
loses all of them, not just itself. That is `run_bounded`'s reason to exist: an
earlier incident left a browser tree alive for two days because only the direct
child was ever signalled.

## Killing a grandchild is not the same as reaping it

Signalling the group genuinely kills every member of it, including a
backgrounded grandchild. That is not where this got interesting. What is easy
to miss is that **killing a process and collecting its exit status are two
different acts**, and only the second one makes the process actually go away
from the kernel's point of view.

When a command backgrounds a job (`sleep 600 & ...; sleep 600`) and is then
killed before it reaps that job itself, the job is orphaned. Its new parent is
decided by the kernel at the moment its old parent dies:

- On a bare host, the orphan reparents to the host's real init (systemd, or
  whatever PID 1 is), which reaps every child it is ever handed almost
  instantly. The orphan is gone before anyone thinks to check.
- Inside a container started **without** an init that reaps orphans - a plain
  `docker run` with no `--init`, which is the shape of this project's own gate
  containers - the orphan reparents to a PID 1 that never calls `wait()` on
  anything. It becomes a zombie *for ever*. `kill(0, $pid)` keeps reporting it
  "alive", because the kernel holds a zombie's pid slot open until something
  reaps it - a zombie is dead, but not yet gone, and `kill 0` cannot tell the
  difference (this is the same subtlety `docs/process-supervision.md`
  documents for the dashboard's own live process checks).

So the same code, the same kill, and the same fixture produce a passing test on
a bare host and a permanently failing one inside an init-less container - not
because of timing, and not because of anything wrong with the kill itself.

## The fix: become the reaper, on purpose, before it is needed

`run_bounded` declares itself a Linux **subreaper**
(`prctl(PR_SET_CHILD_SUBREAPER, 1)`, called via `syscall()` because Perl has no
core binding for `prctl(2)`) before it forks the command. A subreaper is where
an orphan reparents to *instead of* PID 1 - the same mechanism every
zombie-reaping container init (`tini`, `dumb-init`) is built on; `tini` even
documents the identical failure shape and offers `-s`/`TINI_SUBREAPER` as the
fix when it cannot itself run as PID 1.

With that declared, `_terminate_group`'s cleanup sweeps
`waitpid(-$pid, WNOHANG)` for anything in the command's process group that
reparented to it - collecting the grandchild directly, regardless of whether
the host or container around it has an init that would otherwise have done it
for free.

**The sweep has to run on both of `_terminate_group`'s exit paths.** A command
that dies from the polite `TERM` alone (most direct commands do - a plain
`sleep` or `sh` installs no handler and simply dies) never reaches the escalated
`KILL` branch at all. An earlier version of this fix only swept for orphans
after the `KILL`, and missed exactly the common case where `TERM` alone already
finished the job.

The subreaper toggle is scoped narrowly on purpose: it is set immediately
before the fork and cleared immediately after the call returns, so it changes
nothing about how the calling test process behaves at any other point in its
life, and it is restricted to Linux on x86_64 - the platform this project
actually builds and tests on. Everywhere else it is a true no-op (returns
without attempting the syscall), which is exactly the behaviour this module had
before this fix: on a bare host, or on a platform where the syscall is skipped,
ambient init still does the reaping and nothing regresses.

## Why this had to be found by running the fixture in a container, not by reading the code

Every process-group/kill mechanic in this module was already correct: the kill
reaches the grandchild, and it dies. Nothing about that is visible from the
bare host, because the host's own init hides the missing reap so effectively
that the defect looks like it isn't there. It is only observable in an
environment with no ambient reaper - which is exactly the environment this
project's own Docker-based gate runs use. A test that only ever runs on a bare
host cannot discriminate this class of bug at all.
