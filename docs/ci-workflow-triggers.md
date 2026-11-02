# What actually triggers each core CI workflow

`.github/workflows/` contains exactly four active workflows. Platform-aware
testing stays consolidated in one matrix workflow, while coverage has its own
three-verdict workflow so test, POD, and Markdown coverage are visible
independently.

## The active trigger set

| Workflow | push | pull_request | tags | schedule | workflow_dispatch |
|---|---|---|---|---|---|
| `platform-compatibility.yml` | `master` only | yes | no | no | no |
| `coverage.yml` | `master` only | yes | no | no | no |
| `release-github.yml` | no branch push | no | `v*` | no | yes |
| `dockerhub-image.yml` | `master` only | no | no | no | yes |

`platform-compatibility.yml` runs the complete Perl suite on Linux x64/arm64,
macOS Intel/arm64, Windows x64, and Windows arm64. The Windows ARM64 host uses a
current supported x64 Strawberry Perl under Windows-on-ARM emulation because the
hosted image does not provide a native ARM64 Perl runtime. Linux x64 additionally
owns the dependency audits, action-pin provenance audit, and JavaScript
fast-check property tests.

`coverage.yml` has three independent jobs. Test coverage requires 100.0% for
statement, branch, condition, and subroutine coverage through
`script/coverage-gate`. POD coverage discovers the tracked Perl documentation
surface and requires every file to contain valid POD. Markdown coverage
discovers every tracked `.md` file and requires every file to pass the structural
Markdown checks. Any result below 100.0% fails its job.

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
Platform compatibility or moved into Coverage. Re-adding one of these files
would create another GitHub Actions workflow and violates the current
four-workflow contract.

## Keeping the description aligned

`t/227-skills-md-ci-triggers.t` reads the live workflow directory and each
workflow's real `on:` block. It asserts both the exact four-file set and the
trigger table above, so a workflow cannot be silently added, removed, or widened
without updating the repository contract in the same change.

When reviewing CI changes, read the YAML itself rather than reconstructing the
trigger set from historical Actions runs. Old runs remain visible in GitHub even
after their workflow file has been deleted.
