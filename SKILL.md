# Skill Authoring Guide

This guide is for people who want to create a new Developer Dashboard skill
without keeping the Developer Dashboard source tree open beside them.

It explains:

- what a skill is
- when to use a skill instead of a normal dashboard bookmark or custom CLI command
- the directory layout Developer Dashboard expects
- how skill CLI commands and hook directories work
- how skill bookmarks are routed
- what bookmark syntax and browser helpers Developer Dashboard supports
- where the current boundaries are, so you do not build against behavior that does not exist

If you only remember one thing, remember this:

Developer Dashboard skills are Git-backed, isolated packages installed under
`~/.developer-dashboard/skills/<repo-name>/`. They can ship CLI commands,
hooks, config, bookmarks, optional Perl dependencies, and their own state and
log folders, but they do not get the whole core runtime automatically.

## 1. What A Skill Is

A skill is a repository that Developer Dashboard installs and runs in its own
isolated skill root.

Use a skill when you want a shareable package that can provide:

- one or more commands under `dashboard skill <repo-name> <command>`
- skill-local hook files under `cli/<command>.d/`
- one or more browser bookmarks under `/skill/<repo-name>/bookmarks/<id>`
- optional isolated Perl dependencies from a `cpanfile`
- its own `config/`, `state/`, `logs/`, and `local/` directories

Do not use a skill when you only need a one-off command or bookmark for one
project. In that case, a normal dashboard runtime command or bookmark is often
the simpler tool:

- project or home CLI extensions live under `./.developer-dashboard/cli/` or
  `~/.developer-dashboard/cli/`
- normal saved bookmarks live under `./.developer-dashboard/dashboards/` or
  `~/.developer-dashboard/dashboards/`

## 2. Quick Start

Start with a normal Git repository:

```text
example-skill/
├── cli/
│   └── hello
├── config/
│   └── config.json
└── dashboards/
    └── welcome
```

Minimal command:

```perl
#!/usr/bin/env perl
use strict;
use warnings;

print "hello from skill\n";
```

Minimal config:

```json
{
  "skill_name": "example-skill"
}
```

Minimal bookmark:

```text
TITLE: Example Skill
:--------------------------------------------------------------------------------:
BOOKMARK: welcome
:--------------------------------------------------------------------------------:
NOTE: A bookmark shipped by a skill.
:--------------------------------------------------------------------------------:
HTML:
<h1>Example Skill</h1>
<p>This page came from the skill repository.</p>
```

Install it:

```bash
dashboard skills install file:///absolute/path/to/example-skill
```

Run its command:

```bash
dashboard skill example-skill hello
```

List its shipped bookmarks:

```bash
curl http://127.0.0.1:7890/skill/example-skill/bookmarks
```

Render one bookmark in the browser:

```text
http://127.0.0.1:7890/skill/example-skill/bookmarks/welcome
```

## 3. Skill Lifecycle Commands

Developer Dashboard already gives you the lifecycle commands:

```bash
dashboard skills install git@github.com:user/example-skill.git
dashboard skills update example-skill
dashboard skills list
dashboard skills uninstall example-skill
dashboard skill example-skill hello arg1 arg2
```

Important behavior:

- the installed skill name is derived from the Git repository basename
- the repository is cloned under `~/.developer-dashboard/skills/<repo-name>/`
- `dashboard skills update` does `git pull --ff-only`
- `dashboard skills uninstall` removes only that skill directory
- skill commands are not installed into the system `PATH`

## 4. Filesystem Layout

The skill manager prepares this layout inside the installed skill root:

```text
~/.developer-dashboard/skills/<repo-name>/
├── cli/
├── config/
│   ├── config.json
│   └── docker/
├── dashboards/
├── state/
├── logs/
├── local/
└── cpanfile
```

### `cli/`

Put executable skill commands here.

If you create:

```text
cli/report
```

you run it as:

```bash
dashboard skill <repo-name> report
```

Current rule: skill commands are file-based commands. Create a real executable
file such as `cli/report`, `cli/report.pl`, `cli/report.sh`, or `cli/report.ps1`.
Do not rely on a directory-backed `cli/report/run` pattern here. That `run`
pattern exists for dashboard-wide custom CLI commands, not for skill commands.

### `cli/<command>.d/`

Put executable hook files here.

Example:

```text
cli/report
cli/report.d/
├── 00-validate
└── 10-log-context
```

Hook behavior:

- executable files run in sorted filename order
- non-executable files are skipped
- hook `stdout` and `stderr` are captured
- hook results are serialized into `RESULT` JSON for later hooks and the main command
- the main skill command still runs after hooks; hook failure does not
  automatically short-circuit command execution

