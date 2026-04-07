# Developer Dashboard

A local home for development work.

## Introduction

Developer Dashboard gives a developer one place to organize the moving parts of day-to-day work.

Without it, local development usually ends up spread across shell history, ad-hoc scripts, browser bookmarks, half-remembered file paths, one-off health checks, and project-specific Docker commands. With it, those pieces can live behind one entrypoint: a browser home, a prompt status layer, and a CLI toolchain that all read from the same runtime.

It brings together browser pages, saved notes, helper actions, collectors, prompt indicators, path aliases, open-file shortcuts, data query tools, and Docker Compose helpers so local development can stay centered around one consistent home instead of a pile of disconnected scripts and tabs.

When the current project contains `./.developer-dashboard`, that tree becomes the first runtime lookup root for dashboard-managed files. The home runtime under `~/.developer-dashboard` stays as the fallback base, so project-local bookmarks, config, CLI hooks, helper users, sessions, and isolated docker service folders can override home defaults without losing shared fallback data that is not redefined locally.

The home runtime is now hardened to owner-only access by default. Directories
under `~/.developer-dashboard` are kept at `0700`, regular runtime files are
kept at `0600`, and owner-executable scripts stay owner-executable at `0700`.
Run `dashboard doctor` to audit the current home runtime plus any older
dashboard roots still living directly under `$HOME`, or `dashboard doctor
--fix` to tighten those permissions in place. The same command also reads
optional hook results from `~/.developer-dashboard/cli/doctor.d` so users can
layer in more site-specific checks later.

Frequently used built-in helpers such as `jq`, `yq`, `tomq`, `propq`, `iniq`,
`csvq`, `xmlq`, `of`, and `open-file` are staged privately under
`~/.developer-dashboard/cli/` and dispatched by `dashboard` without polluting
the global `PATH`. Compatibility aliases `pjq`, `pyq`, `ptomq`, and `pjp` still map
to the renamed commands when they are invoked through `dashboard`.

It provides a small ecosystem for:

- saved and transient dashboard pages built from the original bookmark-file shape
- bookmark-file syntax compatibility using the original `:--------------------------------------------------------------------------------:` separator plus directives such as `TITLE:`, `STASH:`, `HTML:`, and `CODE1:`
- Template Toolkit rendering for `HTML:`, with access to `stash`, `ENV`, and `SYSTEM`
- bookmark `CODE*` execution with captured `STDOUT` rendered into the page and captured `STDERR` rendered as visible errors
- per-page sandpit isolation so one bookmark run can share runtime variables across `CODE*` blocks without leaking them into later page runs
- old-style root editor behavior with a free-form bookmark textarea when no path is provided
- file-backed collectors and indicators
- prompt rendering for `PS1` and the PowerShell `prompt` function
- project and path discovery helpers
- a lightweight local web interface
- action execution with trusted and safer page boundaries
- config-backed providers, path aliases, and compose overlays
- update scripts and installable runtime packaging

Developer Dashboard is meant to become the developer's working home:

- a local dashboard page that can hold links, notes, forms, actions, and rendered output
- a prompt layer that shows live status for the things you care about
- a command surface for opening files, jumping to known paths, querying data, and running repeatable local tasks
- a configurable runtime that can adapt to each codebase without losing one familiar entrypoint

### What You Get

- a browser interface on port `7890` for pages, status, editing, and helper access
- a shell entrypoint for file navigation, page operations, collectors, indicators, auth, and Docker Compose
- saved runtime state that lets the browser, prompt, and CLI all see the same prepared information
- a place to collect project-specific shortcuts without rebuilding your daily workflow for every repo

### Web Interface And Access Model

Run the web interface with:

```bash
dashboard serve
```

By default it listens on `0.0.0.0:7890`, so you can open it in a browser at:

```text
http://127.0.0.1:7890/
```

Run `dashboard serve --ssl` to enable HTTPS with a generated self-signed
certificate under `~/.developer-dashboard/certs/`, then open:

```text
https://127.0.0.1:7890/
```

When SSL mode is on, plain HTTP requests on that same host and port are
redirected to the equivalent `https://...` URL before the dashboard route
runs. Browsers then show the normal self-signed certificate warning until you
trust the generated certificate locally.

The access model is deliberate:

- exact numeric loopback admin access on `127.0.0.1` does not require a password
- helper access is for everyone else, including `localhost`, other hosts, and other machines on the network
- helper logins let you share the dashboard safely without turning every browser request into full local-admin access

In practice that means the developer at the machine gets friction-free local admin access, while shared or forwarded access is forced through explicit helper accounts.
If no helper user exists yet in the active dashboard runtime, outsider requests return `401` with an empty body and do not render the login form at all.
When a saved `index` bookmark exists, opening `/` now redirects straight to
`/app/index` so the saved home page becomes the default browser entrypoint.
When no saved `index` bookmark exists yet, `/` still opens the free-form
bookmark editor.
If a user opens an unknown saved route such as `/app/foobar`, the browser now
opens the bookmark editor with a prefilled blank bookmark for that requested
path instead of showing a 404 error page.
When helper access is sent to `/login`, the login form now keeps the original
requested path and query string in a hidden redirect target. After a successful
helper login, the browser is sent back to that saved route, such as
`/app/index`, instead of being dropped at `/`.

### Collectors, Indicators, And PS1

Collectors are background or on-demand jobs that prepare state for the rest of the dashboard. A collector can run a shell command or a Perl snippet, then store stdout, stderr, exit code, and timestamps as file-backed runtime data.

That prepared state drives indicators. Indicators are the short status records used by:

- the shell prompt rendered by `dashboard ps1`
- the top-right status strip in the web interface
- CLI inspection commands such as `dashboard indicator list`

This matters because prompt and browser status should be cheap to render. Instead of re-running a Docker check, VPN probe, or project health command every time the prompt draws, a collector prepares the answer once and the rest of the system reads the cached result.
Configured collector indicators now prefer the configured icon in both places,
and when a collector is renamed the old managed indicator is cleaned up
automatically so the prompt and top-right browser strip do not show both the
old and new names at the same time. Those managed indicator records now also
preserve a newer live collector status during restart/config-sync windows, so a
healthy collector does not flicker back to `missing` after it has already
reported `ok`.

### Why It Works As A Developer Home

The pieces are designed to reinforce each other:

- pages give you a browser home for links, notes, forms, and actions
- collectors prepare state for indicators and prompt rendering
- indicators summarize that state in both the browser and the shell
- path aliases, open-file helpers, and data query commands shorten the jump from “I know what I need” to “I am at the file or value now”
- Docker Compose helpers keep recurring container workflows behind the same `dashboard` entrypoint

