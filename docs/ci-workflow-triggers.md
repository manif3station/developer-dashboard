# GitHub Actions workflow triggers

The repository has four active GitHub Actions workflow files: one serial
orchestrator and three reusable platform workflows.

| Workflow | Trigger or use | Role |
|---|---|---|
| `five-platform-coverage.yml` | Push to `master`, pull request, or manual dispatch | Runs macOS arm64, Linux amd64, Linux arm64, Windows amd64, and Windows arm64 coverage in order |
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

The orchestrator is fail-fast: each stage depends on the previous stage
succeeding. Read-only permissions and SHA-pinned external actions are required.
The workflow regression tests protect the inventory, stage order, architecture
checks, Linux build dependencies, and coverage invocation.

## Retired workflows

Standalone unit-test and coverage workflows, DockerHub and GHCR publishing,
CodeQL, GitHub Release, platform-compatibility, and JavaScript fuzz workflows
are not present in the active workflow directory.
