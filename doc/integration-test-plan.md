# Blank Environment Integration Test Plan

## Purpose

This plan validates that `Developer::Dashboard` can be built with `Dist::Zilla`
on the host, installed into a clean container from that built tarball, and
exercised there as an installed CLI and
web application rather than as a checkout-local script.

The goal is to prove that a new environment can:

- build the CPAN distribution tarball on the host from the repo
- install the built tarball with `cpanm`
- run the installed `dashboard` command successfully
- initialize runtime state in a fake project
- execute the major CLI surfaces through installed binaries against that fake project
- start and stop the web service
- exercise helper login and helper logout cleanup
- verify browser-facing editor and saved fake-project bookmark pages in a real headless browser
- verify the environment-variable project override flow works end to end

## Scope

The integration run covers these command families:

- host packaging: `dzil build`
- installation: `cpanm <tarball>`
- bootstrap: `dashboard init`, user-provided `dashboard update`
- help and prompt: `dashboard`, `dashboard help`, `dashboard ps1`, `dashboard shell bash`, `dashboard shell ps`
- paths: `dashboard paths`, `dashboard path list`, `dashboard path resolve`, `dashboard path project-root`
- encoding: `dashboard encode`, `dashboard decode`
- indicators: `dashboard indicator set`, `dashboard indicator list`, `dashboard indicator refresh-core`
- collectors: `dashboard collector write-result`, `run`, `list`, `job`, `status`, `output`, `inspect`, `log`, `start`, `restart`, `stop`
- config: `dashboard config init`, `dashboard config show`
- auth: `dashboard auth add-user`, `list-users`, `remove-user`
- pages: `dashboard page new`, `save`, `list`, `show`, `encode`, `decode`, `urls`, `render`, `source`
- actions: `dashboard action run system-status paths`
- docker resolver: `dashboard docker compose --dry-run`
- web lifecycle: `dashboard serve`, `dashboard restart`, `dashboard stop`
- browser checks: headless Chromium editor, saved fake-project bookmark page, outsider bootstrap DOM verification, and helper-login DOM verification after helper-user enablement
- ajax streaming: installed long-running `/ajax/<file>` route timing, early-chunk verification, refresh-safe singleton replacement, `fetch_value()` / `stream_value()` DOM helper coverage, and browser pagehide cleanup coverage in unit tests
- windows verification assets: `integration/windows/run-strawberry-smoke.ps1` and `integration/windows/run-qemu-windows-smoke.sh`

## Environment

The test container should be intentionally minimal:

- base image: official Perl runtime image
- no preinstalled Developer Dashboard
- only generic build, browser, and HTTP tooling added
- a temporary `HOME` so the installed app must bootstrap itself from scratch
- no requirement that `ss` or other iproute2 tools exist inside the image

The repo checkout is not mounted into the container as the app under test.
Only the host-built tarball is mounted into the blank container.

## Test Data

The integration run creates:

- a temporary home directory under `/tmp`
- a fake project root under `/tmp/fake-project`
- a fake project `./.developer-dashboard` tree with `dashboards`, `config`, and `cli` directories
- a saved page named `sample`
- a saved bookmark page named `project-home`
- a saved stream regression bookmark page
- shared nav bookmark pages under `nav/*.tt`
- a helper user for explicit add/remove testing
- a second helper user for browser login/logout cleanup testing
- a temporary Compose project under `/tmp`

## Execution Flow

