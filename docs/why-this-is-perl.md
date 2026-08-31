# Why this is Perl, and what a port would actually cost

This page records the architectural properties that make Developer Dashboard
expensive to move to another language. It is not an argument against ever doing
it — it is the list of things anyone proposing it has to have an answer for.

The figures below were measured on 2026-08-31 and are re-measurable in one
command each. **Prefer re-measuring to trusting them**: they drifted within
twenty hours of first being recorded, because ordinary work adds lines.

## The ratio, not the size, is the obstacle

```
lib/    42,342 lines across  58 modules
t/      97,410 lines across 168 files
        ------------------------------
        2.30x more test code than production code
```

Re-measure with `find lib -name '*.pm' | xargs cat | wc -l` and the same for
`t/ -name '*.t'`.

That ratio exists because of a standing rule rather than by accident: every
change is gated on **100% Devel::Cover on all four metrics** — statement,
branch, condition and subroutine. A suite that large is the real safety net,
and it is the part that does **not** port. Translating 42k lines of production
code is a project; recreating the thing that proves the translation is correct
is a much larger one, and until it exists there is nothing to verify the port
against.

**This is the load-bearing fact.** The absolute line counts drift; the ratio,
and the reason for it, do not.

## Three surfaces that are redesigns, not translations

Nothing here is *functionally incompatible* with Rust or Go — both can express
what this system does. These are places where the shape of the solution would
change, which is a different and larger kind of work than porting syntax.

**1. AUTOLOAD-based dynamic dispatch.** `lib/Developer/Dashboard/File.pm` and
`Folder.pm` resolve aliases at call time through `AUTOLOAD`. Rust and Go want
static interfaces or traits declared up front; the equivalent is a redesign of
how aliases are resolved, not a rewritten function.

**2. Runtime-assembled layer stacks.** The DD-OOP-LAYERS contract discovers
every `.developer-dashboard/` directory from `~` down to the cwd and merges
them at runtime — config, collectors, hooks, skills. That is a dynamic
composition model.

**3. The skills system.** Installable repos with their own CLI, dashboards and
isolated `local/`, dispatched by dotted name at runtime. A statically compiled
target changes what "install a skill" can mean.

## The tooling is a wholesale replacement, and it is the smaller piece

The CPAN / `dzil` / PAUSE release pipeline is entirely Perl-ecosystem: `dist.ini`
with its `exclude_filename` list, the kwalitee gate, the signed-release workflow
keyed to a `vX.XX` tag. All of it would be replaced by `cargo` + crates.io or Go
modules + GitHub releases.

**Flagged explicitly as the smaller piece of work**, because it is the most
visible one and therefore the easiest to mistake for the hard part. It is not.

## The recorded decision

Asked on 2026-08-31, answered the same night: **a full rewrite is not
recommended**, on the grounds above. The owner's own reply closed it — *"This is
just research card. Not actually do it."*

DD-691 carries the full assessment. **Read that card rather than this summary**
if you are reopening the question, and re-measure before quoting any number
here.
