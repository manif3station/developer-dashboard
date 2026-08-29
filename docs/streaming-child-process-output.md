# Streaming a child process's output — why this is harder than it looks

Several parts of the dashboard run a child process and need **both** its stdout
and its stderr, as they arrive, without deadlocking. Skill dispatch does it,
skill installation does it, and saved-ajax page handlers do it. This page is
about why that arrangement is delicate, what the failure modes actually look
like, and which decisions each caller has to make for itself.

It is system-scoped: it describes the model, not any change to it.

## The construction, and its own documentation's warning

Reading two pipes from one child means you cannot use `readline` on either —
blocking on one while the other fills its pipe buffer deadlocks the child. So
the pattern is `IPC::Open3` plus `IO::Select` plus `sysread`:

```perl
my $pid      = open3( $stdin, $stdout, $stderr = gensym, @command );
my $selector = IO::Select->new( $stdout, $stderr );
while ( my @ready = $selector->can_read ) {
    for my $handle (@ready) {
        my $chunk = '';
        my $read  = sysread( $handle, $chunk, 8192 );
        if ( !defined $read || $read == 0 ) {
            $selector->remove($handle);
            close $handle;
            next;
        }
        # ... dispatch $chunk ...
    }
}
waitpid $pid, 0;
```

**`IPC::Open3`'s own perldoc calls this arrangement "very dangerous, as you may
block forever".** That is not a stylistic note. Two specific hazards follow from
it, and both have bitten this codebase.

## Hazard 1: `open3` does not reap the child, so `$?` becomes a trap

`open3` leaves the child for you to `waitpid`. That `waitpid` sets `$?` — and
`$?` is a global. Any function that reaps a child, or shells out at all, leaves
the caller's `$?` overwritten as a side effect:

```perl
local $?;   # in every function that touches it
```

Without the guard, a *query* — a function whose job is to answer a question —
silently changes the state its caller is about to report, and something far
away decides a command failed. This has been fixed repeatedly and across
unrelated ticket series, which is why a standing sweep now fails the build if a
new unguarded `$?` read appears anywhere in the tree.

**The general rule: a function that answers a question must not change the
state its caller is about to report.**

## Hazard 2: the EOF condition is easy to get subtly wrong

```perl
if ( !defined $read || $read == 0 ) { ... }
```

`sysread` returns **undef** on error and **0** at end of file, and those need
the same handling here but are different conditions. Writing `if (!$read)`
looks equivalent and is not — it also fires on a legitimately empty read.
Getting it wrong produces a loop that spins, or one that drops the tail of a
child's output, and neither fails loudly.

The handle must also be **removed from the selector before being closed**.
Closing without removing leaves a closed handle in the select set, which
`can_read` will keep returning.

## What every caller must decide for itself

The loop above is the *common* part. Around it sit five decisions, and the
dashboard genuinely answers them differently in different places — because the
situations differ, not by accident:

| decision | why it varies |
|---|---|
| **timeout policy** | none (block until EOF), a wall-clock alarm, or a short poll — depending on whether the caller can afford to wait forever, must bound total runtime, or needs to notice other events while reading |
| **what a timeout does** | nothing, terminate the child TERM-then-KILL and report a sentinel exit, or probe whether the child already exited and drain what remains |
| **where bytes go** | accumulated for a return value, teed through to the real STDOUT/STDERR because a person is watching, or streamed to a client connection |
| **where the exit status comes from** | `$? >> 8` after `waitpid`, a sentinel when a timeout killed the child, or a status captured by an explicit child-exit probe |
| **post-exit draining** | on Windows a child can exit with output still buffered, so a reader that stops at child-exit loses the final chunk |

**A shared implementation must not flatten these.** Collapsing the timeout
policy, or the sink, or the exit-status source into one behaviour would change
what some callers do while every existing test still passed — each caller's
tests only assert its own behaviour. That is the same trap that applies to any
helper shared between classes that need it to differ.

## Where this lives

| concern | location |
|---|---|
| skill command dispatch, streaming to a terminal | `SkillDispatcher` |
| skill installation, with progress reporting and a timeout | `SkillManager` |
| saved-ajax page handlers, streamed to a client | `PageRuntime` |
| the `$?` guard sweep that polices the whole tree | the test suite |

Note that `Web::Server` also uses `IO::Select`, and is **not** an instance of
this pattern: it proxies between two sockets for the loopback SSL front end.
No child process, no `open3`, no exit status. Same module, different subject —
worth knowing before a search for `IO::Select` is mistaken for a survey of
child-process readers.
