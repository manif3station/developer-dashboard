# Fixed Bugs

## 2026-03-30

- Fixed test-fixture hygiene by replacing the remaining dummy helper login passphrases in tests, integration assets, and POD examples with neutral placeholder values.
- Fixed helper chrome drift by showing the authenticated helper username in the top-right user marker instead of always rendering the local system account.
- Fixed Devel::Cover harness drift by making the daemon-style collector loop tests coverage-safe instead of letting covered child processes break TAP completion in `t/07-core-units.t`.
- Fixed collector-loop coverage gaps by adding direct wrapped-fork and child-dispatch tests for `Developer::Dashboard::CollectorRunner` so the full `lib/` report returns to 100% statement and subroutine coverage.

## 2026-03-29

- Fixed integration-plan drift by extending the blank-container test plan to require browser-backed verification and fake-project environment overrides instead of only CLI smoke coverage.
- Fixed integration-browser drift by installing Chromium in the blank-environment container and using it to verify the editor, saved fake-project bookmark page, and helper login page.
- Fixed fake-project flow drift by wiring the integration runner through `DEVELOPER_DASHBOARD_BOOKMARKS`, `DEVELOPER_DASHBOARD_CONFIGS`, and `DEVELOPER_DASHBOARD_STARTUP` and verifying that installed dashboard commands honor those overrides.
- Fixed integration-invocation drift by requiring the host-built tarball flow through `integration/blank-env/run-host-integration.sh` and `docker compose ... run --build --rm blank-env`.
- Fixed artifact-isolation drift by mounting only the host-built tarball into the blank container instead of mounting the live repo source as the app under test.
- Fixed update-path drift in the blank-container run by extracting the mounted tarball inside the container so `dashboard update` runs from built artifact contents.
- Fixed legacy naming drift by adding `bookmarks` and `bookmarks_root` path aliases for integration and user compatibility.
- Fixed release-confidence gaps by adding a clean-container integration harness that builds with Dist::Zilla, installs with cpanm, and exercises the installed dashboard CLI.
- Fixed deployment-validation gaps by documenting a comprehensive blank-environment integration test plan for the installed runtime.
- Fixed CPAN packaging drift by excluding the checked-in `Makefile.PL` from `GatherDir` so `dzil build` no longer aborts on duplicate `Makefile.PL` output.
- Fixed built-tarball dependency drift by enabling `AutoPrereqs` so an installed `dashboard` binary pulls in runtime modules such as `Template`.
- Fixed installed CLI source resolution so `dashboard page source welcome` and similar saved bookmark ids are not misclassified as transient tokens.
- Fixed helper logout drift by adding a helper-only Logout link in the page chrome instead of showing it to exact-loopback admin views.
- Fixed helper logout cleanup so logging out now removes both the active helper session and the helper account itself.
- Fixed editor workflow drift by removing the manual Update button and restoring the old textarea change/blur auto-submit behavior.
- Fixed machine-address drift by discovering the machine IP from the active interfaces instead of echoing the request host into the top-right chrome.
- Fixed clock drift by making the top-right date and time update live in the browser instead of staying frozen at the initial render.
- Fixed top-right chrome drift by restoring the old local user, host/IP, and date-time context alongside the page status strip.
- Fixed Docker indicator alias drift by restoring the old page-header style of `🟢🐳` instead of `🟢Docker`.
- Fixed page-header indicator drift by restoring the original `status + alias` model from `Playground.pm` instead of using prompt icons or prompt ordering.
- Fixed top-chrome drift by restoring the old indicator-strip behavior instead of rendering the full shell prompt at the top of bookmark pages.
- Fixed title-render drift by keeping bookmark `TITLE:` values in the HTML `<title>` element only instead of also injecting them into the page body.
- Fixed runtime-isolation drift by switching legacy `CODE*` execution to one throwaway sandpit package per page run, matching the old cleanup model more closely.
- Fixed bookmark-format drift by restoring the original `KEY:` plus `:--------------------------------------------------------------------------------:` file structure as the canonical bookmark source format.
- Fixed directive drift by removing synthetic bookmark directives from saved bookmark serialization and returning to the old directive set.
- Fixed rendering drift by switching `HTML:` and `FORM.TT:` processing to Template Toolkit with `stash`, `ENV`, and `SYSTEM` available in templates.
- Fixed legacy runtime drift so `CODE*` blocks now render captured `STDOUT` into the page and display captured `STDERR` as visible runtime errors.
- Fixed editor drift by adding live section highlighting for bookmark directives, HTML blocks, and Perl `CODE*` blocks while editing.
- Fixed editor interaction drift by moving syntax highlighting into the same editing surface instead of a separate side preview.
- Fixed transient-token test coverage drift by escaping transient page tokens in the browser-facing tests to match real query-string transport.

