# Fixed Bugs
## 4.03 - OWASP claim wording now matches the actual shipped evidence

- Fixed the repo's OWASP claim boundary so the docs and gates no longer stop
  at policy wording without a shipped closure artifact.
- Root cause:
  the repository already had an OWASP ASVS 5.0 and Top 10 gate in policy,
  tests, and manuals, but it still lacked a dedicated scope-of-work record
  that mapped chapters to evidence and stated clearly when a stronger public
  `OWASP compliant` claim would actually be justified.
- Fix:
  added a shipped OWASP compliance SOW and evidence matrix under `doc/`,
  wired it into `t/47-owasp-gate.t` and `t/15-release-metadata.t`, and
  tightened the security and release manuals plus the main generated manual so
  the safe public wording remains `OWASP-aligned` / `OWASP-gated` until the
  remaining governance and release blockers are really closed.

## 4.02 - Runtime helper detection and final gate closure are stable

- Fixed the runtime helper substring probe and the final coverage-closure harness path that depended on it.
- Root cause:
  `_helper_file_supports_internal_command` was using a compact return
  expression that did not stay trustworthy under the full gate loop, and the
  matching coverage-closure test used a fragile temporary helper setup that
  was too easy to destabilize while closing the last line-level coverage gaps.
- Fix:
  the runtime helper matcher now returns an explicit boolean from a stable
  substring check, and `t/47-zombie-coverage-closure.t` now keeps a real
  helper fixture alive on disk and exercises the matcher through a direct
  runtime object call before validating the remaining collector-runner
  branches.

## 4.01 - Layered API auth is now operable through a first-class dashboard api command

- Fixed the missing operator workflow for layered saved-Ajax machine auth.
- Root cause:
  the backend already understood layered `config/api.json`, but operators had
  no supported command to inspect the effective merged registry, hash raw
  secrets safely, update only the deepest writable layer, or hide inherited
  API groups without editing parent JSON by hand.
- Fix:
  added the built-in `dashboard api` command with `ls`, `add`, and `rm`
  actions; `dashboard api` now defaults to listing the effective merged
  registry, raw secrets are hashed to SHA-256 before persistence, exact
  `/ajax/...` routes can be added or removed idempotently, `--maybe-secret`
  now supports one-command route-focused creates or overwrites, fresh runtimes
  bootstrap `config/api.json` automatically, and inherited API groups can be
  masked through child-layer tombstones in the writable layer while the parent
  config stays untouched.

## 4.00 - Layered API auth for saved ajax routes works without weakening helper sessions

- Fixed remote machine access for selected saved `/ajax/...` handlers so
  operators can authorize them with layered `config/api.json` keys instead of
  forcing a helper-user login flow.
- Root cause:
  saved ajax routes only understood the existing local-admin or helper-session
  auth path. Even when an operator needed one exact saved ajax route for a
  remote application, the backend had no layered `config/api.json` contract,
  no SHA-256 machine-secret verification, and no route-scoped auth bypass for
  that use case. The PSGI/Dancer adapter also discarded the custom API auth
  headers before they could reach the backend.
- Fix:
  the config loader now merges `config/api.json` through `DD-OOP-LAYERS` plus
  installed skill layer chains, the web backend recognizes exact registered
  `/ajax/...` routes and verifies `X-DD-API-Key` plus `X-DD-API-Secret`
  against stored SHA-256 digests, helper sessions still work on the same
  routes, and missing or wrong machine credentials now fail closed with
  `403 {"status":"forbidden"}`. The PSGI/Dancer adapter now forwards those API
  headers unchanged so the browser-facing entrypoint and direct backend calls
  enforce the same contract.

## 3.99 - Blank-environment tarball installs keep shell-based child commands runnable

- Fixed blank-environment tarball installs that failed even after dashboard
  child processes repaired `PATH` for the current Perl interpreter.
- Root cause:
  collector shell commands are launched through `sh -c`, but the shared child
  environment builder only forced the current Perl interpreter directory to
  the front of `PATH`. In a clean container with an intentionally broken or
  stripped `PATH`, that kept `perl` resolvable while still leaving `sh`
  missing, so `_run_command` failed during the packaged `t/07-core-units.t`
  regression that exercises the repaired-path contract.
- Fix:
  dashboard-managed child env builders now also keep the active shell
  directory at the front of `PATH`, alongside the current interpreter bin.
  The loader regression now locks in that shell-directory guarantee, the core
  units regression proves `_run_command` succeeds under a stripped `PATH`, and
  the rebuilt tarball now installs successfully in a blank Docker environment
  with `cpanm` and dist tests enabled.

## 3.98 - Disabled collectors, singleton loops, and lifecycle stop paths behave correctly

- Fixed collector config handling so `disable => 1` or `"disable": true`
  means the collector is actually disabled instead of only being marked in
  config while the runtime still lets it run.
- Root cause:
  collector startup and indicator sync still treated configured collectors as
  active as long as they were present in merged config. A disabled collector
  could still be started by lifecycle commands, a named manual start could
  still launch it, and its managed indicator state could linger behind as if
  it were still part of the live fleet.
- Fix:
  collector config normalization now carries a stable disable flag, runtime
  startup skips those jobs, named starts reject them explicitly, and lifecycle
  actions stop any already-running managed loop for a disabled collector.
  Managed collector indicator sync now also removes disabled collector
  indicators instead of keeping stale active rows around.
- Fixed lingering dashboard `<defunct>` processes that still built up under
  long-lived collector loops and collector watchdog supervisor parents.
- Root cause:
  the collector loop only reaped finished worker children at the top of the
  next scheduler tick, and the watchdog supervisor did not reap adopted direct
  children at all. Long-interval collectors could therefore leave zombie worker
  children behind until the next interval, and stale supervisors could keep
  unreaped dashboard children around for days.
- Fix:
  collector loops now reap exited workers immediately through a local
  `SIGCHLD` handler as well as on each loop pass, and the watchdog supervisor
  now reaps exited direct children both when `SIGCHLD` fires and on every
  watchdog pass. The regression tests lock in both paths so the runtime no
  longer depends on a later tick or external cleanup to remove defunct
  dashboard processes.
- Fixed dashboard-managed tmux ticket and workspace sessions that repainted
  their status block every two seconds and kept `ps1 --mode tmux-status-top`
  churn permanently hot.
- Root cause:
  the staged shell bootstrap and ticket status helper hard-coded tmux
  `status-interval 2`, so every managed session kept re-running the prompt
  status command far more often than the dashboard indicators actually needed.
- Fix:
  dashboard-managed tmux sessions now refresh that status strip every
  fifteen seconds instead of every two seconds. The helper staging and CLI
  regression tests lock the new cadence in.
- Fixed shell collectors that recursively executed `dashboard ...` or `d2 ...`
  on tiny intervals and could flood one machine with overlapping dashboard
  process trees.
