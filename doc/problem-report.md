# Problem Report

Problems are listed in numeric order. This file is the current status index;
`doc/problem-report.txt` retains the historical investigation and release log.
Statuses distinguish functional verification from release/commit delivery.

## Problems 1–11: Initial dashboard and skill runtime

### Problem 1: Forward saved bookmark URLs and merge request query parameters (2a09c53b) — done
Saved URLs redirect while preserving saved query keys, allowing request keys to override matching values and append new ones. Regression coverage: `t/03-web-app.t`, `t/104-skilldispatcher-coverage.t`, `t/131-bookmark-url-encoding.t`.

### Problem 2: Resolve skill-aware Template Toolkit includes (2a09c53b) — done
Skill pages can include local dashboard fragments and explicit skill dashboard paths. The include allow-list now covers the owning skill dashboard root. Regression coverage: `t/08-web-update-coverage.t`, `t/20-skill-web-routes.t`.

### Problem 3: Render supplied data in saved Ajax code templates (2a09c53b) — done
Ajax handler source is rendered with its supplied Template Toolkit data before it is stored and executed. Regression coverage: `t/12-legacy-helper-coverage.t`, `t/85-zipper-coverage.t`.

### Problem 4: Keep dashboard-owned init helpers private (f561a7e0) — done
Built-in staged helpers belong under `cli/dd`, separate from user `cli` files. Historical pre-fix and current Docker staging checks are recorded in the text audit; `t/30-dashboard-loader.t` covers the current behavior.

### Problem 5: Inherit nested skill CLI environment and runtime layers (2a09c53b) — done
Parent-to-leaf skill `.env`/`.env.pl` and DD-OOP runtime layers reach the nested command. Regression coverage: `t/19-skill-system.t`, `t/87-envloader-coverage.t`, `t/104-skilldispatcher-coverage.t`.

### Problem 6: Add the owning skill `lib/` to `@INC` (2a09c53b, bc516b29) — done
The active skill library is first in `@INC` for CLI and dashboard CODE execution. Regression coverage includes actual Docker CLI and dashboard requests: `t/20-skill-web-routes.t`, `t/76-web-dancerapp-coverage.t`, `t/104-skilldispatcher-coverage.t`.

### Problem 7: Complete `cli/__init__` by the bare skill name (2a09c53b; nested follow-up 5.36) — done
Completion exposes `foo`, not `foo.__init__`; nested initializers resolve deepest-first without shadowing explicit commands. Docker regression: `t/39-cli-suggest-complete-coverage.t`, `t/104-skilldispatcher-coverage.t`.

### Problem 8: Load invocation-directory env files outside home/project roots (2a09c53b) — done
`d2` loads the current directory `.env`/`.env.pl` independently of home/project ancestry. Pre-fix and current checks are recorded in the text audit; regression coverage: `t/06-env-overrides.t`, `t/87-envloader-coverage.t`, `t/79-perlenv-coverage.t`.

### Problem 9: Remove the confusing `d2 ticket` alias (2a09c53b) — done
`workspace` is the public command and `ticket` is no longer advertised as a competing command. Regression coverage: `t/39-cli-suggest-complete-coverage.t`, `t/69-cli-complete-coverage.t`, `t/91-cli-ticket-coverage.t`.

### Problem 10: Resolve arbitrarily nested skill CLI names (regression guard 2a09c53b) — behavior verified; supplied example inconsistent
An equivalent four-segment command resolves in Docker. The original example names `a.b.c.d` but omits the `c` skill directory; the discrepancy and audit are documented in `doc/problem-report.txt`.

### Problem 11: Let invocation cwd env override skill defaults (2a09c53b) — done
Environment precedence applies cwd values after inherited skill defaults. Regression coverage: `t/20-skill-web-routes.t`, `t/06-env-overrides.t`.

## Problems 12–19: Skill aliases, Docker, and dashboard behavior

### Problem 12: Resolve skill-qualified workspace aliases (7b0974e6; follow-ups 5.44, 5.47, and 5.48) — done in 5.48
Configured and Folder.pm aliases work at nested depths with `workspace -c`. The current follow-up maps dotted logical workspace refs such as `ch.docker` to tmux's underscore-normalized session name, verifies session ownership, and confirms duplicate-create races before reuse. Docker tests: `t/91-cli-ticket-coverage.t`; exact behavior is recorded in `doc/problem-report.txt`.

### Problem 13: Import DataHelper in saved-page CODE automatically (7b0974e6) — done
Dashboard CODE receives standard DataHelper imports without repeated declarations. Regression coverage: `t/76-web-dancerapp-coverage.t`, `t/99-pageruntime-coverage.t`.

### Problem 14: Load skill Dashboard extensions at web startup (7b0974e6; refined 874d8df6) — done
Skill `lib/Dashboard.pm` routes/settings load once at startup and run behind dashboard authorization. Regression coverage: `t/20-skill-web-routes.t`, `t/30-dashboard-loader.t`, `t/76-web-dancerapp-coverage.t`.

### Problem 15: Support opt-in Docker development Compose overlays (b5e7ac4a) — done
Base Compose files load consistently; development overlays require the marker and disable markers exclude a service. Regression coverage: `t/05-cli-smoke.t`, `t/10-extension-action-docker.t`, `t/94-dockercompose-coverage.t`.

### Problem 16: Merge Folder.pm aliases into path lookup and completion (11aaaa1f) — done
Skill Folder methods and `__list__` provide read-only aliases while config aliases remain writable and take precedence. Regression coverage: `t/90-cli-paths-coverage.t`, `t/97-pathregistry-coverage.t`, `t/205-skill-depth-alias.t`.

### Problem 17: Report present-but-empty skill dependency manifests accurately (6dcbfe35) — done
An existing empty manifest is not reported as missing. Regression coverage: `t/19-skill-system.t`, `t/102-skillmanager-coverage.t`.

### Problem 18: Inject bookmark HEAD content into the document head (6dcbfe35) — done
Bookmark `HEAD:` content is parsed, serialized, and rendered inside `<head>`. Regression coverage: `t/72-pagedocument-coverage.t`.

### Problem 19: Preserve skill Dancer hooks, variables, and startup loading (874d8df6) — done
Skill hook variables are visible in page/Ajax CODE, explicit response headers survive defaults, and Dashboard extensions load once at startup. Regression coverage: `t/20-skill-web-routes.t`, `t/30-dashboard-loader.t`, `t/76-web-dancerapp-coverage.t`.

## Problems 20–29: Coverage, runtime, and CLI

### Problem 20: Bring repository-wide Perl coverage to 100% — complete; verified 2026-10-03
The four-metric library coverage gate has reached 100.0% statement, branch, condition, and subroutine coverage. This problem is distinct from coverage work performed during other numbered cycles; current verification evidence is appended below.

