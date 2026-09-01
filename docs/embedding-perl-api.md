# Embedding this project's runtime from Perl: `d2()`

What `d2()` is, why it exists, and the contract it holds - for anyone
reaching into this runtime from Perl code rather than the `dashboard`/`d2`
command line.

## What it is

`use Developer::Dashboard;` exports one sub, `d2()`. It returns a
`Developer::Dashboard::Handle` scoped to the current working directory,
memoized so repeated calls from the same directory reuse the same handle
instead of rebuilding its registry each time.

    use Developer::Dashboard;

    my $foo = d2->paths->{foo};                    # in-process, no subprocess
    my $out = d2->doctor;                           # shells to `dashboard doctor`
    my $res = d2->run( 'tira.ticket.show', '--ref', 'DD-726' );
                                                      # dotted subcommands

## Why it exists (DD-726)

Filed after the project owner asked directly, over the project's Telegram
bridge, for a one-line Perl equivalent of `dashboard path resolve NAME`
instead of hand-building a `PathRegistry` + `FileRegistry` + `Config` (the
same composition `dashboard path resolve` itself uses internally, in
`Developer::Dashboard::CLI::Paths::_build_paths`/`run_paths_command`). The
request then widened mid-ticket: *"d2 isn't just for paths [...] Anything I
can run with d2 on bash [...] I am expecting the d2() subroutine can do the
same."*

## The two halves of the contract

**`d2->paths`** is the fast path: it builds a `PathRegistry`, registers the
configured named aliases from `Config->path_aliases` (exactly as
`dashboard paths` does), and returns `->all_path_aliases` - a plain hash
reference of alias name to resolved directory. No subprocess.

**Everything else is a subprocess proxy.** Any method name not defined on
the handle (`AUTOLOAD`) is treated as a single-word `dashboard` subcommand -
`d2->doctor` runs `dashboard doctor`. A dotted subcommand (Tira's
`tira.ticket.show` and friends) cannot be spelled as a bareword Perl method,
so `d2->run($subcommand, @args)` is the explicit form for those.

Both paths capture stdout via `Capture::Tiny`, decode it as JSON into a real
Perl structure when it looks like JSON (matching the owner's framing: JSON
is the wire format between processes, never something Perl code should have
to parse itself), and return the raw trimmed text otherwise. **A nonzero
exit dies, with stderr attached to the message** - a failing subcommand
never returns something that looks like a successful result.

## What it deliberately does not do

- It does not reimplement the CLI's command dispatch in Perl. Anything past
  `->paths` is a real subprocess call to the installed `dashboard`
  executable - the single source of truth for what a subcommand does stays
  the CLI itself.
- It is not used by the CLI's own code. `Developer::Dashboard::CLI::Paths`
  and the rest of the CLI continue to build their own registries directly;
  `d2()` is purely a convenience entrypoint for *external* Perl code
  (scripts, other distributions embedding this one) that wants the same
  runtime without shelling out by hand and parsing the output itself.

## Related

See [path-containment.md](path-containment.md) for how a resolved directory
is validated once you have it, and
[docs-vault-vs-doc-directory.md](docs-vault-vs-doc-directory.md) for where
project documentation like this page lives.