- Root cause:
  collector scheduling treated heavy dashboard-recursive shell commands the
  same as cheap direct probes, so a local config with several `interval: 5`
  dashboard collectors could keep the runtime permanently busy even when the
  user only wanted occasional status updates.
- Fix:
  collector loops now apply a default `30` second floor to shell collectors
  that re-enter dashboard, while still allowing explicit opt-out through
  `allow_fast_poll`, `allow_fast_dashboard_poll`, or the
  `DEVELOPER_DASHBOARD_MIN_DASHBOARD_COMMAND_INTERVAL_SECONDS` override. The
  watchdog uses that same effective interval when deciding whether a collector
  is stale, so the safety floor does not create false restarts.
- Fixed collector stop and restart paths that could leave a long-running
  singleton command alive after the loop wrapper had already been stopped.
- Root cause:
  collector stop logic concentrated on the managed loop pid and its worker pid,
  but not the full worker process group. A shell-launched long-running command
  could outlive the loop wrapper, making singleton scheduling appear to overlap
  because the old command was still alive after the loop bookkeeping moved on.
- Fix:
  collector workers now run in their own process groups, loop shutdown signals
  those whole worker groups, and loop state persists `active_worker_pids` so
  tests can lock in the live singleton no-overlap contract.
- Fixed web stop flows that could hang or return misleading lifecycle state when
  process discovery lagged behind the saved runtime metadata.
- Root cause:
  `stop_web` only escalated to `KILL` when `running_web()` could still
  rediscover the live pid, and it treated every `dashboard ajax:` process owned
  by the current user as part of the web runtime being stopped.
- Fix:
  web stop now keeps the saved managed pid as the reported lifecycle owner,
  still kills the saved pid when runtime discovery lags, and limits ajax worker
  cleanup to the current dashboard runtime root instead of sweeping unrelated
  ajax workers.
- Fixed macOS helper/collector startup failures caused by stale user-local
  dual-life XS modules shadowing the active Perl core.
- Root cause:
  dashboard-owned processes inherited `PERL5LIB` as-is, so a local-lib tree
  with an older `Encode.bundle` or similar dual-life module could appear ahead
  of the current interpreter's matching core directories. Staged helpers,
  collector child commands, saved Ajax subprocesses, and skill hooks could
  then die during startup with XS handshake mismatch errors.
- Fix:
  dashboard bootstrap now normalizes `PERL5LIB` so dashboard-owned libraries
  remain visible while the active interpreter's core, site, and vendor
  directories stay ahead of inherited user-local shadow copies. The same safe
  ordering is used for the public switchboard, staged private helper core,
  runtime child-process envs, and skill command envs.
- Fixed macOS collector child commands that still fell back to the wrong Perl
  binary even after the safe `PERL5LIB` ordering was in place.
- Root cause:
  dashboard-managed child commands and hooks could still execute `dashboard`
  through `/usr/bin/env perl` inside a non-interactive child `PATH` that found
  `/usr/bin/perl` before the Perl interpreter that installed Dashboard under
  `~/perl5`. That left collector commands such as
  `dashboard system-status.load memory` running the wrong executable against
  the right library tree, which failed with Perl-version mismatch errors and
  left restart flows chasing stale loop state.
- Fix:
  dashboard-managed child env builders now keep the current interpreter's bin
  directory at the front of `PATH` alongside the safe `PERL5LIB` ordering, so
  collectors, saved Ajax subprocesses, and skill hooks continue to execute the
  same Perl build as the parent dashboard process.
- Fixed macOS collector commands that emitted shell startup chatter before
  their JSON payload and then failed collector JSON parsing.
- Root cause:
  collector shell commands were launched through a login shell. On affected
  macOS hosts that let the shell print session-restore text, commands such as
  `dashboard system-status.load memory` produced banner text before the JSON
  body, which made collector JSON parsing fail even though the command itself
  succeeded.
- Fix:
  collector shell commands now run through a non-login shell, keeping the
  inherited runtime environment but avoiding shell startup chatter that is not
  part of the collector payload.
- Fixed manual named collector stop/restart operations that could hang while
  the watchdog restarted the same collector underneath the CLI.
- Root cause:
  explicit named collector lifecycle commands removed the target from the
  watched set, but they left the watchdog supervisor process itself running.
  One in-flight watchdog pass could still observe the collector as missing and
  spawn a replacement loop while the manual restart path was still waiting for
  the collector it had just stopped.
- Fix:
  explicit named collector stop/restart operations now pause the watchdog
  supervisor while the manual lifecycle action runs, then restore supervision
  for the remaining watched collectors afterwards.

## 3.92 - Prompt switchboard eager-load trimming and targeted helper refresh

- Fixed the remaining `dashboard ps1` startup drag after the earlier prompt
  renderer cleanup.
- Root cause:
  the public `dashboard` switchboard was still doing expensive work before the
  staged `ps1` helper ran. Every prompt render still loaded the suggestion
  runtime, loaded helper-staging-only modules, rebuilt the same path registry
  multiple times, and refreshed the whole helper tree instead of just the one
  helper being invoked.
- Fix:
  the switchboard now lazy-loads the unknown-command suggestion runtime, keeps
  `File::ShareDir` and `SeedSync` out of the hot path unless a helper really
  needs repair, stages only the requested built-in helper during steady-state
  dispatch, and reuses one `PathRegistry` object across the whole invocation.
- Fixed prompt-time config loading to read installed skill `config/config.json`
  files directly instead of constructing the full skill dispatch runtime just
  to merge config fragments.

## 3.91 - Prompt fast-path subprocess trimming and collector sync skipping

- Fixed `dashboard ps1` so it no longer probes `tmux show-environment` when
  the shell is not inside tmux. Ordinary non-tmux shells now avoid that extra
  subprocess entirely.
- Fixed prompt git branch rendering so it reads `.git/HEAD` and worktree
  `gitdir:` metadata directly instead of spawning `git branch` on every prompt
  render.
- Fixed prompt core-indicator refresh so the prompt path now refreshes only
  prompt-visible core indicators instead of paying for hidden `project` and
  `git` subprocess checks every time.
- Fixed prompt collector syncing so repeated `dashboard ps1` renders skip the
  full collector indicator sync path when the stored managed indicator state
  already matches the configured collector set.
- Removed one unused `Developer::Dashboard::Collector` construction from the
  staged `ps1` helper so prompt startup does not instantiate dead runtime work.

## 3.90 - PathRegistry cwd reuse, env-loader cwd reuse, and nested skill env hardening

- Fixed the startup-performance miss from the improvement plan: `PathRegistry`
  now actually uses the constructor-supplied cwd and memoizes repeated
  DD-OOP-LAYERS path derivation for the lifetime of one helper invocation.
- Fixed `EnvLoader` plain-directory traversal so it reuses the registry cwd
  instead of calling `cwd()` again while walking root, project, and leaf `.env`
  files.
