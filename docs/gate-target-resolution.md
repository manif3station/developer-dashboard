# Which tree does a gate actually measure?

Every gate tool in this repository has to answer one question before it does
anything: **which checkout am I grading?** There are only two possible answers —
the tree the *caller is standing in*, or the tree the *script itself lives in* —
and the tools here deliberately do not all give the same one.

That is not an inconsistency to tidy up. The three answers are different because
the tools do different jobs. What matters is that each one's answer is *stated*,
because the failure mode is not picking the wrong tree — it is picking a tree
silently and producing a result that looks exactly like the one you wanted.

## The three resolutions in use

| tool | resolves its target from | consequence |
|---|---|---|
| `.claude/tools/run-suite` | the **caller's cwd** (its own location is used only for the state directory) | invoking the main checkout's copy from a sandbox correctly grades the sandbox |
| `script/coverage-gate` | **its own file location**, then `chdir`s there | invoking the main checkout's copy from a sandbox grades the **main checkout** |
| `.claude/tools/gate-status` | **its own file location** for `COVER_DB` | reads the main checkout's database whatever the cwd |

`run-suite`'s behaviour is what makes cross-checkout gating work at all, and it
is the one to preserve. A sandbox has no `.claude/` — the directory is
git-ignored — so the only way to reach these tools from a sandbox is by the main
checkout's absolute path, and `run-suite` is the one where that does the
expected thing.

## Why the script-relative answer is defensible, and where it stops being so

Resolving from `__FILE__` is a real design choice, not an accident. A gate is a
*repository operation*: run from `/tmp`, "grade the repository I belong to" is
more sensible than "grade whatever directory you happen to be in". The specs
depend on it — `t/151-coverage-gate-launch-boundary.t` copies the gate into a
throwaway repository precisely so the `chdir` lands inside the sandbox, and says
so in its helper's comment.

It stops being defensible at the point where the two trees **both exist and
disagree**, because then the tool is making a choice the caller did not know was
being made. The caller believes they are gating the tree they are standing in.
The tool grades another one, succeeds, and prints a normal-looking result.

**The provenance is the part that turns a wasted run into a false pass.** A
verdict records `TREE` (which commit) and `WORKSTATE` (what was uncommitted on
disk) so a later reader can tell whether the figure still describes their code.
If those are computed in the caller's tree while the measurement happened in
another, the verdict does not merely describe the wrong tree — it carries
*correct-looking provenance for a tree nobody graded*, and passes the staleness
guard that exists to catch exactly this.

## The instrument trap, which is the reusable part

Asking `coverage-gate --dry-run` which tree it will use **cannot answer the
question.** It prints:

```
coverage gate:   database    : cover_db
```

a *relative* name, byte-identical whether the gate is about to grade your
sandbox or someone else's checkout. Reading that output and concluding "both
copies behave the same" is a confident wrong answer produced by a working
command.

What discriminates is reading the resolved **absolute** path — or, from outside,
the live process's own working directory:

```sh
perl <path-to-gate> --dry-run >/dev/null 2>&1 &
readlink /proc/$!/cwd        # the tree it actually moved to
```

**Two rules generalise past this file:**

- **When a tool reports a configured value rather than a resolved one, it cannot
  be used to check resolution.** A relative path, a symbolic name, or a
  default-as-written all look identical across the cases you are trying to tell
  apart.
- **A spec that overrides a default can never test that default.** Every
  coverage-gate spec here passes an explicit `--database`, for a good reason —
  the default would contend with the real gate holding that lock — and the
  consequence is that no spec exercises the resolution that real runs use. Where
  a default is dangerous enough that tests avoid it, that is the value most
  needing a test of its own.

## What a workaround in one place tells you

`t/151`'s helper works around this by copying the gate into its sandbox, and
explains why in prose. That comment is a bug report nobody filed. Worse, a
hazard handled in one spot makes every unhandled spot read as **deliberate** — a
later reader assumes somebody considered the area and chose differently here,
when in fact nobody looked. When you work around something, either fix the other
instances or say in writing that you did not.