That combination makes the dashboard useful as a real daily base instead of just another utility script.

### Not Just For Perl

Developer Dashboard is implemented in Perl, but it is not only for Perl developers.

It is useful anywhere a developer needs:

- a local browser home
- repeatable health checks and status indicators
- path shortcuts and file-opening helpers
- JSON, YAML, TOML, or properties inspection from the CLI
- a consistent Docker Compose wrapper

The toolchain already understands Perl module names, Java class names, direct files, structured-data formats, and project-local compose flows, so it suits mixed-language teams and polyglot repositories as well as Perl-heavy work.

Project-specific behavior is added through configuration, saved pages, and user CLI extensions.

### Module Namespacing

All project modules are scoped under the `Developer::Dashboard::` namespace to prevent pollution of the CPAN ecosystem. Core helper modules are available under this namespace:

- `Developer::Dashboard::File` - file I/O helpers with alias support
- `Developer::Dashboard::Folder` - folder path resolution and discovery
- `Developer::Dashboard::DataHelper` - JSON encoding/decoding helpers
- `Developer::Dashboard::Zipper` - token encoding and Ajax command building
- `Developer::Dashboard::Runtime::Result` - hook result environment variable decoding

Project-owned modules now live only under the `Developer::Dashboard::`
namespace so the distribution does not pollute the CPAN ecosystem with
generic package names.

## Documentation

### Contributor Documentation Contract

`FULL-POD-DOC` is a repo contract. Every repo-owned Perl file must end with
POD under `__END__` that explains what the file is, what it is for, why it
exists, when to use it, how to use it, what uses it, and at least one
concrete example. Contributors should be able to open any module, script,
helper, or test and understand its role without reverse-engineering the tree
first.

### Main Concepts

- `Developer::Dashboard::PathRegistry`
  Resolves the runtime roots that everything else depends on, such as dashboards, config, collectors, indicators, CLI hooks, logs, and cache.

- `Developer::Dashboard::FileRegistry`
  Resolves stable file locations on top of the path registry so the rest of the system can read and write well-known runtime files without duplicating path logic.

- `Developer::Dashboard::PageDocument` and `Developer::Dashboard::PageStore`
  Implement the saved and transient page model, including bookmark-style source documents, encoded transient pages, and persistent bookmark storage.

- `Developer::Dashboard::PageResolver`
  Resolves saved pages and provider pages so browser pages and actions can come from both built-in and config-backed sources.

- `Developer::Dashboard::ActionRunner`
  Executes built-in actions and trusted local command actions with cwd, env, timeout, background support, and encoded action transport, letting pages act as operational dashboards instead of static documents.

- `Developer::Dashboard::Collector` and `Developer::Dashboard::CollectorRunner`
  Implement file-backed prepared-data jobs with managed loop metadata, timeout/env handling, interval and cron-style scheduling, process-title validation, duplicate prevention, and collector inspection data. This is the prepared-state layer that feeds indicators, prompt status, and operational pages.

- `Developer::Dashboard::IndicatorStore` and `Developer::Dashboard::Prompt`
  Expose cached state to shell prompts and dashboards, including compact versus extended prompt rendering, stale-state marking, generic built-in indicator refresh, and page-header status payloads for the web UI.

- `Developer::Dashboard::Web::DancerApp`, `Developer::Dashboard::Web::App`, and `Developer::Dashboard::Web::Server`
  Provide the browser interface on port `7890`, with Dancer2 owning the HTTP route table while the web-app service handles page rendering, login/logout, helper sessions, and the exact-loopback admin trust model.

- `dashboard of` and `dashboard open-file`
  Resolve direct files, `file:line` references, Perl module names, Java class names, and recursive file-pattern matches under a resolved scope so the dashboard can shorten navigation work across different stacks.

- `dashboard jq`, `dashboard yq`, `dashboard tomq`, and `dashboard propq`
  Parse JSON, YAML, TOML, and Java properties input, then optionally extract a dotted path and print a scalar or canonical JSON, giving the CLI a small data-inspection toolkit that fits naturally into shell workflows. Compatibility names `pjq`, `pyq`, `ptomq`, and `pjp` still normalize through `dashboard` for backward compatibility, but they are no longer shipped as standalone executables.

- `dashboard iniq`, `dashboard csvq`, and `dashboard xmlq`
  Parse INI, CSV, and XML file input with dotted path extraction.

- private `~/.developer-dashboard/cli/*` built-in helpers plus `~/.developer-dashboard/cli/_dashboard-core`
  Provide dashboard-managed helper assets without installing generic command names into the global PATH. Query/open-file/ticket/path/prompt helpers keep their own dedicated helper bodies, while the remaining built-in commands stage thin wrappers that hand off to the shared private `_dashboard-core` runtime.

Only `dashboard` is intended to be the public CPAN-facing command-line entrypoint. The real built-in command bodies now live outside `bin/dashboard` under `share/private-cli/`, then stage into `~/.developer-dashboard/cli/` on demand. Generic helper names such as `ticket`, `of`, `open-file`, `jq`, `yq`, `tomq`, `propq`, `iniq`, `csvq`, `xmlq`, `path`, and `paths` are intentionally kept out of the installed global PATH to avoid polluting the wider Perl and shell ecosystem.

- `dashboard ticket`
  Creates or reuses a tmux session for the requested ticket reference, seeds `TICKET_REF` plus dashboard-friendly branch aliases into that session environment, and attaches to it through a dashboard-managed private helper instead of a public standalone binary.

- `Developer::Dashboard::RuntimeManager`
  Manages the background web service and collector lifecycle with process-title validation, `pkill`-style fallback shutdown, and restart orchestration, tying the browser and prepared-state loops together as one runtime.

- `Developer::Dashboard::UpdateManager`
  Runs ordered update scripts and restarts validated collector loops when needed, giving the runtime a controlled bootstrap and upgrade path.

- `Developer::Dashboard::DockerCompose`
  Resolves project-aware compose files, explicit overlay layers, services, addons, modes, env injection, and the final `docker compose` command so container workflows can live inside the same dashboard ecosystem instead of in separate wrapper scripts.

### Environment Variables

The distribution supports these compatibility-style customization variables:

- `DEVELOPER_DASHBOARD_BOOKMARKS`
  Override the saved page root.

- `DEVELOPER_DASHBOARD_CHECKERS`
  Filter enabled collector or checker names.

- `DEVELOPER_DASHBOARD_CONFIGS`
  Override the config root.

- `DEVELOPER_DASHBOARD_ALLOW_TRANSIENT_URLS`
  Allow browser execution of transient `/?token=...`, `/action?atoken=...`, and older `/ajax?token=...` payloads. The default is off, so the web UI only executes saved bookmark files unless this is set to a truthy value such as `1`, `true`, `yes`, or `on`.


