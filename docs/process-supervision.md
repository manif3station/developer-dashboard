# Process supervision — how the dashboard decides a process is alive

The dashboard starts, watches and stops processes it does not own the lifetime of:
a web server, a collector fleet, a supervisor, page and ajax handlers. Everything
downstream of that — the watchdog's restart counters, the cached status strip, a
stop that must actually stop — rests on one question being answered correctly:

> **is process N still running?**

That question is harder than it looks, and this page is about why the answer is
built the way it is. It is system-scoped: it describes the model, not any change
to it.

## `kill(0, $pid)` is not the answer

The obvious check is `kill 0`, and it is wrong on its own in a way that is easy to
miss, because it is wrong only *sometimes*:

```perl
sub _process_exists {
    my ( $self, $pid ) = @_;
    return kill( 0, $pid ) ? 1 : 0;
}
```

A **zombie** — a child that has exited but whose status nobody has collected —
still answers `kill 0`. It has a pid, it is in the process table, and it is not
running. A supervisor that trusts `kill 0` will believe a dead collector is
healthy for as long as nobody reaps it, which for a process the dashboard itself
forked is potentially for ever.

So the real check is layered, and each layer exists because the one before it
lies in a specific case:

```perl
sub _pid_is_running {
    my ( $self, $pid ) = @_;
    return 0 if !defined $pid || $pid !~ /^\d+$/ || $pid < 1;   # 1. is it even a pid
    return 0 if $self->_reap_child_process($pid);               # 2. was it OUR zombie
    return 0 if ( $self->_read_process_state($pid) || '' ) eq 'Z';  # 3. is it ANY zombie
    return $self->_process_exists($pid) ? 1 : 0;                # 4. finally, kill 0
}
```

Note the order. **Reaping comes before asking.** If the pid is one of our own
exited children, collecting it turns "exists" into "gone" in the same call, which
is both the correct answer and the cleanup. Step 3 catches zombies that are not
ours to reap. Only then is `kill 0` meaningful.

## A pid is only meaningful inside its namespace

In a container, pid 42 exists in several places at once and they are unrelated
processes. Killing "pid 42" from the wrong namespace is not a no-op — it is a
different process.

```perl
sub _pid_namespace_id {
    my ( $self, $pid ) = @_;
    my $path = "/proc/$pid/ns/pid";
    return if !-l $path;
    return readlink $path;
}
```

`_same_pid_namespace` compares that link against our own, and **deliberately fails
open**: if either identity cannot be read, it returns true. That is the safer
default here, because the alternative — refusing to act on a process whose
namespace we cannot determine — would make the dashboard unable to stop its own
children on any platform without that `/proc` entry.

## `/proc` is not always there, and the fallback has a side effect

`_read_process_state` prefers `/proc/<pid>/stat` and falls back to `ps` when procfs
is unavailable — which is the normal case on macOS, and the reason a `/proc`-only
implementation would pass every test on Linux and fail on a developer's laptop.

The fallback shells out, and that is where a subtle defect lives:

```perl
local $?;
```

A `system()` call sets `$?`. Without `local $?`, a *query* — a function whose job
is to answer a question — leaves the caller's exit status overwritten as a side
effect. The caller then returns that value as its own, and something far away
decides a command failed. This has been fixed repeatedly across the codebase,
which is why every `$?`-touching function now carries the guard and why a standing
test sweep fails the build if a new one appears without it.

**The general rule: a function that answers a question must not change the state
its caller is about to report.**

## State files are replaced, never written in place

Cached process state is read by the prompt renderer, the web status strip and page
handlers, none of which coordinate with the writer. A half-written state file
would be read as truth.

So writes go to a temporary path and are renamed over the target. Rename is atomic
within a filesystem: a reader sees either the whole old file or the whole new one,
never a partial write. On Windows, where rename-over-existing behaves differently,
there is a PowerShell replacement path for the same guarantee.

## Where this lives

| concern | location |
|---|---|
| web server and collector fleet lifecycle, watchdog | `RuntimeManager` |
| individual collector execution | `CollectorRunner` |
| platform differences in argv and quoting | `Platform` |
| page and ajax child processes | `PageRuntime` |
| cleanup of stale state, logs and sessions | `Housekeeper` |

**The liveness and state-file primitives described above currently exist in more
than one of those modules.** A reader should not assume that a helper of a given
name behaves identically in each — some pairs are byte-identical and some have
diverged. Check the module you are actually in.