- Kept the nested skill env and compose layering behavior intact while closing
  the remaining coverage and packaging gates on top of the new startup-path
  changes.

## 3.89 - Nested skill env chains, nested compose roots, and ActionRunner gate closure

- Fixed nested skill env loading so dotted commands such as
  `dashboard foo.bar.zzz.show` now load `foo/.env`, `foo/bar/.env`, and
  `foo/bar/zzz/.env` from root to leaf before the command runs.
- When a deeper nested skill overrides the same key, the parent value is now
  preserved under cumulative aliases before the leaf wins the plain key. For
  example, three nested `VERSION` assignments now leave `foo_VERSION`,
  `foo_bar_VERSION`, and `VERSION` available together.
- Fixed docker compose skill discovery so nested installed skill compose roots
  such as `skills/foo/skills/bar/skills/zzz/config/docker/zzz/compose.yml`
  participate in service resolution instead of being ignored.
- Participating nested skill compose roots now export both the leaf
  `<skill>_DDDC` alias such as `zzz_DDDC` and the cumulative nested alias such
  as `foo_bar_zzz_DDDC`, both pointing at the owning `config/docker/` root.
- Closed the remaining ActionRunner gate miss by adding regression coverage for
  invalid action payloads, missing cwd failures, safe/trust edge cases, and
  detached background-child startup failures around stdio, cwd, and exec.

## 3.88 - Compose skill env layering and detached background tarball stability

- Fixed `dashboard docker compose` so each participating skill compose service
  now contributes its `<skill-root>/.env` file plus one normalized
  `<skill>_DDDC` docker-root variable during stack resolution.
- Fixed detached background page command actions so root-owned blank-container
  tarball installs no longer fail when the action wrapper exits. The detached
  supervisor now reaps its owned command child, and action-runner liveness
  checks treat already-reaped or zombie wrappers as stopped instead of leaving
  stale background-action state behind.

## 3.86 - Fix packaged shell bootstrap entrypoint reuse

- Fixed `dashboard shell` packaging so generated bootstrap helpers always
  re-enter the active public `bin/dashboard` path instead of leaking a stale
  inherited `DEVELOPER_DASHBOARD_ENTRYPOINT` from another checkout or build
  tree.
- This closes the blank-container tarball install failure where extracted
  distributions generated shell helpers that pointed back to the source
  checkout.

## 3.85 - Export skill-specific compose env roots for participating skills

- Fixed `dashboard docker compose` so installed skill services can contribute
  `<skill-root>/.env` when their `config/docker/<service>/compose.yml` or
  `development.compose.yml` file actually participates in the resolved stack.
- Disabled skills stay excluded from compose env loading, and the compose path
  does not execute `<skill-root>/.env.pl`.
- Added a skill-specific `<skill-name>_DDDC` compose environment variable for
  each participating skill, pointing at that skill's `config/docker/` root
  after normalizing non-identifier characters in the skill name to
  underscores.

## 3.84 - Load participating skill .env files into docker compose resolution

- Fixed `dashboard docker compose` so installed skill services can contribute
  `<skill-root>/.env` when their `config/docker/<service>/compose.yml` or
  `development.compose.yml` file actually participates in the resolved stack.
- Disabled skills stay excluded from compose env loading, and the compose path
  does not execute `<skill-root>/.env.pl`.
## 3.83 - Show only real skill dependency work in install progress

- Fixed the interactive `dashboard skills install` progress board so it no
  longer prints `[OK] ... skipped: ... not present` rows for dependency files
  that do not exist in the fetched skill.
- Root cause:
  the progress board predeclared every possible dependency step before the
  skill checkout had been inspected, so the install path later marked absent
  manifests as successful skipped work. That made users think a dependency had
  been installed when there had actually been nothing to do.
- Fix:
  the progress board now starts with fetch and layout tasks only, then appends
  dependency rows after the fetched skill root is known and only for manifest
  files that are really present.
- Fixed platform noise in the same install progress flow.
- Root cause:
  operating-system-specific manifests such as `brewfile` and `wingetfile` were
  being shown on unrelated hosts, even though those package managers could
  never run there.
- Fix:
  `aptfile`, `apkfile`, `dnfile`, `wingetfile`, and `brewfile` now appear only
  on their matching host families, while cross-platform manifests such as
  `package.json`, `requirements.txt`, `cpanfile`, `cpanfile.local`,
  `Makefile`, `ddfile`, and `ddfile.local` appear only when the corresponding
  file exists.
  pid as live forever, then died with `Collector '...' did not stop after TERM
  and KILL`.
- Fix:
  both `CollectorRunner` and `RuntimeManager` now read process state and treat
  zombie `Z` pids as stopped before deciding whether the pid is still alive.

## 3.79 - Replace TOML::Tiny with TOML::Parser for tarball-install stability

- Fixed the `tomq` runtime dependency chain by replacing `TOML::Tiny` with
  `TOML::Parser`.
- `TOML::Tiny 0.21` no longer passes its own clean-container test suite on
  Perl 5.38, which made `cpanm Developer-Dashboard-X.XX.tar.gz` fail under
  the required install-with-tests gate before the distribution could finish
  installing.
- The new parser path also inflates TOML booleans into plain Perl `1` and `0`
  scalars so CLI and JSON query output stays predictable.

## 3.78 - Fix missing Devel::Cover in the GitHub release workflow

- Fixed the tag-triggered GitHub release workflow so it installs
  `Devel::Cover` before it runs the numeric coverage gate.
- This removes the `cover: command not found` exit-127 failure that blocked
  GitHub release publication even after the local test and coverage gates had
  already passed.

## 3.77 - Align all shipped lib module versions with the repo version

- Fixed a release metadata drift where the main repo version had moved forward
  but many shipped modules under `lib/` still declared the previous version.
- Fixed the source tree so every shipped Perl module now reports the same
  `3.77` distribution version, keeping CI, release metadata, and packaged
  builds in sync.

## 3.76 - Fix blank-host bootstrap installer checkout configure prereqs

- Fixed blank Ubuntu streamed installs such as
  `curl .../install.sh | sh` so the installer now seeds
  `File::ShareDir::Install` into `~/perl5` before it asks `cpanm --notest .`
  to install the cloned checkout.
- Fixed the matching Windows checkout bootstrap path so `install.ps1` also
  stages `File::ShareDir::Install` before the local checkout install.

## 3.75 - Fix source-tree helper lookup in RuntimeManager and bundle jQuery 4

- Root cause:
  the Windows background web-launch helper path in `RuntimeManager` called
  `dist_dir('Developer-Dashboard')` directly. That works in installed
  distributions, but a source-tree CI run has no installed dist share yet, so
  `t/09-runtime-manager.t` could die early with `Failed to find share dir for
  dist 'Developer-Dashboard'`. Separately, `/js/jquery.js` still served an
  older handwritten compatibility shim instead of the real bundled jQuery 4
  asset the route name now implies.

