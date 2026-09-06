# A skip that cannot say why

**System-scoped.** This is about any guard that declines to run — a `skip_all`,
an early `return`, a `continue`, a job that finds nothing to do. It is not about
one spec.

## The claim

This project already insists that a checker distinguish **clean** from
**could-not-look**, because a checker that dies quietly reads exactly like one
that found nothing. Every tool here has a separate non-zero exit for *unusable*.

**A skip is the same thing, in test output, and nobody applies the rule there.**
A skipped file prints one line and passes. If that line cannot say *which*
condition caused the skip, a benign cause and a serious one are reported in
identical words — and the reader has no way to tell which they are looking at.

## The worked example

```perl
plan skip_all => 'not a source tree, or no operator tools directory'
  if !-e $ROOT/.git || !-d $TOOLS;
```

Two conditions, one message. They are not equivalent:

| state | meaning | correct response |
|---|---|---|
| `.git` absent, tools absent | an installed copy from the tarball — genuinely nothing to run | skip; expected; ignore |
| `.git` **present**, tools absent | a source tree missing its tools — the specs exist, but not here | **this is a gap** |

The second case is every CI run, because the tools directory is operator-local
and was removed from version control by a deliberate decision. So the case that
matters is announced in the words of the case that does not, and has been since
that decision.

The file in question existed *because* a previous incident found thirteen specs
that nothing executed. Its own header says: *"a spec nobody runs cannot fail, so
it protects nothing while LOOKING like protection."* The guard written to stop
specs going unrun could not itself run — the same failure, one level up.

## Why nothing catches it

**The headline number cannot discriminate.** `prove` counts a `skip_all` file in
`Files=`, so a run that skips reports the same total as one that executes:
`172 ok + 4 skipped = 176 = Files=176`. Two runs covering different populations
print an identical summary line.

**So the skip LIST is the discriminating output and the COUNT is not.** A
verdict reported as "Files=176, Result: PASS" is true of both populations. A
verdict reported as "176 accounted for: 172 ok, 4 skipped — *named*" is true of
exactly one.

## The rule

- **One condition, one message.** If a guard tests two things, it must say which
  one fired. Collapsing them costs one `if` and buys nothing.
- **Name what did not run**, not just that something did not. "Twenty operator
  specs are unreachable here" is actionable; "no operator tools directory" is a
  fact about a path.
- **Skip, do not fail** — where the absence is a deliberate choice. Turning a
  legitimate operator-local absence into a red build punishes everyone for a
  decision someone made on purpose. The deliverable is legibility, not
  enforcement, and confusing the two is how a good finding becomes a bad fix.
- **Report a suite verdict as its accounting, never as its total.** N files = X
  ok + Y skipped, each skip named. The total is the number that survives being
  wrong.

## The generalisation

A skip is a *decision not to measure*. Every other decision not to measure in
this project is required to announce itself — a checker's could-not-look exit, a
gate's BLOCKED verdict, a monitor's "I could not look" state. Test output is the
one place where declining to measure still prints as success, and that is a
convention rather than a necessity.