### Problem 21: Discover both runtime roots together (23981132) — done in 5.25; reverified in 5.30
`.d2` and `.developer-dashboard` participate independently at each active layer with documented lookup/write precedence. Docker regression: `t/25-d2-alias.t`.

### Problem 22: Keep `ddfile.local` dependencies private to their owning skill (23981132) — done in 5.25; reverified in 5.30
Local dependencies install under the owner skill's `skills/` tree with traversal/symlink protections. Docker regression: `t/102-skillmanager-coverage.t`.

### Problem 23: Remove PAX from Developer Dashboard (bb14a6fe) — done in 5.29; reverified in 5.30
The compiler/cache/helper and PAX-specific release path were removed; standard commands and archive contents were checked. Docker regression: `t/264-pax-removal-contract.t`.

### Problem 24: Require patched Pod::Text for CLI help rendering — done in 5.34
The declared dependency floor prevents clean installs from selecting the vulnerable Pod::Text release. CI advisory and blank-container package evidence are recorded in `doc/problem-report.txt`; regression coverage: `t/108`, `t/181-podlators-security-floor.t`.

### Problem 25: Keep Dashboard help on internal CLIs and preserve external CLI help — done in 5.53
Help metadata and completion include nested actions/options; delegated grep, Docker Compose, and dotted skill-command help pass through to their owning CLIs. The private `skills _exec` dispatch sentinel is not treated as a public help action. Focused Docker regressions passed, including native `--help`, `-h`, and `help` pass-through. The full D2 suite passed 258 files / 22,403 tests. The 5.53 blank-environment integration run passed with plain `cpanm` test execution. The 5.53 image was built and checked with both `d2 version` and `Developer::Dashboard::VERSION` reporting 5.53. The configured base image initially exceeded the overlay mount-option limit; a disposable flattened base allowed the required Compose build. The base also carried an older module at an unversioned path, so the disposable image build removed only that stale module copy before installing the 5.53 archive. No repository Dockerfile change was retained. Commit `1dc5c062` had narrowed `.gitignore` to `.claude/`; the required `nytprof.out`, `nytprof/`, `.worktrees/`, and `dogfood-output/` patterns have been restored alongside it, and the release metadata gate passes. Tests include `t/265-cli-help-completion-contract.t` and `t/266-cli-help-dispatch.t`.

### Problem 26: Preserve full branch labels in `ps1` across all shells — done in 5.37/5.38
Branch names retain slashes; `origin/` is removed only when an equivalent local branch exists. Full evidence is in the historical report.

### Problem 27: Restore `of` content grep and complete Perl `@INC` lookup (78d6573d; package follow-up) — done
`d2 of grep` searches content safely via argv and module lookup traverses every `@INC` root. Focused tests cover matches, errors, print mode, editor dispatch, and multiple roots.

### Problem 28: Resolve collector working-directory path aliases (78d6573d) — done
Collector `cwd` accepts config aliases and skill Folder.pm aliases, with config-first precedence. Regression coverage: `t/103-collectorrunner-coverage.t`.

### Problem 29: Determine whether stopping a collector stops its child processes — investigation pending
The requested Docker reproduction and verified stop-propagation result are missing from the tracked report. Do not infer process-tree behavior from dispatcher shutdown; complete an isolated container investigation before marking done.

## Problems 30–39: Collector, marker, completion, and Compose behavior

### Problem 30: Repair config.json collector cron scheduling — done in 5.44
Five-field cron expressions support names, lists, ranges, steps, crontab day matching, and per-minute deduplication; missing/invalid schedules fail visibly. Regression coverage: `t/103-collectorrunner-coverage.t`.

### Problem 31: Honor Docker service markers at every layer — done in 5.44/5.45
Markers are discovered and removed across active service layers; newly written markers use the selected home runtime. Regression coverage: `t/10-extension-action-docker.t`, `t/361-dockercompose-coverage.t`.

### Problem 32: Separate command/path completion and make cdr completion responsive — done in 5.48
Root command completion no longer mixes path aliases; `workspace` completion includes configured and Folder.pm aliases. `cdr` completion lists direct children and narrows one directory level per entered term. Docker regressions: `t/69-cli-complete-coverage.t`, `t/90-cli-paths-coverage.t`; measured fixture returned 40 candidates in 0.131 seconds.

### Problem 33: Keep an unregistered first `cdr` word as a search pattern — done in 5.48 (existing behavior regression-guarded)
If the first `cdr` word is not a registered alias, it remains a search term and participates in later TAB narrowing. Current implementation already preserves it; new targeted assertions in `t/90-cli-paths-coverage.t` verify resolution and `t/69-cli-complete-coverage.t` covers completion behavior. No production code change was needed for this report item.

### Problem 34: Limit automatic Compose services to the local Compose project — implementation done in 5.48/5.54/5.55; runtime verified
When cwd contains a supported Compose file, it is the base and only runtime services declared by that file are automatically merged. Explicit service selection remains possible, and runtime discovery is unchanged when no local base exists. Follow-up: operational commands previously lost the invocation project directory after merging layers into a temporary file. The final command now retains that directory, and explicit `--project-directory` remains authoritative. A further audit found the public helper called `resolve()` and directly executed the unresolved `-f` stack, bypassing the materialization logic entirely; the earlier `run()` tests therefore did not cover the real CLI path. The helper now routes non-dry-run operations through a streaming materializing runner, which holds the merged file until Compose exits. Regression tests cover the actual helper dispatch and `up`, `build`, and `down` execution, including merged-file availability during execution. An isolated real Compose project and the 5.54 release evidence are recorded in `doc/problem-report.txt`; this 5.55 follow-up was verified with Docker Compose stubs in the isolated dev container because that container does not include the Docker CLI. The ignored local Dockerfile/version caveat from the 5.54 image build remains recorded in the historical evidence below.

### Problem 35: Configure a real Dist::Zilla releaser for `dzil release` — done in 5.50
`dist.ini` now configures `Dist::Zilla::Plugin::UploadToCPAN`, so an explicit `dzil release` has a real PAUSE upload action. The release-metadata test failed before the stanza and passes after it; `dzil authordeps` lists the plugin, Dist::Zilla resolves it as a `-Releaser`, and `dzil build` succeeds and produces `Developer-Dashboard-5.50.tar.gz`. The matching Docker image built successfully and reports version 5.50. A fresh blank Docker environment installed the tarball with `cpanm` (without `--notest`) and completed its full integration script. The release command was not run, so no package was uploaded.

