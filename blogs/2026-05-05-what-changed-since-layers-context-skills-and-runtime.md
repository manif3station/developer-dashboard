# What Changed Since “Layers, Context, Skills, and Runtime”

The last post explained the model behind Developer Dashboard: layered runtime roots, shared context, skill installs, and a local runtime that follows you from home into projects.

Since then, the project has moved from “interesting model” to “much more usable every day”.

This post is about what changed, what is actually new, and why it is worth caring about if you spend most of your day in a terminal.

## The Short Version

Developer Dashboard is now better at five practical things:

- getting installed on real machines, including Windows and blank macOS hosts
- keeping skills, pages, routes, and helper commands predictable after upgrades
- managing background runtime pieces without stepping on sibling environments
- making long-running work visible instead of looking stalled
- reducing prompt noise while still showing useful live status

That may not sound flashy. For a developer tool, that is exactly the point.

The exciting part is not a single giant feature. It is that more of the daily workflow now feels stable enough to trust.

## 1. Fresh-Machine Setup Got Much Better

One of the biggest changes is that bootstrap now takes “blank machine” seriously.

### Windows now has a real bootstrap path

There is now a PowerShell installer:

```powershell
irm https://raw.githubusercontent.com/manif3station/developer-dashboard/refs/heads/master/install.ps1 | iex
```

That matters because Windows support is no longer a side note or a manual recipe hidden in issue comments.

The installer work since the last post covered:

- bootstrap package installation
- PowerShell profile setup
- `dashboard` command availability in new sessions
- `dashboard restart` and `dashboard logs` checks in fresh PowerShell sessions
- real Windows smoke coverage through the project’s test workflow

For developers who move between Linux, WSL, and Windows, this is a real quality-of-life jump.

### Blank macOS hosts got less brittle

On macOS, Developer Dashboard now bootstraps Homebrew automatically when it is missing instead of dying immediately with a “missing brew” error.

That means a fresh Mac is closer to:

```bash
curl .../install.sh | sh
```

and further from:

- install Homebrew first
- patch your shell manually
- rerun the installer
- guess what failed

That is not glamour work, but it is exactly the kind of friction that decides whether a tool becomes part of your routine or gets abandoned after first contact.

## 2. Skills Became More Useful as a Real Package Surface

The earlier post talked about skills as installable capability bundles. Since then, the skill system became broader and more operationally useful.

### More dependency types are supported

Skill installs now understand a larger set of dependency manifests, including:

- `aptfile`
- `apkfile`
- `dnfile`
- `wingetfile`
- `brewfile`
- `package.json`
- `cpanfile`
- `cpanfile.local`
- `Makefile`
- `ddfile`
- `ddfile.local`

That means a skill can describe more of what it needs in its own folder instead of relying on a README that says “install these seven things first”.

### `wingetfile` support matters more than it sounds

This is especially important on Windows. A skill can now declare Windows package requirements in `wingetfile`, and non-Windows hosts will skip that manifest cleanly.

That is a small change with a big effect: cross-platform skills get easier to maintain because the dependency surface can live with the skill itself.

### Makefile support makes skills less toy-like

Some skills need more than “install these packages”. They need setup sequences.

The skill installer now supports a `Makefile` in the install flow, which gives skill authors a place to express setup that is too complicated for a plain package list.

That moves skills closer to “reusable local platform module” and further away from “folder with a couple of scripts”.

## 3. Long-Running Skill Installs No Longer Feel Blind

This is one of the changes that matters every single day once you start using more skills.

`dashboard skills install` now has a Docker-style progression view:

- the high-level task board stays visible
- the active task shows a rolling detail window
- old detail lines fall out of the window instead of flooding the screen
- successful tasks collapse back into `[OK]`
- failed tasks stop with visible detail

That means a long-running step like `brewfile`, `npm`, `cpanm`, or `make` no longer looks like a frozen terminal.

This is not just cosmetic.

It changes the user experience from:

- “is this hanging?”
- “should I Ctrl-C?”
- “what is it even doing?”

to:

- “it is in the `brewfile` step”
- “I can see the current output”
- “if it fails, I know which layer failed”

If you install and update skills often, this is one of the most practically valuable upgrades in the whole project.