### Transient Web Token Policy

Transient page tokens still exist for CLI workflows such as `dashboard page encode`
and `dashboard page decode`, but browser routes that execute a transient payload
from `token=` or `atoken=` are disabled by default.

That means links such as:

- `http://127.0.0.1:7890/?token=...`
- `http://127.0.0.1:7890/action?atoken=...`
- `http://127.0.0.1:7890/ajax?token=...`

return a `403` unless `DEVELOPER_DASHBOARD_ALLOW_TRANSIENT_URLS` is enabled.
Saved bookmark-file routes such as `/app/index` and
`/app/index/action/...` continue to work without that flag.
Saved bookmark editor pages also stay on their named `/app/<id>/edit` and
`/app/<id>` routes when you save from the browser, so editing an existing
bookmark file does not fall back to transient `token=` URLs under the default
deny policy.

`Ajax` helper calls inside saved bookmark `CODE*` blocks should use an
explicit `file => 'name.json'` argument. When a saved page supplies that name,
the helper stores the Ajax Perl code under the saved dashboard ajax tree and emits a stable
saved-bookmark endpoint such as `/ajax/name.json?type=text`.
Those saved Ajax handlers run the stored file as a real process, defaulting to
Perl unless the file starts with a shebang, and stream both `stdout` and
`stderr` back to the browser as they happen. That keeps bookmark Ajax
workflows usable even while transient token URLs stay disabled by default, and
it means bookmark Ajax code can rely on normal `print`, `warn`, `die`,
`system`, and `exec` process behaviour instead of a buffered JSON wrapper.
Saved bookmark Ajax handlers also default to `text/plain` when no explicit
`type => ...` argument is supplied, and the generated Perl wrapper now enables
autoflush on both `STDOUT` and `STDERR` so long-running handlers show
incremental output in the browser instead of stalling behind process buffers.
If a saved handler also needs refresh-safe process reuse, pass
`singleton => 'NAME'` in the `Ajax` helper. The generated url then carries
that singleton name, the Perl worker runs as `dashboard ajax: NAME`, and the
runtime terminates any older matching Perl Ajax worker before starting the
replacement stream for the refreshed browser request. Singleton-managed Ajax
workers are also terminated by `dashboard stop` and `dashboard restart`, and
the bookmark page now registers a `pagehide` cleanup beacon against
`/ajax/singleton/stop?singleton=NAME` so closing the browser tab also tears
down the matching worker instead of leaving it behind.
If `code => ...` is omitted, `Ajax(file => 'name')` targets the existing
executable at `dashboards/ajax/name` instead of rewriting it.
Static files referenced by saved bookmarks are resolved from the effective
runtime public tree first and then from the saved bookmark root. The web layer
also provides a built-in `/js/jquery.js` compatibility shim, so bookmark pages
that expect a local jQuery-style helper still have `$`, `$(document).ready`,
`$.ajax`, jqXHR-style `.done(...)` / `.fail(...)` / `.always(...)` chaining,
the `method` alias used by modern callers, and selector `.text(...)` support
even when no runtime file has been copied into `dashboard/public/js` yet.

Saved bookmark editor and view-source routes also protect literal inline script
content from breaking the browser bootstrap. If a bookmark body contains HTML
such as `</script>`, the editor now escapes the inline JSON assignment used to
reload the source text, so the browser keeps the full bookmark source inside
the editor instead of spilling raw text below the page. Earlier bookmark
rendering now emits saved `set_chain_value()` bindings after the bookmark body
HTML, so pages that declare `var endpoints = {};` and then call helpers from
`$(document).ready(...)` receive their saved `/ajax/...` endpoint URLs without
throwing a play-route JavaScript `ReferenceError`.
Bookmark pages now also expose `fetch_value(url, target, options,
formatter)`, `stream_value(url, target, options, formatter)`, and
`stream_data(url, target, options, formatter)` helpers so a bookmark can bind
saved Ajax endpoints into DOM targets without hand-writing the fetch and
render boilerplate. `stream_data()` and `stream_value()` now use
`XMLHttpRequest` progress events for browser-visible incremental updates, so a
saved `/ajax/...` endpoint that prints early output updates the DOM before the
request finishes. Those helpers support plain text, JSON, and HTML output
modes, and the saved Ajax endpoint bindings now run after the page declares
its endpoint root object, so `$(document).ready(...)` callbacks can call
helpers such as `fetch_value(endpoints.foo, '#foo')` on first render.


### User CLI Extensions

Unknown top-level subcommands can be provided by executable files under
the current working directory's `./.developer-dashboard/cli` first, then the
nearest git-backed project runtime `./.developer-dashboard/cli` when it is a
different directory, and then `~/.developer-dashboard/cli`. For example,
`dashboard foobar a b` will exec the first matching
`cli/foobar` with `a b` as argv, while preserving stdin, stdout, and stderr.

`DD-OOP-LAYERS` is now the runtime contract for the whole local ecosystem.
Starting at `~/.developer-dashboard` and walking down through every parent
directory until the current working directory, every existing
`.developer-dashboard/` layer participates. The deepest layer stays the write
target and the first lookup hit, but bookmarks, `nav/*.tt`, config,
collectors, indicators, auth/session state lookups, runtime `local/lib/perl5`,
and custom CLI hooks are all inherited across the full chain instead of only a
single project-or-home split.

Dashboard-managed built-in helper extraction is the one explicit exception:
`dashboard init` and on-demand helper staging always write the built-in helper
scripts only to `~/.developer-dashboard/cli/`. Layered lookup still applies to
user commands and hook directories, but built-in helper offloading does not
seed duplicate copies into child project layers.

### Shared Nav Fragments

If `nav/*.tt` files exist under the saved bookmark root, every non-nav page
render includes them between the top chrome and the main page body.

For the default runtime that means files such as:

- `~/.developer-dashboard/dashboards/nav/foo.tt`
- `~/.developer-dashboard/dashboards/nav/bar.tt`

And with route access such as:

- `/app/nav/foo.tt`
- `/app/nav/foo.tt/edit`
- `/app/nav/foo.tt/source`

The bookmark editor can save those nested ids directly, for example
`BOOKMARK: nav/foo.tt`. On a page like `/app/index`, the direct `nav/*.tt`
files are loaded in sorted filename order, rendered through the normal page
runtime, and inserted above the page body. Non-`.tt` files and subdirectories
under `nav/` are ignored by that shared-nav renderer.

Under `DD-OOP-LAYERS`, the shared nav renderer now scans every inherited
`dashboards/nav/` layer from `~/.developer-dashboard` down to the current
directory, keeps parent-only fragments visible, and lets a deeper layer
replace the same `nav/<name>.tt` id without losing the rest of the shared nav
set. Template includes used by those bookmarks follow the same layered
bookmark lookup path.

