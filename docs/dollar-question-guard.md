# The `$?` guard — why a query helper never leaves it mutated

Perl's global `$?` is set by `waitpid`, `system`, and backticks, and read by
whatever code wants to know how the last subprocess exited. It is a single
global with no call-stack scoping of its own, which means any helper that
touches it can corrupt what its *caller* reads next — silently, because the
mutation and the read happen in unrelated-looking places. This page describes
the model this codebase settled on to make that impossible by construction.
It is system-scoped: it describes the standing rule, not any single fix.

## The shape of the bug

A **query** helper — something whose job is to answer a yes/no or status
question, like "is this pid still running?" — often has to call `waitpid` or
similar internally to do its job. If it does that without protecting `$?`,
the query's own internal housekeeping leaks out as a side effect: whatever
code called the query, then goes on to check `$?` for its own unrelated
reason, reads a value the query silently overwrote.

```perl
sub _reap_child_process {
    my ( $self, $pid ) = @_;
    return 0 if !defined $pid || $pid !~ /^\d+$/ || $pid < 1;
    my $waited = waitpid( $pid, WNOHANG );   # sets $? - and nothing undoes that
    return $waited == $pid ? 1 : 0;
}
```

Called from a query like `_pid_is_running`, this is invisible until something
downstream reads `$?` and gets the reaped child's exit status instead of
whatever it actually meant to check.

## The fix is `local $?;`, and it goes at the top of the function

```perl
sub _reap_child_process {
    my ( $self, $pid ) = @_;
    local $?;                                 # <- restores the caller's value on return
    return 0 if !defined $pid || $pid !~ /^\d+$/ || $pid < 1;
    my $waited = waitpid( $pid, WNOHANG );
    return $waited == $pid ? 1 : 0;
}
```

`local` dynamically scopes the global for the rest of the block and restores
its prior value when the function returns, by any path - an early `return`,
a `die`, falling off the end. It has to be the *first* thing the guarded
function does, before any code that might set `$?`, or there is a window
where the leak still happens.

## Two different bugs, and only one of them announces itself

This class has a read side and a setting side, and they are not the same
defect:

- **A sub that READS `$?`** without a preceding `local $?;` guard might be
  *misled* by a stale value some earlier call left behind. This is the
  original DD-585/589-593/597 class: `t/159-dollar-question-guard-sweep.t`
  sweeps every sub under `lib/` for this shape and fails the suite the moment
  a new instance appears, with an explicit baseline of any still-open,
  already-known instances.

- **A sub that SETS `$?`** - by calling `waitpid`, `system`, or backticks -
  without a guard is the sub that *does* the misleading, for whatever caller
  reads `$?` next. This is invisible to the read-side sweep by construction:
  the setter itself never reads `$?`, so nothing about its own body looks
  suspicious to a check built to catch reads. DD-670 added a second sweep and
  a second baseline (`%SETTER_BASELINE` in the same test file) specifically
  because a green read-side gate reads as "this bug class is eliminated" and
  is not - it only means nothing currently reads `$?` unsafely, which says
  nothing about what currently *sets* it unsafely.

## Not every setter needs a guard

A sub that sets `$?` and whose own caller never reads `$?` afterward causes
no bug, and guarding it anyway is not free: it adds noise that makes the next
*genuinely* risky instance harder to spot among defensive guards that were
never load-bearing. So the setting-side sweep's baseline is explicitly
triaged rather than blanket-guarded - each entry is either a confirmed real
instance (guarded and removed from the baseline) or an explicitly-tracked
"not yet individually verified" entry, never a silently-unguarded one. A
top-level entry point (e.g. the outermost handler for a background action)
is the common case of a setter that needs no guard: nothing above it in the
call stack is going to read `$?` afterward, because there is nothing above
it.

## The sweep itself has a false-positive class: it reads comments as code

Both sweeps in `t/159-dollar-question-guard-sweep.t` work by grepping a sub's
raw source text - deliberately dependency-free, matching the rest of the
file's "no full parser" style. That has a real cost: a **comment** quoting
backticks, or naming the variable `$?` in prose, matches exactly like real
code, because a regex over raw text cannot tell an explanation from the thing
it explains.

```perl
sub _drain_ready_handle {
    ...
    # PageRuntime's helper can do an early "return 1 if $!{EINTR}" - handing
    # control back so its outer select loop calls again...
```

This comment mentions no real `waitpid`/`system`/backtick call, but the
setting-side sweep's regex (`` /`[^`]*`/ `` etc.) does not know that - a
backtick pair anywhere in the sub body reads as a command substitution
(DD-693, found when it turned an unrelated DD-678 change red).

**The fix (DD-693) is `_strip_comments`**: a small quote-state scanner that
removes every `#`-to-end-of-line comment before either sweep's regex runs,
leaving a `#` or backtick *inside a string literal* alone (tracked via
single/double-quote state with backslash escaping). It is applied to both
sweeps, because both are vulnerable to the same shape.

**The baseline consequence is the sharper lesson.** Before this fix,
`%SETTER_BASELINE` held several entries that were never real offenders - held
there only by comment punctuation, verified by opening each sub and finding
no actual `waitpid`/`system`/backtick call in its code. A baseline entry held
by prose can never be removed by fixing anything, because there is nothing to
fix - it sits there forever, diluting the property the baseline exists to
have (every member is a real, currently-open offender). **Re-deriving that
baseline was done by reading each candidate sub by hand, not by trusting an
automated comment-stripper for the removal decision** - a crude stripper
(one that doesn't track quote state, e.g. a bare `s/#.*$//`) can itself
corrupt a `#` inside a string or regex and produce a false *negative*, which
silently un-guards a real offender. That failure mode is strictly worse than
the false positive it would be fixing.

## Where to look

- `t/159-dollar-question-guard-sweep.t` - both sweeps and both baselines, run
  on every `prove -lr t`.
- `lib/Developer/Dashboard/ProcessSupervision.pm::_reap_child_process` and
  `lib/Developer/Dashboard/ActionRunner.pm::_reap_child_process` - two
  independent instances of the query-leaking-through-waitpid shape, both
  guarded, both `_pid_is_running`'s own internal reap step.
