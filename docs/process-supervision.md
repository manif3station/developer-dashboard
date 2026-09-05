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

## An external executable is resolved, not named

Every place the dashboard shells out to a program it did not install faces the same
question: **is that program actually there, under that name, on this host?** For
PowerShell on Windows the answer is often no under the bare name `powershell` — a
corrupted or misconfigured `PATH` is a common real-world state, and the executable
normally lives at `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
whether or not that directory is on `PATH`.

So the model here is: **resolve the command, then fail with a stated reason if you
cannot.** The resolution is a fallback chain, tried in order:

1. `command_in_path('powershell')`
2. `command_in_path('powershell.exe')`
3. `$ENV{SystemRoot}\System32\WindowsPowerShell\v1.0\powershell.exe`, if it exists
4. otherwise the empty string

The empty string is the contract. A caller branches on it and reports *which
executable could not be found*, naming the process that needed it.

### Why the empty string rather than a die

The resolver returns a value rather than throwing, because whether a missing
PowerShell is fatal depends on the caller. A collector that cannot launch must stop
and say so; a query helper asking which processes are listening can reasonably return
an empty list. A resolver that threw would take that choice away from both.

### What hardcoding costs, concretely

`system 'powershell', '-NoLogo', ...` on a host where PowerShell is unresolvable does
not fail in a way anyone can read. `system` returns non-zero, the captured stdout is
empty, and the caller sees *"no processes matched"* or *"the state file was not
replaced"* — a plausible, wrong answer rather than an error. The failure is
indistinguishable from a legitimately empty result, which is the property that makes
it expensive: nothing looks broken.

That is why the difference is worth a page rather than a preference. Both spellings
"work" on a healthy host, and they diverge only where diagnosis matters most.

### The trap when fixing this

A partial fix is worse than none here. If some call sites in a module resolve and
others do not, the hardcoded remainder stops looking like an oversight and starts
looking like a decision — somebody clearly considered this area, so the difference
must be intentional. When converting call sites, convert **all** of them in a module,
or annotate the ones deliberately left with the reason.

Related: the `_spawn_windows_background_command` and `_replace_path_via_powershell`
rows in the divergent-pairs table below are two instances of exactly this split.

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

### The nine that were left, and why "nine" is not the useful part

Naming them matters, because "nine helpers differ" is a fact nobody can act on and
a list is checkable in seconds. Measured comment-stripped — which is essential,
since one module comments its helpers and the other does not, and a first pass
comparing bodies *with* comments reported almost the inverse split:

| helper | shared lines | what actually differs |
|---|---|---|
| `_dashboard_core_helper_path` | 90% | one default: `web-foreground` vs `collector-loop-foreground` |
| `_same_pid_namespace` | 88% | which accessor fetches the current namespace id |
| `_helper_file_supports_internal_command` | 85% | **nothing** — one assigns then returns, the other returns |
| `_spawn_windows_background_command` | 83% | RuntimeManager hardcodes `powershell`; CollectorRunner resolves it |
| `_replace_path_via_powershell` | 82% | the same, plus a stated failure when it is unavailable |
| `_close_inherited_fds` | 75% | RuntimeManager has a `preserve_harness` guard; CollectorRunner has an explicit keep-loop |
| `_read_process_title` | 60% | `_procfs_available` + `_slurp_proc_file` vs `_read_proc_file` + a `capture` fallback |
| `_read_process_state` | 52% | the same two strategies |
| `_now_iso8601` | 50% | **`localtime` vs `gmtime` — deliberate** |

#### The similarity score sorts them; it does not classify them

It misleads in **both** directions, and either mistake is expensive:

- `_helper_file_supports_internal_command` is **85% different and behaviourally
  identical.** Its entire difference is assigning to a variable before returning.
- `_now_iso8601` is the **lowest at 50% and must never be merged.** That split is
  a subsystem boundary: `localtime` in `Collector` and `CollectorRunner`, the two
  writers of collector state, which chain consistently; `gmtime` in
  `RuntimeManager`, `Auth`, `SessionStore`, `Housekeeper` and `ActionRunner`. A
  card proposing to reconcile it was **discarded** on exactly this ground.

So an extraction ordered by similarity would have merged the one pair that must
stay apart and skipped one that could be merged today. **Read the pair.**

#### The cost, measured: one defect, four investigations

`_read_process_state` is defined in **three** modules, and no two bodies are
textually alike. All three nonetheless read the procfs file *identically* — an
`-r` guard, an open, a slurp — so the only behavioural difference is the
fallback, and there are **two** policies, not three:

| module | fallback when the procfs read yields nothing |
|---|---|
| `RuntimeManager` | returns undef; does **not** try `ps` when procfs exists |
| `CollectorRunner` | always confirms with `ps` |
| `ActionRunner` | always confirms with `ps` — same policy, expressed inline |

That distinction matters because *the bodies differing is not the same fact as
the behaviour differing*, and only the second is a reason to give two helpers
two names.

All three open with `local $?`, and each cites a **different card**: DD-585,
DD-589, DD-590, DD-591. The same defect — *a query deciding its caller's exit
status* — was found independently four times, in four modules, and fixed four
times.

**Nothing connected them.** The name was shared and the bodies were not, so a
search for "the other copies" by similarity would have missed them, and a
copy-paste detector would have flagged none. Each was rediscovered by somebody
meeting the symptom again. One of the four comments carries the whole incident —
`t/153` walking `/proc` in its END block, a vanished pid poisoning `$?`,
Test::Builder reporting *"exited with 256"* and failing the file at 255 with all
fifteen subtests passing. The other three describe the same shape in their own
words, unaware.

> **Same-name divergence does not merely mislead a reader. It multiplies the cost
> of every defect in the divergent code by the number of copies, because no
> search connects them.**

That is the argument for a check that *derives* the divergent set rather than
listing it: a list tells you about the copies somebody remembered.

#### A shared name can be the mechanism, not the mistake

Two of the divergent helpers cannot be renamed at all, and the reason is
structural rather than a matter of taste. The shared bodies dispatch through
them:

```
ProcessSupervision::_pid_is_running    calls  $self->_read_process_state
ProcessSupervision::_replace_state_file calls $self->_replace_path_via_powershell
```

Because those calls go through `$self`, each consumer's own version is the one
that runs. **The shared name is what makes the shared body work.** Rename
either implementation and the dispatch silently binds every consumer to
whichever body kept the name — a behaviour change against a suite that would
stay green, because nothing asserts which copy answered.

So same-name-different-body has three resolutions, not two:

| the divergence is | resolution |
|---|---|
| accidental — the bodies should never have differed | **reconcile** into one shared implementation |
| real, and nothing shared depends on the name | **rename** so the name stops claiming sameness |
| real, and a shared body dispatches through the name | **declare it** — this is polymorphism working |

The third class is easy to misfile as the second, and misfiling it is a
behaviour change rather than a cosmetic one. The test is one question with a
cheap answer: *does any shared body call this through `$self`?*

#### Sometimes the qualifier is the module, not the helper

Two helpers — `_read_process_state` and `_read_process_title` — split the same
way in the same two modules: `RuntimeManager` checks `_procfs_available` and
then trusts procfs, while `CollectorRunner` always confirms with `ps`. That
looks like two divergences. It is one, and it belongs to the classes rather
than to the helpers:

| module | procfs-reading subs | how many gate on `_procfs_available` |
|---|---|---|
| `RuntimeManager` | 3 | **3** |
| `CollectorRunner` | 3 | **0** |
| `ActionRunner` | 1 | 0 |

Each stance is defensible on its own terms. A long-lived supervisor can
establish once whether the host has procfs and rely on it; a collector runner
deals with short-lived pids that routinely vanish between `readdir` and the
read, so it confirms every time.

**So the name is not lying — the class name is already the qualifier.**
Renaming these would append the same suffix to every procfs helper in each
class, encoding once per helper a fact the module states once, and every helper
added later would have to repeat it.

The test for this case: *does the same split appear across several helpers in
the same pair of modules?* If it does, it is a property of the modules, and
renaming spreads one fact over many names.

#### A fourth case: divergent because one side is wrong

`_spawn_windows_background_command` differs in a way neither reconcile nor
rename can honestly resolve. `CollectorRunner` resolves the interpreter through
`_powershell_command` and dies with a clear message when it is unavailable;
`RuntimeManager` hardcodes the string `powershell`.

That is not a design difference. One of them is a defect, tracked separately.
Both other resolutions would hide it:

- **reconcile** picks a winner silently, and the losing behaviour disappears
  with no record that it was ever the other way;
- **rename** gives the defect a permanent name and makes it read as a
  deliberate variant — the same failure as the partial workaround that makes
  its unfixed siblings look intentional.

**Declaring it, with a reference to the card that fixes it, is the only option
that leaves the defect visible.** It reconciles once that card lands.

#### A same-name helper is not confined to these two modules

The two-module framing is a property of where the divergence was first noticed,
not of the code. `_read_process_state` is defined in **three** modules —
`ActionRunner` as well — and `_now_iso8601` in **seven**. A rename covering only
the two files where the problem was spotted leaves a third definition on the old
name, which is *worse* than the divergence: the difference becomes invisible
**and** inconsistent.

Before renaming any shared-looking helper, `grep -rln` for its definition across
all of `lib/`. The count is frequently not two.

#### And a divergence can be a bug report nobody filed

Two of the nine differ mainly because `CollectorRunner` resolves the PowerShell
executable and reports a clear failure when it cannot, while `RuntimeManager`
hardcodes the bare string. That is not a naming difference — it is one module
carrying a fix the other never received. Renaming the pair without noticing would
leave the weaker implementation in place under a clearer name, which is the worst
of the available outcomes.

**When two versions of a helper differ, ask which one is better before asking what
to call them.**

So a reader should still not assume a helper of a given name is shared. Check
whether it is imported or defined locally; `t/160` pins which are which, and
fails by design if a divergent one is moved into the shared module.