1. Build the distribution tarball on the host with `dzil build`.
2. Start the blank container with only that host-built tarball mounted into it.
3. Install the mounted tarball with `cpanm`.
4. Create the fake-project `./.developer-dashboard` tree only after that install step succeeds so the tarball's own tests still run against a clean runtime.
5. Extract the same tarball inside the container for the rest of the installed-command checks.
6. Verify the installed CLI responds to `dashboard help`.
7. Verify bare `dashboard` returns usage output.
8. Verify `dashboard version` reports the installed runtime version.
9. Create a fake project root with a local `./.developer-dashboard` runtime tree.
10. Run `dashboard init` from inside that fake project and confirm the project-local runtime roots plus `welcome`, `api-dashboard`, and `sql-dashboard` starter pages exist.
11. Browser-check the seeded `api-dashboard` page from that fake project and confirm the Postman-style shell shows the collection tabs, request tabs, request-token form for `{{token}}` placeholders, the hide/show request-credentials panel with the supported auth presets, import/export controls, any `./.developer-dashboard/config/api-dashboard/*.json` collections loaded on startup, and the project-local `config/api-dashboard` directory plus saved collection files tightened to `0700` / `0600`.
11.1. When an `api-dashboard` import bug only reproduces with a real external Postman file, run `API_DASHBOARD_IMPORT_FIXTURE=/path/to/collection.postman_collection.json prove -lv t/23-api-dashboard-import-fixture-playwright.t` on the host to verify that the visible browser import control can load the fixture, render the collection in the Collections tab, and persist the Postman JSON under `config/api-dashboard`.
11.2. When changing the `api-dashboard` layout, run `prove -lv t/24-api-dashboard-tabs-playwright.t` on the host to verify the top-level Collections/Workspace tabs, the collection tab strip, and the inner Request Details/Response Body/Response Headers tabs below the response `pre` in a real browser.
11.3. When changing `api-dashboard` import transport or saved-Ajax payload handling, run `prove -lv t/25-api-dashboard-large-import-playwright.t` on the host to verify that a deliberately oversized Postman collection still imports through the visible browser control without tripping the saved-Ajax argument-size limit.
12. Browser-check the seeded `sql-dashboard` page from that fake project and confirm the profile tabs, merged `SQL Workspace` tab, workspace left-nav collection tabs plus the active collection's saved SQL list, visible active saved-SQL label, large auto-resizing editor, quiet action row beneath that editor, inline `[X]` delete affordances in the saved-SQL list, schema explorer reached through the top tab, shareable `connection` URL state, any `./.developer-dashboard/config/sql-dashboard/*.json` profiles loaded on startup, any `./.developer-dashboard/config/sql-dashboard/collections/*.json` SQL collections loaded on startup, both sql-dashboard directories tightened to `0700`, saved profile/collection files tightened to `0600`, the installed-driver dropdown rewrites only the `dbi:<Driver>:` DSN prefix, saving a second SQL name into one collection creates another saved SQL entry instead of overwriting the selected one, and a shared URL without a locally saved password rebuilds a draft connection profile instead of leaking a password.
13. Exercise `dashboard cpan DBD::Driver` inside the fake project and confirm the requested driver plus `DBI` are installed into `./.developer-dashboard/local` and recorded in `./.developer-dashboard/cpanfile`.
14. Seed a user-provided fake-project `./.developer-dashboard/cli/update` command plus `update.d` hooks in the clean container, run `dashboard update`, and confirm the normal top-level command-hook pipeline completes, including later-hook reads through `Runtime::Result`.
15. Exercise path, prompt, shell, encode/decode, and indicator commands.
16. Exercise collector write/run/read/start/restart/stop flows, including fake-project config collector definitions.
17. Restart the installed runtime with one intentionally broken Perl config collector and one healthy config collector, then verify the broken collector reports an error without stopping the healthy collector or its green indicator state, even when prompt/browser status refreshes run during the restart window.
18. Exercise page create/save/show/encode/decode/render/source flows inside the fake bookmark directory.
19. Exercise builtin action execution.
20. Exercise docker compose dry-run resolution against a temporary project.
21. Start the installed web service.
22. Confirm exact-loopback access reaches the editor page in Chromium.
23. Confirm the browser can render a saved fake-project bookmark page from the fake project bookmark directory.
24. Confirm the browser inserts sorted rendered `nav/*.tt` bookmark fragments between the top chrome and the main page body.
25. Confirm the browser top-right status strip shows configured collector icons, not collector names, that UTF-8 icons such as `🐳` and `💰` are visibly rendered, and that renamed collectors no longer leave stale managed indicators behind.
26. Confirm an installed saved bookmark page can declare `var endpoints = {};`, then use `fetch_value()` and `stream_value()` from `$(document).ready(...)` against saved `/ajax/<file>` routes without inline-script ordering failures or browser console `ReferenceError`s.
27. Confirm an installed long-running saved `/ajax/<file>` route starts streaming the first output chunks promptly instead of buffering until the worker exits.
28. Confirm non-loopback self-access returns `401` with an empty body and without a login form before any helper user exists in the active runtime.
29. Add a helper user for the outsider browser flow, then confirm non-loopback self-access reaches the helper login page in Chromium.
30. Log in as a helper through the HTTP helper flow.
31. Confirm helper page chrome shows `Logout`.
32. Log out and confirm the helper account is removed.
33. Restart the installed runtime from the extracted tarball tree and confirm the web service comes back.
34. Stop the runtime and confirm the web service is gone.