### Problem 36: Merge project and home skill commands in shell completion — done in 5.53
When a project and home runtime both contain a skill with the same name, `d2 <skill>.<TAB>` includes commands from both layers, with shared command names listed once. The isolated Docker regression `t/804-skill-completion-layer-merge.t` failed before the fix because completion resolved each discovered skill name back to only the winning project root; it now enumerates all participating skill roots. The full D2 suite passed 258 files / 22,403 tests, including the layered-skill completion regression. Earlier 5.52 all-metric coverage passed 258 files / 22,897 tests with 100.0% statement, branch, condition, and subroutine coverage (45,356 detail rows). Version 5.53 is built, the blank-environment integration run passed, and the runtime image reports 5.53.

### Problem 37: Avoid false watchdog restarts during cron quiet hours — implementation and package verification complete in 5.56
Reproduction: with a cron collector configured as `0 7-8 * * *`, seed its last completed execution as old while the scheduler loop remains live with a fresh heartbeat, and set its watchdog restart count to the threshold. Before the fix, the watchdog stopped the healthy loop, incremented the count, and raised `attention_required` with “stopped unexpectedly too many times within 300 seconds.” The warning was triggered because the watchdog interpreted expected time between cron runs as stalled execution. Cron collectors now use scheduler heartbeat age for stall checks; interval collectors continue using last execution progress. Focused Docker tests passed (2 files / 1,005 assertions); the instrumented full suite passed (258 files / 22,497 tests) with 100.0% statement, branch, condition, and subroutine coverage. Required security web tests passed (3 files / 459 tests). `dzil build`, `d2 docker.images.build`, and blank-environment `cpanm` integration all passed. The image's existing `/root/perl5` 5.54 module shadows its newly installed 5.56 system-library module, so the running-image version probe remains a documented environment caveat, not a Problem 37 code fix. See the detailed chronology in `doc/problem-report.txt`.

## Cross-problem verification note (2026-10-03)

Problems 12, 32, 33, and 34 were verified in the isolated `dd-problem32` Compose
development container. Focused regressions passed: 3 files / 359 assertions
(`t/90`, `t/91`, `t/94`); `t/69` passed 71 assertions after adding the missing
defensive-branch case; `t/590` passed 17 assertions after its mocked resolver
was updated to return production `compose_root`. The final 5.48 instrumented
suite passed 257 files / 22,372 tests. The four-metric gate exited successfully
with 100.0% statement, branch, condition, and subroutine coverage (45,335
detail rows; no stale annotations). Devel::Cover printed warnings for
temporary skill fixture sources removed during tests; the gate returned
success, but the run is not described as warning-free.

Problem 12's duplicate tmux-session reproduction and all four problems' final
Docker checks are captured in the detailed chronological audit in
`doc/problem-report.txt`. Functional and coverage verification are complete.
`dzil build` produced `Developer-Dashboard-5.48.tar.gz`; the matching Docker
image built and reported `d2 version` 5.48. The blank-environment integration
container installed that tarball with `cpanm` (without `--notest`) and completed
its full integration script successfully. The 5.49 documentation refresh
changed only release metadata and report content. Its full Docker coverage rerun
passed 257 files / 22,732 tests and the four-metric gate at 100.0% across all
metrics (45,335 detail rows, no stale annotations); temporary fixture digest
warnings remain visible. `dzil build` produced `Developer-Dashboard-5.49.tar.gz`;
`d2 docker.images.build` completed and a fresh image returned `d2 version` 5.49.
The blank-environment Compose run installed that archive with `cpanm` (without
`--notest`) and the full integration script passed. The release gates and
problem fixes are committed; no push was performed.

### Problem 38: Normalize merged Docker Compose YAML encoding — done (5.63)
Expected: every Docker Compose operation first materializes the effective base and overlays with `docker compose config`, then runs the requested verb against that merged file. Re-audit found a second root cause after the earlier fixes: `resolve()` parsed each local base with `YAML::XS::LoadFile` before materialization, so an isolated Windows-1252 byte in source `compose.yaml` failed with `invalid leading UTF-8 octet` before Compose could produce its merged config. A red-first Docker regression writes a raw `0xA3` into a local base, reproduces that failure before any Compose invocation, then verifies the fix uses a normalized in-memory copy for service discovery, leaves the source file untouched, runs `config` first, and passes a valid UTF-8 merged file to the requested operation. The zero-explicit-file operation-order case and all config/up/down/build/ps/logs materialization paths remain covered; non-Compose commands stay direct. Docker coverage passed 258 files / 22,550 tests with statement, branch, condition, and subroutine metrics all 100.0% (45,519 detail rows, no stale uncoverable annotations). The focused release/Compose tests passed 5,965 assertions and the focused web security trio passed 459. `dzil build`, image build/version verification, and blank-environment `cpanm` installation without `--notest` plus its full integration script passed. The coverage image lacked optional browser/QEMU/kwalitee tools and `cpan-audit`; those checks were skipped by the gate. Devel::Cover emitted visible warnings for temporary fixtures removed before report digestion. Final release metadata is 5.63 because the image build guard rejects reusing 5.62; the original `/tmp/here.yml` was not read or used as a fixture.
### Problem 39: Numbering gap — no problem description recorded (status: unassigned)
The supplied problem sequence and repository records contain Problem 38 followed by Problem 40, with no Problem 39 description, capture, expected outcome, or implementation request found. This entry records the gap without inventing a bug or claiming a fix. If Problem 39 was assigned elsewhere, its source report is needed before this slot can be classified further.

## Problems 40–44: Compose and runtime environment behavior

### Problem 40: Resolve the base Compose service list before loading service overlays — done (5.65)

Expected: for every real Compose operation, run `docker compose config` first
using the local base and configured non-service layers. Parse that resolved
output's `services` map, then search active home, project, and nested-skill
Docker config roots for only those service names. Apply disabled and
development markers before materializing the selected overlays and executing
the requested operation. Explicit `--project-directory` and user `-f` inputs
must be preserved without relying on a calculated argv offset.

Root cause: execution previously called `resolve()` before Compose, where
service files were selected from raw local YAML and names inferred from command
arguments. `_materialized_command` then sliced the composed argv using
`2 + 2 * number_of_files`, assuming every generated `-f` pair was a contiguous
prefix. The initial config therefore contained overlays for services that had
not been established by Compose, and option/file arguments made the positional
slice fragile.

Reproduction: in an isolated Docker dev container, create a base compose file
with `source_only` and `blocked`, a configured non-service overlay defining
`present`, home and nested-skill `present/compose.yml` files, a `blocked`
service folder with `disabled.yml`, and a `present/develop.yml` marker with
development overlays. Invoke the resolver with an explicit project directory,
an extra `-f` file, and `build ghost`; make the Compose stub's first `config`
output list `present` and `blocked`. Before the fix, the red assertions showed
only two calls, the first call already contained both `ghost` and `present`
service folders, and there was no later config call selecting overlays from
the first output. The test also forced the raw YAML service parser to die,
proving that execution must not consult it before Compose.

