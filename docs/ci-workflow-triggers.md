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

## Targeting individual platforms with commit tags

Normally an untagged latest commit runs the **full five-platform chain**:

1. macOS arm64 (tag: `mac`)
2. Ubuntu amd64 (tag: `ubuntu-amd64`)
3. Ubuntu arm64 (tag: `ubuntu-arm64`)
4. Windows amd64 (tag: `win-amd64`)
5. Windows arm64 (tag: `win-arm64`)

To run only selected platforms, put one or more **square-bracket tags** in
the latest commit's subject or body, for example:

    fix: native Windows compatibility [win-amd64]

Or select nonadjacent stages in the same commit:

    fix: Linux ARM64 and Windows ARM64 [ubuntu-arm64] [win-arm64]

An explicit commit message trailer works too:

    CI-Platforms: mac, win-amd64, win-arm64

The exact tags are case-insensitive. Plain mentions like "macOS" or "Windows"
are not tags. Invalid names in `CI-Platforms:` cause selection to fail visibly.
For pull requests, only the **latest PR head commit** decides the platforms,
not the merge commit or all commits in the PR. Pushing another untagged commit
restores the full five-stage run. On master pushes and manual dispatches, the
latest commit of the triggering ref determines the selection.

The five platforms always retain their original order, **not tag order**.
An unselected predecessor is skipped without blocking the next selected
platform. But any selected stage that fails prevents all later selected stages
from running. This applies equally to single-platform and multi-platform
runs; it does not relax the 100% four-metric coverage gate.

Read-only permissions and SHA-pinned external actions are required. Workflow
regression tests protect tag parsing, the ordered skip-aware dependency chain,
architecture checks, Linux dependencies, and coverage invocation.

## Retired workflows

Standalone unit-test and coverage workflows, DockerHub and GHCR publishing,
CodeQL, GitHub Release, platform-compatibility, and JavaScript fuzz workflows
are not present in the active workflow directory.
