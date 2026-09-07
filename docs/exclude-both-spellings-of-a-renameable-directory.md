# A directory kept out of a build by its dotfile default needs its own exclusion, in both spellings

Why relying on a build tool's "skip dotfiles" default is not the same as
naming a hazardous directory, and what to do when the directory can be
renamed.

## The problem this solves

Dist::Zilla's `GatherDir` defaults `include_dotfiles` to 0, so a directory
like `.developer-dashboard/` is absent from a built tarball without
anyone excluding it by name. That default protects the directory only
while it keeps its dot-prefixed name. The moment it is renamed to a
non-dot form - `.hermes/` becoming `_hermes/` was the real incident this
project met (DD-432) - the default stops applying, and if nothing names
the directory explicitly, the rename removes the only thing that was ever
keeping it out of a release.

`.developer-dashboard/` on this machine holds real secrets - `.env`,
`config/auth`, `cli/auth`, `certs/` - so a silent rename here is not a
cosmetic risk. It is the exact shape that shipped credentials once
already (DD-432).

## The rule

> **A directory kept out of a build only by a tool's dotfile default is
> not protected - it is unprotected and happens to have the right name
> today.** Any directory whose absence from a shipped artifact matters
> must be named explicitly in every exclusion mechanism the build uses
> (here: `dist.ini`'s `[GatherDir] exclude_match` and `MANIFEST.SKIP`),
> and named in BOTH the dot-prefixed and non-dot-prefixed spelling, so a
> rename in either direction stays covered.

## How to apply

- When adding a runtime state directory that must never ship, exclude it
  by name in every relevant manifest/build-exclusion file - do not rely on
  a framework default excluding dotfiles, hidden files, or any other
  incidental property of its current name.
- Exclude both the dot and non-dot spelling up front, even though only one
  exists today. The cost is one extra line; the alternative is a silent
  gap that opens the moment someone renames the directory for an unrelated
  reason.
- Prove the exclusion hermetically, the way DD-432 did: build a scratch
  distribution carrying both spellings with real (or realistic) sentinel
  files inside, and confirm neither spelling appears in the built
  tarball - not by reading the exclude pattern and trusting it matches.
- A gate that only checks the exclusion line is *present* can pass while
  the pattern is *wrong* (a typo, a wrong anchor). DD-432's own t/15 gate
  extracts the `exclude_match` patterns from `dist.ini` and asserts they
  actually match the hazardous paths while leaving every shipped path
  gatherable - so a present-but-wrong pattern still fails red.
