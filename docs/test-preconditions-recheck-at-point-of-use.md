# Test preconditions: re-check at the point of use, not at the door

## What this is

A pattern for writing a test guard against a known, external, load-dependent
hazard (like a sibling test's process interfering with this test's own
process) without letting that guard either (a) hide the real defect this
file's own assertions exist to test, or (b) go red for a hazard the file
explicitly does not own.

## The failure shape

A "door-check" reads some state ONCE, before the scenario that depends on it
runs, then trusts that single reading for an assertion that runs afterward.
Between the read and the assertion is real wall-clock time - the scenario's
own setup, a `start_loop()` call, whatever the test does - during which the
state the guard checked can change. The guard is correct about the instant it
sampled and wrong about the interval the caller trusted it for.

`t/153-collector-loop-accumulation.t` had exactly this shape guarding against
DD-543 (a supervisor process becoming an unreaped zombie under batch load,
caused by a sibling collector test's inherited `END` block sending it a
signal): the guard read the supervisor's process title once, before
`start_loop()` ran a second time, then `plan skip_all`'d the WHOLE FILE if
that one reading looked bad. The supervisor could die in the gap between the
reading and the assertion six lines later, so the guard passed while the
supervisor was still alive and failed while it was already gone - the file
went red for a hazard it explicitly did not own, and the failure was then
misattributed to whatever unrelated change happened to be under test at the
time (DD-803, fixed 2026-09-16).

## The fix: re-check right before the dependent assertion

Move the liveness check to immediately before the assertion(s) that need it,
not once at the top of the scenario. Wrap only THOSE assertions in a `SKIP`
block, so a hit costs the one scenario that genuinely cannot run without the
precondition - never the whole file.

```perl
my $liveness = supervisor_liveness( $pid, $name );
SKIP: {
    skip "DD-543: $liveness->{reason}", 2 if !$liveness->{alive};
    is( ... );   # the assertions that actually need the precondition
    is( ... );
}
```

## Distinguish the causes, don't just report "not alive"

A supervisor process that has stopped existing by the time you check it can
be in several different states, and only some of them are the hazard the
guard exists for. Collapsing all of them into one bare skip message makes
"the known hazard fired" indistinguishable from "the supervisor never
started" or "it exited cleanly on its own" - which hides a REAL regression
behind the SAME skip message a known, accepted flake produces.

Since the test process is very often the supervisor's own parent (a plain
`fork()`, no `setsid()`-based reparenting), a `waitpid( $pid, POSIX::WNOHANG )`
right at the check yields the KERNEL's own termination status - `$? & 127`
for the terminating signal, `$? >> 8` for a clean exit code - which is a much
stronger signal than re-reading a process-table title string:

```perl
my $reaped = waitpid( $pid, WNOHANG );
if ( $reaped == $pid ) {
    my $signal = $? & 127;
    if ($signal) {
        # was it a signal whose handler ran (check the component's own log
        # for a "received by pid $pid" entry), or one that never got the
        # chance (uncatchable, or delivered before the handler was
        # installed)? Only the SECOND is the door-check hazard.
    }
    else {
        # exited on its own - NOT the signal-race hazard, report as such
    }
}
```

A title still showing `<defunct>` in the process table (not yet reaped by
this `waitpid` call) is the same hazard, caught by a second, cheaper check.

## Prove the guard with a forced interleaving, not a wait for it to recur

A door-check that flakes under load is, by construction, hard to reproduce
reliably in isolation - which is exactly why the wrong version of it can sit
unnoticed for a long time. Don't write the fix's own test as "run this file
many times and hope the race hits"; force the exact interleaving directly:
start the real thing, then kill it in the precise window between the check
and the use, and assert the guard does the right thing on that forced case.

Two things the forcing test must get right:

- **Use a signal the component cannot catch and recover from**, if the
  component installs its own handler for orderly shutdown (many supervisor
  loops do, for a clean `TERM`). A `TERM` caught by a working handler is a
  real, benign, different path - not the hazard - and asserting `TERM` here
  produces a signal without a kill, then a signal->cannot->reach the actual
  race. Send `KILL` to force the genuinely uncatchable case the door-check
  exists for.
- **`kill()` only sends the signal; it does not block until the target has
  processed it.** A flat "check the very next Perl statement" reintroduces
  the SAME door-check shape on the forcing side of the test. Poll briefly
  (a short bounded loop, not a fixed sleep) until the liveness check itself
  reports the process gone, before asserting on that outcome.

## The negative control is not optional

Alongside the forced-failure case, prove the SAME liveness check reports a
genuinely healthy process as alive, and that the assertion depending on it
actually runs (not just "doesn't error"). A fix that turns every check into
an unconditional skip passes the forced-failure test vacuously and is
indistinguishable, from the outside, from a deleted test - this project's
own established "a test aimed at an empty set can only return the answer it
hoped for" lesson, applied to a guard rather than to a mutation test.

## When a DIFFERENT failure surfaces while working this class of defect

Re-checking at the point of use can expose a genuinely different, previously
hidden defect that the old coarse door-check happened to mask (because the
coarse check let the scenario through in more cases than the strict one
would have). That new failure is not this fix's to swallow - widening the
guard to skip it too repeats the exact anti-pattern this page exists to warn
against ("a naive fix... means the assertion never runs whenever the hazard
occurs"). File it separately, let it fail loudly, and re-verify the door-
check fix itself on a clean host before concluding anything about either.
