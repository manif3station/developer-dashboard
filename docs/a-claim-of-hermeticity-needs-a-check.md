# A test that says it is hermetic is making a claim, and claims need checks

A spec here carried this sentence in its own documentation:

> The file is hermetic.

It was not, and it went red in CI ninety minutes after landing while passing every
local run — including a full suite of 176 files and 17,813 tests on the identical
tree.

## What "hermetic" turned out to mean

The spec exercised a gate that requires two modules. It shadowed one of them with a
fake, to control the value under test, and said nothing about the other.

That was invisible locally because the local runner sets a library path containing
the real distribution, so the fake was merely **prepended** to a path that already
had what was missing. The dependency was satisfied by the environment and the file
never had to declare it.

CI keeps the two things in different places — the tool's *binary* on `PATH`, its
*library* in a separate prefix that the test step does not put on the library path.
So the module was present as a program and absent as a library, the gate refused to
run, and every assertion that exercised it failed.

## The claim was false when written, and it was written by the same hand

The POD sentence was added in the same commit as the fake. It described the
**intent** of the fake — control the value, depend on nothing — rather than the
file's actual dependencies. Nothing checked it, so nothing contradicted it.

**This is the general shape and it is not specific to Perl.** A statement about what
a thing depends on is exactly as verifiable as a statement about what it does, and
it is far less often verified. "Hermetic", "self-contained", "no network", "no
global state", "pure" — every one of them is a testable proposition that usually
ships as prose.

## The check is one command

```sh
env -u PERL5LIB perl -Ilib t/<file>.t     # or the equivalent for your runtime
```

Strip the ambient thing that might be propping it up, and run it. If the file claims
independence from the environment, that claim IS the test, and it costs seconds.

The same move generalises: run it with an empty `PATH` entry, with `HOME` unset,
with the network off, in a container with nothing installed. **Pick the resource the
claim denies needing, remove exactly that, and re-run.**

## And the control is what makes the green mean anything

Fixing it produced a passing run without the ambient path. That alone proves less
than it appears: the environment might simply have changed. The result that
establishes causation is the third one —

| run | result |
|---|---|
| fixed, ambient path removed | passes |
| fixed, ambient path present | passes |
| **pre-fix, ambient path removed** | **still fails** |

— because it shows the fix changed the outcome rather than the conditions. On a card
about a test that passed for the wrong reason, accepting a green without that
control would have repeated the original defect exactly.

## Where else this bites

Anywhere a component's dependencies are satisfied incidentally by a rich
environment and the component never declares them. Development machines are rich;
CI, containers, fresh clones and end users' machines are not. **The gap does not
appear as a wrong answer — it appears as a thing that works everywhere you tried
it**, which is why it survives review and is found by the first environment that
lacks the accident.

Related: `docs/a-verdict-must-name-its-corpus.md` — the same failure one level up,
where the thing left undeclared is not a dependency but the data a verdict was
reached from.
