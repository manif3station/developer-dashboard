# What actually triggers each core CI workflow

`.github/workflows/` contains exactly three active workflows. Platform-aware
testing is intentionally consolidated into one workflow instead of split across
a Linux Test workflow, a JavaScript fuzz workflow, and separate analysis jobs.

## The active trigger set

| Workflow | push | pull_request | tags | schedule | workflow_dispatch |
|---|---|---|---|---|---|
| `platform-compatibility.yml` | `master` only | yes | no | no | no |
| `release-github.yml` | no branch push | no | `v*` | no | yes |
| `dockerhub-image.yml` | `master` only | no | no | no | yes |

`platform-compatibility.yml` is the single routine verification workflow. Its
matrix runs the complete Perl suite on Linux, macOS, and Windows. The Linux x64
leg additionally owns the all-metric coverage gate, dependency audits,
action-pin provenance audit, and JavaScript fast-check property tests.

`release-github.yml` is a publishing workflow, not a routine branch test. A
`v*` tag push builds and publishes the signed GitHub Release; manual dispatch is
the recovery path for an existing tag.

`dockerhub-image.yml` publishes the multi-architecture Docker Hub image from
`master` and also supports manual dispatch.

## Removed workflows

The following files are deliberately not part of the active Actions surface:

- `test.yml`
- `fuzz-js.yml`
- `codeql.yml`
- `package-ghcr.yml`

Their useful routine verification responsibilities were either consolidated into
Platform compatibility or intentionally retired. Re-adding one of these files
would create another GitHub Actions workflow and therefore violates the current
three-workflow contract.

## Keeping the description aligned

`t/227-skills-md-ci-triggers.t` reads the live workflow directory and each
workflow's real `on:` block. It asserts both the exact three-file set and the
trigger table above, so a workflow cannot be silently added, removed, or widened
without updating the repository contract in the same change.

When reviewing CI changes, read the YAML itself rather than reconstructing the
trigger set from historical Actions runs. Old runs remain visible in GitHub even
after their workflow file has been deleted.
