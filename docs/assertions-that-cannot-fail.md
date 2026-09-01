# Assertions that cannot fail

A test that passes tells you one of two things, and it does not say which: the
behaviour is correct, or the assertion was never in a position to notice. This
page is about the second kind, how it hides, and how to find it.

It is system-scoped. It describes a failure mode in this repository's tests, not
any ticket that fixed one.

## The shape

The clearest example this project has produced looked like a real test:

```perl
my $marker = $ready ? $manager->_read_process_env_marker( $child, 'HOME' ) : undef;
is( $marker, undef, '_read_process_env_marker returns undef when the environment is empty' );
```

`$ready` is set by a poll loop that waits for a probe child to reach its `exec`.
When the poll times out, `$ready` is false — **the function under test is never
called**, `$marker` is assigned the expected answer directly, and the assertion
passes.

So the test reports success in both of these cases:

| | function called | assertion |
|---|---|---|
| probe succeeded | yes | passes because the code is right |
| **probe timed out** | **no** | **passes because the ternary supplied the answer** |

Nothing in the output distinguishes them. Verified by forcing the poll to
`for ( 1 .. 0 )`: the file still reported *All tests successful, Tests=527,
Result: PASS* while the branch it exists to cover was never executed.

## Why coverage does not catch it

Because coverage measures **execution**, not **verification**. A line that runs
is covered whether or not anything checked its result — you can reach 100% with
tests that assert nothing at all.

What made this instance visible was not the coverage number but its
*instability*. The branch was covered only when the suite happened to encounter
a process with a readable-but-empty environ, so two four-metric passes over the
same unedited tree returned `Total 99.9` with the gate exiting 1 and then
`Total 100.0` with it exiting 0.

**Note which direction is dangerous.** A gate that fails spuriously wastes a
cycle and gets investigated. A gate that *passes* spuriously ships. This one
could do either, and only the first would have been noticed.

## The name for it

Modifying code and observing that the tests still pass is **mutation testing**,
and a mutation the suite fails to notice is a **surviving mutant** — somewhere
an assertion that should have caught the regression did not.

This repository already does the manual form and calls it falsification: break
it deliberately, confirm red, restore. That habit is why several instruments
here are trustworthy. Its systematic version would find mutants of this shape
without waiting for a coverage figure to wobble and someone to be curious about
it.

## The rules that follow

**1. Never let a ternary supply the expected answer.** Call the function
unconditionally once the setup is ready. If the setup failed, that is a
different outcome and must be reported as one.

**2. Pin the precondition with its own assertion.** `is($marker, undef)` is
satisfied equally by an empty environ and by a populated one that lacks the key.
A separate `is($probe_environ, '', ...)` fails when the fabrication did not
work, which is the only thing that keeps the real assertion meaningful.

**3. A setup that cannot be established FAILS — it does not skip.** Replacing a
silent pass with a silent skip preserves the defect and changes only its
spelling. Reserve `skip` for genuine environmental absence (no `/proc`, no
binary), and say which was missing.

**4. Remove intermediate processes from a probe.** Fabricating an empty
environment with `exec 'env', '-i', 'sleep', ...` gives the poll two processes
to match, and the intermediate `env` satisfies a cmdline check *before* it has
installed the empty environment. Clear `%ENV` in the fork itself.

**5. Diagnose a failed probe by naming what was seen** — whether the child never
reached its `exec`, or its `/proc` entry could not be read. A bare `got undef`
distinguishes neither, and note that `undef` never means "the value was empty":
an empty `/proc/<pid>/environ` reads back as `''` with length 0.

## Reviewing a change against this

Ask of any new assertion: **what would have to break for this to fail?** If the
answer includes "nothing, if the setup silently didn't happen", the test is not
finished. The cheapest check is to break the setup on purpose and confirm the
test goes red — the same falsification this project applies to its operator
tooling.

## A second mechanism: the assertion throws the discriminator away

The first instance on this page fails because a *setup* silently did not happen.
There is a second route to the same place, and it is harder to see because
nothing about the test is missing — the assertion simply **narrows the value it
checks until success and failure look identical**.

`t/09-runtime-manager.t` forks a child running `_follow_log_file`, sends it
`SIGHUP`, and asserts:

```perl
kill 'HUP', $missing_pid;
waitpid( $missing_pid, 0 );
is( $? >> 8, 0, '_follow_log_file exits cleanly on HUP' );
```

The child's handler ends with `POSIX::_exit(0)`. So a child that honours the
signal exits 0 — and a child killed by **any** other means also presents
`$? >> 8 == 0`, because a signal death puts the signal in the *low* byte and
leaves the exit byte zero. Measured in a container:

```
HUP lands BEFORE the handler exists   $? >> 8 = 0    $? & 127 = 1   assertion PASSES
HUP lands AFTER  the handler exists   $? >> 8 = 0    $? & 127 = 0   assertion PASSES
```

