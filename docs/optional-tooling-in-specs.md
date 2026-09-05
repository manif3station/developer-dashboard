# Optional tooling in specs: skip with a reason, never fail

Some of this suite's specs test the *coverage tooling* rather than the product:
they exercise `script/coverage-gate`, its entrypoint, its launch boundary and its
handling of truncated output. Those specs need **Devel::Cover**, which is a
development tool and is not part of the product's declared runtime dependencies.

Every other spec runs happily without it. Devel::Cover is loaded by the *harness*
switch — `HARNESS_PERL_SWITCHES=-MDevel::Cover=...` — never by a spec. Grepping
the suite for the string finds it in 114 files and **zero** of them `use` or
`require` it; those are all comments. So the question below applies to a handful
of specs, not to the suite.

## The rule

> **A spec whose subject cannot be measured without an optional tool SKIPS, with
> a stated reason naming the tool. It does not fail.**

The reason is not tidiness. A spec that fails because a tool is absent produces
output byte-identical to a spec that found a defect, so a reader cannot tell an
environmental problem from a real one without going and looking. That is the same
family as [assertions that cannot fail](assertions-that-cannot-fail.md): in both
cases the output stops carrying the information it appears to carry.

## What this looks like when it is right

`t/138-coverage-exec-truncation.t` already does it, and its wording is the model:

```
t/138-coverage-exec-truncation.t .. skipped: Devel::Cover is not installed,
                                    so coverage attribution cannot be measured
```

The message names the tool **and** what could not be measured because of it. A
bare `skipped` would satisfy the mechanism and not the purpose.

`script/coverage-gate` takes the same position in the product code — it tolerates
the module's absence rather than dying:

```perl
return undef if !eval { require Devel::Cover::DB::IO; 1 };
```

## The placement that matters

**Guard before the plan, not inside it.** A spec that declares `plan tests => 9`
and then dies at assertion 3 reports:

```
Bad plan. You planned 9 tests but ran 3
```

Six assertions never executed, and every one of them is reported as a failure.
That is strictly worse than a plain failure, because the output cannot distinguish
*unmet* from *never attempted* — the reader has no way to know which six were
which. A skip that runs before the plan is declared avoids the whole shape.

The standard Perl idiom does this naturally:

```perl
eval { require Devel::Cover; 1 }
  or plan skip_all => 'Devel::Cover is not installed, so <what> cannot be measured';
```

`Test::Needs` and `Test2::Require::Module` exist for the same purpose. That two
CPAN modules were written for it is a reasonable signal that the problem is common
and the answer is settled.

## The half that is easy to get wrong

A guard that *always* skips satisfies every without-the-tool test and destroys the
spec. Whenever one of these guards is added or changed, the check has two halves
and both are required:

| environment | expected |
|---|---|
| Devel::Cover absent | skips with a reason, `prove` exits 0 |
| Devel::Cover present | **every assertion still runs and passes, same counts as before** |

Only the second half can catch an always-skip guard, and nothing in the first
half hints that it is needed. Record the with-the-tool counts *before* changing a
guard, or there is nothing to compare against afterwards.

## Which images carry what

The platform gate names container images, and they differ:

| image | product installed | Devel::Cover | runtime deps |
|---|---|---|---|
| `developer-dashboard:latest` | yes (`cpanm` of a built tarball) | **no** | yes, as of its build date |
| `developer-dashboard:test` | **no** — stock `perl` plus a version marker | no | no |

Two consequences follow. Coverage-tooling specs will skip in either image, which
is the correct behaviour and not a gap. And `:test` cannot exercise the *installed*
product at all, because there is no installed product in it — mounting a source
tree and running `perl -Ilib` tests the source on that distro, which is a
different and weaker claim than the image's name suggests.

Adding Devel::Cover to a platform image is the wrong fix for a failing spec here.
A platform gate answers "does this work on that distro"; it does not need a
coverage instrument, and installing one to quiet two specs treats the symptom at
the most expensive available point.

### "as of its build date" was doing real work (DD-761)

`developer-dashboard:latest`'s build was self-referential —
`test_by_michael/Dockerfile` read `FROM developer-dashboard:latest` and
`compose.yml` tagged the result back to the same name, so every rebuild layered
on top of the *previous* build of itself rather than starting clean. Paired
with a checked-in `DD.tgz` tarball that nothing regenerated, the image drifted
three weeks behind master: `String::Compare::ConstantTime` — a **declared
runtime dependency** (`cpanfile`, `Auth.pm` loads it at compile time) — was
simply absent, and every code path through `Auth.pm` died in the container the
platform gate names. `dashboard encode`/`decode` failed outright; a fast-check
property test presented the failure as a plausible-looking empty-string
counterexample (see [assertions that cannot fail](assertions-that-cannot-fail.md)
for that shape generally) before a control run (`encode("hello")` failing
identically) showed the module was never loading for *any* input.

Fixed by regenerating `DD.tgz` from current master, pinning the Dockerfile to a
real base (`FROM ubuntu:26.04`, the OS the image actually runs) instead of
itself, and adding a build-time check that parses `cpanfile`'s declared
`requires` and fails the **build** if any of them cannot load — so the next
drift of this kind is caught the moment it's introduced, not months later by
whoever next hits the missing module through an unrelated symptom. The table
above is accurate again as of the rebuild; it will drift again if the
Dockerfile ever reverts to referencing itself.