Shared nav fragments and normal bookmark pages both render through Template
Toolkit with `env.current_page` set to the active request path, such as
`/app/index`. The same path is also available as
`env.runtime_context.current_page`, alongside the rest of the request-time
runtime context. Token play renders for named bookmarks also reuse that saved
`/app/<id>` path for nav context, so shared `nav/*.tt` fragments do not
disappear just because the browser reached the page through a transient
`/?mode=render&token=...` URL.
Shared nav markup now wraps horizontally by default and inherits the page
theme through CSS variables such as `--panel`, `--line`, `--text`, and
`--accent`, so dark bookmark themes no longer force a pale nav box or hide nav
link text against the background.

### Open File Commands

`dashboard of` is the shorthand name for `dashboard open-file`.

These commands support:

- direct file paths
- `file:line` references
- Perl module names such as `My::Module`
- Java class names such as `com.example.App`
- recursive pattern searches inside a resolved directory alias or path

Without `--print`, `dashboard of` and `dashboard open-file` now behave like the
older picker workflow again: one unique match opens directly in `--editor`,
`VISUAL`, `EDITOR`, or `vim` as the final fallback, and multiple matches render
a numbered prompt. At that prompt you can press Enter to open all matches with
`vim -p`, type
one number to open one file, type comma-separated numbers such as `1,3`, or use
a range such as `2-5`. Scoped searches also rank exact helper/script names
before broader substring matches, so `dashboard of . jq` lists `jq` and
`jq.js` ahead of `jquery.js`.

### Data Query Commands

These built-in commands parse structured text and optionally extract a dotted path:

- `dashboard jq [path] [file]` for JSON (also `pjq` for backward compatibility)
- `dashboard yq [path] [file]` for YAML (also `pyq` for backward compatibility)
- `dashboard tomq [path] [file]` for TOML (also `ptomq` for backward compatibility)
- `dashboard propq [path] [file]` for Java properties (also `pjp` for backward compatibility)
- `dashboard iniq [path] [file]` for INI files (new)
- `dashboard csvq [path] [file]` for CSV files (new)
- `dashboard xmlq [path] [file]` for XML files (new)

If the selected value is a hash or array, the command prints canonical JSON. If the selected value is a scalar, it prints the scalar plus a trailing newline.

The file path and query path are order-independent, and `$d` selects the whole parsed document. For example, `cat file.json | dashboard jq '$d'` and `dashboard jq file.json '$d'` return the same result. The same contract applies to `yq`, `tomq`, `propq`, `iniq`, `csvq`, and `xmlq` commands.

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
rm -rf Developer-Dashboard-* Developer-Dashboard-*.tar.gz
dzil build
```

The release gather rules exclude local coverage output such as `cover_db`, so
covered runs before `dzil build` do not leak Devel::Cover artifacts into the
shipped tarball.

Run the CLI directly from the repository:

```bash
perl -Ilib bin/dashboard init
perl -Ilib bin/dashboard auth add-user <username> <password>
perl -Ilib bin/dashboard version
perl -Ilib bin/dashboard of --print My::Module
perl -Ilib bin/dashboard open-file --print com.example.App
printf '{"alpha":{"beta":2}}' | perl -Ilib bin/dashboard jq alpha.beta
printf 'alpha:\n  beta: 3\n' | perl -Ilib bin/dashboard yq alpha.beta
mkdir -p ~/.developer-dashboard/cli/update
printf '#!/bin/sh\necho runtime-update\n' > ~/.developer-dashboard/cli/update/01-runtime
chmod +x ~/.developer-dashboard/cli/update/01-runtime
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

mkdir -p ~/.developer-dashboard/cli/jq
printf '#!/usr/bin/env perl\nprint "seed\\n";\n' > ~/.developer-dashboard/cli/jq/00-seed.pl
chmod +x ~/.developer-dashboard/cli/jq/00-seed.pl
printf '{"alpha":{"beta":2}}' | perl -Ilib bin/dashboard jq alpha.beta
```

Per-command hook files can live under either
`./.developer-dashboard/cli/<command>/` or
`./.developer-dashboard/cli/<command>.d/` in every inherited layer from
`~/.developer-dashboard` down to the current directory. Executable files in
those directories are run in sorted filename order within each layer, with the
layers themselves running top-down from home to the deepest current layer,
non-executable files are skipped, and each hook now streams its own `stdout`
and `stderr` live to the terminal while still accumulating those channels into
`RESULT` as JSON. Built-in
commands such as `dashboard jq` use the same hook directory. A directory-backed
custom command can provide its real executable as
`~/.developer-dashboard/cli/<command>/run`, and that runner receives the final
`RESULT` environment variable. After each hook finishes, `dashboard` rewrites
`RESULT` before the next sorted hook starts, so later hook scripts can react to
earlier hook output. Perl hook scripts can read that JSON through
`Developer::Dashboard::Runtime::Result`. If a Perl-backed command wants a
compact final summary after its hook files run, it can call
`Developer::Dashboard::Runtime::Result->report()` to print a simple
success/error report for each sorted hook file.

If you want `dashboard update`, provide it as a normal user command at
`./.developer-dashboard/cli/update` or `./.developer-dashboard/cli/update/run`
in any inherited layer, with the deepest matching layer winning the final
command path. Its hook files can live under `update/` or `update.d/`, and the
real command receives the final `RESULT` JSON through the environment after
those hook files run.

Use `dashboard version` to print the installed Developer Dashboard version.

The blank-container integration harness now installs the tarball first and then
builds a fake-project `./.developer-dashboard` tree so the shipped test suite
still starts from a clean runtime before exercising project-local overrides.
That same blank-container path now also verifies web stop/restart behavior in a
minimal image where listener ownership may need to be discovered from `/proc`
instead of `ss`, including a late listener re-probe before `dashboard restart`
brings the web service back up.

### First Run

Initialize the runtime:

```bash
dashboard init
```

Inspect resolved paths:

```bash
dashboard paths
dashboard path resolve bookmarks_root
dashboard path add foobar /tmp/foobar
dashboard path del foobar
```

Custom path aliases are stored in the effective dashboard config root so shell helpers such as `cdr foobar` and `which_dir foobar` keep working across sessions. When a project-local `./.developer-dashboard` tree exists, alias writes go there first; otherwise they go to the home runtime. When a saved alias points inside your home directory, the stored config uses `$HOME/...` instead of a hard-coded absolute home path so a shared fallback runtime remains portable across different developer accounts. Re-adding an existing alias updates it without error, and deleting a missing alias is also safe.

Use `Developer::Dashboard::Folder` for runtime path helpers. It resolves the
same runtime, bookmark, config, and configured alias names exposed by
`dashboard paths`, including names such as `docker`, without relying on
unscoped CPAN-global module names.

Render shell bootstrap for bash, zsh, POSIX sh, or PowerShell:

```bash
dashboard shell bash
dashboard shell zsh
dashboard shell sh
dashboard shell ps
```

Audit runtime permissions:

```bash
dashboard doctor
dashboard doctor --fix
```

Resolve or open files from the CLI:

```bash
dashboard of --print My::Module
dashboard open-file --print com.example.App
dashboard open-file --print path/to/file.txt
dashboard open-file --print bookmarks welcome
```

Query structured files from the CLI:

```bash
printf '{"alpha":{"beta":2}}' | dashboard jq alpha.beta
printf 'alpha:\n  beta: 3\n' | dashboard yq alpha.beta
printf '[alpha]\nbeta = 4\n' | dashboard tomq alpha.beta
printf 'alpha.beta=5\n' | dashboard propq alpha.beta
dashboard jq file.json '$d'
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

