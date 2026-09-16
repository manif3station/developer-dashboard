# dashboard of / open-file: the non-interactive STDIN contract (DD-915)

## What changed

`_select_open_file_matches` (`lib/Developer/Dashboard/CLI/OpenFile.pm`) is the
older numbered chooser flow reached whenever a scope search or Perl-module /
Java-class lookup produces more than one match and `--print` was not given.
It used to do an unconditional `my $selection = <STDIN>;` after printing the
numbered list. If STDIN was a real, open connection that genuinely never
sends anything - an inherited terminal nobody types into, a pipe that stays
open with no writer - that read blocked forever.

DD-915 added `_stdin_has_pending_input($timeout_seconds)`, checked before the
prompt is printed and the read is attempted. When it reports false, the
chooser skips straight to returning every match, having already printed the
numbered list.

## Why a bare `-t STDIN` check was wrong here

The obvious fix - skip the prompt whenever STDIN is not a tty - was tried
first, and broke five real assertions in `t/05-cli-smoke.t`. This command's
chooser is deliberately designed to be answered non-interactively by piping
an answer ahead of time:

```sh
printf '2\n' | EDITOR=/path/to/editor dashboard of some-dir some-pattern
```

That is load-bearing, tested behavior (`t/05-cli-smoke.t` asserts the chooser
prompt marker `> ` itself still appears under exactly this piped-answer
pattern, then that the editor receives the piped selection). A pipe is never
a tty, so a bare `-t STDIN` check treats a real, intended answer exactly like
"nobody is coming" and silently discards it - the two situations have to be
told apart, not conflated.

## The actual check

```perl
sub _stdin_has_pending_input {
    my ($timeout_seconds) = @_;
    return 1 if -t STDIN;                          # a person is expected to type
    my $fileno = fileno(STDIN);
    return 1 if !defined $fileno || $fileno < 0;    # not a real OS descriptor at all
    require IO::Select;
    my $select = IO::Select->new( \*STDIN );
    return $select->can_read($timeout_seconds) ? 1 : 0;
}
```

Three cases, in order:

1. **A real terminal.** Someone is expected to type; always proceed.
2. **Not a real OS file descriptor.** This project's own established way of
   faking STDIN in tests is `open my $fh, '<', \$scalar; local *STDIN = $fh;`
   - an in-memory handle. `fileno()` on one reports a *defined but negative*
   value while the handle is open (`-1`, verified live on this platform), and
   `undef` once it has been closed. `select()`/`IO::Select` can only examine
   a real OS descriptor (pipe, socket, terminal, regular file); it never
   reports an in-memory handle ready no matter what it holds, so a timeout
   check against one would always wait out the full duration and then
   incorrectly report "nothing pending." But reading an in-memory handle can
   never physically block the process regardless of its content - there is
   nothing to protect against there, so both shapes (undef or negative
   fileno) are treated as always ready.
3. **A real descriptor.** Only here does the actual `IO::Select->can_read`
   wait apply - a genuine pipe/terminal/file, checked for real, within the
   given timeout.

## What this means for callers

- Piping a real answer (`printf 'N\n' | dashboard of ...`) is unaffected -
  the pipe becomes readable essentially instantly once the shell writes to
  it, well inside the timeout, and the existing prompt-then-read flow runs
  exactly as before.
- A caller whose STDIN is closed or already at EOF was never at risk of
  hanging in the first place - `<STDIN>` returns `undef` immediately at EOF,
  and the pre-existing `return @matches if !defined $selection;` fallback
  already handled that case before DD-915.
- The case DD-915 actually protects against is a STDIN that is open,
  connected to something real, but silent - inherited from a parent process
  that neither writes to it nor closes it. That now times out (default 5
  seconds in production use) instead of hanging indefinitely.

## Testing note

`can_read()` genuinely needs a real OS file descriptor to exercise its true
branch (a regular file with content, always immediately select()-ready) and
its false branch (an open `pipe()` with nothing written, which must be made
to actually wait out a short timeout to prove the give-up path is real, not
just claimed). Both live in `t/98-cli-openfile-coverage.t`; the false-branch
test deliberately costs about a second of real wall-clock time in the suite
- that is the price of proving the timeout genuinely elapses rather than
returning early for the wrong reason.