A follow-up red test covered projects without a conventional Compose filename
where the only base is supplied through `-f`. Before the correction, the first
config call preloaded runtime service folders and omitted the selected skill
environment; two assertions failed. `resolve()` now parses leading Compose
options to detect explicit `-f`/`--file` inputs and defers service lookup for
that case too. The fixture then passed with only the explicit base in the first
call, matching overlays in the later config, and service environment applied
only after Compose returned its base service map.

Fix and verification: execution now defers service discovery. It explicitly
constructs a base-config argv, parses the resolved service map, gathers only
matching service files with existing layered marker logic, and materializes
the final config only when service overlays were found. Compose-returned names
must be valid single path segments; empty names, `.`/`..`, and path separators
are rejected before runtime lookup. Argument parsing separates global
options, explicit base files, project directory, and the requested operation
instead of slicing `@full`. The six changed focused regressions (`t/05`,
`t/10`, `t/11`, `t/30`, `t/94`, and `t/266`) first passed 2,105 assertions;
after the 5.64 metadata update, all seven focused files including
`t/15-release-metadata.t` passed 7,540 tests. The resolver file independently
passed 305 assertions, including the explicit-file-only base case. The fresh
full Docker coverage gate passed 258 files / 22,609 tests with 100.0%
statement, branch, condition, and subroutine coverage (45,787 detail rows; no
stale uncoverable annotations). The required focused
web-security trio passed 459 tests. The 5.65 tarball passed CPANTS kwalitee
at 100% (7/7 assertions) and the source POD gate (348 files, 355 assertions).
`dzil build` produced `Developer-Dashboard-5.65.tar.gz`; the image build
succeeded and a one-off Compose run reported `dashboard version` as `5.65`.
The blank-environment container installed the tarball using `cpanm` without
`--notest`, then its complete installed-runtime integration script passed.
`perlsec` was reviewed from the container's `perlsec.pod` with `pod2text`
because the image's `perldoc` has no formatter.
Required security searches found no Problem 40 shell-string execution or
production use of a forbidden library; broad search hits were existing audit
expressions and test fixtures. Devel::Cover warnings for temporary generated
fixture files removed during tests remain visible in its report output, while
the coverage gate exits successfully and reports all four metrics at 100.0%.

### Problem 41: Remove Docker from built-in indicators — done (5.67)

Expected: core indicator refresh works on systems without Docker and does not
probe for the `docker` executable or create a Docker indicator. A Docker status
indicator remains supported when the user explicitly defines a Docker
collector. Legacy persisted core Docker records should be removed without
deleting customized or collector-owned records with the same name.

Root cause: `refresh_core_indicators()` in
`Developer::Dashboard::IndicatorStore` called `command_in_path('docker')` and
persisted a `docker` indicator at priority 20. The configured collector in the
operator's home config uses the same name, so both behaviors converged on one
record and made Docker appear first in the prompt.

Reproduction: run `d2 ps1` in a shell without tmux indicator suppression, or
unset `TMUX`, `WORKSPACE_REF`, `TICKET_REF`, and
`DEVELOPER_DASHBOARD_TMUX_STATUS` for the command. Before the change, core
refresh probes for Docker and creates a whale status even with no configured
Docker collector. The focused Docker test reproduced the old behavior by
replacing the executable probe with a fatal test stub; the first red run exited
early at that probe. A second fixture seeds the exact old core record and
checks that core refresh removes it while preserving a collector-managed
`docker` record.

Implementation removes the executable probe and built-in status write. Core
refresh recognizes and removes only the former exact built-in record signature;
customized and collector-managed Docker indicators remain intact. The focused
Docker regressions pass after the change.

Safety regression: three red assertions exposed missing writer-lock protection
and invisible lock failures in cleanup. Cleanup now acquires the same lock as
status writers before reading ownership. Rerunning both focused test files in
Docker passed 1,042 assertions, including layered/custom collector preservation
and visible filesystem failures.

Container setup correction: the first full run hit Git's dubious-ownership
guard for the bind-mounted `/work` checkout, failing four tracked-document
assertions. A disposable Compose test definition adds `/work` to Git's
safe-directory list inside the test container only. The affected integration
asset tests and indicator tests then passed 491 assertions; the full gate was
restarted with that same isolated setup. Host Git settings were not changed.
The release-metadata gate then caught a stale main-POD version and a disallowed
word in the new testing guidance. Both were corrected; README was regenerated
from POD. Release metadata, integration assets, and indicator regressions passed
5,913 assertions before the next full run.

Security applicability review (ASVS V1–V14): V1/V11 preserve the opt-in
indicator contract; V5 uses a fixed name and presentation signature, not
user-supplied command or path text; V7 reports lock/open/remove errors;
V8/V12 preserve configured records and serialize filesystem cleanup; V14
removes an unwanted default without changing configuration. V2/V3/V4,
V6/V9/V10/V13 introduce no authentication, session, authorization,
cryptography, communication, executable-code, or API changes. Top 10 review:
A04/A05/A08/A09 apply to safe defaults, data ownership, concurrent writes,
and visible failures; A01/A02/A03/A06/A07/A10 have no new access-control,
crypto, injection, dependency, authentication, or outbound-request surface.
Required source searches found only existing audit expressions, documentation,
and synthetic test fixtures for prohibited/sensitive patterns; no new raw SQL,
shell execution, dependency, or credential data was added.

Verification: the complete Docker suite passed 258 files / 22,645 tests and
the library report reached 100.0% statement, branch, condition, and subroutine
coverage (45,841 detail rows, no stale uncoverable annotations). Devel::Cover
also printed missing-digest diagnostics for temporary test-generated helpers
that had already been removed; the canonical gate exited 0 and confirmed the
complete library metrics. The focused security/web trio passed 459 assertions;
the release kwalitee, source POD, and release-metadata gates passed 5,783
assertions, including 100% kwalitee. The final 5.67 archive contains no
`cover_db`. The blank Docker environment installed the same 5.67 release code
with `cpanm` and its normal test execution (no `--notest`); the complete
installed-runtime integration runner reported success. The installed Perl
`perlsec` documentation was reviewed after the gate. No new command execution,
dependency, SQL, endpoint, credential, or authentication surface was
introduced.

### Problem 42: Let skill environment values override home defaults (done in 5.68)

