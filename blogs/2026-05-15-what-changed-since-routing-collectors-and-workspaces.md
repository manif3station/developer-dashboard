# What Changed Since Routing, Collectors, and Workspaces Started Getting Serious

The last blog post covered the stretch where Developer Dashboard became more usable in the real world: better installs, better skill dependency handling, cleaner routing, clearer progress, and a more trustworthy local runtime.

Since then, the project has moved again.

This newer round of work is less about adding a single headline feature and more about making the platform hold up under daily use:

- background collectors that do not quietly die and wait for babysitting
- runtime helpers that stop leaving zombie child processes behind
- custom routes that work across saved pages and skill assets without breaking smart routing
- workspace sessions that carry the right environment every time
- skill commands that can now be written in JavaScript and Python just as naturally as Perl, Go, Java, or shell

This is the point where the tool starts feeling less like a promising local framework and more like something you can lean on all day.

## The Short Version

Developer Dashboard got stronger in six practical areas:

- collectors are more resilient and less likely to fail silently
- overlapping collector runs are now explicit and configurable
- custom routes are broader, cleaner, and easier to reason about
- tmux workspaces gained layered environment refresh instead of stale session state
- process management got cleaned up so runtime helpers stop leaking zombies
- skills can now ship JavaScript and Python commands plus Node and Python dependency manifests

If the earlier work was about making the system broader, this work is about making it safer and more predictable.

## 1. Collectors Got Much More Operational

One of the most important recent improvements is collector resilience.

Before this round of changes, a collector could end up in the worst kind of failure mode:

- still configured
- expected to be running
- not actually updating anything
- quiet enough that the user notices only by checking manually

That is bad local-platform behavior. If a background collector is meant to maintain status, it should either keep doing the work or make the failure obvious.

Developer Dashboard now does more of that correctly.

### Stalled and crashed collectors are watched explicitly

Managed collectors now have watchdog behavior that does not only notice a process exit. It also treats a collector as unhealthy when it stays alive but stops making progress.

That matters because some of the worst runtime failures are not clean crashes. They are half-dead loops that still exist in `ps` output but have stopped doing useful work.

The newer collector supervision work now:

- restarts unexpectedly stopped managed loops
- treats live-but-stalled loops as a failure condition
- records restart counters and restart-window metadata
- raises an explicit attention-needed state instead of looping forever when a collector keeps failing

That changes the operator experience from “I guess I need to keep checking it” to something much closer to “the runtime should notice this first”.

### Overlap is now a real policy choice

Collectors also gained explicit execution modes.

The default remains the safe one:

- `singleton`

That means if a collector is still running when the next interval arrives, the next run is suppressed until the current run finishes.

There is now also:

- `multiple`

When a collector opts into `multiple`, later ticks are allowed to start while earlier runs are still active, and the number of parallel runs is bounded by a configurable limit.

That is useful for collectors where skipping an interval is worse than overlap, but it stays opt-in and controlled rather than accidental.

In other words, overlap is no longer undefined behavior. It is part of the config model.

## 2. Runtime Process Cleanup Stopped Being Sloppy

Another important fix was child-process cleanup.

On hosts like macOS and WSL, the runtime could leave zombie processes behind when web helpers, collectors, or detached background actions exited in awkward ways.

That kind of bug is easy to underestimate, because a tool can look functional while still slowly polluting the process table.

The recent work tightened this across the runtime:

- managed collector stop paths now reap children properly
- detached helpers no longer leave launcher zombies behind
- SSL/web runtime paths handle child cleanup more cleanly
- regression coverage now treats unreaped child processes as a real failure

This is not visible in the same way a new feature is visible, but it is one of the changes that most directly affects whether a long-running developer tool feels trustworthy.

## 3. Routing Became More Coherent Without Breaking Smart Routing

Routing was another area that matured a lot.

Earlier work had already started making skill-local web surfaces more structured. The recent follow-up made that model much broader and more consistent.

### Custom route metadata moved into a clearer shape

Custom route definitions now live in:

```json
config/routes.json
```

and the format is flatter and easier to understand: public paths map directly to the internal route they should resolve to.

That matters because route configuration should be obvious when you open the file. It should not require remembering a special nested schema just to publish one alias.

### Custom routes are not only for Ajax anymore

The custom-route model now covers:

- `/app`
- `/ajax`
- `/js`
- `/css`
- `/others`

That means a skill or runtime surface can expose bookmarks, handlers, and assets behind cleaner paths without inventing a separate mechanism for each route family.

