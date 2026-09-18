# How `d2 <name>` and `d2 <name>.<command>` resolve to a skill's files

What actually decides which file runs for a skill invocation, how nested
dotted commands walk into sub-skills, and where a skill's own
`cli/__init__.<ext>` self-script fits into that chain.

## The two entry shapes

- **`d2 <skill>.<command>`** — an explicit dotted command. `bin/dashboard`'s
  `_skill_dotted_command_parts` splits on the first `.`, confirms
  `<skill>` is an installed skill (via `SkillManager->get_skill_path`), and
  routes to `dashboard skills _exec <skill> <command> [args...]`, which
  constructs a `Developer::Dashboard::SkillDispatcher` and calls
  `exec_command`/`command_spec`.
- **`d2 <name>` with no dot at all** — currently has NO skill-shorthand
  route. `_skill_dotted_command_parts` returns immediately when its input
  contains no `.`, so a bare skill name falls through to whatever
  built-in/layered lookup `bin/dashboard` does next (an unknown-command
  error, absent any other match).

## How a dotted command resolves, including nested skills

`SkillDispatcher::_command_spec` (given a skill name and a command token)
builds a list of candidate splits via `_command_root_specs`: the whole
command token as one flat name, then every way to split it at a `.`
boundary into a leading "nested skill path" and a trailing "command name".
For each candidate, `_nested_skill_path` walks `skills/<repo>/skills/<repo>/…`
one segment per nested name, and `resolve_runnable_file` looks for
`cli/<command_name>` under that resolved path. The first candidate that
resolves to a real, runnable file wins.

This is already how `d2 foo.bar` reaches a command inside a nested
`skills/foo/skills/bar/` tree — the nesting walk is not new machinery.

## Where the `__init__` self-script fallback belongs

A skill can define `cli/__init__.<ext>` (any extension - `.pl`, `.go`,
`.java`, whatever the skill is written in) as its own default entrypoint.
Two hook points, both extending existing machinery rather than adding new
mechanism:

1. **No-dot case** (`d2 <name>` alone): `_skill_dotted_command_parts`'s
   "no dot, so nothing to route" early return is exactly where a fallback
   check belongs — after confirming `<name>` resolves to an installed
   skill, check for that skill's own `cli/__init__.<ext>` before giving up.
2. **Dotted-but-no-explicit-subcommand case** (`d2 foo.bar` where `bar` has
   no `cli/bar` file anywhere in the nested walk): the fallback lives
   inside `_command_spec`'s existing per-`provider_path` loop, checked
   after `resolve_runnable_file(cli/$command_name)` comes back empty for
   that candidate — so it fires at every nesting level the loop already
   visits, for free, rather than needing its own separate recursive walk.

**Precedence, both cases:** an explicit subcommand file always wins over a
skill's own `__init__` fallback. The fallback only fires when nothing more
specific resolves.

## Out of scope: a bare top-level `cli/__init__.<ext>`

A `cli/__init__.<ext>` sitting at a *layer's* top-level `cli/` root (e.g.
`~/.developer-dashboard/cli/__init__.pl`), not inside any specific skill
folder, has no skill name for `d2` alone (with nothing after it at all) to
bind to. This convention applies only inside a named skill's own `cli/`
directory.

## Related

- `command-in-path-resolution.md` — a different resolution question (finding
  an *external* binary on `$PATH`), not this page's subject.
