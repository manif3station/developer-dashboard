# GitHub Actions workflow triggers

The repository contains exactly **two** active GitHub Actions workflows:

| Workflow | Trigger | Runs when |
|---|---|---|
| `unit-tests.yml` | Push to `master`, pull request, or manual dispatch | The event occurs |
| `test-coverage.yml` | `workflow_run` after `Unit Tests` completes | Only when the Unit Tests run concluded `success` |

Both workflows run on Ubuntu with threaded Perl 5.44, install dependencies into
an isolated `local/` tree, and compile the native XS extension. Unit Tests runs:

```bash
prove -j 10 -Iblib/arch -Iblib/lib -lr t
```

The coverage workflow checks out the source SHA from the successful upstream
unit-test run and then executes:

```bash
perl script/coverage-gate --jobs 10
```

Both workflows retain `-j 10` while scheduling process-owning tests
(`t/05-cli-smoke.t`, `t/09-runtime-manager.t`) and the source-inventory
regression (`t/15-release-metadata.t`) sequentially, away from other workers.
All other eligible tests can use ten parallel workers. The coverage gate runs
instrumentable tests under Devel::Cover and separately runs native-thread
tests without unsupported instrumentation. The job fails unless all four covered
`lib/` metrics — statement, branch, condition and subroutine — are exactly
**100.0%**. Failed or cancelled upstream unit tests skip the coverage job.
Coverage does not run directly from a push or a pull request.

The former platform, Docker Hub and release-publishing workflows remain
removed at the owner's request.

## Retired workflows

- `coverage.yml` (replaced by dependent `test-coverage.yml`)
- `dockerhub-image.yml`
- `platform-compatibility.yml`
- `release-github.yml`
- `test.yml`
- `codeql.yml`
- `package-ghcr.yml`
- `fuzz-js.yml`
