# Bounding a poll loop by count is bounding it by nothing stable

A loop that polls for a condition needs an upper bound, or a genuinely
stuck condition hangs the test suite forever. The bound has to be
something, and an iteration count (`for (1..3000)`) looks like a bound -
it is finite, it is testable, it reads as safety. It is not a time bound,
and treating it as one is what this page is about.

## The failure this describes

Two coverage-test fixtures (`t/100-runtimemanager-coverage.t`,
`t/103-collectorrunner-coverage.t`) each fork a child, then poll
`/proc/<pid>/cmdline` up to 3000 times, sleeping 10ms between polls, to
detect the moment the child's `exec` replaces its argv. DD-482 measured
the real cost directly: on a quiet host the child needs about 2 polls;
under Devel::Cover it needs about 678 - because a Devel::Cover-instrumented
child flushes its coverage database before `exec`, and that flush is real
work. 3000 looked like 4.4x headroom over the measured number.

It was not enough a third time (DD-767), on a genuinely loaded host. The
count-as-bound reasoning has a hole: **the wall-clock cost of N polls is
not fixed** - it depends on how long each poll takes, which depends on
system contention, which is *exactly the variable the bound exists to
survive*. Calibrating "N is enough" against a measurement taken on a quiet
host guarantees the bound is weakest precisely when the machine is busiest
- the one condition a coverage gate (which regularly runs alongside other
heavy processes on a shared host) cannot assume away.

## What a genuine time bound looks like

```perl
use Time::HiRes qw(time);
...
my $deadline = time() + 60;   # real headroom over a measured need, not a raised count
while ( time() < $deadline ) {
    ...poll...
    last if $condition_met;
    select undef, undef, undef, 0.01;
}
```

The loop now runs until a fixed amount of *wall-clock* time has passed,
whatever that time actually costs in iterations. A slow iteration under
load simply means fewer of them fit in the same real budget - which is
the property a bound exists to provide, and which a count-based loop
cannot offer because it has no idea what an iteration costs.

**Do not "fix" a count-based bound by raising the count.** That is the
same repair, restated, and it fails the same way the third time - proven
here twice already (the bound was raised once already, to 3000, and still
was not enough).

## The diagnostic matters as much as the bound

A timed-out poll that reports only "gave up, child status undef" tells
the next reader nothing about *why*. Two specific traps to avoid in the
failure message itself:

- **`-e /proc/<pid>` is true for a zombie.** A dead-but-unreaped child
  reports as "alive" under that check, which is the opposite of useful
  when diagnosing why a poll never saw the exec complete.
- **State alone does not distinguish "never exec'd" from "exec'd the
  wrong thing".** Reading both the process state letter (from
  `/proc/<pid>/stat`) *and* the actual `cmdline` separates three real
  outcomes: exec never ran (cmdline is still the parent interpreter),
  exec ran with unexpected argv[0], or the child genuinely died.

## Reviewing a change against this

- **Any `for (1..N)` polling loop is a candidate for this defect.** Ask
  what determines how long N iterations actually take, and whether that
  duration is stable across the environments the loop must survive.
- **A bound "demonstrated" on a quiet host is a measurement of the best
  case, not the bound needed.** State the environment the measurement was
  taken in, in the same sentence as the number.
- **Never raise a count to fix a count-based timeout that failed under
  load.** If the failure is genuinely one of insufficient real time, fix
  the unit the bound is expressed in.

## Related

- `progress-not-liveness.md`-shaped lessons elsewhere in this project make
  the same point about judging a long-running holder by progress rather
  than elapsed time; this page is the mirror case - judging a *bound* by
  the time it actually buys, rather than by a count that looks like one.