## Expected Results

- every covered command exits successfully except bare `dashboard`, which should
  return usage with a non-zero status
- `dashboard version` reports the installed release version
- `dashboard init` creates starter state without requiring manual setup
- `dashboard update` succeeds in the container from a user-provided fake-project `./.developer-dashboard/cli/update` command through the normal command-hook path
- the installed `dashboard` binary works without `perl -Ilib`
- the fake project's `./.developer-dashboard` tree becomes the active local runtime root with the home tree as fallback
- a broken config Perl collector reports an error without stopping other configured collectors
- a healthy config collector still reports `ok` and stays green in `dashboard indicator list`, `dashboard ps1`, and `/system/status`, without being clobbered back to `missing` by concurrent config-sync refreshes
- the web service serves the root editor on `127.0.0.1:7890`
- the browser can load both the editor and a saved fake-project bookmark page from the fake project bookmark directory
- the browser sees sorted shared `nav/*.tt` fragments above the main page body on that fake-project bookmark page
- the browser top-right status strip shows configured collector icons and does not leave stale renamed collector indicators behind
- bookmark pages can use `fetch_value()`, `stream_value()`, and `stream_data()` helpers against saved `/ajax/...` endpoints on first render
- the installed `/ajax/<file>` route streams early output chunks promptly enough to prove browser-visible progress instead of silent buffering
- non-loopback access produces `401` with an empty body and without a login page until a helper user exists in the active runtime
- under `dashboard serve --ssl`, plain `http://HOST:PORT/...` requests on the public listener return a same-port `307` redirect to `https://HOST:PORT/...`, and a browser then reaches the expected self-signed certificate warning instead of a reset connection
- after a helper user exists, non-loopback access produces the helper login page
- helper logout removes both the helper session and the helper account
- `dashboard stop` leaves no active listener on port `7890`
- runtime stop/restart behavior still works when listener ownership must be
  discovered through `/proc` instead of `ss`
- `dashboard restart` also succeeds when a listener pid survives the first stop
  sweep and must be discovered by a late port re-probe

## Out Of Scope

These are not treated as failures for this blank-environment run:

- outbound integrations not implemented by the current core
- actual privileged Docker daemon execution inside the container

The docker command family is validated through `--dry-run`, which is enough to
prove that the installed CLI resolves the compose stack correctly in a clean
environment.

## Invocation

For a quick host-side bookmark browser repro before the full blank-environment
container cycle, run:

```bash
integration/browser/run-bookmark-browser-smoke.pl
```

That script is the fast path for saved bookmark browser issues such as static
asset loading, bookmark Ajax binding, and final DOM rendering checks.

For Windows verification outside the Linux container flow, run the checked-in
Strawberry Perl smoke on a Windows host:

```powershell
powershell -ExecutionPolicy Bypass -File integration/windows/run-strawberry-smoke.ps1 -Tarball C:\path\Developer-Dashboard-1.46.tar.gz
```

For release-grade Windows compatibility claims, run the same smoke through the
prepared QEMU Windows guest:

```bash
WINDOWS_IMAGE=/var/lib/vm/windows-dev.qcow2 \
WINDOWS_SSH_USER=developer \
WINDOWS_SSH_KEY=~/.ssh/id_ed25519 \
TARBALL=/path/to/Developer-Dashboard-1.46.tar.gz \
integration/windows/run-qemu-windows-smoke.sh
```

Build the tarball on the host and run the integration harness with:

```bash
integration/blank-env/run-host-integration.sh
```

The harness expects the prebuilt integration image `dd-int-test:latest` to
exist locally and mounts the host-built tarball into that container.

## Pass Criteria

The run passes when:

- the container exits `0`
- the app under test comes only from the host-built tarball
- the installed `dashboard` CLI completes the scripted fake-project flow from the mounted tarball install
- Chromium verifies the editor, saved bookmark page, outsider disabled-access page, and helper login page
- the web lifecycle and helper browser flow behave as expected
