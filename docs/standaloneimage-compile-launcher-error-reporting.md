# StandaloneImage's launcher compile step reports the real build failure

This page describes the current behavior of the system, not any one
ticket. `Developer::Dashboard::Pax::StandaloneImage::_compile_launcher`
compiles a Pax launcher binary in two nested `eval` blocks: the first runs
`objcopy` and `cc`; the second restores the process's original working
directory afterward, regardless of whether the first succeeded.

## Why this matters

Perl resets `$@` to the empty string at the start of every `eval` block,
and again on that block's successful completion. Two sequential `eval`
blocks therefore share one mutable `$@` - whichever eval ran *last*
determines what `$@` holds, not whichever eval actually failed.

The cwd-restore eval runs unconditionally after the build eval, regardless
of whether the build succeeded. If the build eval died (objcopy or cc
failed) and the restore eval then succeeded - the common case, since
restoring a working directory rarely fails - the restore eval's own
success resets `$@` to `''`, destroying the build failure's diagnostic
message before anything reads it.

## The fix

Each eval's `$@` is captured into its own local variable **immediately**
after that eval returns, before the other eval runs and can overwrite the
shared `$@`:

```perl
my $ok = eval { ... 1; };
my $build_error = $@;                                    # captured first
my $restore_ok = eval { chdir $cwd or die "..."; 1; };
my $restore_error = $@;                                   # captured second
return { status => 'not_built', reason => $build_error }   if !$ok;
return { status => 'not_built', reason => $restore_error } if !$restore_ok;
```

The failure path that actually occurred now reports its own real
diagnostic - `objcopy code.pkg failed`, `launcher compile failed`, or
whichever step died - instead of an empty string whenever the cwd restore
that follows happened to succeed.

## Verification

`t/209-standaloneimage-build-error-capture.t` proves this directly: it
forces `objcopy` to fail (via a stubbed `_which` pointing at a failing
binary) while the cwd restore succeeds, and asserts the returned `reason`
contains the real objcopy failure text rather than an empty string. It
also proves the cwd-restore failure path reports its own distinct message,
and that the happy path (`status => 'built'`) is unaffected.
