# What actually triggers each core CI workflow

`.github/workflows/` ships four workflows, and none of them runs on only one
event. Read this before restating any of their trigger sets in prose - the
last time that was done from memory, in the top-level skills guide, it was
wrong for one workflow the day it was written and wrong for the other three
within a few days of being corrected.

## The real trigger set, per workflow

| Workflow | push | pull_request | tags | schedule | workflow_dispatch |
|---|---|---|---|---|---|
| `test.yml` | `master` only | yes | no | no | no |
| `codeql.yml` | **every branch** (`**`) | yes | no | weekly (`19 3 * * 1`) | no |
| `package-ghcr.yml` | `master` only | no | `v*` | no | yes |
| `fuzz-js.yml` | `master` only | yes | no | no | yes |

`codeql.yml` is the widest: it is the only one of the four whose push trigger
is not scoped to `master` at all, and the only one with a schedule.
`package-ghcr.yml` is the only one that also fires on a version tag push.
`test.yml` and `fuzz-js.yml` are the closest to "push to master", but both
also run on every pull request; `fuzz-js.yml` additionally takes manual
dispatch.

**No workflow in this set runs ONLY on push to master.** A sentence claiming
otherwise, for any subset of these four, is wrong.

## Why this drifted before, and how the drift is now caught

The skills guide originally stated all four "run on every push to master",
which was wrong only for `codeql.yml` (DD-1001's original finding). By the
time that was corrected, `test.yml` and `fuzz-js.yml` had gained
`pull_request` and `package-ghcr.yml` had gained `tags` and
`workflow_dispatch` - the same class of drift, recurring within days, because
nothing re-checked the claim against the live YAML.

`t/227-skills-md-ci-triggers.t` now reads each workflow's real `on:` block
(via the same YAML::XS trigger-block resolution `t/34-scorecard-guardrails.t`
already uses, to work around the bare-`on`-parses-as-boolean-true YAML
gotcha) and asserts the skills guide's prose against it on every suite run.
The next drift in any of the five dimensions in the table above fails that
test loudly, instead of sitting unnoticed until someone happens to reread
the workflow files by hand.

## Reviewing a change against this

- **Adding or changing an `on:` trigger on any of the four workflows** must
  update `t/227-skills-md-ci-triggers.t`'s expectations for that file, and
  the table above, in the same change - not as a follow-up.
- **Never restate a workflow's trigger set in prose from memory.** Read the
  file's own `on:` block, the way `t/227` does, and quote it.
- **A workflow reported here as narrow ("master only", "no schedule") is a
  claim that can be falsified by one line added to that file.** Treat it the
  same way as any other behavioral claim in this vault: check it against the
  source, not against this page, when it matters.