Expected: when a skill command runs, matching values from that skill's `.env`
or `.env.pl` override home runtime values from `~/.d2` or
`~/.developer-dashboard`. A deeper project runtime layer continues to override
both. Non-skill commands keep their current runtime-layer behavior.

Root cause: `SkillDispatcher` loaded skill and skill-CLI files, then called
`load_runtime_layers()` over the entire chain. That reapplied home `.env` files
after the skill and replaced the skill's value. The capture's exact outcome
was `(FOO) ...=HOME` and `(BAR) ...=HOME`, despite each skill having its own
different value; without the home file, both skills printed their own value.

Reproduction: in an isolated Docker dev container, create `foo/.env` with
`SKILL_WILL_OVERWRITE_THIS=I am foo`, `bar/.env` with
`SKILL_WILL_OVERWRITE_THIS=I am bar`, and
`~/.developer-dashboard/.env` with
`SKILL_WILL_OVERWRITE_THIS=HOME`. Run `d2 foo.bash -c` with a command that
prints `$SKILL_WILL_OVERWRITE_THIS`, then repeat for `bar.bash`. Before the
fix both print `HOME`; after the fix they print `I am foo` and `I am bar`.
Remove the home `.env` and rerun to verify the skill-specific values remain.
Also seed the same key in a deeper project runtime `.env` and verify that
project value remains the final override.

Red/green evidence: a regression was added to `t/19-skill-system.t` before
implementation. In Docker, it failed with actual `home-runtime` versus
expected `skill`. After the change, the focused skill and EnvLoader tests pass,
including both home runtime directory names, the skill override, and deeper
project precedence.

Verification: the complete Docker suite passed 258 files / 22,656 tests. The
coverage gate passed at 100.0% statement, branch, condition, and subroutine
coverage (45,874 detail rows; no stale uncoverable annotations). The required
web/security trio passed 459 tests. The gate emitted Devel::Cover missing-
digest diagnostics for temporary fixture helpers removed by their tests; some
existing negative-fixture tests also print expected shell/archive diagnostics.
These are visible and are not described as a warning-free run. `dzil build`
produced the sole archive `Developer-Dashboard-5.68.tar.gz`, with no `cover_db`
entry. CPANTS kwalitee passed 7/7 checks at 100%; POD syntax passed 348 source
files / 355 assertions. The blank Perl 5.44 container installed the archive via
`cpanm` without `--notest`, ran the distribution test suite, and completed its
installed-runtime integration script successfully. `d2 docker.images.build`
completed, and an isolated run of the built `d2` image reported version 5.68.

### Problem 43: Keep Docker Compose skill env scoped to the selected service (done in 5.71)

Expected: when two installed skills each contribute a Docker Compose service
and define the same variable in their skill `.env`, `d2 docker compose up
<service>` interpolates using that service's own skill value. Running `foo`
must not cause a later `bar` command to inherit `foo`'s value. An operation
without a selected service continues to use the environment from all effective
base services. Caller-exported values remain higher priority under Problem 44.

Reproduction from `/tmp/capture-1476.txt`: create `foo/.env` with
`SKILL_WILL_OVERWRITE_THIS=I am foo` and `bar/.env` with
`SKILL_WILL_OVERWRITE_THIS=I am bar`; add matching `config/docker/foo/compose.yml`
and `config/docker/bar/compose.yml` services whose `message` uses
`${SKILL_WILL_OVERWRITE_THIS:-UNDEFINED}`. Run `d2 docker compose up foo`,
remove the home `.env`, and run `d2 docker compose up bar`. Before the fix,
the second container printed `I am foo` although `bar/.env` contained
`I am bar`.

Root cause: `_materialized_command()` replaced the initially requested service
list with every service returned by the base Compose config, then loaded all
of their skill env files into Compose's single global interpolation
environment. With colliding keys, the last enumerated skill won. The red-first
Docker test in `t/94-dockercompose-coverage.t` reproduced this sequence: the
bar materialization and operation both received `I am foo`. The fix preserves
the original selection, intersects it with effective base services, and uses
only those service skill layers for interpolation. Deferred local-base
requests infer selected services from parsed operation arguments; requests
with no matching service retain the established all-base-services behavior.
Compose file gathering and dependency overlays are unchanged.

The focused Docker regression passes 317 assertions, including selected
service isolation, deferred selection, no-service fallback, and the exact
sequential foo/bar case. The full Docker suite passed 258 files / 23,044
tests. The isolated four-metric coverage gate passed with statement, branch,
condition, and subroutine coverage all at 100.0% (46,002 detail rows; no stale
uncoverable annotations). The required web/security trio passed 459 tests.
The gate output includes existing Devel::Cover diagnostics for temporary
fixtures removed by tests and expected output from negative archive fixtures;
the full suite and coverage gate both exited successfully. Security review:
ASVS V1/V11 cover service-scoped interpolation and the tested selection rules;
V5/V12/V14 cover validated service identifiers, service-specific environment
file discovery, and precedence; V7 preserves visible failures. V2/V3/V4/V6/V9/V13
are untouched (authentication, sessions, authorization, cryptography,
transport, and web APIs). V8 has no new secret persistence or logging path.
V10 command construction is unchanged and continues to pass Compose arguments
as an argv list, not through a shell. OWASP Top 10 A03, A04, A05, A08, and A09
were considered; no new injection, authorization, deployment-security,
integrity, or logging surface was added. Perl's `perlsec` documentation was
reviewed in the D2 container. Required source scans found no new production
forbidden-library, credential, SQL, redirect, traversal, or security-header
issue; broad matches were in test fixtures and documented scan commands. The
focused web/security trio passed 459 tests.

`dzil clean` preceded the 5.71 bump. `dzil build` produced only
`Developer-Dashboard-5.71.tar.gz`, with no `cover_db` content. The release
metadata gate passed 5,428 assertions, and CPANTS kwalitee passed all 7
indicators (100%). The exact archive installed in a blank Perl 5.44 container
with plain `cpanm` (no `--notest`), ran the packaged distribution tests, and
reported `Successfully installed Developer-Dashboard-5.71` / `121
distributions installed`. `d2 docker.images.build` succeeded, and an isolated
run of the built image reported version 5.71. The optional t/44 post-build
guard skipped because the dev container has no nested Docker CLI; the direct
blank-container install-and-test flow above completed successfully instead.
No source file under `OLD_CODE` was modified.

### Problem 44: Preserve explicit command-line environment overrides (done in 5.70)