Bookmark documents use the original separator-line format with directive headers such as `TITLE:`, `STASH:`, `HTML:`, and `CODE1:`.
Posting a bookmark document with `BOOKMARK: some-id` back through the root editor now saves it to the bookmark store so `/app/some-id` resolves it immediately.

The browser editor now renders syntax-highlight markup again, but keeps that highlight layer inside a clipped overlay viewport that follows the real textarea scroll position by transform instead of via a second scrollbox. That restores the visible highlighting while keeping long bookmark lines, full-text selection, and caret placement aligned with the real textarea.
Edit and source views preserve raw Template Toolkit placeholders inside `HTML:` sections, so values such as `[% title %]` are kept in the bookmark source instead of being rewritten to rendered HTML after a browser save.

Template Toolkit rendering exposes the page title as `title`, so a bookmark
with `TITLE: Sample Dashboard` can reference it directly inside `HTML:` with
`[% title %]`. Transient play and view-source links are also
encoded from the raw bookmark instruction text when it is available, so
`[% stash.foo %]` stays in source views instead of being baked into the
rendered scalar value after a render pass.

Earlier `CODE*` blocks now run before Template Toolkit rendering during
`prepare_page`, so a block such as `CODE1: { a => 1 }` can feed
`[% stash.a %]` in the page body. Returned hash and array values are also
dumped into the runtime output area, so `CODE1: { a => 1 }` both populates
stash and shows the bookmark-style dumped value below the rendered page body.
The `hide` helper no longer discards already-printed STDOUT, so
`CODE2: hide print $a` keeps the printed value while suppressing the Perl
return value from affecting later merge logic.

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

Collector jobs support two execution fields:

- `command` runs a shell command string through the native platform shell: `sh -lc` on Unix-like systems and PowerShell on Windows
- `code` runs Perl code directly inside the collector runtime

Example collector definitions:

```json
{
  "collectors": [
    {
      "name": "shell.example",
      "command": "printf 'shell collector\\n'",
      "cwd": "home",
      "interval": 60
    },
    {
      "name": "perl.example",
      "code": "print qq(perl collector\\n); return 0;",
      "cwd": "home",
      "interval": 60,
      "indicator": {
        "icon": "P"
      }
    }
  ]
}
```

Collector indicators follow the collector exit code automatically: `0` stores
an `ok` indicator state and any non-zero exit code stores `error`.
When `indicator.name` is omitted, the collector name is reused automatically.
When `indicator.label` is omitted, it defaults to that same name.
Configured collector indicators are now seeded immediately, so prompt and page
status strips show them before the first collector run. Before a collector has
produced real output it appears as missing. Prompt output renders an explicit
status glyph in front of the collector icon, so successful checks show `✅🔑`
style fragments and failing or not-yet-run checks show `🚨🔑` style fragments.
The top-right browser status strip now uses that same configured icon instead
of falling back to the collector name, and stale managed indicators are
removed automatically if the collector config is renamed. The browser chrome
now uses an emoji-capable font stack there as well, so UTF-8 icons such as
`🐳` and `💰` remain visible instead of collapsing into fallback boxes.
The blank-environment integration flow also keeps a regression for mixed
collector health isolation: one intentionally broken Perl collector must stay
red without stopping a second healthy collector from staying green in
`dashboard indicator list`, `dashboard ps1`, and `/system/status`.

### Docker Compose

Inspect the resolved compose stack without running Docker:

```bash
dashboard docker compose --dry-run config
```

Include addons or modes:

```bash
dashboard docker compose --addon mailhog --mode dev up -d
dashboard docker compose config green
dashboard docker compose config
```

The resolver also supports old-style isolated service folders without adding entries to dashboard JSON config. If `./.developer-dashboard/docker/green/compose.yml` exists in the current project it wins; otherwise the resolver falls back to `~/.developer-dashboard/config/docker/green/compose.yml`. `dashboard docker compose config green` or `dashboard docker compose up green` will pick it up automatically by inferring service names from the passthrough compose args before the real `docker compose` command is assembled. If no service name is passed, the resolver scans isolated service folders and preloads every non-disabled folder. If a folder contains `disabled.yml` it is skipped. Each isolated folder contributes `development.compose.yml` when present, otherwise `compose.yml`.

During compose execution the dashboard exports `DDDC` as the effective config-root docker directory for the current runtime, so compose YAML can keep using `${DDDC}` paths inside the YAML itself.
Wrapper flags such as `--service`, `--addon`, `--mode`, `--project`, and `--dry-run` are consumed first, and all remaining docker compose flags such as `-d` and `--build` pass straight through to the real `docker compose` command.
Without `--dry-run`, the dashboard hands off with `exec`, so you see the normal streaming output from `docker compose` itself instead of a dashboard JSON wrapper.

### Prompt Integration

Render prompt text directly:

```bash
dashboard ps1 --jobs 2
```

`dashboard ps1` now follows the original `~/bin/ps1` shape more closely: a
`(YYYY-MM-DD HH:MM:SS)` timestamp prefix, dashboard status and ticket info, a
bracketed working directory, an optional jobs suffix, and a trailing
`🌿branch` marker when git metadata is available. If the ticket workflow
seeded `TICKET_REF` into the current tmux session, `dashboard ps1` also reads
it from tmux when the shell environment does not already export it.

The path helpers also treat path identity canonically where the filesystem can
surface aliases. On macOS, `dashboard path project-root` may report the same
repo through `/private/var/...` even when the shell entered it through
`/var/...`, and the test/install contract now treats those as the same real
path instead of failing on a raw-string mismatch.