### Smart routing still stays in charge

Just as importantly, this was done without breaking smart routing.

The route model now behaves the way you would expect from a sane layered system:

1. smart route resolution tries to find the real parent route first
2. custom alias routing is the fallback path
3. normal `404` behavior still happens if neither path resolves

That keeps the routing rules predictable instead of turning aliases into a second competing dispatcher.

### Runtime aliases now work for saved pages too

One practical fix from this work is that runtime `config/routes.json` aliases now actually participate in normal dashboard routing, including saved bookmarks.

So a shorter path like:

```json
{
  "/java": "/app/learn.ai"
}
```

can resolve to a saved bookmark page directly, even though `learn.ai` is simply a filename and not a dotted skill namespace.

That sounds small. It is exactly the kind of small thing that makes a local tool feel natural instead of brittle.

## 4. Workspaces Replaced Tickets as the First-Class tmux Flow

The tmux workflow also got cleaned up.

The command surface now treats:

```bash
dashboard workspace
```

as the primary session workflow, while the older `ticket` naming remains as a compatibility path.

That rename matters because the newer model is broader than “ticket work”. It is really about resuming a local project workspace with the right context and shell state.

### Layered `.env` refresh is now part of workspace resume

This was also paired with a more important runtime change: workspace create and resume now refresh plain `.env` files across the directory chain instead of relying on stale session environment.

The order now follows a clear model:

- highest ancestor `.env` as the base
- parent `.env` files layered next
- current directory `.env` last as the override

and resumed workspace sessions refresh values in place, including unsetting keys that were removed.

That is exactly the behavior people expect once they start using nested project folders with environment-specific overrides.

Without this, tmux workspaces drift. With it, resuming a workspace behaves more like re-entering the project deliberately.

## 5. Skill Commands Now Cover JavaScript and Python Too

This is the most recent extension to the skill system, and it is an important one.

Developer Dashboard already supported direct command and hook dispatch for several source-backed command types. It now also supports:

- JavaScript via `node`
- Python via `python`

That means a skill can now ship command files such as:

- `cli/foo.js`
- `cli/foo.d/01-first.js`
- `cli/bar.py`
- `cli/bar.d/01-first.py`

and they participate in the same logical command and hook resolution flow as the existing Perl, Go, Java, and shell-backed commands.

This matters for two reasons.

First, it makes skills more realistic as reusable local modules. People already have small developer tools in Node and Python. They should not need to rewrite them into another language just to fit the dashboard.

Second, it keeps the command model coherent. The platform is not growing a special “Node mode” and a separate “Python mode”. It is extending one dispatch model across more runtimes.

## 6. Skill Dependency Handling Now Matches Those New Runtimes

Supporting JavaScript and Python commands would be incomplete without supporting their dependency manifests too.

That is now in place.

The skill install chain already covered system package manifests and Perl-specific manifests. It now also covers:

- `package.json`
- `requirements.txt`

with `requirements.txt` running after `package.json` in the dependency flow.

That means a skill can now describe more of its real runtime needs inside its own repo, instead of requiring separate setup notes that drift from reality.

At that point, a skill is much closer to being a real installable unit:

- commands
- hooks
- pages
- routes
- assets
- dependency manifests

all living together in one place.

That is a much stronger local-platform story than “copy this folder and read the README carefully”.

## 7. The Daily User Experience Is Less Random

A lot of these changes share the same underlying theme:

- less silent failure
- less accidental randomness
- less operator guesswork

Examples:

- collector indicators now preserve configured order instead of drifting around
- skill install progress stays more scoped and less noisy
- routes resolve through clearer rules
- resumed tmux workspaces pick up the right environment instead of a stale one
- helper runtimes clean up after themselves instead of leaving process litter behind

None of that is marketing-friendly in the usual sense.

It is, however, exactly what makes a local developer platform usable for months instead of days.

## Closing

The recent work on Developer Dashboard has been about making the system act more like infrastructure and less like a promising bundle of features.

That means:

- if something is running in the background, it should be supervised
- if something dies, it should either restart or report clearly
- if a route is configured, it should resolve predictably
- if a workspace is resumed, it should load the right environment
- if a skill wants to use Node or Python, the runtime should meet it where it already is

This is a quieter kind of progress than launching a giant new subsystem.

It is also the kind of progress that usually matters more.

Developer Dashboard is becoming less of a neat local toolkit and more of a dependable terminal-first platform for organizing real development work.
