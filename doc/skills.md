# Skills Documentation

The long-form skill authoring guide lives in [`../SKILL.md`](../SKILL.md).

Use it when you need:

- how `dashboard skills install` accepts Git URLs and qualified local checked-out skill directories
- how `dashboard skills install` accepts multiple explicit sources in one ordered batch
- how `dashboard skill` aliases the `dashboard skills` management command family without replacing dotted skill execution
- how an existing home runtime `.gitignore` or compatibility `.gitiignore` receives `skills/<repo-name>/` entries for installed skill trees without duplicates
- that repeated `dashboard skills install ...` calls reinstall or refresh the installed isolated copy
- the expected skill directory structure
- the meaning of each folder
- the skill CLI and `cli/<command>.d/` hook model, including `RESULT`, `LAST_RESULT`, and `[[STOP]]`
- skill Perl library lookup: the command/page-providing skill's `lib/` is first in CLI and dashboard CODE `@INC`
- skill-provided path aliases from `lib/Folder.pm`, including config precedence and read-only listing behavior
- executable `.go` hook files running through `go run` and executable `.java` hook files compiling through `javac` before they run through `java`
- the difference between skill-local commands and dashboard-wide custom CLI hooks
- bookmark syntax, bookmark browser helpers, and route details
- skill-local `dashboards/routes.json` custom ajax path and alias metadata
- app-style skill routes such as `/app/<repo-name>` and `/app/<repo-name>/<page>`
- underscored config merge keys such as `_<repo-name>`
- dependency manifest processing order: C<aptfile>, C<apkfile>, C<dnfile>, C<wingetfile>, C<brewfile>, C<package.json>, C<cpanfile>, C<cpanfile.local>, C<Makefile>, C<dockerfile>, then C<ddfile>
- skill Docker layering and automatic C<dockerfile> builds during installation
- current limitations of skill bookmark routes versus normal saved runtime bookmarks

The shipped POD version of the same topic lives in
`Developer::Dashboard::SKILLS`.

## Skill path aliases

An installed skill may define `lib/Folder.pm` with package `Folder` and
methods that return path strings. The public name is qualified by the skill,
for example `cdr ch.workspace` calls `Folder->workspace` from the `ch` skill.
Resolution checks the effective skill `config/config.json` aliases first, so
an explicit config alias always wins over a same-named module method.

If `Folder->__list__` exists, it must return alias names in list context, not
an array reference. `d2 paths`, `d2 path list`, and `cdr` completion call the
listed methods and merge their values into the output at runtime. This merge is
read-only: it does not copy module aliases into config or edit skill files.
`d2 path add ch.workspace /some/path` persists an explicit override to
`config/config.json`; subsequent resolution uses that configured value.
