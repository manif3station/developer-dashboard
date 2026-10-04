# What Changed Since Runtime Hardening, API Auth, and Layered Skills Became Real

The last blog post was about Developer Dashboard becoming more trustworthy as a daily tool:

- collectors that supervise themselves properly
- routing that makes more sense
- workspace sessions that carry the right context
- skill commands that no longer assume one language

Since then, the project has moved again.

This newer round is less about one visible front-end feature and more about something more important:

Developer Dashboard is starting to behave like a real local platform that can be automated safely, layered deeply, and trusted across less-friendly environments.

That matters because local developer tools often die in the same three ways:

- they work only from the checkout that created them
- they break as soon as environment layers get deep
- they become dangerous the moment you try to automate them remotely

This stretch of work pushed directly against those problems.

## The Short Version

Since the last post, Developer Dashboard made four especially important jumps:

- selected saved Ajax routes can now be exposed to machine callers through route-scoped API credentials instead of only browser-helper login
- layered runtime behavior became deeper and more consistent, especially across installed skills, nested skill trees, env loading, docker resolution, and shared nav
- the runtime got much harder to break on messy real machines with stale local Perl libraries, stripped `PATH` values, shell startup chatter, or packaged-install path drift
- the public command path got leaner, so prompt and helper dispatch work feels less like paying an invisible tax every few seconds

There were also a lot of smaller but important operational fixes around disabled collectors, watchdog coordination, blank-environment installs, and helper refresh stability.

The theme underneath all of it is simple:

Developer Dashboard is getting better at surviving contact with reality.

## 1. Saved Ajax Routes Can Now Be Automated Without Weakening Browser Auth

This is the biggest conceptual addition since the last post.

Before this work, saved Ajax routes had a hard limitation:

- they worked well for the browser
- they worked well for helper-user sessions
- they did not have a clean machine-to-machine auth model

That meant an operator who wanted one exact route for an external tool had two bad options:

- force the caller through a browser-oriented helper-session flow
- weaken the route in some broader way

Neither is a serious long-term answer.

Developer Dashboard now has a proper route-scoped machine-auth model for selected saved Ajax routes.

### The new config surface is explicit

Machine access now lives in layered:

```json
config/api.json
```

and the model is intentionally narrow:

- exact saved `/ajax/...` routes are registered explicitly
- callers must present `X-DD-API-Key`
- callers must present `X-DD-API-Secret`
- stored secrets are verified as SHA-256 digests instead of plain raw values
- unregistered routes still follow the normal helper-auth path

That last point matters.

This is not “turn on an API mode for everything.” It is “authorize exactly these routes, and only these routes, for machine callers.”

That is a much better security shape for a local platform.

### Helper sessions still keep working

Just as importantly, this did not break the existing browser model.

Helper-session auth still works on those same registered routes.

So the system now supports both:

- browser/helper users using the existing local access flow
- machine callers using explicit route-scoped API credentials

without confusing the two.

That is a real platform milestone, because it means saved dashboard behavior can now be exposed to automation in a deliberate and auditable way.

## 2. `dashboard api` Turned That Auth Model Into Something Operable

A backend auth model is not enough if the operator experience is bad.

That is why the next step matters almost as much as the auth feature itself.

Developer Dashboard now has a built-in:

```bash
dashboard api
```

management command.

This command exists because route-scoped machine auth is not really usable if operators have to hand-edit JSON and hash secrets themselves every time they want to add or inspect one route.

The command now lets operators:

- list the effective merged API registry
- inspect what is actually active after layering
- add exact Ajax route grants
- remove them cleanly
- hash raw secrets before saving
- write only to the deepest writable layer
- hide inherited API groups in child layers without rewriting the parent config

That last part is especially important under the project’s layered runtime model.

It means one project can narrow or mask inherited machine auth locally without mutating a shared home-level config.

This is the kind of feature that does not just add power. It adds operational clarity.

## 3. Layered Skills Stopped Being “Flat With Exceptions”

Another major change since the last post is that installed skills now behave much more like a genuinely layered, nested ecosystem.

The earlier skill work made skills useful.

This newer work made them much more structurally honest.

### Nested skill env loading now follows the full chain

Installed nested skills now load env files from root to leaf, preserving overwritten parent values under cumulative aliases such as:

- `foo_VERSION`
- `foo_bar_VERSION`
- `VERSION`

That means a deeply nested skill command does not just see the leaf value. It can also understand the path of overrides that got it there.

That is a much stronger model for reusable local modules, because nested skill trees no longer collapse important context into one final overwritten key.

### Docker compose resolution now understands installed skill roots properly

Nested installed skills can now contribute docker roots through their own:

```text
config/docker/<service>/
```

trees, and the compose resolver exports both leaf and cumulative aliases for participating skill roots.

That matters because one of the easiest ways to make a layered tool lie is to let the command surface understand nesting while the runtime service resolver still thinks in a flat tree.

That mismatch is now much smaller.

### Shared nav also got more honest

Installed skills, including nested skills, can now contribute shared `nav/*.tt` fragments in the same layered way the rest of the runtime already works.

That means a nested skill can behave like a real part of the browser surface instead of a bolt-on that only works at the first skill level.

