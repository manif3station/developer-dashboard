# Scorecard Actions

## Purpose

This file is the working checklist for `SCORECARD-GATEKEEPER`.

Nothing is done until:

1. every repository-side Scorecard failure has been fixed
2. every GitHub-side setting that can be changed from the available token has been changed
3. the live Scorecard report has been rerun
4. any remaining non-`10 / 10` checks have a documented external blocker with evidence

## Required Command

On this machine the live command is:

```bash
bash -ic "scorecard --repo=github.com/manif3station/developer-dashboard"
```

## Live Baseline

Initial live result observed on `2026-04-08`:

- aggregate `2.8 / 10`
- `Binary-Artifacts` `10 / 10`
- `Dangerous-Workflow` `10 / 10`
- `Vulnerabilities` `10 / 10`

Remaining non-`10 / 10` checks at that point:

- `Branch-Protection` `0 / 10`
- `CI-Tests` `?`
- `CII-Best-Practices` `0 / 10`
- `Code-Review` `0 / 10`
- `Contributors` `0 / 10`
- `Dependency-Update-Tool` `0 / 10`
- `Fuzzing` `0 / 10`
- `License` `0 / 10`
- `Maintained` `0 / 10`
- `Packaging` `?`
- `Pinned-Dependencies` `0 / 10`
- `SAST` `0 / 10`
- `Security-Policy` `0 / 10`
- `Signed-Releases` `?`
- `Token-Permissions` `0 / 10`

Current repo-side remediation work after the first push:

- `Dependency-Update-Tool` improved to `10 / 10`
- `Packaging` improved to `10 / 10`
- `SAST` improved to `10 / 10`
- `Security-Policy` improved to `10 / 10`
- `License` improved to `9 / 10`
- `Pinned-Dependencies` improved to `8 / 10`
- `Token-Permissions` stayed at `0 / 10` until top-level workflow writes were removed
- `Fuzzing` stayed at `0 / 10` until a Scorecard-supported fuzzing marker was added
- `Signed-Releases` stayed inconclusive until a real GitHub release exists with attached release assets that Scorecard can inspect
- the JS fuzz workflow also needs the Perl runtime because it shells into `dashboard encode` / `dashboard decode`; without `cpanm --installdeps --notest .`, the first property case dies on `Capture::Tiny` before fuzzing actually starts

Current live result observed on `2026-05-08`:

- aggregate `7.0 / 10`
- `Binary-Artifacts` `10 / 10`
- `Dangerous-Workflow` `10 / 10`
- `Dependency-Update-Tool` `10 / 10`
- `Fuzzing` `10 / 10`
- `License` `10 / 10`
- `Packaging` `10 / 10`
- `SAST` `10 / 10`
- `Security-Policy` `10 / 10`
- `Token-Permissions` `10 / 10`
- `Vulnerabilities` `10 / 10`
- `Pinned-Dependencies` `8 / 10`
- `Branch-Protection` `0 / 10`
- `CII-Best-Practices` `0 / 10`
- `Code-Review` `0 / 10`
- `Contributors` `0 / 10`
- `Maintained` `0 / 10`
- `CI-Tests` `?` with reason `no pull request found`
- `Signed-Releases` `?` with reason `no releases found`

Current live result observed on `2026-06-11` after the `v4.14` push:

- `Pinned-Dependencies` improved to `10 / 10` with reason `all dependencies are pinned`
- `Signed-Releases` improved to `8 / 10` with reason `1 out of the last 1 releases have a total of 1 signed artifacts`
- `SAST` moved to `7 / 10` with reason `SAST tool detected but not run on all commits`;
  the gap is the `[skip ci]` automation commits in the merge history that CodeQL
  never analyzed, which is historical and not repo-fixable retroactively; the
  CodeQL workflow runs on every branch push now, including the `v4.14` master push
- `Dangerous-Workflow`, `Dependency-Update-Tool`, `Fuzzing`, `License`,
  `Packaging`, `Security-Policy`, `Token-Permissions`, `Vulnerabilities`
  all remain `10 / 10`
- `Branch-Protection`, `CII-Best-Practices`, `Code-Review`, `Contributors`,
  `Maintained` remain `0 / 10` for the externally blocked reasons documented
  below (token permissions, badge-program enrollment, solo-maintainer history,
  and the 90-day repo-age window measured from `2026-03-30`)

Current live result observed on `2026-10-08` after commit `851ee353` was pushed:

- aggregate `8.2 / 10`
- `Branch-Protection` `0 / 10`: branch protection is not enabled on `master`
- `CII-Best-Practices` `0 / 10`: no OpenSSF Best Practices badge was detected
- `Code-Review` `0 / 10`: Scorecard found `0/30 approved changesets`
- `Contributors` `3 / 10`: only one contributing organization was detected
- every other reported check is `10 / 10`, including `CI-Tests`,
  `Signed-Releases`, `Maintained`, `Pinned-Dependencies`, and `Vulnerabilities`

