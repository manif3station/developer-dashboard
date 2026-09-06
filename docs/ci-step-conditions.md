# Which CI steps must fail fast, and which must still report

A workflow step with no `if:` is skipped when an earlier step fails. That is
usually right and occasionally disastrous, and the difference is not
"important step" versus "unimportant step" — it is **what the step is for**.

## The line

> **Steps that build the TREE fail fast. Steps that prepare or perform
> VERIFICATION must survive an earlier failure and report their own verdict.**

Established by DD-568 and stated in `test.yml` itself:

- **Build the tree** — `Checkout`, `Install project dependencies`. These get no
  condition. A suite run against a half-built tree is meaningless, so when they
  fail everything after them *should* stop.
- **Prepare or perform verification** — installing test tools, running the
  suite, checking coverage, auditing dependencies. These carry `if: always()`,
  because their whole job is to produce a verdict, and *the case where an
  earlier step failed is exactly the case someone needs that verdict for.*

## Skipped is not passed

A skipped step has **no conclusion**. Read quickly, a run whose only red mark
is one failing step looks like one problem; in fact every verification
downstream of it produced nothing at all. That is the verdict you did not get,
and it is indistinguishable from a verdict nobody wanted.

This has now happened in two workflows here, which is what makes it a shape
rather than an incident:

| workflow | failing step | what it took with it |
|---|---|---|
| `test.yml` | `Audit isolated Perl dependencies` — explicitly **not** the release gate (DD-499) | `Audit the declared dependency chain`, which **is** the release gate |
| `fuzz-js.yml` | `Install Perl dependencies` | `Install JS test dependencies`, `Run fast-check property tests` |

In the first, a step the project documents as *not* a release blocker silently
suppressed the one that is. Master carried no release-gate verdict across two
commits and nothing announced it.

## The failure mode this protects against is worse than a skip

DD-568's own reasoning, and the reason the line is not simply "put `always()`
on everything": marking only the *test* steps as `always()` while leaving the
step that **exports `PERL5LIB`** unconditional means the suite fires into an
environment that was never prepared. It then fails for want of setup rather
than for want of correctness —

> turning "no verdict" into a FALSE FAILING verdict, which is worse than the
> skip it replaced: a skip is visibly absent, a spurious red is believed and
> chased.

So a verification step's *preparation* has to travel with it. Adding a
condition to one and not the other converts a silent gap into a loud lie.

## What about a genuinely unusable run?

The objection to `always()` on an audit is that it might run against a tree
that was never built. That is fine **when the tool has an unusable state**, and
this project's audits do: `script/cpan-audit-declared-chain` exits `2` when it
cannot walk the closure, and says why.

A reported *unusable* is strictly better than a skip. One is a state a reader
can act on; the other is an absence. This is the same distinction the project
draws everywhere else — **clean, could-not-look, and failing are three answers,
not two** — applied to a workflow step.

## Naming, which is half the defect

`Audit isolated Perl dependencies` and `Audit the declared dependency chain`
are accurate and give a reader no way to tell that only the second gates a
release. Someone reading a red run has to already know DD-499 to interpret it —
and the project's own documentation tells them the first one's subject is
environmental, which invites dismissing a failure that may be real.

**A step name should say what a failure means**, not just what the step does.
That is not cosmetic here: the two audits differ in whether they can block a
release, which is the single fact a reader of a failed run most needs.

## Checking this

Conditions are cheap to inventory and worth re-reading whenever a step is added:

```sh
grep -nE '^      - name:|^        if:' .github/workflows/test.yml
```

And to see what a run actually did — never infer from the summary, which
reports the *run*, not the steps:

```sh
GH_TOKEN="$GITHUB_AUTH_TOKEN" gh api \
  repos/manif3station/developer-dashboard/actions/runs/<id>/jobs \
  --jq '.jobs[].steps[] | select(.conclusion != "success") | "\(.conclusion)  \(.name)"'
```

`gh` is installed here but not logged in; `GH_TOKEN` from the shell init is
enough and needs no `gh auth login`. `curl` against the same path works too and
needs nothing at all.

Read each step's `conclusion`: `success`, `failure`, `skipped`, or `null` for a
step that has not run yet. **A filter like the one above returns nothing for an
all-green run** — confirm against a run you know failed before trusting an empty
result, or an empty subject reads as a clean one.

A step whose conclusion is `skipped` did not pass. If it is a gate, you have no
gate.
