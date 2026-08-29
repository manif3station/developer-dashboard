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

## Where else to look

The pair of near-identical routines that produced this one still exists:
`_read_process_env_marker` is duplicated across `RuntimeManager` and
`CollectorRunner`, and only one copy's test had the guard. Wherever a primitive
is duplicated, its *tests* can diverge as silently as its code — and the test
divergence is harder to see, because both files are green.
