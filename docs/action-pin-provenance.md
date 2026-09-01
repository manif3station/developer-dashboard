# Pinning a GitHub Action: resolve the commit, not the tag

This project pins every `uses:` line in `.github/workflows/` to a 40-hex SHA
with a version comment (`uses: owner/repo/action@<sha>  # vX.Y.Z`). This page
describes how that SHA is meant to be resolved and the one way that goes
wrong silently.

## Why a SHA pin at all

A tag can move; a branch definitely moves. Pinning to a commit SHA is what
makes `uses:` mean "exactly this code," matching the standard supply-chain
hardening advice for third-party Actions. `script/audit-action-pins` checks
this project's pins still resolve to the release their comment claims and
still declare a node24+ runtime, and runs as part of every CI job.

## The trap: a tag's own SHA is not the commit's SHA

GitHub's tag API has two shapes depending on whether a tag is *lightweight*
or *annotated*:

```
GET /repos/<owner>/<repo>/git/ref/tags/<tag>
  -> { object: { sha: X, type: "commit" | "tag" } }
```

For a **lightweight** tag, `type` is `"commit"` and `X` already IS the commit
SHA to pin. For an **annotated** tag (the more common case for a maintained
project's releases), `type` is `"tag"` - `X` is the SHA of the **tag
object itself**, a distinct Git object that merely *points at* a commit. That
tag object's own SHA is a real, resolvable, well-formed 40-hex SHA - it is
just not the thing `uses:` needs. Pinning to it directly gives Actions a SHA
that never appears in the repository's commit history, and the failure mode
depends on how it is checked out.

**Resolving it correctly needs a second call, dereferencing the tag object:**

```
GET /repos/<owner>/<repo>/git/tags/<tag_object_sha>
  -> { object: { sha: Y, type: "commit" } }   # Y is the real commit SHA
```

`Y`, not `X`, is what goes into the pin.

## How this bit DD-675

Verifying that v4.37.8 genuinely differed from the pinned v4.37.7 (per this
project's own standing rule - a Dependabot PR is presumed correct until the
SHA says otherwise, not the reverse, after DD-449/435/436's trail of stale
guardrails certifying pins from their comment rather than their SHA), the
tag-ref call returned an annotated tag object's SHA. That value was recorded
on the card as "upstream tag v4.37.8 resolves to 37f2634a...". It does
resolve - to the tag object, not the commit - and was caught only by
dereferencing it a second time before using it in the actual pin.

## How to apply

Before writing a resolved SHA into a workflow pin (or into a card as
evidence for one), check the tag-ref response's `object.type`. If it says
`"tag"`, dereference once more via `git/tags/<sha>` and use *that* result's
`object.sha`. Never assume the first SHA returned is the commit just because
it looks like one - a tag object's SHA is exactly as well-formed as a
commit's, which is what makes this trap easy to walk past unnoticed.
