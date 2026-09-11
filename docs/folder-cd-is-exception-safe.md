# `Folder->cd()` restores the working directory even when its callback dies

`Developer::Dashboard::Folder::cd($where, $code)` temporarily changes the
process's working directory, invokes `$code`, and restores the original
directory afterward. Its own POD has always described this as a
"temporarily change directory" helper - the kind of contract a caller
reasonably assumes is exception-safe.

## The gap (DD-844)

Before this fix, `cd()` called `$code->(...)` with no `eval` around it:

```perl
chdir $dir or return;
my $result = $code->( { ... } );
chdir $pwd if $pwd;      # never reached if $code died
return $result;
```

A `die` inside the callback propagates immediately out of `cd()`, and the
`chdir $pwd if $pwd` restoration line is simply never executed. The
calling **process** - not just the current call frame - is left sitting
in the target directory. Any code that runs afterward in that process,
including code with no idea `cd()` was ever called, then resolves relative
paths against the wrong base.

## The fix: restore, then rethrow - never swallow

```perl
my $result = eval {
    $code->( { ... } );
};
my $err = $@;
chdir $pwd if $pwd;
die $err if $err;
return $result;
```

The callback runs under `eval`, so a `die` no longer skips the
restoration. The original exception is captured, the directory is
restored unconditionally, and **only then** is the exception rethrown -
verbatim, not replaced or summarized. A caller wrapping `cd()` in its own
`eval` still sees the exact same error it would have seen before this fix;
the only change is that the process's working directory is no longer
corrupted as a side effect of that error.

## Why restoration uses `$pwd`, not a fixed "original" value

`cd()`'s callback receives a `stay` closure
(`$ctx->{stay}->($some_other_dir)`) that lets it redirect where `cd()`
restores to - a deliberate escape hatch for a callback that wants to leave
the process somewhere other than where it started. The fix restores
whatever `$pwd` currently holds at the moment of the `chdir $pwd if $pwd`
line, which is **already** how the success path worked - `stay()` mutates
the same `$pwd` variable the restoration line reads. This fix does not
change that contract: if a callback calls `stay($new_dir)` and *then*
dies, `cd()` restores to `$new_dir`, not the original directory - exactly
as if the callback had returned normally after calling `stay()`.

## Reviewing a change against this

- **Any new exit path added to `cd()`'s callback invocation must go
  through the same eval/restore/rethrow shape.** A second, unguarded call
  site would reopen exactly this gap.
- **Never swallow the callback's exception.** The fix's entire value is
  that a caller relying on the exception for its own error handling still
  gets it, byte-for-byte - restoration is a side effect the caller need
  not know about, not a replacement for the caller's own error handling.
- **`stay()` and the eval/restore interact correctly by construction**,
  because both act on the same `$pwd` lexical - there is no ordering
  requirement to get right, only to preserve.