## 4. File Navigation Got Stronger

The public command surface now has better file-oriented behavior.

You can register files directly, not just directories, and use them through the dashboard command layer. You can also scope file lookup through registered path roots.

That helps with a real recurring problem in development:

- you remember the name, not the path
- you know the project, not the exact file
- you want one stable entrypoint instead of shell-history archaeology

This is the kind of feature that saves small amounts of time many times a day.

Those are exactly the improvements that compound.

## 5. Optional Dashboards Were Pulled Out of Core

API Dashboard and SQL Dashboard were removed from the core code, docs, and tests.

That is a healthy architectural move.

Why it matters:

- not every install needs those features
- the core distribution gets lighter
- optional capability is cleaner when it behaves like optional capability

This is also good for understanding the product. Developer Dashboard becomes easier to reason about when the core is the core and optional tools are actually optional.

## 6. Smart Skill Routing Got Better

Skill-local routes for bookmarks, Ajax handlers, and static assets became much more coherent.

In practical terms, that means a skill can own more of its own web surface without leaking into the wrong namespace.

This matters if you are building richer skills that include:

- pages
- Ajax handlers
- JavaScript
- CSS
- other public assets

The result is that skills feel more self-contained and less like scattered special cases.

That is important if you want Developer Dashboard to be the home for local tools, not just a command launcher.

## 7. Runtime Control Became More Operational

The runtime side of the project got more complete.

There is now better support for:

- scoped restart and stop behavior
- scoped collector control
- log access
- better status summaries

This matters because a local developer platform is not just “commands that run”.

It is also:

- what is running
- what restarted
- what failed
- what logs belong to which part

Developer Dashboard is gradually becoming more useful as a real local control surface, not only a CLI alias manager.

## 8. Linux Host and Docker Runtime Isolation Got Safer

One of the more important reliability changes is runtime isolation.

The project now explicitly protects against the host Developer Dashboard runtime interfering with a Developer Dashboard runtime inside a Docker container that happens to be running similar web or collector processes.

Why that matters:

- many developers use containers for isolated app work
- many developers also keep helper runtimes on the host
- if a host restart command kills the wrong thing, trust is gone immediately

That bug class is subtle and nasty. Fixing it makes Developer Dashboard safer to use on real development machines that mix host and container workflows.

## 9. `d2 ticket` Became More Serious as a Daily Terminal Workflow

There was a lot of refinement around tmux and ticket sessions.

The general direction is clear:

- ticket sessions should feel cleaner
- indicators should be visible without polluting the prompt
- prompt context and live status should not fight each other

If you live in tmux and use ticket or session-based work as your main terminal workflow, this is one of the most promising parts of recent development.

It pushes Developer Dashboard toward being not just a command set, but a better terminal operating environment.

## So Why Should You Bother?

Because this is the stage where the project starts paying back routine friction.

The earlier model work explained how Developer Dashboard is structured.

These changes make it easier to actually rely on that structure:

- setup is less annoying
- upgrades are safer
- skills are more expressive
- long-running work is more transparent
- host and container behavior is less dangerous
- terminal workflow is getting cleaner instead of noisier

In other words: it is becoming easier to leave more of your local developer life inside one system without feeling trapped by it.

That is the real value.

## What Is Exciting About It?

The exciting part is not “look at this one giant flagship feature”.

The exciting part is that Developer Dashboard is starting to feel like a real local platform:

- installable
- layered
- skill-driven
- runtime-aware
- cross-platform
- less fragile than the usual pile of dotfiles and helper scripts

Most developer tooling fails because the daily edges are too sharp:

- setup is brittle
- upgrades are weird
- progress is invisible
- background processes are confusing
- platform differences are painful

The recent work hits those exact edges.

That is why it matters.

## Closing

If the first post was about the idea of Developer Dashboard, this one is about the tool becoming more practical.

The model is still the same:

- layered runtime roots
- shared local context
- installable skills
- one command surface

But the day-to-day experience is now better in ways that developers actually feel:

- fewer bootstrap surprises
- better install feedback
- safer runtime behavior
- more useful skills
- cleaner terminal workflows

That is the kind of progress worth paying attention to.
