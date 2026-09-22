# The GitHub Release page attaches the compiled PAX binaries (DD-1025)

This page describes the current behavior of the system, not any one
ticket.

## The gap this closes

`pax-release.yml` builds compiled PAX standalone binaries (currently
linux-amd64/arm64/i686 and windows-amd64) and uploads them via
`actions/upload-artifact`. That is a GitHub Actions **workflow-run
artifact** - ephemeral (default 90-day expiry), tied to that specific
run, and never surfaced on the repository's actual Releases page.
`release-github.yml`'s own release only ever attached the source
distribution (`Developer-Dashboard-X.XX.tar.gz` and its checksum/
signature/provenance files), so a user visiting a tagged release saw
no compiled binaries at all - only the source tarball, which needs a
Perl install to use.

## How it's wired

`pax-release.yml` gained a `workflow_call: {}` trigger alongside its
existing `push`/`workflow_dispatch` ones, making it callable as a
**reusable workflow** - the same file, invoked as a job in another
workflow's run rather than reached across separately. `release-github.yml`
adds it as a sibling job:

```yaml
pax-binaries:
  uses: ./.github/workflows/pax-release.yml
```

and a follow-up job, `attach-pax-binaries`, that `needs: [release,
pax-binaries]` - both the release (which must exist first, since
`gh release upload` attaches to an existing release) and the compiled
binaries (which must have finished building). It downloads every
`d2-dashboard-*` artifact via `actions/download-artifact` (which, run
within the same workflow's own execution, can pull artifacts uploaded
by a sibling job - including one reached via a reusable-workflow call
- with no cross-workflow lookup needed), renames each to its target
name, and uploads them to the release with `gh release upload
--clobber`.

**This is deliberately NOT folded into the `release` job itself.**
Keeping `pax-binaries` as its own parallel job means building the
compiled binaries adds no wall-clock time to an ordinary release on
top of whichever of the two paths (the full Perl test/coverage/build
pipeline, or the PAX build matrix) happens to take longer - nobody
waits on binaries they don't look at.

## Why this workflow now builds twice on a tag push

`pax-release.yml`'s own `push`/tags trigger is unchanged - it still
runs standalone on every push, independent of releasing, which was its
original purpose (build-testing every commit, not just tagged ones).
A tag push therefore triggers it twice: once via its own trigger,
once via `release-github.yml`'s `workflow_call`. This is intentional
redundancy, not a bug - the standalone run's own conclusion still
matters for ordinary master pushes that never become a release, and
removing it would mean master pushes stop getting build-tested between
releases.

## Failure behavior

`attach-pax-binaries` fails loudly (`exit 1`) if it finds zero binaries
to attach - a silent no-op (every target still a placeholder, or the
`pax-binaries` job producing nothing) would look identical to a
correctly-empty result otherwise, and this project's own discipline is
that a real gap should be noticed at release time, not discovered
later by someone looking at the page and wondering where the binaries
went.

## Where to look

- `.github/workflows/pax-release.yml` - the `workflow_call` trigger and
  the build matrix itself.
- `.github/workflows/release-github.yml` - the `pax-binaries` and
  `attach-pax-binaries` jobs.
- `docs/pax-multi-platform-ci.md` - the epic-level (DDE-006) overview
  of the whole multi-platform build matrix this page's binaries come
  from.