- Fix:
  switched `RuntimeManager` onto the existing guarded helper-asset resolver so
  missing installed dist shares no longer abort source-tree tests and the
  staged helper path still wins when appropriate. Added regression coverage
  for the exact missing-dist-share failure case. Replaced the built-in
  `/js/jquery.js` response with a bundled local copy of `jquery-4.0.0.min.js`,
  kept `/js/jquery-4.0.0.min.js` as a compatibility alias for the same
  shipped payload, and updated route, static-file, release-metadata, and
  documentation checks to reflect the bundled asset. Also taught the browser
  bookmark editor to expand a fresh `:---` line into the full separator and
  seed the next sensible unique directive automatically, so common
  `TITLE -> HTML -> CODE<N>` edits no longer require repetitive manual typing.

## 3.74 - Add Python skill command dispatch and requirements.txt installs

- Root cause:
  the runtime could already launch Perl, Node, Go, Java, shell, and Windows
  script extensions directly from logical `cli/<command>` names, but it did
  not recognize `.py` files at all. Skill installs also had no first-class
  Python dependency step, so a skill could ship `cli/foo.py` and
  `requirements.txt` but the runtime would neither launch the command through
  `python` nor install its Python dependencies through the normal manifest
  chain.

- Fix:
  added `.py` to the runnable-file resolution path on Unix and Windows,
  dispatches those files through the preferred `python` interpreter, and added
  regression coverage for extensionless lookup plus Windows runnable-file
  detection. Added a dedicated `requirements.txt` install step after
  `package.json` and before the Perl manifests, running
  `python -m pip install --user --requirement requirements.txt` from the skill
  root. Updated the shipped manuals, progress labels, and dependency-order
  coverage so the public docs and release gates describe the Python path in
  full detail.

## 3.73 - Run executable JavaScript skill commands and hooks through node

- Root cause:
  the runnable-file resolver only knew about `.pl`, `.go`, `.java`, shell,
  and Windows script extensions. Skills could already install Node
  dependencies from `package.json`, but executable `cli/<command>.js` files
  and `.js` hook files were never discovered from logical command names and
  were never launched through `node`.

- Fix:
  added `.js` to the runnable-file extension search chain, dispatches those
  files through the preferred `node` binary on Unix and Windows, and added
  regression coverage for both extensionless lookup and Windows runnable-file
  detection. Updated the shipped manuals and release-metadata coverage so the
  public docs describe the end-to-end Node command path alongside the
  existing `package.json` install chain.

## 3.72 - Fix stalled collectors and move tmux workspaces to layered env refresh

- Root cause:
  the collector watchdog only checked whether the managed loop process still
  existed. If a collector loop stayed alive but stopped updating its runtime
  status or completing new runs, the watchdog treated it as healthy and left
  it silent forever. The tmux workflow was also still named `ticket`
  throughout the primary user-facing command surface, and resumed sessions
  kept whatever environment they were created with instead of reloading the
  current plain-directory `.env` chain.

- Fix:
  the watchdog now detects a live managed collector loop that has stopped
  making progress, stops that loop explicitly, and restarts it through the
  same managed restart path used for dead-loop recovery. Added regression
  coverage for stalled-loop recycling and for the watchdog error metadata
  written when a stall is repaired. The primary tmux workflow is now
  `dashboard workspace`, with `dashboard ticket` preserved as a compatibility
  alias. Workspace sessions now seed `WORKSPACE_REF`, keep `TICKET_REF` for
  compatibility, and reload plain-directory `.env` files from the highest
  ancestor down to the current directory both when a session is created and
  when it is resumed, unsetting keys that disappeared from the current layered
  environment.

## 3.71 - Preserve collector indicator order and runtime custom-route aliases

- Root cause:
  collector config sync correctly seeded `collector_order` from the
  `collectors` array in `config/config.json`, but a later live
  `CollectorRunner->run_once()` update rebuilt that indicator payload without
  passing the existing indicator record back into
  `collector_indicator_candidate()`. That dropped the persisted
  `collector_order` field after one collector refreshed itself, so the status
  board, page-header indicators, and `dashboard ps1` could drift back to
  alphabetical ordering even though the configured collector order was still
  correct.
  The custom route loader also only read installed skill `config/routes.json`
  files. Runtime-level `config/routes.json` aliases for normal saved bookmarks
  or built-in `/ajax`, `/js`, `/css`, and `/others` paths were never loaded,
  so a route like `"/java": "/app/learn.ai"` always fell through to `404`
  even when `dashboards/learn.ai` existed.

- Fix:
  live collector status writes now reload the existing indicator state and
  pass it into `collector_indicator_candidate()` before persisting the updated
  status. That keeps the managed collector metadata, including
  `collector_order`, stable across live refreshes. Added a regression that
  runs one collector after `sync_collectors()` and verifies the ordered
  indicator list still matches the `collectors` array order. The route
  dispatcher now also loads runtime-level `config/routes.json` files across
  the active config-layer chain, so saved bookmark aliases like `/java ->
  /app/learn.ai` resolve through the same flat route schema as skill custom
  routes. Added regressions for runtime `/app`, `/ajax`, `/js`, `/css`, and
  `/others` aliases, plus an integration check that `/java` renders the same
  bookmark body as `/app/learn.ai`.

## 3.70 - Move skill route metadata to config/routes.json and widen custom route coverage

- Root cause:
  installed skill custom routing only understood the earlier
  `dashboards/routes.json` Ajax-only schema. Skill authors could not define
  custom fallback paths for `/app`, `/js`, `/css`, or `/others`, and the
  manifest format did not match the simpler public-path-to-smart-route form
  you wanted. That left the route contract broader in the runtime than in the
  authoring surface, and it kept the metadata in the wrong place.

- Fix:
  moved skill route metadata to `config/routes.json` and changed the supported
  schema to a flat custom-path map. Each custom path now maps to one local
  smart route string such as `/ajax/foo` or to an object with `to` plus an
  optional `type`. The loader now expands that format into the internal route
  model, rejects mixed/invalid schemas explicitly, defaults custom Ajax routes
  to `json`, and serves custom `/app`, `/ajax`, `/js`, `/css`, and `/others`
  paths only after the smart parent routes miss. Saved skill-page Ajax URLs
  now continue to emit the canonical custom path from `config/routes.json`.
  Also fixed `dashboard serve logs -f` so it snapshots the already-read log
  byte offset before entering follow mode; without that, a line appended in
  the gap between the initial tail print and the old seek-to-end follow loop
  could be skipped forever and hang the follower tests.

## 3.69 - Fix skill ajax custom routing and collector indicator ordering

