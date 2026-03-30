# Developer Dashboard

Project-neutral local developer dashboard runtime.

## Introduction

Developer Dashboard is a local-first developer toolkit intended to be reusable across unrelated projects.

It provides a small ecosystem for:

- saved and transient dashboard pages built from the original bookmark-file shape
- legacy bookmark syntax compatibility using the original `:--------------------------------------------------------------------------------:` separator plus directives such as `TITLE:`, `STASH:`, `HTML:`, `FORM.TT:`, `FORM:`, and `CODE1:`
- Template Toolkit rendering for `HTML:` and `FORM.TT:`, with access to `stash`, `ENV`, and `SYSTEM`
- legacy `CODE*` execution with captured `STDOUT` rendered into the page and captured `STDERR` rendered as visible errors
- legacy-style per-page sandpit isolation so one bookmark run can share runtime variables across `CODE*` blocks without leaking them into later page runs
- old-style root editor behavior with a free-form bookmark textarea when no path is provided
- file-backed collectors and indicators
- prompt rendering for `PS1`
- project and path discovery helpers
- a lightweight local web interface
- action execution with trusted and safer page boundaries
- plugin-loaded providers, path aliases, and compose overlays
- update scripts and release packaging for CPAN distribution

The core distribution is intentionally project-neutral.

Project-specific behavior should be added through configuration, startup collector definitions, saved pages, and optional plugins.

## Documentation

### Main Concepts

- `Developer::Dashboard::PathRegistry`
  Resolves logical runtime, config, dashboard, collector, and indicator directories.

- `Developer::Dashboard::FileRegistry`
  Resolves stable logical files on top of the path registry.

- `Developer::Dashboard::PageDocument` and `Developer::Dashboard::PageStore`
  Implement the saved and transient page model.

- `Developer::Dashboard::PageResolver` and `Developer::Dashboard::PluginManager`
  Resolve saved pages, provider pages, plugin-defined aliases, and extension packs.

- `Developer::Dashboard::ActionRunner`
  Executes built-in actions and trusted local command actions with cwd, env, timeout, background support, and encoded action transport.

- `Developer::Dashboard::Collector` and `Developer::Dashboard::CollectorRunner`
  Implement file-backed prepared-data jobs with managed loop metadata, timeout/env handling, interval and cron-style scheduling, process-title validation, duplicate prevention, and collector inspection data.

- `Developer::Dashboard::IndicatorStore` and `Developer::Dashboard::Prompt`
  Expose cached state to shell prompts and dashboards, including compact versus extended prompt rendering, stale-state marking, and generic built-in indicator refresh.

- `Developer::Dashboard::Web::App` and `Developer::Dashboard::Web::Server`
  Provide the minimal local browser interface, including exact-loopback admin trust and helper login sessions.

- `dashboard of` and `dashboard open-file`
  Resolve direct files, `file:line` references, Perl module names, Java class names, and recursive file-pattern matches under a resolved scope.

- `Developer::Dashboard::RuntimeManager`
  Manages the background web service and collector lifecycle with process-title validation, `pkill`-style fallback shutdown, and restart orchestration.

- `Developer::Dashboard::UpdateManager`
  Runs ordered update scripts and restarts validated collector loops when needed.

- `Developer::Dashboard::DockerCompose`
  Resolves project-aware compose files, explicit overlay layers, services, addons, modes, env injection, and the final `docker compose` command.

### Environment Variables

The distribution supports these compatibility-style customization variables:

- `DEVELOPER_DASHBOARD_BOOKMARKS`
  Override the saved page root.

- `DEVELOPER_DASHBOARD_CHECKERS`
  Filter enabled collector or checker names.

- `DEVELOPER_DASHBOARD_CONFIGS`
  Override the config root.

- `DEVELOPER_DASHBOARD_STARTUP`
  Override the startup collector-definition root.

### User CLI Extensions

Unknown top-level subcommands can be provided by executable files under
`~/.developer-dashboard/cli`. For example, `dashboard foobar a b` will exec
`~/.developer-dashboard/cli/foobar` with `a b` as argv, while preserving
stdin, stdout, and stderr.

### Open File Commands

`dashboard of` is the shorthand name for `dashboard open-file`.

These commands support:

- direct file paths
- `file:line` references
- Perl module names such as `My::Module`
- Java class names such as `com.example.App`
- recursive pattern searches inside a resolved directory alias or path

If `VISUAL` or `EDITOR` is set, `dashboard of` and `dashboard open-file` will exec that editor unless `--print` is used.

## Manual

### Installation

Install from CPAN with:

```bash
cpanm Developer::Dashboard
```

Or install from a checkout with:

```bash
perl Makefile.PL
make
make test
make install
```

### Local Development

Build the distribution:

```bash
dzil build
```

Run the CLI directly from the repository:

```bash
perl -Ilib bin/dashboard init
perl -Ilib bin/dashboard auth add-user <username> <password>
perl -Ilib bin/dashboard of --print My::Module
perl -Ilib bin/dashboard open-file --print com.example.App
perl -Ilib bin/dashboard update
perl -Ilib bin/dashboard serve
perl -Ilib bin/dashboard stop
perl -Ilib bin/dashboard restart
```

User CLI extensions can be tested from the repository too:

```bash
mkdir -p ~/.developer-dashboard/cli
printf '#!/bin/sh\ncat\n' > ~/.developer-dashboard/cli/foobar
chmod +x ~/.developer-dashboard/cli/foobar
printf 'hello\n' | perl -Ilib bin/dashboard foobar
```

### First Run

Initialize the runtime:

```bash
dashboard init
```

Inspect resolved paths:

```bash
dashboard paths
```

Render shell bootstrap:

```bash
dashboard shell bash
```

Resolve or open files from the CLI:

```bash
dashboard of --print My::Module
dashboard open-file --print com.example.App
dashboard open-file --print path/to/file.txt
dashboard open-file --print bookmarks welcome
```

Start the local app:

```bash
dashboard serve
```

Open the root path with no bookmark path to get the free-form bookmark editor directly.

Stop the local app and collector loops:

```bash
dashboard stop
```

Restart the local app and configured collector loops:

```bash
dashboard restart
```

Create a helper login user:

```bash
dashboard auth add-user <username> <password>
```

Remove a helper login user:

```bash
dashboard auth remove-user helper
```

Helper sessions show a Logout link in the page chrome. Logging out removes both
the helper session and that helper account. Helper page views also show the
helper username in the top-right chrome instead of the local system account.
Exact-loopback admin requests do not show a Logout link.

### Working With Pages

Create a starter page document:

```bash
dashboard page new sample "Sample Page"
```

Save a page:

```bash
dashboard page new sample "Sample Page" | dashboard page save sample
```

List saved pages:

```bash
dashboard page list
```

Render a saved page:

```bash
dashboard page render sample
```

Encode and decode transient pages:

```bash
dashboard page show sample | dashboard page encode
dashboard page show sample | dashboard page encode | dashboard page decode
```

Run a page action:

```bash
dashboard action run system-status paths
```

Bookmark documents use the original separator-line format with directive headers such as `TITLE:`, `STASH:`, `HTML:`, `FORM.TT:`, `FORM:`, and `CODE1:`.

The browser editor highlights directive sections, HTML, CSS, JavaScript, and Perl `CODE*` content directly inside the editing surface rather than in a separate preview pane.

Page `TITLE:` values only populate the HTML `<title>` element. If a bookmark should show its title in the page body, add it explicitly inside `HTML:`, for example with `[% title %]`.

`/apps` redirects to `/app/index`, and `/app/<name>` can load either a saved bookmark document or a saved ajax/url bookmark file.

### Working With Collectors

Initialize example collector config:

```bash
dashboard config init
```

Run a collector once:

```bash
dashboard collector run example.collector
```

List collector status:

```bash
dashboard collector list
```

### Docker Compose

Inspect the resolved compose stack without running Docker:

```bash
dashboard docker compose --dry-run config
```

Include addons or modes:

```bash
dashboard docker compose --addon mailhog --mode dev up -d
```

### Prompt Integration

Render prompt text directly:

```bash
dashboard ps1 --jobs 2
```

Generate bash bootstrap:

```bash
dashboard shell bash
```

### Browser Access Model

The browser security model follows the legacy local-first trust concept:

- requests from exact `127.0.0.1` with a numeric `Host` of `127.0.0.1` are treated as local admin
- requests from other IPs or from hostnames such as `localhost` are treated as helper access
- helper sessions are file-backed, bound to the originating remote address, and expire automatically
- helper passwords must be at least 8 characters long

The editor and rendered pages also include a shared top chrome with share/source links on the left and the original status-plus-alias indicator strip on the right, refreshed from `/system/status`. That top-right area also includes the local username, the current host or IP link, and the current date/time in the same spirit as the old local dashboard chrome.
The displayed address is discovered from the machine interfaces, preferring a VPN-style address when one is active, and the date/time is refreshed in the browser with JavaScript.
The bookmark editor also follows the old auto-submit flow, so the form submits when the textarea changes and loses focus instead of showing a manual update button.
- helper access requires a login backed by local file-based user and session records

This keeps the fast path for exact loopback access while making non-canonical or remote access explicit.

The default web bind is `0.0.0.0:7890`. Trust is still decided from the request origin and host header, not from the listen address.

### Runtime Lifecycle

- `dashboard serve` starts the web service in the background by default
- `dashboard serve --foreground` keeps the web service attached to the terminal
- `dashboard stop` stops both the web service and managed collector loops
- `dashboard restart` stops both, starts configured collector loops again, then starts the web service
- web shutdown and duplicate detection do not trust pid files alone; they validate managed processes by environment marker or process title and use a `pkill`-style scan fallback when needed

### Environment Customization

After installing with `cpanm`, the runtime can be customized with these environment variables:

- `DEVELOPER_DASHBOARD_BOOKMARKS`
  Overrides the saved page or bookmark directory.

- `DEVELOPER_DASHBOARD_CHECKERS`
  Limits enabled collector or checker jobs to a colon-separated list of names.

- `DEVELOPER_DASHBOARD_CONFIGS`
  Overrides the config directory.

- `DEVELOPER_DASHBOARD_STARTUP`
  Overrides the startup collector-definition directory.

Startup collector definitions are read from `*.json` files in `DEVELOPER_DASHBOARD_STARTUP`. A startup file may contain either a single collector object or an array of collector objects.

Example:

```json
[
  {
    "name": "docker.health",
    "command": "docker ps",
    "cwd": "home",
    "interval": 30
  }
]
```

### Updating Runtime State

Run the ordered update pipeline:

```bash
dashboard update
```

This performs runtime bootstrap, dependency refresh, shell bootstrap generation, and collector restart orchestration.

### Blank Environment Integration

Run the host-built tarball integration flow with:

```bash
integration/blank-env/run-host-integration.sh
```

This integration path builds the distribution tarball on the host with
`dzil build`, starts a blank container with only that tarball mounted into it,
installs the tarball with `cpanm`, and then exercises the installed
`dashboard` command inside the clean Perl container.

The harness also:

- creates a fake project wired through `DEVELOPER_DASHBOARD_BOOKMARKS`, `DEVELOPER_DASHBOARD_CONFIGS`, and `DEVELOPER_DASHBOARD_STARTUP`
- verifies the installed CLI works against that fake project through the mounted tarball install
- extracts the same tarball inside the container so `dashboard update` runs from artifact contents instead of the live repo
- starts the installed web service
- uses headless Chromium to verify the root editor, a saved fake-project bookmark page from the fake project bookmark directory, and the helper login page
- verifies helper logout cleanup and runtime restart and stop behavior

## FAQ

### Is this tied to a specific company or codebase?

No. The core distribution is intended to be reusable for any project.

### Where should project-specific behavior live?

In configuration, startup collector definitions, saved pages, and optional extensions. The core should stay generic.

### Is the software spec implemented?

The current distribution implements the core runtime, page engine, action runner, plugin/provider loader, prompt and collector system, web lifecycle manager, and Docker Compose resolver described by the software spec.

What remains intentionally lightweight is breadth, not architecture:

- plugin packs are JSON-based rather than a larger CPAN plugin API
- provider pages and action handlers are implemented in a compact v1 form
- legacy bookmarks are supported, with Template Toolkit rendering and one clean sandpit package per page run so `CODE*` blocks can share state within a bookmark render without leaking runtime globals into later requests

### Does it require a web framework?

No. The current distribution includes a minimal HTTP layer implemented with core Perl-oriented modules.

### Why does localhost still require login?

This is intentional. The trust rule is exact and conservative: only numeric loopback on `127.0.0.1` receives local-admin treatment.

### Why is the runtime file-backed?

Because prompt rendering, dashboards, and wrappers should consume prepared state quickly instead of re-running expensive checks inline.

### How are CPAN releases built?

The repository is set up to build release artifacts with Dist::Zilla and upload them to PAUSE from GitHub Actions.

### What JSON implementation does the project use?

The project uses `JSON::XS` for JSON encoding and decoding, including shell helper decoding paths.

### What does the project use for command capture and HTTP clients?

The project uses `Capture::Tiny` for command-output capture via `capture`, with exit codes returned from the capture block rather than read separately. There is currently no outbound HTTP client in the core runtime, so `LWP::UserAgent` is not yet required by an active code path.

## GitHub Release To PAUSE

The repository includes a GitHub Actions workflow at:

- `.github/workflows/release-cpan.yml`

It expects these GitHub Actions secrets:

- `PAUSE_USER`
- `PAUSE_PASS`

The workflow:

1. checks out the repo
2. installs Perl, Dist::Zilla, and release dependencies
3. builds the CPAN distribution tarball with `dzil build`
4. uploads the tarball to PAUSE

It can be triggered by:

- pushing a tag like `v0.01`
- manual `workflow_dispatch`

## Testing And Coverage

Run the test suite:

```bash
prove -lr t
```

Measure library coverage with Devel::Cover:

```bash
cpanm --local-lib-contained ./.perl5 Devel::Cover
export PERL5LIB="$PWD/.perl5/lib/perl5${PERL5LIB:+:$PERL5LIB}"
export PATH="$PWD/.perl5/bin:$PATH"
cover -delete
HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t
cover -report text -select_re '^lib/' -coverage statement -coverage subroutine
```

The repository target is 100% statement and subroutine coverage for `lib/`.

The coverage-closure suite includes managed collector loop start/stop paths
under `Devel::Cover`, including wrapped fork coverage in
`t/14-coverage-closure-extra.t`, so the covered run stays green without
breaking TAP from daemon-style child processes.