Two opposite realities, one observable. The test certifies "exits cleanly on
HUP" in a run where the handler never ran and the default action did the
killing.

**The discriminator was never missing.** `$?` is a 16-bit wait status carrying
the exit code in the high byte, the signal number in the low seven bits, and the
core flag at bit 8. `>> 8` discards exactly the half that distinguishes the two
cases. The fix is to assert the *whole* status — `$? & 127 == 0` alongside
`$? >> 8 == 0`, or `POSIX::WIFEXITED`/`WIFSIGNALED`, which `:sys_wait_h` already
provides.

**The generalisation, which is the reason this belongs on the page.** Any
transformation applied to a value *before* asserting on it can erase the
difference the assertion exists to detect: a shift, a regex capture, a `sort -u`,
a truncation, a cast, a `head`. So the question to ask of any assertion is not
only *"could this fail?"* but:

> **What did I discard between the observation and the comparison, and could the
> failure I am testing for be hiding in it?**

There is also a window here worth naming separately, because it is what makes
the bad case reachable rather than theoretical: `_follow_log_file` **creates the
log file** before it **installs its signal handlers**, and the parent's
readiness test is the file's existence. So the parent can legitimately signal a
child that is not yet able to catch it. A readiness check that watches for a
*side effect* of setup rather than for setup *completing* will eventually fire
early — and if the assertion downstream cannot discriminate, nothing reports it.

## The same shape in a checker, not a test

Everything above is about tests. The failure is not confined to them: a guard
that reports on the repository can carry an assertion that cannot fail, and it
is worse there, because nobody reviews a tool's output line the way they review
a test.

`.claude/tools/decline-watch` answers one question — is a rule this project
declined still rightly declined? It fetches the declines, judges each one's
re-declare trigger, and finishes with a deliberate completeness line:

```perl
# Say N of N out loud. A checker that quietly drops one of its subjects reads
# exactly like a checker that found nothing wrong with it.
say sprintf 'decline-watch: accounted for %d of %d declined rules, %d due for revisit',
  scalar @{$declines}, scalar @{$declines}, scalar @findings;
```

The comment is right and the line beneath it cannot deliver what the comment
promises. **Both operands are the same variable.** "N of N" compares the fetched
list against itself, so it holds for every N and can never report a shortfall —
the exact drop the comment was written to make visible.

It matters because the fetch is narrower than the subject. `tira.policy.declined`
with no `--ref` returns board-wide declines only; per-card declines, scoped to a
single card, are invisible to it. The tool prints `accounted for 2 of 2 declined
rules, 0 due for revisit` and exits 0 while the unseen part goes unexamined.

**And the verdict was correct anyway**, which is what makes it hard to catch. The
unseen declines sat on cards whose triggers had not fired, so "0 due for revisit"
was the true answer. It would print the identical line if a trigger *had* fired.
The defect is not a wrong answer — it is an answer that cannot be wrong, and a
silence that cannot become a finding is indistinguishable from a clean result.

The size of the gap is not quoted here on purpose, and that is worth its own
sentence. The first draft of this page said "two of four", which is what I had
counted by checking the one card I already knew about. Running the fixed tool
over every card found **four** per-card declines across **three** cards, six in
total — so the page describing counts that cannot be falsified carried a count
taken from a subset. The numbers moved again within the hour, as two of those
declines were corrected. A count belongs in the tool's output, where it is
re-derived every run; a page that quotes one is stating a measurement at an
instant in the one place nobody updates.

### Why a total must come from somewhere else

A count is only a check when it is derived twice. The judged count and the total
have to come from **independent derivations**, because one derivation compared
against itself is the tautology above wearing arithmetic. Counting more
carefully does not fix it; it reproduces it with a bigger number.

So a completeness line needs three properties, and the third is the one that
gets skipped:

1. a count of what was actually fetched and judged;
2. a total obtained by a different route;
3. **a comparison whose failure is reported and exits non-zero.** Printing both
   numbers is not enough — a reader who sees `2 of 4` and shrugs is exactly the
   reader the line exists for.

### Applying it

- When a guard prints "accounted for", find where each number comes from. If
  they trace to one fetch, the line is decorative.
- Ask what the fetch **excludes**. A subject narrowed by a default — no `--ref`,
  no `--all`, one column, one session — is the usual cause, and the narrowing is
  invisible in the output.
- Falsify it: make the two derivations disagree on purpose and confirm the tool
  goes red. A completeness check never seen to fire proves nothing, which is the
  same standard this repository already applies to its other instruments.
- The established name is a **tautological assertion**, and the classic cause is
  **aliasing** — one value supplied as two operands. It is normally discussed
  about tests; it is not a property of tests.

## Where else to look

The pair of near-identical routines that produced this one still exists:
`_read_process_env_marker` is duplicated across `RuntimeManager` and
`CollectorRunner`, and only one copy's test had the guard. Wherever a primitive
is duplicated, its *tests* can diverge as silently as its code — and the test
divergence is harder to see, because both files are green.