- Root cause:
  installed skill ajax handling only knew the smart `/ajax/<repo>/...`
  namespace and the saved-page `Ajax(file => ...)` helper always emitted that
  older route shape. Skill authors had no supported way to publish a
  canonical custom path such as `/v1/status`, no alias metadata contract, and
  no route-level default content type beyond repeating `?type=...` in every
  generated URL. At the same time, managed collector indicators were sorted by
  name once they reached prompt and page-header rendering, so the browser
  status strip and `dashboard ps1` could drift away from the configured
  collector array order.

- Fix:
  added `dashboards/routes.json` skill metadata with `version`, `ajax`,
  required canonical `path`, optional `aliases`, and optional default `type`
  fields. Skill pages now emit the declared canonical custom path while the
  smart `/ajax/<repo>/...` resolver stays the parent route and alias/custom
  paths only run after that smart route misses. The web layer now honors route
  default content types including raw mime strings, and browser prompt/status
  rendering now preserves managed collector order from the configured
  collector array instead of re-sorting those indicators alphabetically.

- Prevention:
  added focused dispatcher, direct web, PSGI, prompt, and page-header
  regressions for canonical custom ajax paths, alias fallback, smart-route
  compatibility, default `json`/`html`/raw mime handling, and configured
  collector-order rendering in both `/system/status` payloads and PS1 output.

## 3.68 - Fix collector overlap policy and bounded parallel scheduling

- Root cause:
  collector loops executed `run_once()` inline inside the long-lived scheduler
  process. A slow collector therefore blocked the next interval tick entirely,
  which made "run again on schedule even while the previous run is still
  active" impossible. The persisted collector status model also used an
  unlocked read/merge/write path plus a single `running => 0` completion write,
  so any future overlap support would have raced and cleared a still-live run.

- Fix:
  normalized collector config to accept `mode` and `multiple`, defaulting to
  `singleton` and allowing bounded overlap only when `mode` is `multiple`.
  The collector loop now spawns bounded worker children per due tick, reaps
  them explicitly, and keeps singleton collectors from overlapping while
  allowing opt-in multiple collectors to run up to their configured parallel
  limit. Collector status writes now run under an exclusive lock and maintain
  an `active_runs` counter so concurrent completions do not incorrectly mark
  another live run as stopped.

- Prevention:
  added focused config and collector-loop regressions that lock in the default
  singleton policy, the default `multiple => 2` bound, invalid config
  rejection, active-run cleanup after synchronous execution, and the
  scheduler's different overlap behavior across singleton and multiple modes.

## 3.67 - Fix zombie child processes across runtime helpers

- Root cause:
  several long-lived runtime paths started or stopped child processes without
  fully owning their wait/reap lifecycle. Detached web startup left behind the
  intermediate launcher child, collector and watchdog stop paths signalled
  managed children without reaping them, the SSL frontend only reaped
  connection workers opportunistically from the accept loop, and background
  page actions returned the direct forked child to the caller instead of
  daemonizing cleanly. On macOS and WSL that left visible zombie processes
  behind after normal runtime activity.

- Fix:
  moved child reaping into the runtime owners. Collector stop and watchdog
  shutdown now reap managed children after TERM/KILL handling, background page
  actions now daemonize through an intermediate launcher and return the real
  detached pid, web startup reaps its intermediate launcher child, and the SSL
  frontend now reaps connection workers through `SIGCHLD` while treating
  interrupted `accept()` calls as retries until an explicit shutdown signal is
  requested.

- Prevention:
  strengthened the focused runtime tests so stop paths now fail if they leave
  caller-owned children to be reaped later, and SSL/action regressions now
  lock the no-zombie contract into the suite.

## 3.66 - Fix silent collector death with watchdog restart supervision

- Root cause:
  collector job failures inside the loop were already caught and logged, but
  there was no long-lived watchdog around the collector loop process itself.
  If that loop process died after startup, the collector stayed down until a
  human noticed and restarted it manually, which looked like a silent stop.

- Fix:
  added a managed collector watchdog supervisor in `RuntimeManager` that keeps
  watching the configured collector fleet after startup, restarts loops that
  die unexpectedly, and records restart counters, timestamps, and error text
  in collector status plus collector logs. After too many crashes in the
  watchdog window, it now stops blindly restarting and marks the collector
  `attention_required` so the operator sees a concrete problem to address.

- Prevention:
  added regression coverage for post-start collector supervision so the runtime
  tests now fail if a managed collector can disappear without watchdog restart
  state or without an explicit attention-required escalation path.

## 3.65 - Fix release closeout drift and staged helper/runtime verification regressions

- Root cause:
  the post-`3.64` tree contained real fixes, but the closeout flow stalled
  before commit and push. During that gap, version metadata was left at `3.64`
  while new changes accumulated, staged helpers that re-entered
  `_dashboard-core` directly could lose the repo lib path in direct helper
  smoke coverage, and `CLI::Progress` treated falsey `max_detail_lines` as
  zero visible detail lines instead of the documented fallback rolling window.

- Fix:
  bumped the release to `3.65`, resynced the canonical POD, generated README,
  and release metadata expectations, taught staged core-backed helpers to seed
  `DEVELOPER_DASHBOARD_REPO_LIB` from `@INC` before re-entering
  `_dashboard-core`, and normalized falsey `max_detail_lines` to the intended
  ten-line fallback window.

- Prevention:
  added an explicit repo rule that once a mandatory gate miss is identified,
  the closeout flow must continue automatically instead of stopping at a soft
  handoff question.

## 3.64 - Fix macOS Terminal.app update_terminal_cwd error

- Root cause:
  On macOS, Terminal.app defines `update_terminal_cwd()` in
  `/etc/bashrc_Apple_Terminal` to update the window title with the current
  working directory. When the dashboard shell bootstrap was evaluated in a
  fresh bash session without this file being sourced first, pressing Enter
  would trigger the error: `-bash: update_terminal_cwd: command not found`

- Fix:
  added guard to bash shell bootstrap to source `/etc/bashrc_Apple_Terminal`
  when `update_terminal_cwd` is missing, preventing the error on fresh macOS
  bash sessions.

## 3.63 - Fix Docker build output truncation and add dockerfile manifest support

- Root cause:
  `Progress.pm` capped detail lines at 10 by default, truncating long-running
  operation output such as Docker builds during skill installation. Users saw
  only the first 10 lines with no autoscroll or continuation.

- Fix:
  changed `Progress.pm` to make `max_detail_lines` optional (undef = unlimited),
  allowing full streaming output for operations like Docker builds while still
  supporting explicit caps where needed.

- Enhancement:
  added `dockerfile` manifest support to `SkillManager`, allowing skills to
  declare a `dockerfile` that gets built automatically during installation.
  The build output now streams in full to the progress board.

- Testing:
  added test coverage for dockerfile detection in skill metadata and progress
  task sequence.

- macOS Terminal.app fix:
  added guard to source /etc/bashrc_Apple_Terminal when update_terminal_cwd
  is missing, preventing "-bash: update_terminal_cwd: command not found" errors
  on fresh macOS bash sessions.