When a caller runs `NAME=value d2 <skill>.<command>`, the command must see
`value`, even when home or skill `.env`/`.env.pl` files define `NAME`. File
values still fill unset variables, and skill files continue to override home
defaults for variables the caller did not export. Regression coverage:
`t/30-dashboard-loader.t`, `t/87-envloader-coverage.t`.
The EnvLoader regression first failed in Docker (`got from-file`, expected
`from-caller`). The implementation captures caller-provided environment key
names at the public switchboard, carries them through helper handoff, and
restores caller values after both runtime and direct skill-file loading. Files
still populate unset keys, skill files still override home defaults where the
caller did not export a value, and env-audit provenance is removed for
caller-owned winning values. Loader errors remain visible after restoring the
caller environment.

The full Docker suite passed 258 files / 22,690 tests with 100.0% statement,
branch, condition, and subroutine coverage (45,961 detail rows; no stale
uncoverable annotations). The required web/security trio passed 459 tests.
Devel::Cover reported temporary fixture files removed by tests; negative
fixtures also print expected shell/archive diagnostics, so the run is not
described as warning-free. Security review found no new forbidden library,
secret, raw SQL path, or missing security-header issue; the environment
handoff adds no shell evaluation or path interpretation. README and main POD
are synced. CPANTS kwalitee passed 7/7 indicators (100%), and POD syntax passed
all 348 discovered source files. `dzil build` produced the sole archive
`Developer-Dashboard-5.70.tar.gz`, which contains no `cover_db`. The blank
Perl 5.44 Compose container installed that archive with `cpanm` without
`--notest`, ran the distribution test suite, and passed the installed-runtime
integration flow. Headless Chromium printed expected missing-D-Bus diagnostics
and the browser probe logged an expected non-2xx response while checking the
unauthenticated route; the integration assertions passed. `d2 docker.images.build`
completed, and an isolated Compose run of that image
reported `d2 version` 5.70. The image-build guard had already recorded 5.69
as used, so the finalized report and repeat artifact checks were assigned this
distinct version. No release upload was performed.

### Problem 45: Add Docker-style timestamps, follow, and tail to dashboard logs (done in 5.77)

Expected: `d2 logs` supports Docker-style `-t`, `-f`, `--tail N`, and
`--tail=N` across the default mixed web/collector view, web-only output, all
collector logs, and a named collector. Flags combine: tail limits the initial
snapshot and follow continues with appended entries. `-n N` remains a
compatible tail alias; zero prints no initial lines, and malformed or
negative counts fail with usage text. Collector lines use their persisted run
timestamp. Raw web log lines have no historical per-line timestamp, so `-t`
uses the time the command reads those lines.

Reproduction: seed isolated web and collector logs, then run
`d2 logs -t --tail=2`, `d2 logs -f --tail 2`, `d2 logs web -t -f`,
`d2 logs collector -t -f`, and `d2 logs collector NAME -t -f`. Before the
timestamp change, `-t` was rejected for every scope. Before the follow change,
`-f` was rejected for collector and mixed scopes. The original Problem 45
regression also showed `--tail=2` returning the full combined output instead
of its final two lines.

Root cause: the runtime-control parser had no timestamp flag, and web follow
delegated to a blocking reader that prevented the CLI from polling collector
logs. Collector output was rendered from completed persisted records instead
of being watched as an append-only source.

Root-cause fix: the shared runtime-control parser accepts `-t`, `-f`,
`--tail N`, and `--tail=N` (retaining `-n N`). It timestamps collector output
from persisted run records and uses UTC read time for raw web records, whose
file format has no historical per-line timestamp. Tail is applied to the
selected output after source composition and timestamp formatting. Follow
polls each source independently, emits only appended bytes, and restarts from
the beginning when a log is truncated. `dashboard serve logs` delegates to
the same parser, so its options and validation stay aligned. The shared help
catalog, option completion metadata, README, POD, and integration plan are
updated.

Docker verification: the focused runtime-control test passes 141 assertions,
and the full instrumented Docker suite passes 258 files / 23,151 tests. The
four-metric gate reports 100.0% statement, branch, condition, and subroutine
coverage (46,174 detail rows; no stale uncoverable annotations). The focused
help-dispatch test passes 469 assertions; release metadata passes 5,427 tests;
POD syntax passes 348 files; and the required web-security trio passes 459
tests. The 5.77 image reports `d2 version` 5.77 and `d2 logs --help` lists
`-t`, `-f`, `--tail N`, and `--tail=N`. Plain `cpanm` (without `--notest`)
installed the archive in a blank Perl 5.44 container, passed the distribution
tests, and completed installed-runtime integration. `dzil clean`,
`dzil build`, and `d2 docker.images.build` succeeded for 5.76; the archive
contains no `cover_db`. The isolated integration Compose project was removed
after the run. The 5.76 feature build's tarball installation and integration
also passed; 5.77 only finalizes release metadata and these archived results.

Security review (ASVS 5.0 applicability): V1, V2, V3, V4, V6, V8, V9, V10,
V11, V13, and V14 have no changed controls for this local CLI log reader. V5
is relevant to strict option/count parsing and registered collector-name
validation; V7 to visible read/follow errors and timestamped output; V12 to
reading only the existing FileRegistry/Collector log sources. No command
execution, write path, route, authentication behavior, dependency, or secret
handling changed. The OWASP Top 10 cross-check found no new A01/A02/A06/A07/A10
surface; A03 input handling, A04 follow/tail behavior, A05 CLI defaults, A08
packaging integrity, and A09 log visibility were reviewed and regression
tested. Required forbidden-library, sensitive-pattern, header, auth/session,
SQL, redirect, path, and process-execution scans produced no new production
finding. `perldoc perlsec` was reviewed for untrusted arguments, command
execution, and file access; no shell or user-selected path is introduced.

Problem numbering note: Problem 44 is already used for environment precedence
in the repository report, so this log issue remains Problem 45 rather than
overwriting that completed entry. The verified change was committed and pushed;
post-push Scorecard reported an 8.1/10 aggregate with remaining external project
settings, approval history, contributor makeup, and badge enrollment items.

### Problem 46: Start path-alias workspaces inside Docker (container config and safe-reuse fixes 2026-10-10)

Expected: `d2 workspace -c <alias> --docker` (or `-d`) resolves the registered
path alias and changes to its directory. If the Compose `workspace` service is
already running, reuse it without rebuilding or replacing its container. If it
is stopped, run `d2 docker compose up -d --build workspace` with Docker's normal
build cache enabled. Only after the service is running should the command run
`d2 docker compose exec -e
DEVELOPER_DASHBOARD_CONFIG_OVERLAY=/dev/shm/developer-dashboard-workspace-config
workspace d2 path add <alias> /workspace` and then the same `exec -e
DEVELOPER_DASHBOARD_CONFIG_OVERLAY=/dev/shm/developer-dashboard-workspace-config
workspace d2 workspace <alias> -c`. If the Compose
`workspace` service is absent or fails to start, print an actionable setup
error and run neither in-container command. If service state cannot be checked,
stop without rebuilding. Without Docker mode, workspace behavior must remain
the existing local tmux flow.

