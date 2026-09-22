# CPAN/PAUSE release has no GitHub-triggered path (DD-1026)

This page describes the current behavior of the system, not any one
ticket.

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

- `test.yml` - the full test/coverage suite, on every push and PR.
- `pax-release.yml` - builds compiled PAX standalone binaries per
  platform/arch (see `docs/pax-multi-platform-ci.md`).
- `release-github.yml` - creates the signed GitHub Release (source
  tarball + checksum/signature/provenance, plus the compiled PAX
  binaries via `pax-binaries`/`attach-pax-binaries` - see
  `docs/github-release-attaches-pax-binaries.md`) on a `vX.XX` tag push.

None of these touch PAUSE or CPAN in any way.

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
- `.github/workflows/` no longer contains any CPAN-related workflow.