Taken together, this is one of the most important architectural changes in the project:

the layered model is applying to more of the actual system, not just to the obvious top-level runtime files.

## 4. Real-World Runtime Portability Got Much Better

Some of the most valuable work in this stretch is the least glamorous.

Developer Dashboard got much better at handling machines that are not perfectly clean.

That includes hosts with:

- stale user-local Perl XS modules shadowing the active Perl
- a stripped or half-broken `PATH`
- shell startup chatter contaminating collector output
- packaged helper scripts that accidentally remember the wrong source-tree path

Those all sound different, but they share one failure pattern:

the tool looks fine in the development checkout and then breaks in the environments people actually use.

### Perl and shell path normalization became much more defensive

Dashboard-managed processes now normalize `PERL5LIB` so dashboard-owned libraries stay visible while the active core, site, and vendor Perl directories stay ahead of stale inherited local-lib shadows.

Dashboard-managed child commands also keep both:

- the current Perl interpreter directory
- the active shell directory

at the front of `PATH`.

This is a big deal because a lot of “works on my machine” failures are really “works only in the shell that built it.”

That gets especially nasty when helpers, collectors, or Ajax subprocesses invoke `dashboard` through:

```perl
#!/usr/bin/env perl
```

and silently pick up the wrong interpreter in child processes.

This is one of those fixes users do not always see directly, but they absolutely feel it when it is missing.

### Collector shell commands stopped trusting login-shell noise

Collector shell commands now run through a non-login shell so startup banners and shell-session restore chatter do not get prefixed onto JSON output.

That is the kind of bug that can be maddening in practice:

- the collector command itself succeeds
- the JSON parser fails
- the output looks half-right
- the runtime appears flaky even though the actual problem is shell startup text

This is exactly the sort of real-machine hardening a local platform needs.

### Packaged helper bootstrap stopped leaking checkout paths

Another important fix was packaged helper bootstrap behavior.

Staged helpers now re-enter the active public `dashboard` entrypoint instead of leaking a stale inherited source-tree path into extracted tarball installs.

That is a very high-leverage correction because it closes one of the worst local-tool trust failures:

the installed version should behave like the installed version, not like a ghost of whichever checkout happened to create it.

## 5. The Public Command Path Got Leaner

The project also spent real effort on prompt and dispatch performance.

That matters because performance problems in a developer tool are often death by repetition rather than one huge pause.

If the prompt path is heavy, you pay for it constantly.

Recent work trimmed several sources of unnecessary cost:

- the public switchboard now avoids suggestion and helper-staging overhead on the normal prompt path
- helper refresh can target only the requested helper instead of restaging everything
- path derivation and invocation cwd lookup are reused more aggressively
- prompt rendering avoids unnecessary tmux and collector work when the environment does not require it

None of that is a marketing bullet by itself.

Together, it changes the feel of the tool.

Developer Dashboard is gradually moving from “clever command surface” toward “background layer that stays out of the way until needed.”

That is exactly what a prompt-adjacent runtime should become.

## 6. Collector Operations Got Safer, Not Just Smarter

The last blog post already covered collector resilience in a broader sense.

Since then, the collector story improved again in more operational ways.

### Disabled really means disabled now

Configured `disable` state is now treated as a hard stop-and-skip signal.

That means:

- disabled collectors are not started
- explicit named starts reject them
- already-running loops are stopped on the next lifecycle action
- stale indicators for disabled collectors are removed instead of hanging around

That sounds obvious, but local tools often get this wrong. They treat “disabled” as UI metadata instead of runtime truth.

### Manual lifecycle and watchdog behavior interfere less

The watchdog supervisor now pauses during explicit named collector stop and restart operations, then resumes supervision afterwards.

That matters because one of the ugliest runtime races is:

- the operator stops or restarts a collector on purpose
- the watchdog notices the gap mid-flight
- the watchdog spawns another loop underneath the manual action

That kind of behavior destroys trust quickly.

This is exactly the right kind of fix: not flashy, but deeply stabilizing.

## 7. The Overall Shape Is Getting More Mature

A lot of these changes might look unrelated at first:

- API credentials for saved Ajax routes
- nested skill env inheritance
- child `PATH` repair
- helper bootstrap correctness
- prompt-path trimming
- collector disable semantics

They are not unrelated.

They are all about the same transition:

Developer Dashboard is getting less tolerant of hidden assumptions.

The system is becoming more explicit about:

- who is allowed to call what
- which layer owns which config
- which runtime path is actually active
- which environment values should win
- which processes belong to the tool
- which command path is the public truth

That is what maturity looks like in local infrastructure.

It is not just “more features.”

It is fewer lies.

## Closing

The last post was about Developer Dashboard becoming more dependable in daily use.

This next stretch went deeper.

The project is getting better at three things that matter a lot if you want one local system to carry more of your workflow:

- safe automation
- honest layering
- portability across imperfect machines

That is a strong direction.

Because once a local platform can:

- expose selected behavior to machines without weakening everything else
- keep layered skill and runtime context coherent as the tree gets deeper
- survive stale environments, packaged installs, and child-process edge cases

it stops being just a useful pile of commands.

It starts becoming infrastructure you can build on.
