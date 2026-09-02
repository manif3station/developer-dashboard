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

## A fractional sleep is a silent no-op without `Time::HiRes`

The Windows branch of `_replace_state_file` retries a rename up to ten times,
backing off between attempts, to wait out a transient lock — an antivirus
scanner, a search indexer, another reader still holding the handle:

```perl
sleep 0.05;
```

`CORE::sleep` takes **integer seconds**. Handed `0.05` it truncates to zero,
sleeps for no time at all, and returns 0. It does not warn and it does not die.
The line still reads as a delay, so the loop looks correct while burning all ten
retries in microseconds — the backoff that is the entire point of the loop is
gone, and the state file the prompt renderer and web status strip depend on
fails to publish under exactly the contention the retry was written for.

The delay only exists if the module imports the faster one:

```perl
use Time::HiRes qw(sleep);
```

**Why this is worth a section rather than a comment.** The failure is invisible
three ways at once. It produces no warning; the source still says `sleep 0.05`;
and the code path sits behind an `is_windows` guard, so every assertion about it
runs on Linux with that mocked — exercising the control flow without ever
measuring elapsed time. The suite can be entirely green on a tree where the
backoff does not exist. That is not a weak assertion but a subtler thing: an
assertion whose subject is unreachable on the machine running it.

This has been shipped twice here. Once a flaky test was "fixed" by widening a
poll loop from 60 to 150 iterations in a file that never imported `Time::HiRes`,
so the change bought exactly zero seconds and was found much later. Again when
these shared helpers were extracted into their own module and the import did not
come with them — a refactor advertised as behaviour-preserving that did not
preserve behaviour.

`t/161-fractional-sleep-guard-sweep.t` now fails the build for any fractional
sleep in a file that cannot reach `Time::HiRes`. A fully-qualified
`Time::HiRes::sleep(0.05)` is fine and is not reported.

## Identifying a process you have no pid for

Everything above answers *is process N still running?* — a question that starts
with a pid you were given. The operator tooling asks a harder one:

> **is anybody else running a gate right now?**

There is no pid to start from. The answer has to come from the process table, and
three things about reading it go wrong quietly enough that all three have shipped
here.

**A substring is not a command.** `grep -F 'prove'` matches every command line
that merely contains that sequence, and real ones do: `improvement-scan`,
`approve-thing`. A checker built this way reports the host busy because of a
process that has nothing to do with it. Match the command **word** — the
executable's basename, or an anchored pattern — never a substring of the whole
line.

**A checker can match itself.** The command doing the searching is in the table
it is searching, and so are its children and the shell that spawned it. Filtering
by name is unreliable in both directions: `grep -v grep` removes the pipeline but
not a sibling, and any name-based exclusion is a guess about what your own
process looks like. Compare **process groups** instead: read your own with
`ps -o pgid= -p $$` and drop every row sharing it. A pgid comparison cannot
misidentify you, because it is your identity rather than a description of it.

**"I could not look" is a third answer, and it is the one that gets dropped.**
A reader of the process table can fail — `ps` missing, non-zero, denied, output
unparseable — and the failure looks exactly like an empty result. Code shaped
like

```perl
my $busy = 0;
$busy = 1 if defined $out && $out =~ /\S/;
return $busy ? 0 : 1;
```

returns *not busy* when it could not look at all. Whether that is safe depends
entirely on which way the caller leans: here it meant **the host is free, release
the park**, so a broken `ps` would advance work on a measurement that never
happened. Return `undef` — or whatever the caller's vocabulary for *unknown* is —
and make the caller handle it. Collapsing unknown into either answer is the
failure; which answer it collapses into only decides the direction of the damage.

The same three rules apply to any check that reads the process table, whether it
is deciding that a gate is running, that a supervisor is alive, or that a host is
quiet enough to measure on.

## A doomed loop must never be forked in the first place (DD-737)

Every check on this page is about telling a live process from a dead one
after the fact. The cheaper fix, when it applies, is to never create the
process at all - and one collector shape made exactly that mistake.

A collector's config entry needs either a `command` (shell text) or `code`
(Perl) to actually do anything; `_collector_source` has always validated
that, dying with `"Collector '<name>' missing command or code"` when
neither is present. The problem was *when* that validation ran: only on
each loop tick, inside the forked worker, after `start_loop` had already
created a pidfile, written loop state, and spawned the process. A
misconfigured collector - one config entry with only `interval` and `name`,
nothing to run - was forked into a real loop worker anyway, which then died
immediately on its first tick, and on every tick after that, forever. The
collector never disabled itself; it just kept retrying a config that could
never succeed.

**Observed live, from a real machine (owner's photo).** Every time that
loop-worker process died - from this error, or from an ordinary `dashboard
restart` cycle - it needed something to call `waitpid` on it before it
would leave the process table. On a normal host, systemd (PID 1) does that
automatically for any orphaned process, so a supervisor exiting without
reaping its own children is invisible. Under a PID 1 that does not do that
- a plain Docker container with no init, `sleep`, or similar as its
entrypoint - every one of those exits became a permanent zombie instead.
Reproduced directly in `developer-dashboard:latest`: two `dashboard
restart` cycles against the same broken config left multiple `<defunct>`
entries, all reparented to PID 1, none cleared by either restart. The
owner's screenshot showed the same shape at a much larger scale - hundreds
of zombies sharing one non-init PPID, accumulated over hours.

**The fix is at the point of creation, not the point of death.**
`start_loop` now calls `_collector_source($job)` - the same validation the
tick loop already performed - before writing any pidfile or forking
anything. A collector with neither `command` nor `code` now fails
immediately and visibly (`dashboard collector start` / `dashboard restart`
report the error directly) instead of silently forking a process whose
only future is dying once per interval forever.

**This does not fix the general reaping gap.** A collector that is
correctly configured can still fail for other reasons - a crashing command,
an external `kill`, the environment itself going away - and its worker can
still become an orphan needing PID-1-level reaping. What this closes is the
specific pattern that turns *one* permanently broken config into an
*unbounded, ever-growing* pile of zombies: a collector that can never
succeed no longer gets to try, and fail, and leak, every interval for as
long as the host stays up.

## Where this lives

| concern | location |
|---|---|
| web server and collector fleet lifecycle, watchdog | `RuntimeManager` |
| individual collector execution | `CollectorRunner` |
| platform differences in argv and quoting | `Platform` |
| page and ajax child processes | `PageRuntime` |
| cleanup of stale state, logs and sessions | `Housekeeper` |

**The liveness and state-file primitives described above now live in ONE place:
`ProcessSupervision`**, which both `RuntimeManager` and `CollectorRunner` import.
Fourteen helpers whose bodies were byte-identical were extracted there; the nine
that genuinely differ between the two classes were deliberately left where they
were, because sharing one of those would impose a single behaviour on both and
every existing test would still pass — each version satisfies its own module's
tests today.

So a reader should still not assume a helper of a given name is shared. Check
whether it is imported or defined locally; `t/160` pins which are which, and
fails by design if a divergent one is moved into the shared module.