## 2026-03-27

- Fixed constructor state loss in `Developer::Dashboard::CollectorRunner` where `files` and `paths` were not reliably stored, breaking collector execution.
- Fixed constructor state loss in `Developer::Dashboard::Web::Server` where `host` and `port` were not reliably stored, breaking explicit server binding.
- Fixed shell bootstrap generation so `\j` is preserved literally for bash `PS1` instead of being interpolated by Perl.
- Fixed duplicate results from project path discovery by deduplicating `locate_projects` output across configured roots.
- Fixed update-script shell bootstrap directory creation by creating nested config directories before writing bootstrap files.
- Fixed dependency refresh update script so it uses `which cpanm` instead of trying to execute the shell builtin `command`.
- Fixed environment customization gaps by adding support for `DEVELOPER_DASHBOARD_BOOKMARKS`, `DEVELOPER_DASHBOARD_CHECKERS`, `DEVELOPER_DASHBOARD_CONFIGS`, and `DEVELOPER_DASHBOARD_STARTUP`.

## 2026-03-28

- Fixed route-model drift by replacing the landing page at `/` with the old free-form bookmark editor.
- Fixed default-bookmark drift by restoring `/apps -> /app/index` compatibility.
- Fixed page-chrome drift by rendering shared share/source links and prompt-style status at the top of edit and render pages.
- Fixed editor drift by making the web textarea post raw instruction text back through `/` again.

- Fixed helper-auth hardening gaps by enforcing username validation, minimum password length, and `0600` permissions on persisted user records.
- Fixed session hardening gaps by expiring helper sessions automatically, binding them to the originating remote address, and storing them with `0600` permissions.
- Fixed web-response hardening gaps by adding CSP, no-store, frame-deny, nosniff, no-referrer, and no-store headers to the local HTTP server.
- Fixed documentation hygiene by removing literal password examples and replacing them with placeholders.
- Fixed repository hygiene outside `OLD_CODE` by confirming the active tree is clear of the banned company-specific references.

- Fixed old bookmark route drift by adding generic `/app/<name>` forwarding for saved bookmark files and saved URL bookmark entries.
- Fixed old ajax compatibility drift by adding a generic `/ajax` token execution path in the new dashboard runtime.
- Fixed legacy helper drift by restoring project-neutral `Ajax`, `acmdx`, `j`, `je`, `Folder`, and `File` compatibility surfaces for bookmark code blocks.
- Fixed legacy parser drift by accepting lowercase `code1:` style sections instead of only uppercase `CODE1:`.
- Fixed the real `api` bookmark compatibility gap so the new runtime now generates the legacy `configs.collections.all` and `configs.send.request` endpoint bindings during render.

- Fixed old-Playground feature drift by supporting both legacy bookmark syntax and the modern section syntax in the page engine.
- Fixed legacy rendering gaps by adding placeholder expansion for `HTML`, `FORM`, and `FORM.TT` content before page render.
- Fixed legacy runtime gaps by adding trusted `CODE*` execution with stash merge and captured output for saved/provider pages.
- Fixed transient trust drift by keeping legacy `CODE*` blocks disabled for transient encoded pages unless explicitly enabled.
- Fixed documentation drift that still claimed the old bookmark syntax required a future importer even after compatibility support was added.