The remaining checks require GitHub administration, OpenSSF badge enrollment,
reviewed pull-request history, or contributions from additional organizations;
they cannot be repaired by this source change. Existing evidence below records
that this machine's available GitHub token cannot administer branch protection.
Do not fabricate review approvals or contributor identities. The operator must
choose whether to enable branch protection, enroll for the badge, and establish
a reviewed-PR workflow before Scorecard can reach 10/10 on these checks.

## Task Breakdown

### Repository-side fixes

- [x] add a tracked top-level `LICENSE` — Scorecard License is 10/10
- [x] add a tracked top-level `SECURITY.md` — Scorecard Security-Policy is 10/10
- [x] add `.github/dependabot.yml` — Scorecard Dependency-Update-Tool is 10/10
- [x] add a SAST workflow — Scorecard SAST is 10/10
- [x] add a fuzzing signal that Scorecard can detect — Scorecard Fuzzing is 10/10
- [x] reduce workflow token permissions to the minimum required — Token-Permissions is 10/10
- [x] pin every GitHub Action by full commit SHA — Pinned-Dependencies is 10/10
- [x] remove weak workflow bootstrap patterns where practical — Dangerous-Workflow is 10/10
- [x] add a packaging workflow Scorecard can detect — Packaging is 10/10
- [x] publish signed GitHub release artifacts — Signed-Releases is 10/10
- [x] add tests that lock these guardrails in place — repository security/Scorecard tests pass

### GitHub-side fixes that need API access or settings changes

- [ ] enable branch protection or a ruleset on `master`
- [ ] ensure pull-request review is required before merge
- [ ] ensure the latest Scorecard run has a PR-backed CI result — the 2026-10-08 run reports `?` / `no pull request found`; an earlier run had `10 / 10`
- [ ] create reviewed PR history that Scorecard can observe
- [x] create GitHub releases with attached artifacts and signatures — Signed-Releases is 10/10

### Checks that may remain externally blocked

- [ ] `Contributors`
  because Scorecard counts contributing organizations, not code quality
- [ ] `CII-Best-Practices`
  because it depends on the external OpenSSF Best Practices program state
- [ ] `Branch-Protection`
  if the available token still lacks `administration` permission
- [ ] `Code-Review`
  if no second reviewer or historical reviewed PR exists

## Evidence Notes

- GitHub API reported repo `created_at = 2026-03-30T22:39:05Z`
- GitHub branch-protection API returned:
  `Resource not accessible by personal access token`
- local repo inspection showed no tracked root `LICENSE`
- local repo inspection showed no tracked root `SECURITY.md`
- local repo inspection showed no `.github/dependabot.yml`
- local repo inspection showed no SAST workflow

## Operating Rule

If a check stays below `10 / 10`, rerun the loop:

1. diagnose the exact cause
2. fix what is actually fixable
3. test it
4. push it if Scorecard needs remote visibility
5. rerun Scorecard
6. update this file

## 2026-08-15 — Signed-Releases 8/10 is NOT repo-fixable, and here is why

Ran after the 4.27/4.28 releases: every check 10/10 except **Signed-Releases 8/10**,
reported as *"5 out of the last 5 releases have a total of 7 signed artifacts."*

**Diagnosed from the release assets rather than the score.** Scorecard reads the
last five *published* releases — which are v4.26, v4.25, v4.22, v4.21, v4.20,
because v4.23, v4.24 and v4.27 published nothing at all (see DD-553):

| release | .asc | .intoto.jsonl | .sigstore.json |
|---|---|---|---|
| v4.26 | yes | yes | yes |
| v4.25 | yes | yes | yes |
| v4.22 | yes | — | — |
| v4.21 | yes | — | — |
| v4.20 | yes | — | — |

Five signatures plus two provenance attestations is the "7 signed artifacts" in
the message. The three older releases predate the `provenance` job in
`release-github.yml`, which uses `actions/attest-build-provenance` and attaches
`.intoto.jsonl` and `.sigstore.json`.

**So there is nothing in the repository to fix.** The workflow already does the
right thing; the score is held down by history that cannot be rewritten, and it
rises on its own as newer releases roll out of the five-release window. This is
NOT a case for the fix → test → push → rerun loop.

**Two things to check before ever re-opening this:**

1. That the `provenance` job actually ran for the newest release. It `needs:
   release`, so a failed release job makes it **skip** — which is exactly what
   happened on v4.27, and a skipped step is not a passed one.
2. That the newest releases genuinely published. Four tags had no release at all
   when this was written, and an unpublished tag silently keeps an old release
   inside Scorecard's five-release window, holding the score down for longer than
   it should. `.claude/tools/release-published` reports that hourly now.

**Written down because it will otherwise be re-investigated.** An 8/10 on a
security check invites exactly that, and the answer — "wait for two more
releases" — is not one anybody guesses from the score.

## 2026-10-03 — Post-push Scorecard audit for Problems 25 and 36

Ran the required authenticated-shell command after pushing commit
`1808b6cc6d80859df0be91f35bb340996d7c0a41`:

```text
bash -ic "scorecard --repo=github.com/manif3station/developer-dashboard"
Aggregate score: 8.2 / 10
```

All reported checks scored `10 / 10` except:

