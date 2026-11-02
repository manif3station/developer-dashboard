# CPAN/PAUSE release has no GitHub-triggered path (DD-1026)

This page describes the current behavior of the system, not any one ticket.

## The decision

CPAN release (uploading a built distribution to PAUSE) happens **only**
locally, via `dashboard pause-release`. There is no GitHub Actions
workflow that can trigger it - `.github/workflows/release-cpan.yml`
(which previously offered a manual `workflow_dispatch` trigger for this)
has been removed entirely.

Owner instruction, verbatim: *"remove Release To CPAN from the github
workflow, we won't release anything to PAUSE on github. all done
locally here."*

## What still runs on GitHub

Exactly three workflows remain:

- `platform-compatibility.yml` - the full Linux/macOS/Windows compatibility
  matrix, including the Linux x64 coverage, dependency-audit, action-pin, and
  JavaScript property-test gates.
- `release-github.yml` - creates the signed GitHub Release (source tarball plus
  checksum, signature, and provenance) from a `vX.XX` tag, with manual recovery
  dispatch for an existing tag.
- `dockerhub-image.yml` - publishes the multi-architecture Docker Hub image from
  `master`, with manual dispatch available when needed.

None of these uploads a distribution to PAUSE or performs a CPAN release.

## Why

GitHub Actions holding PAUSE credentials (even behind manual
`workflow_dispatch`) was a second, remotely-triggerable release path
alongside the local one. The owner decided that surface should not
exist at all - CPAN uploads happen only from a human directly running
`dashboard pause-release` on this machine, never from CI.

## Where to look

- `dashboard pause-release` (an operator-local layered command, not
  shipped in this repo - see CLAUDE.md's Architecture section) is the
  only sanctioned CPAN release trigger.
- `.github/workflows/` contains only Platform compatibility, GitHub Release,
  and Publish Docker Hub Image; there is no CPAN-related workflow.
