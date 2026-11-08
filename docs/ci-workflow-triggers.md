# GitHub Actions workflow triggers

The repository has four active GitHub Actions workflow files: one serial
orchestrator and three reusable platform workflows.

| Workflow | Trigger or use | Role |
|---|---|---|
| `five-platform-coverage.yml` | Push to `master`, pull request, or manual dispatch | Runs all five platforms serially by default, or only explicitly selected platforms |
| `linux-coverage.yml` | Reusable `workflow_call` | Builds and tests the selected native Linux architecture |
| `windows-amd64-unit-tests.yml` | Reusable `workflow_call` | Builds and tests native Windows amd64 |
| `windows-arm64-coverage.yml` | Reusable `workflow_call` | Builds and tests native Windows arm64 |

Every platform stage builds the native XS extension and runs the repository
coverage gate. Linux installs `libayatana-appindicator3-dev` and `libgtk-3-dev`
before its build because the Linux System Menu helper uses the
`ayatana-appindicator3-0.1` and `gtk+-3.0` pkg-config libraries. The gate uses
ten TAP workers and requires 100% statement, branch, condition, and subroutine
coverage. Native-thread tests run separately without unsupported
instrumentation and must still pass.

## Selecting coverage platforms with Git tags

By default, a commit without platform Git tags runs all five 100% coverage jobs
in the original serial fail-fast order:

1. macOS arm64 (`mac`)
2. Ubuntu amd64 (`ubuntu-amd64`)
3. Ubuntu arm64 (`ubuntu-arm64`)
4. Windows amd64 (`win-amd64`)
5. Windows arm64 (`win-arm64`)

**These are real Git tags, not strings in commit messages.** To test only a
middle stage on the currently checked-out commit, create and push the tag:

```sh
git tag win-amd64 HEAD
git push origin win-amd64
```

To test more than one platform on the same commit, attach multiple Git tags:

```sh
git tag ubuntu-arm64 HEAD
git tag win-arm64 HEAD
git push origin ubuntu-arm64 win-arm64
```

The workflow's tag-push trigger can run the tests without first pushing a new
branch commit. The selector fetches Git tag refs and evaluates only tags that
point **exactly at the triggering commit**, or at the PR head commit when a PR
run is triggered. Both lightweight and annotated Git tags are supported.
A tag on a previous commit, or a release tag such as `v6.29`, does not affect
the current commit. The exact tag names are case-sensitive.

**Git tags are repository-wide names:** a name such as `win-amd64` cannot be
used for another commit while it still exists. To retarget a platform tag,
coordinate with collaborators before deliberately moving or replacing the
existing remote tag; force-updating a shared Git ref is not automatic.

For pull requests, tags are read from the actual PR head commit, not GitHub's
synthetic merge commit. The coverage jobs themselves still test the synthetic
merge SHA so that integration against the target branch is validated. If no
platform Git tags are attached to the current commit, all five stages run.

Selected platforms always execute in the original order, regardless of tag
creation or push order. Skipped predecessors do not block selected stages, but
a selected failing platform prevents every later selected platform from running.
Every selected platform still runs the full ten-worker suite and mandatory
100% statement, branch, condition and subroutine coverage gate.

Read-only permissions and SHA-pinned external actions remain required. The
workflow tests guard tag discovery, stage ordering, native dependencies and
the four-metric coverage invocation.

## Retired workflows

Standalone unit-test and coverage workflows, DockerHub and GHCR publishing,
CodeQL, GitHub Release, platform-compatibility, and JavaScript fuzz workflows
are not present in the active workflow directory.