Generate shell bootstrap:

```bash
dashboard shell bash
dashboard shell zsh
dashboard shell sh
dashboard shell ps
```

The generated shell helper keeps the same bookmark-aware `cdr`, `dd_cdr`, and
`which_dir` functions across all supported shells. Bash still uses `\j` for
job counts, zsh refreshes `PS1` through a `precmd` hook with `${#jobstates}`,
POSIX `sh` falls back to a prompt command that does not depend on bash-only
prompt escapes, and PowerShell installs a `prompt` function instead of using
the POSIX `PS1` variable.

On Windows, `dashboard shell` auto-selects PowerShell by default, and
interpreter-backed runtime entrypoints such as collector `command` strings,
trusted command actions, saved Ajax files, custom CLI commands, hook files,
and update scripts now resolve `.ps1`, `.cmd`, `.bat`, and `.pl` runners
without assuming `sh` or `bash`. That keeps Strawberry Perl installs usable
without requiring a Unix shell just to load the dashboard runtime.

The checked-in Windows verification assets follow the same layered approach:
fast forced-Windows unit coverage in `t/`, a real Strawberry Perl host smoke in
`integration/windows/run-strawberry-smoke.ps1`, and a host-side rerun helper in
`integration/windows/run-host-windows-smoke.sh` that delegates to
`integration/windows/run-qemu-windows-smoke.sh` for release-grade Windows
compatibility claims. The supported baseline on Windows is PowerShell plus
Strawberry Perl. Git Bash is optional. Scoop is optional. They are setup
helpers, not runtime requirements for the installed `dashboard` command. In
the Dockur-backed path, the launcher stages the Strawberry Perl MSI from the
Linux host into the OEM bundle and can keep multiple retained Windows guests
alive on configurable host web/RDP ports while it reruns the same smoke.

### Browser Access Model

The browser security model follows the original local-first trust concept:

- requests from exact `127.0.0.1` with a numeric `Host` of `127.0.0.1` are treated as local admin
- requests from other IPs or from hostnames such as `localhost` are treated as helper access
- outsider requests return `401` without a login page until at least one helper user exists
- after a helper user exists, outsider requests receive the helper login page
- helper sessions are file-backed, bound to the originating remote address, and expire automatically
- helper passwords must be at least 8 characters long

The editor and rendered pages also include a shared top chrome with share/source links on the left and the original status-plus-alias indicator strip on the right, refreshed from `/system/status`. That top-right area also includes the local username, the current host or IP link, and the current date/time in the same spirit as the old local dashboard chrome.
The displayed address is discovered from the machine interfaces, preferring a VPN-style address when one is active, and the date/time is refreshed in the browser with JavaScript.
The bookmark editor also follows the old auto-submit flow, so the form submits when the textarea changes and loses focus instead of showing a manual update button.
For saved bookmark files, that browser save posts back to the named
`/app/<id>/edit` route and keeps the Play link on `/app/<id>` instead of a
transient `token=` URL, so updates still work while transient URLs are
disabled.
Bookmark parsing also treats a standalone `---` line as a section
break, preventing pasted prose after a code block from being compiled into the
saved `CODE*` body.
Saved bookmark loads now also normalize malformed bookmark icon bytes from older files before the
browser sees them. Broken section glyphs fall back to `◈`, broken item-icon
glyphs fall back to `🏷️`, and common damaged joined emoji sequences such as
`🧑‍💻` are repaired so edit and play routes stop showing Unicode replacement
boxes from older bookmark files.
- helper access requires a login backed by local file-based user and session records

This keeps the fast path for exact loopback access while making non-canonical or remote access explicit.

The default web bind is `0.0.0.0:7890`. Trust is still decided from the request origin and host header, not from the listen address.

`DD-OOP-LAYERS` comparisons normalize canonical path identities, so symlinked
aliases such as macOS `/var/...` versus `/private/var/...` do not break layer
discovery, deepest-layer writes, or layered bookmark/nav lookup.

### Runtime Lifecycle

- `dashboard serve` starts the web service in the background by default
- `dashboard serve` starts the configured collector loops alongside the web service, so a plain serve keeps collectors and the web runtime under the same lifecycle action
- `dashboard serve --foreground` keeps the web service attached to the terminal
- `dashboard serve --ssl` enables HTTPS in Starman with the generated local certificate and key, redirects non-HTTPS requests to the matching `https://...` URL, and reuses the saved SSL setting on later `dashboard restart` runs unless you override it
- `dashboard serve logs` prints the combined Dancer2 and Starman runtime log captured in the dashboard log file, `dashboard serve logs -n 100` starts from the last 100 lines, and `dashboard serve logs -f` follows appended output live
- `dashboard serve workers N` saves the default Starman worker count and starts the web service immediately when it is currently stopped; `--host HOST` and `--port PORT` can steer that auto-start path, and `dashboard serve --workers N` or `dashboard restart --workers N` can still override it for one run
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

Collector definitions now come only from dashboard configuration JSON, so config remains the single source of truth for saved path aliases, providers, collectors, and Docker compose overlays.

### Updating Runtime State

Run your user-provided update command:

```bash
dashboard update
```

If `~/.developer-dashboard/cli/update` or `~/.developer-dashboard/cli/update/run`
exists, `dashboard update` runs that command after any sorted hook files from
`~/.developer-dashboard/cli/update/` or `~/.developer-dashboard/cli/update.d/`.

`dashboard init` seeds three editable starter bookmarks when they are missing:
`welcome`, `api-dashboard`, and `sql-dashboard`.

Re-running `dashboard init` keeps an existing
`~/.developer-dashboard/config/config.json` intact. The command only fills in
missing default collector config, refreshes missing private helper commands,
and seeds starter bookmarks that are not already present.

The public `dashboard` entrypoint also stays thin for all built-in commands.
It only stages and execs helper assets from `share/private-cli/`: dedicated
helper bodies for `dashboard jq`, `dashboard yq`, `dashboard of`,
`dashboard open-file`, `dashboard ticket`, `dashboard path`, `dashboard
paths`, and `dashboard ps1`, plus thin wrappers for the remaining built-ins
that hand off to the shared private `_dashboard-core` runtime. The shipped
starter bookmark source lives under `share/seeded-pages/`, and the shipped
helper scripts live under `share/private-cli/`, so neither bookmark bodies nor
helper script bodies are embedded directly in the command script. Installed
copies resolve the same
seeded pages and helper assets from the distribution share directory, so
`dashboard init` works after `cpanm` installs and not just from a source
checkout.