Reproduction: define a path alias to a project directory, then run
`d2 workspace -c <alias> --docker` and the `-d` spelling. Before this change,
workspace accepted only `-c` and always created or attached to a tmux session
on the host. Also try `-d` without `-c`, a raw absolute path, and an isolated
Compose project lacking a `workspace` service. Also test with the service
already running (no `up` or build) and stopped (cached `up --build`, never
`--no-cache`).

Root cause: `workspace` stripped only `-c`, then unconditionally created and
attached to the host's tmux session. It had no Docker option, Compose handoff,
or guard ensuring the container setup completed before in-container commands.

Red tests: `t/91-cli-ticket-coverage.t` adds command-order, alias cwd, invalid
option/path, no-service, state-probe, running-service reuse, stopped-service
cached-build, and setup-stage failure checks; `t/266-cli-help-dispatch.t`
and `t/39-cli-suggest-complete-coverage.t` cover public help and completion.
The new safe-reuse assertions failed before implementation; they now pass in
the focused Docker run.

Root-cause fix: the workspace parser now recognizes `-d`/`--docker` alongside
`-c`, resolves and changes into the registered alias directory, then hands off
to the public Docker Compose command with an argument list (no shell). It first
uses `compose ps --status running --services workspace`. If running, it skips
`up --build` so in-container progress is preserved. Otherwise it runs
`up -d --build workspace`, using Compose's default cache (no `--no-cache`). A
failed state probe stops before mutations. It then registers the alias and
starts the inner workspace; failures stop the sequence. Omitting Docker mode
retains the existing local tmux path.

Verification: the full test and four-metric coverage gate passed inside the
`dev` container (258 files, 23,201 tests; statement, branch, condition, and
subroutine coverage all 100.0%). Required focused web/SSL tests passed (3 files,
459 tests). The real checkout invocation against this repository's effective
Compose config failed at startup because that config has only `d2` and `dev`,
not `workspace`; the helper printed setup guidance and confirmed it ran no
in-container commands. Injected-runner integration tests verify exact successful
stage order and early stopping on each failure. The initial blank-container
package run exposed a fixture issue: without an init reaper, process-group tests
left descendants observable as zombies. After recreating the isolated Compose
service with `init: true`, plain `cpanm` (without `--notest`) installed both the
5.78 package and final 5.79 archive; each passed the packaged test suite (128
distributions installed). The 5.79 image built successfully and reports `d2
version` 5.79. The final archive includes the completed problem report; runtime
code is unchanged from 5.78. The repository itself does not configure a
`workspace` service, so a real successful interactive workspace session could
not be started here; the service-absent behavior was exercised directly and the
success sequence is verified by the ordered runner tests.

Post-push Scorecard (2026-10-10) reports 8.1/10. Branch-Protection is 0/10
because `master` has no branch protection; CII-Best-Practices is 0/10 because no
OpenSSF badge enrollment is detected; Code-Review is 0/10 because it finds 0/30
approved changesets; Contributors is 3/10 because it detects one contributing
organization; CI-Tests is unknown because no pull request was found. Source-side
checks scored 10/10. These remaining gates require repository administration,
external badge enrollment, or genuine review/contributor activity and are not
failures in the Problem 46 implementation.

Safe-reuse follow-up verification: the `dev` container reports the real
workspace service as running via `d2 docker compose ps --status running
--services workspace`. The focused `d2 docker compose exec dev prove -lv
t/91-cli-ticket-coverage.t` passes 242 tests, including a fork-isolated failed
`exec tmux` path, no rebuild for a running service, cached `up -d --build` for
a stopped service, and aborting on a failed state probe. The live workspace
container was not restarted or rebuilt. The complete Docker coverage run passed
259 files and 23,290 tests; statement, branch, condition, and subroutine
coverage each report 100.0%, with no stale uncoverable annotations.

Release verification for the P46/P47 changes: `dzil clean` removed the prior
5.82 build, then `dzil build` produced only `Developer-Dashboard-5.83.tar.gz`.
All 76 library modules, `dist.ini`, the main POD, and README report 5.83; the
archive contains the P46/P47 regression tests and no `cover_db`. The isolated
`d2 docker.images.build` completed, and a one-off Compose run returned
`d2 version` 5.83. A separate blank Perl 5.44 container installed the archive
with plain `cpanm` (tests enabled, no `--notest`) and the packaged suite passed;
the full blank-environment integration runner then reported success. Its
uniquely named Compose project was brought down afterward. GitHub's
multi-platform publication and the required post-push Scorecard run remain
pending the verified commit and push.

Regression reported 2026-10-10: when the host alias `somewhere` points to
`/tmp/foobar`, the in-container `d2 path add somewhere /workspace` inherited a
bind-mounted host config directory and rewrote the host alias to `/workspace`.
Expected: host `d2 paths` continues to show `/tmp/foobar`; only the container's
workspace command sees `/workspace`.

Red test and root cause: `t/91-cli-ticket-coverage.t` initially failed because
both container `exec` calls omitted config isolation; expected commands
required a private config-root override. Path configuration writes use the
regular active config mechanism, which previously pointed at the mounted host
config.

Fix: both in-container operations now pass
`DEVELOPER_DASHBOARD_CONFIG_OVERLAY=/dev/shm/developer-dashboard-workspace-config`
to Compose `exec`. This stores the alias in a private, additive container-local
config overlay, preserving existing settings while leaving the host
configuration untouched. A container smoke check added
`somewhere` at `/workspace` with an isolated config root and resolved it back
to `/workspace`. Red/green: the initial updated test failed on the old Compose
commands; after the fix, `d2 docker compose exec dev prove -lv
t/91-cli-ticket-coverage.t` passed all 212 assertions. The actual Compose smoke
used `d2 path add somewhere /workspace -o json` and then `d2 path resolve
somewhere` with the isolated config root. This repository has no `workspace`
service or mounted host-home fixture, so a full interactive workspace session
cannot be run here. The generated temporary container test directories were
removed after verification.

### Problem 47: Publish current master builds to Docker Hub (implementation complete; publication and external Scorecard gates pending)

Expected outcome: a GitHub Actions workflow triggered by pushes to `master`
(and by explicit manual dispatch) builds the current `master` checkout, logs in
to Docker Hub with the configured `DOCKER_HUB_USER` and `DOCKER_HUB_TOKEN`
secrets, and pushes both a `dist.ini` version tag and `latest`. The image must
be usable on Linux amd64 and arm64. Docker does not provide macOS-kernel
containers; Apple Silicon runs the arm64 Linux image through Docker Desktop's
Linux VM.

