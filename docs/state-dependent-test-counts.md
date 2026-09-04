# Tests whose COUNT depends on state, and why a suite total stops meaning anything

A sibling of *Tests that depend on time*. That page is about an assertion's **outcome**
changing with when it runs. This one is about an assertion's **existence** changing with
what is on disk — a subtler fault, because nothing fails.

## The shape

An assertion sits inside a conditional:

    if ( !-d $node_modules ) {
        my ( $out, $err, $exit ) = capture { system 'npm', 'ci' };
        is( $exit, 0, 'npm ci prepares the dependency tree' );
    }

The first run in a tree takes the branch, installs, and emits the assertion. Every run
afterwards finds the directory present, skips the branch, and emits one fewer test. The
file plans `1..4` once and `1..3` for ever after — **in the same tree, at the same
commit, with nothing changed**.

The twist that makes it hard to see: *the condition is state the test itself created.*
The first run is the one that makes every later run different.

## Why it is worse than it sounds

**Nothing fails.** Both runs are green. `done_testing` reports whatever ran rather than
asserting a number agreed in advance, so a vanishing assertion is indistinguishable from
a suite that never had it.

**It destroys the suite total as a signal.** "Files=173, Tests=17660" looks like a fact
about a commit. It is a fact about a commit *plus a working tree*. Two runs of the same
code legitimately differ, so a genuine regression that removes one test is invisible —
you cannot tell it from the ordinary drift.

**It reads as flakiness, and flakiness gets tolerated.** A count that moves by one looks
like a race, and races get shrugged at. This is not a race: it is deterministic given
one input nobody was tracking.

## The rule

**An assertion's existence must not depend on state. Its OUTCOME may.**

Keep the expensive work conditional — reinstalling a dependency tree that is already
there is pure waste — but move the assertion out, and assert the **postcondition**:

    if ( !-d $node_modules ) {
        capture { system 'npm', 'ci' };
    }
    ok( -d $node_modules, 'the dependency tree is present' );

One assertion, always, in both states. Two things improve at once: the plan becomes
constant, and the test now checks the thing the rest of the file actually depends on
rather than the exit code of one command — so an install that "succeeded" and produced
nothing is caught too.

## Verifying a fix, and the check that is easy to omit

Run it twice, deliberately from both states:

    rm -rf node_modules && perl -Ilib t/NN-name.t | grep '^1\.\.'
    perl -Ilib t/NN-name.t | grep '^1\.\.'      # immediately after

Both plans must match. **And assert that the test itself is present in both outputs**,
not merely that the counts agree — a "fix" that stabilised the count by deleting the
assertion passes a count-only check while silently removing coverage. That is the same
trap as any before/after comparison whose subject might not have run.

## The other member of this class, which is not a defect

`t/158-operator-tool-specs.t` discovers its subjects with `opendir` on `.claude/tools/`
and runs whatever `t-*` files it finds. Since that directory is untracked, a fresh
worktree contains none of it and the file plans `1..0`; a populated checkout plans about
twenty more. Same shape — a plan that depends on the working tree — but here the
discovery **is the feature**, and a fixed plan would defeat it.

So the two need different answers, and the distinction is worth stating: a conditional
assertion that nobody intended is a defect; a discovered set of subjects is a design.
What they share is the consequence, and it is the important part:

> **A suite total is a property of the commit AND the working tree.** Comparing totals
> across trees — or across a tree before and after its first run — compares two different
> things. Any drop-detector built on totals must fix the tree state first, or exclude the
> files that legitimately vary, and say which it did.

## Reviewing a change against this

- Is any `ok`/`is`/`like` inside an `if`, `unless`, or an early `return`?
- Does the condition test something the test suite itself creates — a cache, an install,
  a temp tree, a downloaded fixture?
- If the count must vary, is that a deliberate design (discovery) or an accident?
- Does the verification prove the assertion **ran**, or only that a number matched?