The seeded `api-dashboard` bookmark now behaves like a local Postman-style
workspace. It keeps multiple request tabs in browser-local state, supports
import and export of Postman collection v2.1 JSON through the Collections tab,
saves created, updated, and imported collections as Postman collection JSON
under the runtime `config/api-dashboard/<collection-name>.json` path, reloads
every stored collection when the bookmark opens, keeps the active collection,
request, and tab reflected in the browser URL for direct-link and back/forward
navigation, renders Collections and Workspace as top-level tabs for narrower
browser layouts, renders stored collections as click-through tabs instead of
one long vertical stack, shows a request-specific token form above the editor
whenever the selected request uses `{{token}}` placeholders, carries those
token values across matching placeholders in other requests from the same
collection, resolves those token values into the visible request URL, headers,
and body fields, renders a hide/show `Request Credentials` section in the
workspace with Postman-compatible `Basic`, `API Token`, `API Key`, `OAuth2`,
`Apple Login`, `Amazon Login`, `Facebook Login`, and `Microsoft Login`
presets, hydrates imported Postman `request.auth` data back into that
credentials panel, exports saved request auth back into valid Postman JSON,
and applies the configured auth to outgoing headers or query strings when the
request is sent. The OAuth-style provider presets fill common authorize/token
URLs, but the actual access token and client details remain values the user
enters for that request. The bookmark also tightens project-local
`config/api-dashboard` to `0700` and each saved collection JSON file there to
`0600`, because saved request auth can include secrets inside the Postman
collection JSON. It renders Request Details, Response Body, and Response
Headers as inner workspace tabs below the response `pre` box, defaults
Response Body back to the active tab after each send, previews JSON, text,
PDF, image, and TIFF responses appropriately, and sends requests through its
saved Ajax endpoint backed by `LWP::UserAgent`. HTTPS endpoints also require
the packaged `LWP::Protocol::https` runtime prerequisite, so clean installs
can test normal TLS APIs without browser CORS rules. Oversized collection
saves now spill the saved Ajax request payload through temp files instead of
overflowing `execve` environment limits, and the bookmark rejects empty `200`
save/delete responses instead of claiming success when nothing was persisted.

`dashboard cpan <Module...>` installs optional Perl modules into the active
runtime-local `./.developer-dashboard/local` tree and appends matching
`requires 'Module';` lines to `./.developer-dashboard/cpanfile`. The command
stays implemented in the `dashboard` entrypoint rather than introducing a
separate SQL or CPAN manager product module, and saved Ajax workers infer the
same runtime-local `local/lib/perl5` path directly from the active runtime
root. When the requested modules include `DBD::*`, the command also installs
and records `DBI` automatically so generic database driver requests work with
a single command.

The seeded `sql-dashboard` bookmark is a file-backed SQL workspace built
inside the bookmark runtime itself rather than as a separate product module.
It stores connection profiles under
`config/sql-dashboard/<profile-name>.json`, keeps that
`config/sql-dashboard` directory owner-only at `0700`, writes each saved
profile JSON file owner-only at `0600`, stores saved SQL collections under
`config/sql-dashboard/collections/<collection-name>.json` with the same
owner-only `0700` / `0600` directory and file permissions, keeps the active
top-level tab, portable `connection` id, selected collection, selected saved
SQL item, selected schema table, and current SQL in the browser URL instead
of a saved SQL file, and treats SQL collections and connection profiles as
separate concepts so the same saved SQL can run against different
connections. Share URLs only carry the DSN-plus-user connection id without a
password; if another machine already has a matching saved profile with a
saved password, the bookmark reruns the shared SQL there, otherwise it opens
a draft connection profile built from that connection id so the other user
can add the local password and run it. The profile editor now renders the
driver field as a dropdown of installed `DBD::*` modules and rewrites only
the `dbi:<Driver>:` DSN prefix when you switch drivers. The main browser flow
now merges collections and editing into one `SQL Workspace` tab with a
phpMyAdmin-style master-detail layout: collection tabs stay in the left
navigation rail, the saved SQL list for the active collection appears
directly below that heading, the right pane keeps the editor plus results
together, and the active saved SQL name stays visible while you work. Saving
a different SQL name into the same collection adds a second saved SQL entry
instead of overwriting the selected one. The workspace editor now keeps the
SQL textarea as the primary focus with content-based auto-resize, uses one
quiet action row under the editor instead of a loud toolbar, removes the
redundant in-workspace schema button in favour of the top `Schema Explorer`
tab, and moves saved-SQL deletion to a compact inline `[X]` control beside
each saved query so the list stays visually tied to its collection. The
bookmark still renders profile tabs and schema tabs, executes SQL through
generic `DBI`, and uses DBI metadata calls such as `table_info` and
`column_info` for the schema browser. It preserves programmable statement
blocks through `SQLS_SEP` and `INSTRUCTION_SEP`, including `STASH`, `ROW`,
`BEFORE`, and `AFTER` hooks, so result rows can still be transformed locally
before rendering. Its saved Ajax endpoints run through singleton workers. No
`DBD::*` driver ships in the base tarball by default; install the one you
need with `dashboard cpan DBD::Driver`, and the bookmark will return
explicit install guidance when a selected driver is missing.

### Skills System

Extend dashboard with Git-backed skill packages:

**Install a skill** from a Git repository:

```bash
dashboard skills install git@github.com:user/example-skill.git
dashboard skills install https://github.com/user/example-skill.git
```

**List installed skills:**

```bash
dashboard skills list
```

Returns JSON output showing installed skills with metadata:
- skill name (derived from repository name)
- path to installed skill directory
- whether skill has configuration, CLI commands, cpanfile

**Update a skill** to the latest version:

```bash
dashboard skills update example-skill
```

**Execute a skill command:**

```bash
dashboard skill example-skill somecmd arg1 arg2
```

**Uninstall a skill:**

```bash
dashboard skills uninstall example-skill
```

Each installed skill lives under `~/.developer-dashboard/skills/<repo-name>/` with:

- `cli/` - Skill commands (executable scripts, never installed to system PATH)
- `cli/<cmd>.d/` - Hook files for commands (pre/post hooks)
- `config/config.json` - Skill metadata and configuration
- `config/docker/` - Skill-local Docker Compose files
- `state/` - Persistent skill state and data
- `logs/` - Skill output logs
- `cpanfile` - Skill Perl dependencies (optional)

Skills are completely isolated from the main dashboard runtime and from other
skills. Removing a skill is simple: `dashboard skills uninstall <repo-name>`
cleanly removes only that skill's directory.

### Skill Authoring

To build a new skill, start with a Git repository that contains `cli/`,
`config/config.json`, and optional `dashboards/`, `state/`, `logs/`, `local/`,
and `cpanfile` files under the skill root. Skill commands are file-based
commands run through `dashboard skill <repo-name> <command>`, skill hook files
live under `cli/<command>.d/`, and skill bookmarks render from
`/skill/<repo-name>/bookmarks/<id>`.

