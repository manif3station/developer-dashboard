# The bashrc dashboard-line rewrite recomputes guard offsets AFTER mutating the text

`Doctor::_rewrite_bashrc_dashboard_lines` (called by `dashboard doctor --fix`
to repair a user's `~/.bashrc`) relocates dashboard-managed bootstrap lines
(`export PERLBREW_HOME=...`, the perlbrew `PATH` line, the `local::lib` and
dashboard shell-init `eval`s) ahead of bash's standard non-interactive-shell
return guard, so those lines stay reachable when a non-interactive shell
(a tmux status command, for example) sources the file.

## The gap DD-852 fixed

The function located the guard's byte offsets in the bashrc's original text,
then removed every dashboard-managed line from that same text via a global
substitution, and only afterward sliced the text into "before the guard" /
"the guard itself" / "after the guard" using the offsets it had computed
**before** the removal:

```perl
my ( $guard_start, $guard_end ) = $self->_bash_noninteractive_guard_offsets($text);
for my $line (@dashboard_lines) {
    $text =~ s/^\Q$line\E\n?//mg;          # $text just got SHORTER
}
my $before = substr( $text, 0, $guard_start );   # but the offsets did NOT
my $guard  = substr( $text, $guard_start, $guard_end - $guard_start );
my $after  = substr( $text, $guard_end );
```

Whenever a dashboard-managed line sat **before** the guard in the original
file, removing it shifted every later byte offset left by that line's
length. The stale `$guard_start`/`$guard_end` then no longer bounded the
real guard block in the shortened text - `substr` was asked for a range that
either fell past the end of the (now shorter) string or landed inside the
wrong content entirely. Observably, this raised `substr outside of string`
and `Use of uninitialized value $after` warnings, and the rewrite silently
failed to do the one thing it exists to do: the dashboard line that was
supposed to move ahead of the guard was left stranded exactly where it
started, after it.

**This case is not an edge case nobody hits.** `_bashrc_bootstrap_issue`
(the function that decides whether `_rewrite_bashrc_dashboard_lines` should
even run) only reports an issue when a dashboard line is found *after* the
guard. A single dashboard line sitting only before the guard triggers no
issue and the buggy function is never called. The corruption requires a
dashboard line both before and after - which is exactly the realistic
partial/duplicate-install state (a stale line left behind by an earlier
install, alongside a correctly-placed one) that `dashboard doctor --fix`
exists to repair.

## The fix

Recompute the guard's offsets a second time, against the text as it stands
**after** the dashboard lines have been removed:

```perl
for my $line (@dashboard_lines) {
    $text =~ s/^\Q$line\E\n?//mg;
}
my ( $guard_start, $guard_end ) = $self->_bash_noninteractive_guard_offsets($text);
return if !defined $guard_end;
```

`_bash_noninteractive_guard_offsets` is a pure function of the text handed
to it - calling it twice, once before removal to decide whether a guard
exists at all and once after removal to get offsets that actually describe
the mutated text, costs nothing beyond re-running one regex match.

## Reviewing a change against this

- **An offset computed against a string is invalidated by any later
  mutation of that same string.** This holds whether the mutation is a
  single substitution or a loop of them, and whether the offset is used
  once or several times afterward. Treat "I computed this position, then
  changed the string, then used the position" as a bug shape to search for
  on sight, not something that merely looks suspicious.
- **A warning that fires deep inside a write path is not a nicety to
  silence - it is often the only visible symptom of silent data
  corruption.** Here the warnings and the actual corruption were the same
  event; a test asserting "no warnings raised" turned out to be a more
  reliable regression signal than asserting a specific corrupted byte
  sequence, because the exact shape of the corruption (what ends up
  spliced where) depends on the precise offset arithmetic for a given
  fixture, while the warnings fire reliably whenever the underlying
  invariant is violated.
