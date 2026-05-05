# Fixed Bugs

## 3.41 - Fix blank-mac bootstrap, container runtime isolation, and skill install live detail

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
- Fixed tmux prompt/status handling so only `dashboard ticket` tmux sessions
  move indicators into a session-local two-line tmux status area, ordinary
  tmux sessions keep the normal inline prompt, the trailing date-time segment
  is restored, the inline prompt stops duplicating status-line indicators in
  ticket sessions, live collector indicator values stop flickering back to
  config placeholders, and long indicator sets get a dedicated full-width
  status line instead of being squeezed into one `status-right` fragment.

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
