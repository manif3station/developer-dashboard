# Resolving a command name via `Platform::command_in_path`

## What it does

`command_in_path($name)` resolves a bare command name (`make`, `python3`,
`ss`, ...) to a concrete, executable file path, searching the entries of
`File::Spec->path` (the process's `PATH`). It is the single resolver used
across the codebase wherever a helper needs to know whether an external tool
exists and where it lives - 29 call sites across `Platform.pm` itself,
`SkillManager`, `RuntimeManager`, `ProcessSupervision`, `Web::App`, and
`CLI::Upgrade`/`CLI::Ticket`.

## The contract

Every caller passes a **bare** name - never a path containing a directory
separator. That is the only shape this resolver is designed for: a bare name
means "search PATH for this", and the answer is either an absolute path to
the real executable, or `undef`.

`command_in_path` never resolves a bare name against the caller's current
working directory. A file happening to share a name with a resolved command
(`make`, `sh`, `python3`, `docker`, ...) and sitting in whatever directory
dashboard is invoked from must never be returned - only a genuine `PATH`
match counts (DD-765). This matters in two ways:

- **Security.** Without this guarantee, running `dashboard` inside a
  directory whose contents you did not choose (an extracted tarball, a
  freshly cloned repository, a shared work area) could execute a same-named
  file from that directory instead of the real system command - the classic
  dot-in-PATH problem, reached without dot ever appearing in `PATH` itself.
- **Correctness.** A resolver that can return a *relative* string is
  unconditionally wrong the moment any caller's cwd changes between the
  check and the use - the check and the execution end up being about two
  different files.

## What this means for a new caller

- Always pass a bare name. If you have a path with a directory separator
  already, you do not need this resolver - open or exec it directly.
- Trust the result to be either `undef` or an absolute path. Never assume it
  could be relative, and never defensively `File::Spec->rel2abs()` it
  yourself - that would silently resolve a bug in the resolver against
  whatever your own cwd happens to be, which is exactly the class of defect
  this page exists to prevent.
