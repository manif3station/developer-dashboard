# Architecture

Developer Dashboard is a project-neutral local developer runtime.

## Core Services

- `Developer::Dashboard::PathRegistry`
  Resolves logical directories such as runtime, cache, logs, dashboards, collectors, and indicators.

- `Developer::Dashboard::FileRegistry`
  Resolves logical files such as config and logs on top of the path registry.

- `Developer::Dashboard::JSON`
  Centralizes JSON encoding and decoding through `JSON::XS`.

- `Capture::Tiny`
  Captures external command output for collectors, updater scripts, and smoke-test command execution.

- `Developer::Dashboard::PluginManager`
  Loads JSON-based extension packs from global and repo-local plugin directories.

- `Developer::Dashboard::ActionRunner`
  Executes built-in actions and trusted command actions with cwd, env, timeout, background support, and encoded action payload transport.

- `Developer::Dashboard::Collector`
  Stores collector output atomically as file-backed state.

- `Developer::Dashboard::CollectorRunner`
  Runs configured collector jobs once or in loops, persists outputs, records loop metadata, supports timeout/env and cron-style schedules, and validates managed background processes by pid plus process title.

- `Developer::Dashboard::RuntimeManager`
  Starts the web service in the background, stops or restarts both web and collectors, and falls back to `pkill` plus process scanning instead of trusting pid files alone.

- `Developer::Dashboard::IndicatorStore`
  Stores prompt/dashboard indicators as file-backed state and can refresh generic built-in indicators.

- `Developer::Dashboard::Auth`
  Manages helper users and enforces the exact-loopback trust tier.

- `Developer::Dashboard::SessionStore`
  Stores helper browser sessions as file-backed state.

- `Developer::Dashboard::Prompt`
  Renders `PS1` output from cached indicator state in compact or extended mode, with optional color and stale-state marking.

- `dashboard`
  Canonical command-line entrypoint for runtime, page, collector, prompt, and user CLI extension operations.

- `dashboard of` / `dashboard open-file`
  Resolve direct files, `file:line` references, Perl module names, Java class names, and recursive file-pattern matches below a resolved scope, then print or exec the configured editor.

- `dashboard pjq` / `dashboard pyq` / `dashboard ptomq` / `dashboard pjp`
  Parse JSON, YAML, TOML, and Java properties input and optionally traverse a dotted path before printing a scalar or canonical JSON. File-path and query-path argument order is interchangeable, and `$d` selects the full parsed document.

- standalone `of` / `open-file` / `pjq` / `pyq` / `ptomq` / `pjp`
  Are installed as direct executables as well as proxied `dashboard` subcommands, so common CLI flows can avoid loading the full dashboard runtime.

- `Developer::Dashboard::PageDocument`
  Canonical page model for saved, transient, and legacy bookmark pages.

- `Developer::Dashboard::PageStore`
  Persists saved pages and encodes/decodes transient page payloads.

- `Developer::Dashboard::PageResolver`
  Resolves saved pages and generated provider pages into one page-document model.

- `Developer::Dashboard::PageRuntime`
  Applies Template Toolkit rendering for `HTML` and `FORM.TT`, then executes legacy `CODE*` sections inside one throwaway sandpit package per page run and captures their output for page rendering.

- `Developer::Dashboard::Web::App`
  Resolves the root free-form editor, saved page, transient page, login, logout, `/apps`, and legacy `/app/<name>` routes.

- `Developer::Dashboard::Web::Server`
  Minimal HTTP server for browsing saved and transient pages, defaulting to bind `0.0.0.0:7890`.

- `Developer::Dashboard::UpdateManager`
  Runs ordered update scripts, stops running collectors, and restarts them afterward.

- `Developer::Dashboard::DockerCompose`
  Resolves compose base files plus explicit project, service, addon, and mode overlays, env injection, and the final `docker compose` command.

## Runtime Model

The architecture follows a producer/consumer pattern:

- collectors prepare data in the background
- indicators and pages read cached state
- prompt rendering reads cached state only
- update scripts bootstrap runtime state and shell integration

Collector loops are managed explicitly:

- each loop writes a pid file plus `loop.json` metadata
- the process title is set to `dashboard collector: <name>`
- duplicate prevention requires both a live pid and a matching process title
- stale or foreign pid files are cleaned up instead of being trusted blindly

Web service lifecycle is managed the same way:

- `dashboard serve` backgrounds the web service by default
- `dashboard stop` stops both the web service and collector loops
- `dashboard restart` stops both, restarts configured collectors, then starts the web service again
- the web process title is set to `dashboard web: <host>:<port>`
- shutdown prefers managed-process validation, then falls back to `pkill -f` style matching and explicit process scans

Browser access is managed explicitly:

- exact `127.0.0.1` with numeric host `127.0.0.1` is trusted as local admin
- `localhost`, other hosts, and other client IPs are helper-tier requests
- helper-tier requests must authenticate through file-backed user and session records
- helper usernames are validated, passwords require at least 8 characters, and user/session files are written with `0600` permissions
- helper sessions are bound to the originating remote address and expire after 12 hours
- helper page views show a Logout link in the top chrome, display the helper username in the top-right user marker, and logging out removes both the helper session and that helper account
- exact-loopback admin page views do not show a Logout link
- HTTP responses add CSP, frame-deny, nosniff, no-referrer, and no-store headers

Page source compatibility is explicit:

- bookmark files serialize back to the original `KEY: ...` plus divider-line syntax
- legacy `KEY: ...` documents separated by the original divider line are supported directly
- `HTML` and `FORM.TT` are rendered through Template Toolkit with access to `stash`, `ENV`, and `SYSTEM`
- `TITLE` populates the document `<title>` only and is not injected into the page body automatically
- `CODE*` blocks run through the legacy page runtime and their `STDOUT` is appended to the page while `STDERR` is shown as red error output
- one generated sandpit package is reused across `CODE*` blocks for a single render, then destroyed so package globals do not leak into later requests
- `/` with no bookmark path opens the free-form instruction editor directly
- `/apps` redirects to `/app/index`
- edit and render views include shared top chrome with share/source links plus the original status-plus-alias indicator strip, refreshed from `/system/status`, alongside the local user, a machine IP link chosen from the active interfaces, and a browser-updated date/time
- the editor view auto-submits the bookmark form on textarea change/blur instead of relying on a visible update button
- the editor shows in-place syntax highlighting inside the same editing surface for directive, HTML, CSS, JavaScript, and Perl `CODE*` content

## Environment Overrides

The core supports compatibility-style environment overrides for project customization:

- `DEVELOPER_DASHBOARD_BOOKMARKS`
  Saved page/bookmark root.

- `DEVELOPER_DASHBOARD_CHECKERS`
  Filter for enabled collector/checker names using colon-separated values.

- `DEVELOPER_DASHBOARD_CONFIGS`
  Config root.

- `DEVELOPER_DASHBOARD_STARTUP`
  Startup collector-definition root.

Startup definitions are read as JSON files and merged into the collector set.

The runtime also supports user CLI extensions:

- unknown top-level `dashboard` subcommands are resolved from `~/.developer-dashboard/cli`
- the matching executable receives the remaining argv unchanged
- stdin, stdout, and stderr are preserved through `exec`

## Packaging

- `dist.ini` controls Dist::Zilla packaging
- GitHub Actions builds with `dzil build`
- uploads to PAUSE use `PAUSE_USER` and `PAUSE_PASS`

## Quality Gates

- `prove -lr t` must pass
- library coverage is measured with Devel::Cover
- the coverage report should be reviewed before release, especially after adding new runtime modules
