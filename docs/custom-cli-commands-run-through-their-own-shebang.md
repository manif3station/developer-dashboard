# Custom CLI commands run through their own shebang, not their file extension

`Developer::Dashboard::Platform::command_argv_for_path` decides which
interpreter runs a resolved custom-command file (a script under a
`.developer-dashboard/cli/` or `.d2/cli/` layer, staged/resolved by
`bin/dashboard`'s `_custom_command_path`). On non-Windows platforms it
checks the file's own shebang line first, before ever looking at the
file's extension.

## What a shebang decides

If the resolved file's first line starts with `#!`, that line names the
real interpreter, and it wins:

- `#!/usr/bin/env perl` (or any shebang line containing `perl`) still runs
  through the current Perl interpreter with `-I` pointed at this
  distribution's own `lib/`, exactly like an extension-based `.pl` match.
- Any other shebang (`#!/bin/sh`, `#!/usr/bin/env python3`, `#!/usr/bin/env
  node`, ...) is honoured by executing the resolved file directly - the
  operating system's own `exec` reads the shebang line and launches the
  named interpreter. No language-specific dispatch logic runs for these;
  the kernel's shebang handling does the work.

Only when the file carries **no shebang at all** does the function fall
back to its extension-based table (`.pl` -> perl, `.py` -> the layer's
venv python or the system python, `.js` -> node, `.go`/`.java` -> their
source-execution shims, `.ps1`/`.cmd`/`.bat`/`.bash`/`.sh` -> their
respective platform launchers).

## Why the shebang has to be checked first

A file's extension is a naming convention chosen by whoever authored the
script; its shebang is an explicit, load-bearing statement of what should
actually run it. When a `.pl`-suffixed file's content is not Perl - a shell
script saved with the wrong extension, for example - forcing it through
the Perl interpreter anyway does not produce a clear error. Perl is
permissive enough to parse many short shell snippets as valid (if
nonsensical) Perl syntax and run them to completion, producing
unpredictable behaviour with no indication anything went wrong.

Concretely: a file containing

```sh
#!/bin/sh
echo bar
exit;
```

saved as `foo.pl`, fed to `perl` instead of `sh`, parses `echo bar` as
Perl's indirect-object method-call syntax (`'bar'->echo(exit)` - `bar` as
the invocant string, `echo` as the method name, and the bareword `exit` as
part of the argument list). That is a real, syntactically valid Perl
program; it is not the shell script the author wrote, and what it goes on
to do bears no relation to the script's intent.

## Reviewing a change against this

- **Extension-based dispatch is a fallback, not the primary path.** Any new
  extension added to `command_argv_for_path`'s table only applies to files
  with no shebang of their own; do not special-case shebang detection
  around a new branch instead of relying on the existing check at the top
  of the function.
- **A shebang naming Perl is still special-cased** to route through
  `-I`-augmented perl rather than a bare `exec` of the file, so custom Perl
  commands can `use` this distribution's own modules. Any other
  interpreter is trusted to resolve its own module path.
- **This governs custom commands specifically** - it does not change how
  the distribution's own shipped `share/private-cli/` command bodies are
  staged or invoked; those are always genuine Perl carrying a matching
  shebang.
