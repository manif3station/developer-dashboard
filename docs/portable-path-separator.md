# PERL5LIB (and any multi-path env var) needs a portable separator

Why joining paths with a literal `:` is a Windows defect even though it
works everywhere the suite currently runs, and how this codebase already
solves it.

## The problem this solves

Perl's `PERL5LIB` (and `PATH`-shaped env vars generally) are colon-joined
on Unix-like systems and semicolon-joined on Windows -
`$Config{path_sep}` is the canonical, portable way to read which one
applies (`perlrun`). Hardcoding `':'` is not merely the wrong character on
Windows: a native Windows path already contains a colon right after the
drive letter (`C:\...`), so a colon-joined value there is actively
mis-parsed, not just mis-separated.

This project ships `Developer::Dashboard::PerlEnv::path_separator` for
exactly this, and three specs already call it correctly. Five others still
join with a literal `':'` (DD-802). Nothing is broken today because the
suite does not run on Windows - the cost is latent and is paid the first
time one of these specs runs on a real Windows guest.

## The rule

> **Any code that assembles a multi-entry environment variable from
> several paths must get its separator from a portable source
> (`$Config{path_sep}`, or this project's own `PerlEnv::path_separator`
> wrapper around it), never a literal `':'` or `';'`.**

## How to apply

- New code joining paths into an env var: use
  `Developer::Dashboard::PerlEnv::path_separator()`, not a literal
  character. `t/30-dashboard-loader.t` line 193 is the model call.
- A partial fix is worse than none: when a portable helper already exists
  and some call sites use it while others don't, the unconverted sites read
  as a deliberate decision to a later reader, even though nothing on the
  record supports that (see the general shape in
  [[undated-counts-in-prose-go-stale]] and this project's "half-fix
  inherits a closed card's authority" lesson). Convert every site you find,
  not just the one you were asked about.
- A grep for `':'` or `';'` next to `PERL5LIB`/`PATH` is a cheap way to find
  the remaining hardcoded sites; state the grep's control (a file already
  known to use the portable helper, which must NOT match) so an empty
  result is trustworthy rather than merely a badly-aimed search.