- Fixed stale documentation examples that still showed the pre-simplification `dashboard auth add-user <user> <pass> <role>` shape instead of the current two-argument form.
- Fixed coverage blind spots in action trust fallbacks, page resolver saved-page listing, cron scheduling branches, prompt context rendering, and docker compose execution paths so `lib/` is back to 100% statement and subroutine coverage.
- Fixed local repository hygiene by ignoring the `.perl5/` toolchain directory used for local Devel::Cover installs.

- Fixed page-model drift by replacing JSON-first saved and transient page storage with canonical instruction documents as required by the spec.
- Fixed page runtime-state drift by merging query parameters, form submissions, and request context into page state before render and action execution.
- Fixed action-transport drift by adding a separate encoded action payload path instead of relying only on page-token-plus-action-id routing.
- Fixed collector-runtime drift by adding timeout and env handling plus cron-style schedule support to managed collector execution.
- Fixed collector-inspection gaps by persisting combined output and exposing job/output/status inspection data through the CLI and storage layer.
- Fixed prompt-feature drift by adding compact and extended prompt modes, ANSI color support, and stale indicator rendering.
- Fixed indicator-feature drift by adding generic built-in indicator refresh for Docker, Git, and project context.
- Fixed docker-compose layering drift by exposing explicit project, service, addon, and mode overlay precedence in the resolver output.
- Fixed repo rule drift by adding function-level purpose/input/output comments across the Perl codebase and POD trailers across scripts, modules, update scripts, and tests.
- Fixed `Developer::Dashboard::Collector::read_output` so empty stdout and stderr files are read in scalar context and do not collapse hash keys.
- Fixed checker filtering semantics to match the legacy colon-separated `DEVELOPER_DASHBOARD_CHECKERS` contract exactly.
- Fixed repository hygiene by removing legacy company-specific code and embedded sensitive material before open-source publication.
- Fixed collector deduplication so pid files are trusted only when the live process title matches the managed `dashboard collector: <name>` convention.
- Fixed collector shutdown so unrelated foreign processes are no longer terminated just because a stale pid file exists.
- Fixed updater restart detection so it uses validated running loop state instead of blindly trusting every `*.pid` file.
- Fixed `Developer::Dashboard::Web::App` constructor state loss so `pages` and `sessions` are retained alongside `auth` and request routing does not collapse at runtime.
- Fixed the web server request bridge so the app receives method, host, cookie, request body, and peer address, enabling the local-admin versus helper security split.
- Fixed response handling so redirect-style headers such as `Location` and `Set-Cookie` are preserved when the app returns them.
- Fixed JSON implementation drift by replacing remaining `JSON::PP` usage with `JSON::XS`, including the shell bootstrap path used by `dashboard shell bash`.
- Fixed top-level documentation drift by bringing `README.md` and the `Developer::Dashboard` POD back into sync for the current command set and auth model.
- Fixed command-capture drift by replacing remaining backtick and `qx{}` paths with `Capture::Tiny` in the runtime, update scripts, and smoke tests.
- Fixed Capture::Tiny usage drift by removing the last `capture_merged` calls and standardizing on `capture` as required by the repo rules.
- Fixed capture exit handling drift by returning exit codes from the `capture` block itself instead of reading `$?` separately afterward.
- Fixed default listen-address friction by changing `dashboard serve` to bind all interfaces by default while keeping helper gating in the request trust logic.
- Fixed web-service lifecycle drift by making `dashboard serve` run as a managed background service by default and adding matching stop/restart control paths.
- Fixed shutdown reliability so web and collector stop operations no longer depend on pid files alone and can fall back to `pkill`-style managed-process scans.
- Fixed legacy web-process detection so older plain `dashboard serve` perl listeners are now discovered and terminated by `dashboard stop` and `dashboard restart`.
- Fixed false web-process deduplication so `dashboard serve` no longer treats the invoking shell command, tracing wrappers, or its own current process as an already running web service.
- Fixed plugin discovery by correcting the duplicate-file guard so first-seen plugin JSON files are actually loaded.
- Fixed Docker Compose resolution by correcting the duplicate-file guard so discovered compose files and overlays survive into the final stack.
