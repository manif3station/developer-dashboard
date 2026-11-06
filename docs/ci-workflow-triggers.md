# GitHub Actions workflow triggers

The repository contains exactly **two** active GitHub Actions workflows:

| Workflow | Trigger | Runs when |
|---|---|---|
| `macos-arm64-unit-tests.yml` | Push to `master`, pull request, or manual dispatch | Runs full 100% code coverage on macOS arm64 |
| `windows-amd64-unit-tests.yml` | Reusable `workflow_call` only | Called after the macOS coverage job succeeds |

Both platforms install their Perl dependencies, compile the native XS extension,
install Devel::Cover and execute the same full coverage command:

```shell
perl script/coverage-gate --jobs 10
```

The coverage gate schedules its instrumentable Perl tests under Devel::Cover
using ten TAP workers (`prove -j 10`). Tests requiring native threads are
run separately without unsupported instrumentation; they must still pass.
The gate rejects any total below **100.0%** in statement, branch, condition
or subroutine coverage and fails if instrumentation is unavailable.

On macOS the workflow uses an Apple Silicon runner and threaded Perl 5.44.
On Windows it uses the Windows x64 runner with checksum-verified portable
Strawberry Perl and the same mandatory four-metric gate. The Windows job
is a reusable workflow with `needs: macos-arm64` in the macOS caller.
A failed or cancelled macOS run prevents Windows from starting.

The gate retains serial scheduling for process-owning tests and the
source-sensitive coverage fixture pair, while other eligible tests
retain up to ten parallel workers.

Permissions remain read-only and GitHub Actions dependencies are pinned
to immutable commit identifiers. The macOS workflow owns concurrency
for the entire two-stage run.

## Retired workflows

- `unit-tests.yml` (superseded by macOS and Windows coverage)
- `test-coverage.yml` (coverage is now platform-specific)
- `coverage.yml`
- `dockerhub-image.yml`
- `platform-compatibility.yml`
- `release-github.yml`
- `test.yml`
- `codeql.yml`
- `package-ghcr.yml`
- `fuzz-js.yml`