## 3.62 - Fix root ddfile drift after skill uninstall

- Root cause:
  explicit `dashboard skills install <source>` correctly registered the source
  in `~/.developer-dashboard/ddfile`, but `dashboard skills uninstall
  <repo-name>` only removed the cloned skill tree and left the root registry
  behind.

- Fix:
  uninstall now removes root `ddfile` entries whose sources resolve back to the
  uninstalled repo name while preserving comments, line order, and unrelated
  entries.

## 3.61 - Fix inconsistent repository licensing metadata and docs

- Fixed the repository licensing state so it no longer mixed Perl_5 metadata,
  GPL text in `LICENSE`, an Artistic sidecar file, and user-facing wording
  that still described the project as dual-licensed under the Perl terms.
- Switched the distribution metadata, shipped root `LICENSE`, canonical POD,
  generated README, and Scorecard guardrails to one explicit MIT license
  contract so users and automation now see the same license everywhere.

## 3.60 - Clarify license disclaimer and liability baseline in user-facing docs

- Clarified the main README and canonical POD so the open-source license
  position is explicit: the software is provided `as is`, no warranty is
  given, and the project relies on the normal free-software liability
  disclaimer as the baseline protection for ordinary public distribution.
- Clarified that the disclaimer is still not unlimited and local law can
  matter, which keeps the documentation accurate instead of overstating the
  license as absolute protection in every jurisdiction.

## 3.59 - Fix nested installed skill nav discovery in the web UI

- Fixed shared skill-nav discovery so nested installed skill trees such as
  `skills/ho/skills/coverage/dashboards/nav/index.tt` now render their nav
  fragments on the nested skill route itself and also join the shared nav
  strip above normal saved pages such as `/app/index`.
- Fixed the skill dispatcher so global skill-nav collection now recurses
  through nested installed `skills/<repo>` trees in deterministic order while
  still skipping disabled nested skills during normal runtime lookup.
- Fixed layered skill-nav route-id discovery so `dashboards/nav/*` is walked
  recursively instead of only reading direct files from the first `nav/`
  directory. That keeps nested nav fragments addressable without flattening
  them back to one level.

## 3.58 - Fix installed shell-bootstrap drift, packaged helper discovery, and flaky post-build smart-router packaging checks

- Fixed dashboard-managed helper staging so each helper body now carries an
  explicit `developer-dashboard-managed-helper-version` marker. That makes it
  possible to distinguish a genuinely current installed helper from an older
  helper body that happens to share the same module version number, which is
  exactly the failure mode that hid the missing tmux ticket bootstrap on
  `hp.local`.
- Fixed Debian-family bash installs so dashboard-managed shell bootstrap lines
  are now written above the standard non-interactive `return` guards in
  `~/.bashrc`, including Ubuntu's single-line `[ -z "$PS1" ] && return`
  form. That keeps non-interactive shells such as tmux `#()` status commands
  able to resolve `dashboard`, which restores `dashboard ticket` indicator
  rendering on installed hosts such as `hp.local` instead of making the
  feature work only in fully interactive shells.
- Fixed `dashboard doctor` so it now audits that misplaced `~/.bashrc`
  bootstrap shape and repairs it with `dashboard doctor --fix` alongside the
  existing staged-helper drift repair path. This gives already-installed hosts
  a first-party self-heal path instead of forcing operators to reinstall or
  hand-edit their shell startup files.
- Fixed Windows `.cmd` and `.bat` launcher resolution so cross-platform hosts
  such as Linux, WSL, and packaged-install test environments normalize an
  extensionless local `cmd` helper in `PATH` back to `cmd.exe` instead of
  misclassifying it as a custom command processor. This keeps the expected
  Windows command-dispatch contract stable when tarball installs run on
  non-Windows packaging hosts that happen to expose a generic `cmd` shim.
- Fixed `dashboard doctor` so it now audits staged helper drift under
  `~/.developer-dashboard/cli/dd/`, reports stale or missing
  dashboard-managed helpers such as `_dashboard-core`, and can restage them
  with `dashboard doctor --fix` when the installed helper assets are current.
  This gives operators a first-party way to spot runtime helper skew instead
  of reverse-engineering mismatched `dashboard shell` and `dashboard ps1`
  behavior by hand.
- Fixed packaged helper asset discovery so tarball, PAUSE, and `cpanm`
  install-test trees now resolve `share/private-cli` from a stable absolute
  module source path captured at load time. Later `chdir` calls in
  long-running test or install processes no longer make the staged helper
  runtime look for `_dashboard-core` under the wrong working directory.
- Fixed the post-build smart-router two-stage Docker guard so one transient
  upstream `cpanm` fetch or unpack failure is retried once before the
  packaging gate is treated as a deterministic repository regression. This
  keeps a corrupt CPAN download from masquerading as a smart-router breakage
  in the built tarball.

## 3.45 - Fix stale Unix bootstrap target selection and missing tmux package installs

- Fixed Unix-like `install.sh` so blank streamed installs such as
  `curl ... | sh` no longer fall back to the stale
  `Developer::Dashboard` CPAN target when `DD_INSTALL_CPAN_TARGET` is unset.
  Checkout and extracted-tarball runs now install `.` directly, while
  streamed runs clone the current GitHub `master` checkout into a temporary
  local tree and install that checkout instead.
- Fixed the shipped Unix bootstrap package manifests so `aptfile`, `apkfile`,
  `dnfile`, and `brewfile` all install `tmux`, which keeps
  `dashboard ticket` available on blank machines without making operators
  guess a missing first-party dependency.
- Fixed blank Ubuntu bootstrap installs so the Debian-family package set now
  includes `libcrypt-dev`, preventing Perl XS dependencies such as
  `HTTP::Parser::XS`, `JSON::XS`, `YAML::XS`, and `Template::Toolkit` from
  failing with a missing `crypt.h` header during `cpanm`.

## 3.44 - Fix Docker-style progression ANSI detail colors

- Fixed `dashboard skills install` progression output so active rolling detail
  lines now render in blue and failed detail lines stay visible in red instead
  of leaving the Docker-style detail pane mostly uncolored while only the task
  marker changed color.

## 3.43 - Fix stale staged helper reuse across upgrades

- Fixed home-runtime helper staging so rerunning built-in helper extraction
  removes dashboard-managed older flat helpers from
  `~/.developer-dashboard/cli/` and keeps the active built-in helper surface
  converged on `~/.developer-dashboard/cli/dd/`.
- Fixed staged shell bootstrap regression coverage so the managed
  `dashboard shell bash` helper itself must emit the tmux ticket status
  bootstrap after staging instead of only checking the repo checkout command
  path.
- Fixed the blank-environment integration image so host-built tarball
  installs now include the native CPAN build packages required by
  `XML::Parser`, `Net::SSLeay`, and related transitive prerequisites before
  the installed-runtime smoke reaches the helper-staging checks.