The full skill authoring reference lives in `SKILL.md` and the shipped POD
module `Developer::Dashboard::SKILLS`. Those guides cover the isolated skill
layout, environment variables such as `DEVELOPER_DASHBOARD_SKILL_ROOT`,
bookmark syntax like `TITLE:`, `BOOKMARK:`, `HTML:`, and `CODE1:`, bookmark
browser helpers such as `fetch_value()`, `stream_value()`, and
`stream_data()`, and when to use dashboard-wide custom CLI hook folders such
as `~/.developer-dashboard/cli/<command>.d` instead of a skill-local hook
tree.

### Blank Environment Integration

## FAQ

### Is this tied to a specific company or codebase?

No. It is meant to give an individual developer one familiar working home that can travel across the projects they touch.

### Where should project-specific behavior live?

In configuration, saved pages, and user CLI extensions. That keeps the main dashboard experience stable while still letting each project add the local pages, checks, paths, and helpers it needs.

### Is the software spec implemented?

The current distribution implements the core runtime, page engine, action runner, provider loader, prompt and collector system, web lifecycle manager, and Docker Compose resolver described by the software spec.

What remains intentionally lightweight is breadth, not architecture:

- provider pages and action handlers are implemented in a compact v1 form
- bookmark-file pages are supported, with Template Toolkit rendering and one clean sandpit package per page run so `CODE*` blocks can share state within a bookmark render without leaking runtime globals into later requests

### Does it require a web framework?

No. The current distribution includes a minimal HTTP layer implemented with core Perl-oriented modules.

### Why does localhost still require login?

This is intentional. The trust rule is exact and conservative: only numeric loopback on `127.0.0.1` receives local-admin treatment.

### Why does localhost sometimes get 401 without a login page?

Until at least one helper user exists, outsider access is disabled entirely. That includes `localhost`, forwarded hostnames, and non-loopback IPs. Add a helper user first, then outsider requests will receive the login page instead of the disabled-access response.

### Why is the runtime file-backed?

Because prompt rendering, dashboards, and wrappers should consume prepared state quickly instead of re-running expensive checks inline.

### What JSON implementation does the project use?

The project uses `JSON::XS` for JSON encoding and decoding, including shell helper decoding paths.

### What does the project use for command capture and HTTP clients?

The project uses `Capture::Tiny` for command-output capture via `capture`, with exit codes returned from the capture block rather than read separately. There is currently no outbound HTTP client in the core runtime, so `LWP::UserAgent` is not yet required by an active code path.

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
The runtime-manager coverage cases also use bounded child reaping for stubborn
process shutdown scenarios, so `Devel::Cover` runs do not stall indefinitely
after the escalation path has already been exercised.
Tests that depend on a missing or empty environment variable now establish that
state explicitly inside the test file, rather than assuming the parent shell
or install harness starts clean.

For fast saved-bookmark browser regressions, run the dedicated smoke script:

```bash
integration/browser/run-bookmark-browser-smoke.pl
```

That host-side smoke runner creates an isolated temporary runtime, starts the
checkout-local dashboard, loads one saved bookmark page through headless
Chromium, and can assert page-source fragments, saved `/ajax/...` output, and
the final browser DOM. With no arguments it runs the built-in Ajax
`foo.bar` bookmark case. For a real bookmark file, point it at the saved file
and add explicit expectations:

```bash
integration/browser/run-bookmark-browser-smoke.pl \
  --bookmark-file ~/.developer-dashboard/dashboards/test \
  --expect-page-fragment "set_chain_value(foo,'bar','/ajax/foobar?type=text')" \
  --expect-ajax-path /ajax/foobar?type=text \
  --expect-ajax-body 123 \
  --expect-dom-fragment '<span class="display">123</span>'
```

For `api-dashboard` import regressions against a real external Postman
collection, run the generic Playwright repro with an explicit fixture path:

```bash
API_DASHBOARD_IMPORT_FIXTURE=/path/to/collection.postman_collection.json \
prove -lv t/23-api-dashboard-import-fixture-playwright.t
```

That browser test injects the external fixture into the visible
`api-dashboard` import control and verifies that the collection appears in the
Collections tab, opens from the tree, and persists to
`config/api-dashboard/<collection-name>.json` without baking fixture-specific
branding into the repository.

For oversized `api-dashboard` imports that need to stay browser-verified above
the saved-Ajax inline payload threshold, run:

```bash
prove -lv t/25-api-dashboard-large-import-playwright.t
```

That Playwright test imports a deliberately large Postman collection through
the visible browser file input and verifies that the browser still reports a
successful import instead of failing with an `Argument list too long` transport
error.

For the tabbed `api-dashboard` browser layout, run the dedicated Playwright
coverage:

```bash
prove -lv t/24-api-dashboard-tabs-playwright.t
```

That browser test verifies the top-level Collections and Workspace tabs, the
collection-to-collection tab strip inside the Collections view, and the inner
Request Details, Response Body, and Response Headers tabs below the response
`pre` box so the bookmark remains usable in constrained browser widths.

For `sql-dashboard` browser coverage, run:

```bash
prove -lv t/27-sql-dashboard-playwright.t
```

That browser test creates a profile through the visible bookmark UI, runs
programmable SQL through a fake runtime-local `DBI` stack under
`.developer-dashboard/local/lib/perl5`, verifies the shareable URL state, and
checks the schema table-tab browser.

For Windows-targeted changes, also run the Strawberry Perl smoke on a Windows
host:

```powershell
powershell -ExecutionPolicy Bypass -File integration/windows/run-strawberry-smoke.ps1 -Tarball C:\path\Developer-Dashboard-*.tar.gz
```

Before calling a release Windows-compatible, also run the same smoke through
the host-side Windows VM helper:

```bash
WINDOWS_QEMU_ENV_FILE=.developer-dashboard/windows-qemu.env \
integration/windows/run-host-windows-smoke.sh
```

That helper keeps the Windows VM path rerunnable by loading a reusable env
file, rebuilding the latest tarball when needed, and then delegating to the
checked-in QEMU launcher. The supported baseline on Windows is PowerShell plus
Strawberry Perl. Git Bash is optional. Scoop is optional. They are setup
helpers only. In the Dockur-backed path, the launcher can resolve the latest
64-bit Strawberry Perl MSI from Strawberry Perl's official `releases.json`
feed so the env file does not need a pinned installer URL for every rerun.
That same Windows guest smoke can install the tarball with `cpanm --notest`
for third-party dependency setup while still running the full Developer
Dashboard CLI, collector, Ajax, web, and browser smoke afterward.
