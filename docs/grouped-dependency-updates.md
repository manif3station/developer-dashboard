# Grouped dependency updates, and the action families that require them

Some GitHub Action families refuse to run unless every step from that family uses
the **same version**. When an automated updater proposes one pull request per
action *path*, such a family can never be updated by any single PR: each one moves
one step and strands the others, and the version check refuses.

This page describes that behaviour and how this repository handles it. It is not
about any one occurrence — there have been three.

## The constraint

`.github/workflows/codeql.yml` calls three separate action paths, and all three
must agree:

```
github/codeql-action/init@<sha>
github/codeql-action/autobuild@<sha>
github/codeql-action/analyze@<sha>
```

CodeQL enforces this at run time. When they disagree it fails with:

```
Loaded a configuration file for version '4.37.8', but running version '4.37.9'
Not all workflow steps that use `github/codeql-action` actions use the same version.
```

## Why one PR per path cannot work

Dependabot treats each action path as its own dependency. Without grouping, a
single upstream release produces three pull requests — one for `init`, one for
`autobuild`, one for `analyze`. Each moves its own step and leaves the other two
behind, so **every one of them fails by construction**.

The failure is quick and does not look like an analysis result. `Initialize
CodeQL` and `Autobuild` both succeed; `Analyze` and `Post Analyze` fail; the whole
job takes about thirty seconds. That shape — early steps green, a fast failure at
the step that checks versions — is the signature of a handshake refusing rather
than a scan finding something.

**Re-running does not help, and neither does waiting.** The three PRs block each
other, so they can only pass together.

## The fix: group the family into one pull request

Dependabot's `groups:` key combines matching updates into a single PR:

```yaml
- package-ecosystem: "github-actions"
  directory: "/"
  schedule:
    interval: "weekly"
  groups:
    codeql-action:
      patterns:
        - "github/codeql-action*"
```

One PR then moves all three call sites together and the version check is
satisfied.

### Group the family, not everything

The commonly-cited example uses `patterns: ["*"]`, which combines *every* action
update into one pull request. That is a broader change than the problem requires:
it alters how all dependency updates arrive, and it makes a single failing update
block the rest of the batch. Only families with a shared-version constraint need
grouping. Match the family.

### Verify the pattern against the real paths

A trailing wildcard is an assumption until it is tested. Check the pattern against
the literal strings it must match — `github/codeql-action/init`,
`github/codeql-action/autobuild`, `github/codeql-action/analyze` — because the
whole defect is three paths being treated separately, and a pattern that catches
only two reproduces it in a quieter form.

## Grouping does not rescue pull requests already open

Grouping changes how *future* updates are proposed. Pull requests already open
keep their original single-path scope and keep failing. They have to be closed so
the updater re-proposes a grouped one, or merged simultaneously so the versions
line up. Closing or merging pull requests is a change to the repository's public
state, so on this project it is the owner's decision rather than an agent's.

## How to recognise this class

- Several dependency PRs opened at the same moment, all red on the same check.
- The failing check completes far faster than a real analysis would.
- The error names two versions rather than a code defect.
- The updater's configuration has no `groups:` key for that ecosystem.

## Why this page exists

The same defect arrived three times — `4.37.6 → 4.37.7`, `4.37.7 → 4.37.8`,
`4.37.8 → 4.37.9`. Each occurrence was individually small enough to resolve by
moving the pin by hand, which is exactly why the cause survived all three. A
recurrence that is always cheap to work around is one nobody ever fixes.