- Fixed the blank-environment browser runtime so the integration image now
  uses a real Debian Chromium binary instead of the Ubuntu snap-wrapper
  launcher stub that could not run headless browser smoke checks inside the
  container.
- Fixed the host-side blank-environment launcher so it now rebuilds the
  integration image from the current Dockerfile before running the
  installed-runtime smoke, preventing cached older images from silently
  reintroducing the dead snap-wrapper browser path.

## 3.42 - Fix blank-mac bootstrap, container runtime isolation, and ticket tmux status layout

- Fixed blank new macOS bootstrap so `install.sh` now bootstraps Homebrew
  automatically when `brew` is missing instead of dying immediately with
  `Missing required command: brew`.
- Fixed Linux runtime lifecycle isolation so host-side `dashboard restart`
  and `dashboard stop` runs no longer kill or adopt Developer Dashboard web
  and collector pids that belong to another pid namespace such as a sibling
  Docker container.
- Fixed long-running skill dependency installs so manifest steps such as
  `brewfile`, `package.json`, `cpanfile`, and `Makefile` now stream a
  Docker-style rolling detail window under the active epic task while keeping
  the full task board visible.
- Fixed `dashboard ticket` tmux prompt/status handling so both fresh and
  already-existing ticket sessions suppress inline prompt indicators,
  move the full indicator strip into the first row of a two-line bottom
  tmux status block, keep tmux's normal indexed session/window row
  underneath it, preserve TT-backed percentage indicators and live
  collector values, and stop truncating the useful part of the indicator
  strip as aggressively.

## 3.40 - Move tmux prompt indicators into tmux status-right

- Fixed generated shell bootstraps so tmux sessions no longer leave collector
  indicators duplicated inside the inline shell prompt.
- Fixed tmux prompt rendering by moving indicator glyphs into tmux
  `status-right` through `dashboard ps1 --mode tmux-status` while the inline
  prompt stays focused on the cursor line.

## 3.37 - Guard Windows fresh PowerShell bootstrap and InternalCLI installed roots

- Fixed the release verification gap so the explicit coverage suite now proves
  the `InternalCLI` branch where `File::ShareDir` already returns the
  `private-cli` root itself.
- Fixed the release hygiene loop so the numeric `Devel::Cover` gate remains at
  `100.0 / 100.0 / 100.0` after the Windows bootstrap profile fixes.
- Fixed the Windows smoke gap so the streamed `irm .../install.ps1 | iex`
  verification now spawns a brand-new profile-loaded PowerShell session and
  proves that `dashboard`, `dashboard version`, and `dashboard logs` all work
  there without a manual PATH edit.

## 3.36 - Fix Windows self-contained PowerShell profile bootstrap

- Fixed the generated PowerShell profile block so fresh Windows sessions no
  longer send the multi-line `dashboard shell ps` output array directly into
  `Invoke-Expression`.
- Fixed the streamed Windows bootstrap so `irm .../install.ps1 | iex` now
  writes a self-contained profile block that restores `local::lib`, exposes
  `dashboard` on `PATH`, and activates the prompt bootstrap in future
  PowerShell sessions.

## 3.35 - Fix Windows shared helper root selection

- Fixed the installed private helper asset lookup on Windows so
  `dashboard init` no longer stops at an empty
  `MSWin32-x64-multi-thread/auto/Developer/Dashboard/private-cli`
  directory when the real shipped helper assets live under
  `auto/share/dist/Developer-Dashboard/private-cli`.
- Fixed the streamed Windows checkout bootstrap so a blank host can now
  finish `dashboard init` after `irm .../install.ps1 | iex`, stage the home
  helper runtime, and continue into the generated PowerShell shell bootstrap
  cleanly.

## 3.34 - Fix Windows helper staging bootstrap lookup

- Fixed the installed private helper asset lookup so Windows local::lib
  installs no longer look for `_dashboard-core` under the wrong arch-auto
  path when the shared dist asset root actually lives under
  `auto/share/dist/Developer-Dashboard/private-cli`.
- Fixed the streamed PowerShell bootstrap so `install.ps1` now runs
  `dashboard init` before activating `dashboard shell ps` in the current
  shell, ensuring the staged home helper runtime exists before the bootstrap
  asks for PowerShell shell wiring.
- Fixed the generated PowerShell profile guard so new sessions only ask
  `dashboard shell ps` for bootstrap output after the staged home helper
  runtime exists under `~/.developer-dashboard/cli/dd/_dashboard-core`.

## 3.33 - Fix streamed Windows install bootstrap path

- Fixed the packaged install metadata so end-user installs no longer pull
  `Plack::Test` and `Test::Pod` through the `Developer::Dashboard` test
  prerequisite path.
- Fixed the streamed Windows bootstrap path so blank hosts no longer fail with
  `Module 'Test::SharedFork' is not installed` while running
  `irm .../install.ps1 | iex`.
- Fixed the PSGI-facing repository tests by replacing the `Plack::Test`
  dependency with a local harness under `t/lib`, keeping the shipped metadata
  focused on real runtime requirements.
- Fixed the Windows install bootstrap docs so the public examples use the
  `install.ps1` entrypoint and describe the lighter packaged install path.
- Fixed the streamed Windows checkout bootstrap so the default GitHub checkout
  install now uses a Windows-safe `Makefile.PL` version path and no longer
  fails during `cpanm --notest .` with
  `Could not open 'lib/Developer::Dashboard.pm': Invalid argument`.
- Fixed the managed helper staging path so a zero-byte
  `~/.developer-dashboard/cli/dd/_dashboard-core` is repaired automatically
  instead of being preserved as if it were a user helper, restoring thin CLI
  commands such as `dashboard encode`.
- Fixed the PowerShell bootstrap so `install.ps1` now sets the CurrentUser
  execution policy to `RemoteSigned` before writing the generated profile,
  allowing new PowerShell sessions to load the `dashboard shell ps`
  bootstrap instead of failing with `running scripts is disabled`.
- Fixed the generated PowerShell profile block so `PERL_MB_OPT` no longer uses
  nested literal quotes that break new sessions with
  `Unexpected token '$ddInstallRoot""'`.

## 3.30 - Streamed PowerShell bootstrap native-output fix

- Fixed the streamed Windows bootstrap so native `winget` command output is
  written to the host terminal instead of leaking into the PowerShell return
  stream of helper functions.
- Fixed the `irm .../install.ps1 | iex` path so the Strawberry Perl package
  bootstrap now passes a single resolved Perl path string into the PATH setup
  step instead of contaminating that parameter with `winget` console output.
- Fixed the Windows Perl bootstrap so `install.ps1` no longer tries to
  self-install `App::cpanminus` while the downloaded `cpanm` bootstrap script
  is still running, avoiding the Windows file-replacement failure that broke
  the `local::lib` setup step on blank hosts.
