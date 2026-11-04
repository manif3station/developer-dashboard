# GitHub Actions workflow triggers

The repository intentionally has **one** active GitHub Actions workflow:
`.github/workflows/unit-tests.yml`.

| Workflow | Push | Pull request | Manual dispatch |
|---|---|---|---|
| `unit-tests.yml` | `master` only | yes | yes |

The workflow runs on Ubuntu, uses Perl 5.44 with threads, installs Perl
dependencies into an isolated `local/` directory, builds the project's XS
extension, then executes all `t/` unit tests with ten parallel workers:

```bash
prove -j 10 -Iblib/arch -Iblib/lib -lr t
```

The old coverage, platform-compatibility, release, and Docker Hub publishing
workflows were removed at the owner's request. There are no automated
publishing or coverage-verdict workflows.

## Retired workflows

- `coverage.yml`
- `dockerhub-image.yml`
- `platform-compatibility.yml`
- `release-github.yml`
- `test.yml`
- `codeql.yml`
- `package-ghcr.yml`
- `fuzz-js.yml`