| Check | Score | Live reason | Remaining action |
|---|---:|---|---|
| Branch-Protection | 0 | Branch protection is not enabled on development/release branches. | A repository administrator must enable a ruleset or branch protection. This shell has no GitHub CLI login (`gh auth status`: not logged in). |
| CII-Best-Practices | 0 | No OpenSSF Best Practices badge detected. | Project maintainers must enroll the project and meet the external badge criteria. |
| Code-Review | 0 | `Found 0/16 approved changesets`. | The project needs PR-based changes with recorded approvals; this cannot be manufactured by a direct push. |
| Contributors | 3 | One contributing organization, normalized to 3. | Requires contributions from additional organizations; repository code changes cannot produce this history. |

The Problems 25/36 implementation, tests, release metadata, Docker image, and
push are complete. The remaining scorecard findings are not code fixes. The
branch-protection setting additionally requires GitHub administrator access;
this environment currently has no `gh` API login. Re-run Scorecard after the
external actions above and keep this result open until every actionable check
reaches `10 / 10` or its external limitation is evidenced.

## 2026-10-04 — Post-push Scorecard audit for documentation and update hooks

Ran the required command after pushing `5b265409c8ffbd20cc36d17633d54f69a6d74da3`.
The remote `master` ref resolved to that commit before the Scorecard run.

```text
Aggregate score: 8.2 / 10
```

`CI-Tests` now reports `10 / 10` (`1 out of 1 merged PRs checked by a CI test`).
The remaining results below `10 / 10` are:

- `Branch-Protection`: `0 / 10` — branch protection is not enabled.
- `CII-Best-Practices`: `0 / 10` — no OpenSSF Best Practices badge is detected.
- `Code-Review`: `0 / 10` — `Found 0/17 approved changesets`.
- `Contributors`: `3 / 10` — Scorecard counts one contributing organization.

All other reported checks are `10 / 10`. This environment still has no GitHub
CLI API login, so repository settings cannot be changed here. Branch protection,
external badge enrollment, reviewed PR history, and additional organization
contributors remain external actions rather than code tasks.

## 2026-10-07 — Post-push Scorecard audit for Problem 40

Ran the required authenticated-shell command after pushing commit
`d4a9c987f058179db53b66cd73906e17c95d9214`:

```text
bash -ic "scorecard --repo=github.com/manif3station/developer-dashboard"
Aggregate score: 8.2 / 10
```

All reported checks except the following scored `10 / 10`:

| Check | Score | Current reason | Required action |
|---|---:|---|---|
| Branch-Protection | 0 / 10 | Protection is not enabled on development/release branches. | A GitHub repository administrator must configure a ruleset or branch protection. |
| CII-Best-Practices | 0 / 10 | No OpenSSF Best Practices badge is detected. | A maintainer must complete external OpenSSF enrollment and its criteria. |
| Code-Review | 0 / 10 | `Found 0/25 approved changesets`. | A non-author reviewer must approve PR-based changes; direct pushes cannot create review evidence. |
| Contributors | 3 / 10 | One contributing organization, normalized to 3. | Historical contributor makeup cannot be changed by a code patch. |

`bash -ic 'gh auth status'` reports that this environment is not logged into
GitHub, so it cannot change repository settings or complete external badge
enrollment. The outstanding items remain in the GitHub-side and external
blocker task lists above. No attempt was made to fabricate approvals or alter
historical contributor attribution.

## 2026-10-08 — Post-push Scorecard audit for documentation release commit

Ran the required authenticated-shell command after pushing commit
`fd7e460b53767c2c3ea3fbe0574cdf5e2373b9ff` to `master`:

```text
bash -ic "scorecard --repo=github.com/manif3station/developer-dashboard"
Aggregate score: 8.1 / 10
```

Every actionable repository-side check scored `10 / 10`. The remaining results
are not repairable by a source-only change:

| Check | Score | Live reason | Evidence / remaining owner action |
|---|---:|---|---|
| Branch-Protection | 0 / 10 | Protection is not enabled on development/release branches. | Existing GitHub API evidence records `403 Resource not accessible by personal access token`; a repository administrator must enable a ruleset. |
| CII-Best-Practices | 0 / 10 | No OpenSSF Best Practices badge was detected. | Enrollment and badge progress are controlled by the external OpenSSF service and project maintainers. |
| Code-Review | 0 / 10 | `Found 0/30 approved changesets`. | Direct pushes cannot create review approvals; future changes require reviewed PRs and a non-author reviewer. |
| Contributors | 3 / 10 | One contributing organization, normalized to 3. | The score reflects historical contributor makeup and requires genuine contributions from another organization. |
| CI-Tests | ? | No pull request found. | The latest direct push has no PR-associated CI evidence; Scorecard can only observe this through a real PR-backed CI run. |

All other reported checks scored `10 / 10`, including Dangerous-Workflow,
Dependency-Update-Tool, Fuzzing, Pinned-Dependencies, SAST, Signed-Releases,
Token-Permissions, and Vulnerabilities. No approvals, organizations, or badge
state were fabricated. Re-run Scorecard after the owner-controlled actions
above; this result is not a `10 / 10` report.