Reproduction: install from MetaCPAN, then compare the installed CLI with the
latest source on `master` before the next CPAN release. A Docker build that
installs only the MetaCPAN distribution will retain the older package even
though it is labeled as the current image.

Root cause: the normal install bootstrap is designed to fetch the published
CPAN distribution, while unreleased fixes exist only in the Git checkout. The
image flow had no job that rebuilt the checked-out code into a tarball and
installed that exact artifact after bootstrap.

Red test: `t/228-dockerhub-image-workflow.t` asserts the GitHub workflow,
credential wiring, version/latest tags, target platforms, and that the image
build runs `install.sh`, `dzil build`, and installs the generated tarball with
`cpanm`. It also guards that GitHub automation files, excluded from the CPAN
archive, do not make the packaged test suite fail, and that the shared Docker
context re-includes the tarball needed by the repository's local image build.

Implementation: `.github/workflows/dockerhub-image.yml` checks out `master`,
validates the X.XX distribution version, logs in to Docker Hub, and uses
Buildx/QEMU to publish a multi-platform manifest. Its Dockerfile runs
`install.sh`, installs the required Dist::Zilla plugins, builds the current
checkout, and tests/reinstalls the exact versioned tarball so an equal-version
MetaCPAN copy cannot shadow it. `.dockerignore` keeps local runtime state,
credentials, and build artifacts out of the image context. Detailed usage and
platform expectations are documented in the repository manual.

Verification: the full repository suite passed in the isolated Docker dev
container (259 files, 23,312 tests), with statement, subroutine, branch, and
condition coverage each measured at 100%. The Docker image build also passed;
its packaged cpanm install ran without `--notest` and passed (259 files, 16,985
tests), and an isolated Compose smoke test reported `d2 version` 5.81. The
focused release/security container gate passed (8 files, 6,438 tests), covering
web update/static/SSL checks, release metadata, this workflow contract,
kwalitee, POD syntax, and CPAN security metadata. `perlsec` was reviewed, and
the repository security scans and `git diff --check` passed. GitHub secrets are
only available to the configured `release` environment, so the remote
multi-platform Docker Hub publish cannot be exercised locally; it will run
when the workflow is pushed or manually dispatched. The first local image
attempt exposed that `.dockerignore` excluded the archive required by the
repository's `d2` image Dockerfile; a new failing assertion reproduced that
contract, then an exception rule fixed it. The next build passed and a fresh
isolated container reported 5.81. D2's project-layer `.env.pl` had also
selected the previous build marker as `D2D_VERSION`; providing the marker as
`D2D_LAST_BUILT_VERSION` made it select the current 5.81 archive without
editing local environment configuration. Host `dzil clean` followed by
`dzil build` completed successfully for 5.81; archive inspection confirmed
the new workflow contract test is included and no coverage database is
packaged. README/POD parity and all 76 library module versions were verified.

Post-push Scorecard identified one repository-fixable item: the Ubuntu base
image tag was not pinned by digest (Pinned-Dependencies 9/10). A new assertion
in `t/228-dockerhub-image-workflow.t` reproduced that finding before the
Dockerfile was changed to the Scorecard-reported multi-platform manifest
digest. This follow-up is version 5.82. The remaining Scorecard findings
require repository administration or community history; rerun Scorecard after
the next push and record the exact remaining gates. The 5.81 GitHub Docker Hub
workflow was triggered by the first push and its final result is being checked;
5.83 will run the multi-platform publish after the package and local image
gates pass and it is pushed.

Security review for Problems 46-47 (ASVS 5.0): V1, V4, V5, V7, V8, V10,
V11, V12, and V14 were applicable. The workspace service name is fixed, user
aliases remain argv values rather than shell source, the private overlay rejects
symlinks and non-owner directories, and startup/exec errors remain visible.
The image workflow requests read-only repository contents, pins every external
action to a full commit SHA and the Ubuntu base to its multi-platform digest,
and passes Docker Hub credentials only to the login action from the `release`
environment; credentials are not build arguments or context files. V2, V3, V6,
V9, and V13 (authentication, sessions, cryptography, transport, and application
API) have no changed runtime surface. OWASP A03, A04, A05, A08, and A09 were
reviewed for command construction, container reuse, workflow configuration,
source/image integrity, and visible failure reporting. A01, A02, A06, A07, and
A10 do not gain a changed access-control, cryptography, dependency, identity,
or request-forgery surface. Required security scans and web/static/SSL tests
passed in Docker; post-push Scorecard governance findings are tracked separately
from code-side security controls.

#### Problem 47 timeout correction (2026-10-10; release version 5.84)

Expected outcome: the GitHub multi-platform publish completes inside its
120-minute job limit and installs the current tarball into both runtime image
architectures. The full test and coverage gates still run before packaging;
image assembly must not repeat the full suite under QEMU.

Reproduction and root cause: pushed commit `aed8ab8d` triggered Actions run
`38078551920`. Setup, source checkout, version validation, QEMU/Buildx setup,
credential validation, and Docker Hub login all passed. The image build stayed
in progress until the configured 120-minute job timeout cancelled it. The
Dockerfile's final `cpanm` installation had no `--notest`, so it reran the
23,000+ test suite for each emulated target architecture despite the separate
full repository and coverage gates.

Red test: updated `t/228-dockerhub-image-workflow.t` first to require
`cpanm --notest --reinstall` for installing the generated archive. Running it
inside the Docker `dev` service failed at that assertion against the old
Dockerfile (31 passed, 1 failed), reproducing the unwanted duplicate suite.

Fix: the runtime image now installs the newly built, version-matched tarball
with `cpanm --notest --reinstall`. This does not weaken verification: full
repository and coverage gates remain mandatory, and the blank-container
integration gate installs the exact archive with tests enabled. The contract
test then passed all 32 assertions in the Docker `dev` service. The post-fix
5.84 full suite passed in Docker (`259` files, `23,284` tests); statement,
branch, condition, and subroutine coverage each measured `100.0%`. The focused
release/security/workflow gate passed `5,625` tests, and the required
web/static/SSL gate passed `459`. `dzil clean` and `dzil build` produced only
`Developer-Dashboard-5.84.tar.gz`; archive inspection confirmed 5.84, inclusion
of workflow/release tests, and no `cover_db`. The standard local image build
and a fresh one-off container both returned `d2 version` 5.84. A direct local
build of the workflow Dockerfile also completed and its one-off image returned
5.84. Finally, the blank Perl 5.44 Docker environment installed that archive
with cpanm tests enabled and completed the integration harness successfully.
The corrected 5.84 GitHub publish and post-push Scorecard remain pending this
version's push.