If you need hard-stop behavior, enforce it yourself in your main command by
inspecting `RESULT` and exiting when a required hook failed.

### `config/config.json`

This is the skill's own JSON config file.

Developer Dashboard does not enforce a rich schema here. The file is mainly
for your skill. The dispatcher exposes it to skill-side code and guarantees the
path exists.

A safe starting point is:

```json
{
  "skill_name": "example-skill"
}
```

### `config/docker/`

Reserved space for skill-local Docker or Compose-related files.

Current behavior:

- `dashboard skills list` metadata records the directories under `config/docker/`
- skill commands and hooks get `DEVELOPER_DASHBOARD_SKILL_DOCKER_ROOT`
- the core skill system does not automatically run Docker Compose for these files

Use this when your skill command wants to manage its own containers, configs, or
compose fragments.

### `dashboards/`

Put skill-shipped bookmark instruction files here.

Example:

```text
dashboards/
├── welcome
├── status
└── nav/
   └── help.tt
```

Skill bookmark routes are:

- list: `/skill/<repo-name>/bookmarks`
- render: `/skill/<repo-name>/bookmarks/<id>`

Examples:

- `/skill/example-skill/bookmarks/welcome`
- `/skill/example-skill/bookmarks/status`
- `/skill/example-skill/bookmarks/nav/help.tt`

Important current behavior:

- the bookmark list route only lists top-level files under `dashboards/`
- nested bookmark files can still be rendered directly if you know the path
- skill bookmarks are render routes, not browser editing routes
- edit the files in the skill repository itself

### `state/`

Use this for skill-owned persistent state. Developer Dashboard creates the
directory but does not define the files inside it for you.

### `logs/`

Use this for skill-owned log files. Again, the folder exists for you, but the
format and retention policy are your responsibility.

### `local/`

This is the isolated dependency root for the skill.

If the skill ships a `cpanfile`, Developer Dashboard runs:

```bash
cpanm -L local --installdeps <skill-root>
```

and the dispatcher prepends `local/lib/perl5` to `PERL5LIB` for skill hooks and
skill commands.

### `cpanfile`

Optional. Add this if the skill needs Perl dependencies that should stay local
to the skill rather than becoming a Developer Dashboard core dependency.

## 5. Writing Skill CLI Commands

Skill commands receive argv exactly as the user passed them after the skill name
and command name.

Example:

```bash
dashboard skill example-skill report one two
```

means your command sees:

- `one`
- `two`

### Example Perl Command

```perl
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::XS qw(decode_json);

my $result = decode_json($ENV{RESULT} || '{}');
print "command args: @ARGV\n";
print "hook files seen: " . join(', ', sort keys %$result) . "\n";
print "skill root: $ENV{DEVELOPER_DASHBOARD_SKILL_ROOT}\n";
```

### Example Shell Command

```sh
#!/usr/bin/env sh
set -eu

printf 'skill command running in %s\n' "$DEVELOPER_DASHBOARD_SKILL_ROOT"
printf 'args: %s\n' "$*"
```

### Environment Variables Available To Skill Hooks And Commands

Developer Dashboard currently sets these:

- `DEVELOPER_DASHBOARD_SKILL_NAME`
- `DEVELOPER_DASHBOARD_SKILL_ROOT`
- `DEVELOPER_DASHBOARD_SKILL_COMMAND`
- `DEVELOPER_DASHBOARD_SKILL_CLI_ROOT`
- `DEVELOPER_DASHBOARD_SKILL_CONFIG_ROOT`
- `DEVELOPER_DASHBOARD_SKILL_DOCKER_ROOT`
- `DEVELOPER_DASHBOARD_SKILL_STATE_ROOT`
- `DEVELOPER_DASHBOARD_SKILL_LOGS_ROOT`
- `DEVELOPER_DASHBOARD_SKILL_LOCAL_ROOT`
- `RESULT`
- `PERL5LIB`

`RESULT` is JSON with one entry per hook file:

```json
{
  "00-validate": {
    "stdout": "ok\n",
    "stderr": "",
    "exit_code": 0
  }
}
```

## 6. Dashboard-Wide Custom CLI Vs Skill CLI

This matters because the two surfaces are related but not the same.

### Skill-local CLI

Lives inside the skill:

```text
~/.developer-dashboard/skills/<repo-name>/cli/
```

Run with:

```bash
dashboard skill <repo-name> <command>
```

Hook path:

```text
cli/<command>.d/
```