- Fixed the public bootstrap examples so the canonical streamed PowerShell
  command now uses the exact
  `https://raw.githubusercontent.com/manif3station/developer-dashboard/refs/heads/master/install.ps1`
  URL.

## 3.28 - Windows bootstrap filename and winget source repair

- Fixed the public Windows checkout bootstrap entrypoint so the canonical file
  is now `install.ps1` instead of the atypical `install.ps`, keeping the
  streamed `irm ... | iex` operator flow aligned with normal PowerShell script
  naming.
- Fixed the Windows bootstrap `winget` path so Git, Strawberry Perl, and
  Node.js installs are pinned to the community `winget` source instead of
  implicitly touching every configured source.
- Fixed the Windows bootstrap error handling so a broken `msstore` source now
  triggers one `winget source reset --force` plus source refresh retry and, if
  that still fails, the installer reports the failing HRESULT-style exit code
  instead of only a raw negative integer.

## 3.27 - Windows checkout bootstrap installer

- Fixed the checkout bootstrap story on Windows by adding a repo-root
  `install.ps1` entrypoint that can be run directly from PowerShell or streamed
  through `irm ... | iex`.
- Fixed the Windows bootstrap flow so it now provisions missing Git,
  Strawberry Perl, and Node.js LTS packages through `winget`, bootstraps
  `cpanm`, installs Developer Dashboard with `cpanm --notest`, activates the
  PowerShell shell bootstrap, and runs `dashboard init`.
- Fixed the release metadata and integration asset guards so the Windows
  bootstrap installer must stay documented, packaged in the tarball, and kept
  out of the CPAN-installed script namespace.

## 3.26 - Blank-container tarball install policy alignment

- Fixed the blank-container tarball gate so it now installs the built release
  tarball with `cpanm --notest` only after the normal source-tree `prove -lr t`
  and explicit numeric `Devel::Cover` gates have already passed.
- Fixed the integration plan, release workflow notes, and integration asset
  guards so the repo no longer treats `cpanm --notest` as a Windows-only
  exception for the packaged tarball install path.
- Fixed the blank-environment integration runner so its packaged tarball
  install step follows the same `cpanm --notest` policy as the documented
  release flow.

## 3.25 - Installed web route parity for skill-local namespaces

- Fixed the installed Dancer web route layer so `/ajax/<repo>/...` and
  nested child-skill Ajax paths no longer bypass the smart skill router and
  incorrectly fall through to `Ajax handler not found`.
- Fixed the installed Dancer web route layer so `/js/<repo>/...`,
  `/css/<repo>/...`, and `/others/<repo>/...` now use the same longest-prefix
  skill route resolution as the backend app instead of only checking the
  global saved public roots.
- Fixed the installed Dancer web route layer so `/app/<repo>/...` and nested
  child-skill bookmark routes stay aligned with the backend smart skill route
  fallback instead of dropping into the blank editor path for installed skill
  pages.
- Added live PSGI regressions for top-level and nested `/app`, `/ajax`,
  `/js`, `/css`, and `/others` skill-local routes so future smart-router work
  has to pass the installed route layer too, not just direct backend unit
  dispatch.
- Fixed the blank-editor helper-login path so the root editor now keeps the
  helper request context and still renders helper chrome, including the logout
  link and helper username, during installed blank-environment integration
  runs.
- Fixed the release process so the extracted-dashboard smart-router regression
  now has an explicit post-build guardrail in `t/44-smart-router-two-stage.t`
  and the host integration launcher runs it immediately after `dzil build`
  before the larger blank-environment flow starts.

## 3.24 - Skill-local route namespaces and nested skill asset routing

- Fixed skill-local bookmark pages so `Ajax(file => ...)` inside
  `~/.developer-dashboard/skills/<repo>/dashboards/...` now emits stable saved
  endpoints under `/ajax/<repo>/...` instead of falling back to transient
  tokenized `/ajax?token=...` URLs.
- Fixed `/ajax`, `/js`, `/css`, and `/others` so they now prefer the longest
  installed skill prefix, including nested child skills under
  `skills/<repo>/...`, before treating the remaining path as the handler or
  asset path.
- Fixed the ambiguous route case where a normal nested saved-bookmark asset or
  saved Ajax file starts with the same segment as an installed skill name, so
  Developer Dashboard now falls back to the global nested file instead of
  incorrectly returning `404`.
- Fixed nested child skill URL generation so names like
  `/ajax/<repo>/<sub-skill>/...` are emitted as real path segments instead of
  URL-encoding the slash into a single `%2F` segment.

## 3.23 - README source-of-truth and sync guardrails

- Fixed the release process so `README.md` is no longer treated as a second
  hand-edited manual that can drift away from the canonical
  `Developer::Dashboard` POD.
- Fixed the release metadata gate so it now checks that the tracked
  `README.md` exactly matches the Markdown generated by the checkout sync
  helper from the canonical POD source.
- Fixed the JS fast-check test harness so newer `npm` update-notifier messages
  no longer fail the stderr-clean fuzz gate even when the property tests
  themselves are green.

## 3.22 - README.md format regression

- Fixed the shipped `README.md` so it is Markdown again instead of an accidental
  POD copy.
- Fixed the release metadata gate so it now fails if `README.md` starts with POD
  markers such as `=pod` or `=head1`.

## 3.21 - Final extracted dashboard prune cleanup

- Fixed the public `dashboard` POD examples so core no longer mentions the
  extracted API Dashboard by name.
- Fixed the release-metadata gate so it now fails if core code, docs, POD,
  tests, or shipped assets reintroduce `API Dashboard` or `SQL Dashboard`
  names after extraction.

## 3.20 - Root ddfile first-install status reporting

- Fixed `dashboard skills install` so sources listed only in the home root
  `~/.developer-dashboard/ddfile` are reported as `installed` on their first
  successful bare update-all run even when the skill does not ship `.env`
  `VERSION` metadata.
- Fixed the progress rundown and default summary table so first-time
  root-`ddfile` installs no longer claim `unknown (- -> -)` after a
  successful install.
- Fixed `dashboard stop collector NAME` so the default table summary still
  reports the named stopped collector when the managed loop is alive but its
  process title has not become observable yet.

## 3.19 - Optional browser workspace extraction from core

- Fixed the core/runtime boundary so the default Developer Dashboard
  distribution no longer claims, seeds, or ships an optional browser workspace
  that has been moved out of core.
- Fixed the shipped manuals, release metadata, and test guides so they now
  describe only the browser pages and verification paths that still belong to
  the core distribution.

## 3.19 - Container restart and stop listener ownership

- Fixed `dashboard stop` and `dashboard restart` so they can still find and
  terminate the real serving pid after the managed web process renames itself
  into the underlying `starman master` listener shape.
- Fixed container lifecycle control so saved web-state listener ports are used
  to recover the active listener pid, preventing Docker runs from leaving the
  web listener behind or losing restart ownership after startup.