### Dashboard-wide custom CLI

Lives in the normal dashboard runtime:

```text
./.developer-dashboard/cli/
~/.developer-dashboard/cli/
```

Run with:

```bash
dashboard <command>
```

Hook paths:

```text
./.developer-dashboard/cli/<command>
./.developer-dashboard/cli/<command>.d
~/.developer-dashboard/cli/<command>
~/.developer-dashboard/cli/<command>.d
```

Dashboard-wide custom CLI also supports directory-backed commands with:

```text
./.developer-dashboard/cli/<command>/run
~/.developer-dashboard/cli/<command>/run
```

Use dashboard-wide custom CLI when the command is specific to one runtime or
one project. Use a skill when you want a Git-installable package with its own
isolated root and optional bookmarks.

## 7. Bookmark Language Reference

Developer Dashboard bookmark files use the original separator-line format:

```text
TITLE: My Bookmark
:--------------------------------------------------------------------------------:
BOOKMARK: my-bookmark
:--------------------------------------------------------------------------------:
NOTE: Human-readable description
:--------------------------------------------------------------------------------:
STASH:
project => 'demo',
count => 3
:--------------------------------------------------------------------------------:
HTML:
<h1>[% title %]</h1>
<p>[% stash.project %]</p>
:--------------------------------------------------------------------------------:
FORM.TT:
<form><input value="[% stash.project %]"></form>
:--------------------------------------------------------------------------------:
FORM:
<form><input value="raw-html-form"></form>
:--------------------------------------------------------------------------------:
CODE1:
my $name = 'Developer Dashboard';
print "<p>runtime output</p>";
return { name => $name };
```

Supported directive families include:

- `TITLE:`
- `ICON:`
- `BOOKMARK:`
- `NOTE:`
- `STASH:`
- `HTML:`
- `FORM.TT:`
- `FORM:`
- `CODE0:` through `CODE1000:`

### Bookmark Rules That Matter

- `TITLE:` sets the browser `<title>` and is exposed to templates as `title`
- `BOOKMARK:` is the page id
- `NOTE:` is description text
- `STASH:` is simple Perl-ish stash text like `name => 'value'`
- `HTML:` is normal page body HTML
- `FORM.TT:` is template-rendered form HTML
- `FORM:` is raw form HTML
- `CODE*:` runs Perl code in order
- earlier `CODE*` blocks run before final template rendering
- returned hashes merge into stash
- printed `STDOUT` becomes visible runtime output
- `STDERR` becomes visible error output
- one bookmark render reuses one sandpit package across its `CODE*` blocks, then destroys it
- `---` can also act as a section separator

### Template Context You Can Rely On

The bookmark runtime exposes template values including:

- `title`
- `stash`
- `ENV`
- `SYSTEM`
- `env.current_page`
- `env.runtime_context.current_page`

Use `[% title %]` when you want the title in the page body. `TITLE:` alone only
sets the page title tag.

## 8. Bookmark Browser Helpers And Static Assets

Bookmarks can reference static assets from:

- `/js/...`
- `/css/...`
- `/others/...`

Developer Dashboard also ships a built-in `/js/jquery.js` compatibility shim
with:

- `$`
- `$(document).ready(...)`
- `$.ajax(...)`
- jqXHR-style `.done(...)`, `.fail(...)`, `.always(...)`
- `.text(...)`
- the modern `method` alias

Useful bookmark helpers exposed in the browser bootstrap:

- `fetch_value(url, target, options, formatter)`
- `stream_value(url, target, options, formatter)`
- `stream_data(url, target, options, formatter)`

Use:

- `fetch_value()` for one-shot updates
- `stream_value()` or `stream_data()` for progressive output using `XMLHttpRequest`

## 9. Ajax Helper Notes

For normal saved runtime bookmarks, the Perl helper:

```perl
Ajax(
    jvar => 'endpoints.foo',
    file => 'foo',
    type => 'json',
    code => q{
        print '{"ok":true}';
    },
);
```

can create stable saved `/ajax/<file>` handlers and then let your bookmark call
them through `fetch_value()` or `stream_value()`.

That is a normal saved-bookmark capability.

Be careful with skill-shipped bookmarks:

- skill bookmarks are rendered with `source_kind => skill`
- the stable saved-bookmark `Ajax(file => 'name')` path is built for normal
  saved bookmarks
- do not assume a skill bookmark has the full saved `/ajax/<file>` facility
  unless you have tested that path explicitly in your own environment

If you need heavy Ajax workflows today, the safer route is often:

- use a normal saved runtime bookmark under the dashboard runtime, or
- keep the skill focused on CLI and static bookmarks

## 10. Nav Bookmarks

For the normal dashboard runtime, `nav/*.tt` bookmarks are special:

- they are rendered as shared nav fragments above non-nav saved pages
- they still remain direct bookmarks themselves

Examples:

- `dashboards/nav/foo.tt`
- `dashboards/nav/help.tt`

Normal runtime routes:

- `/app/nav/foo.tt`
- `/app/nav/foo.tt/edit`
- `/app/nav/foo.tt/source`

For skill bookmarks, you can still ship files such as:

```text
dashboards/nav/help.tt
```

and render them directly with:

```text
/skill/<repo-name>/bookmarks/nav/help.tt
```

Current limitation: the shared nav auto-insert behavior is a saved runtime
bookmark feature. The skill bookmark route is a simpler render surface.

## 11. Programming Style And Rules

These are good working rules when writing bookmarks and skills:

### For skill commands

- keep commands small and explicit
- use hooks for setup, validation, and logging
- print clear errors; do not silently swallow failures
- use `cpanfile` only when the dependency truly belongs to the skill
- treat `state/` and `logs/` as the skill's storage contract

### For bookmarks

- keep structure in `HTML:` and logic in `CODE*:` rather than mixing everything into inline script
- use `NOTE:` to explain page purpose
- use `[% title %]` or `[% stash.foo %]` instead of hardcoding repeated values
- use `fetch_value()` and `stream_value()` instead of hand-written repetitive DOM fetch code
- use `stream_data()` for long-running output
- use `singleton => 'NAME'` in saved Ajax handlers when a refresh should replace an older worker
- prefer saved runtime bookmarks for heavy Ajax workflows
- keep skill bookmarks simple, readable, and source-controlled

### For custom dashboard CLI

- if the goal is project-local and not reusable, prefer `./.developer-dashboard/cli/<command>`
- use `.d` hook folders when you want pre-command validation or context gathering
- use `run` only for dashboard-wide directory-backed custom commands, not skill commands

## 12. Suggested Starting Points

Start from one of these shapes:

### A command-only skill

Best when you want installable automation and no browser surface yet.

```text
cli/
config/config.json
state/
logs/
```

### A browser bookmark skill

Best when you want a small read-only or lightly interactive browser tool.

```text
cli/
config/config.json
dashboards/
```

### A Perl-heavy skill

Best when you need isolated dependencies.

```text
cli/
config/config.json
cpanfile
local/
state/
logs/
```

## 13. FAQ

### Do I need every folder?

No. Developer Dashboard prepares the standard layout, but you only need to use
the parts your skill actually needs.

### Do skill commands go into my system `PATH`?

No. You always run them through `dashboard skill <repo-name> <command>`.

### Can a skill expose browser pages?

Yes. Put bookmark files under `dashboards/` and open them through
`/skill/<repo-name>/bookmarks/<id>`.

### Can I edit skill bookmarks in the browser?

Not through the current skill route surface. Edit them in the skill repository.

### Can a skill create shared nav automatically like normal saved bookmarks?

Not as a dedicated skill feature today. Normal saved bookmarks have the richer
shared `nav/*.tt` behavior.

### Can a skill use isolated Perl modules?

Yes. Ship a `cpanfile`. Developer Dashboard installs dependencies into `local/`
and prepends `local/lib/perl5` to `PERL5LIB` for skill hooks and commands.

### Can I use `.d` hooks outside skills?

Yes. Dashboard-wide custom commands also support hook folders under
`./.developer-dashboard/cli/<command>.d` and `~/.developer-dashboard/cli/<command>.d`.

### Where should I start if I do not know whether I need a skill or a bookmark?

Start with the simplest thing:

- one project-only command: `./.developer-dashboard/cli/<command>`
- one project-only page: `./.developer-dashboard/dashboards/<bookmark>`
- reusable Git-backed package: skill repository

## 14. Use Cases

- wrap an external internal tool behind `dashboard skill ops-tool run`
- ship a browser bookmark that explains a workflow, links to docs, and reads local status files
- keep isolated Perl dependencies for one automation package without growing the main dashboard dependency set
- provide a reusable team command bundle with validation hooks
- publish a bookmark-plus-command package that other developers can install from Git

## 15. See Also

- `Developer::Dashboard::SKILLS`
- `README.md`
- `Developer::Dashboard::SkillManager`
- `Developer::Dashboard::SkillDispatcher`
- `Developer::Dashboard::PageDocument`
- `doc/skills.md`
