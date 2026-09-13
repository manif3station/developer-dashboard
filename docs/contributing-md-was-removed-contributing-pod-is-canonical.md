# CONTRIBUTING.md was removed - CONTRIBUTING.pod is the canonical contributor doc

This project once had two contributor-facing files: `CONTRIBUTING.md` at
the repo root and `CONTRIBUTING.pod` alongside it. Only `CONTRIBUTING.pod`
was ever a real, tracked, shipped artifact. `CONTRIBUTING.md` was deleted
(DD-855, owner decision) and should not be recreated.

## Why CONTRIBUTING.md existed and why it was removed

`CONTRIBUTING.md` matched this project's blanket `*.md` `.gitignore`
pattern with no `!CONTRIBUTING.md` whitelist entry (unlike, say,
`SECURITY_CHECKS.md` or `SKILLS.md`, which are explicitly whitelisted).
It had **zero commits ever** and was absent from `origin/master`'s tree -
no contributor on GitHub could ever have read it, regardless of what it
said.

`CONTRIBUTING.pod`'s own `DESCRIPTION` states it exists "so the tarball
keeps contributor expectations available even when repository Markdown
files are excluded from the distribution" - wording that assumes
`CONTRIBUTING.md` *is* repo-visible and only tarball-excluded. That
assumption was never true: the file was invisible everywhere except this
one local checkout, and its content had drifted out of sync with
`CONTRIBUTING.pod` (it understated the coverage requirement - DD-854,
discarded as superseded by this card once the file itself went away).

**A related, now-moot discovery:** `dist.ini`'s `[GatherDir]`
`exclude_filename` list - the mechanism that keeps operator-local files
like `CLAUDE.md`/`MISTAKE.md` out of release tarballs - never named
`CONTRIBUTING.md` either. Had it existed on a machine that ran
`dzil build`, it would have shipped in the tarball unprotected. Deleting
the file removes the risk rather than requiring a new exclusion rule.

## What to do instead

Edit `CONTRIBUTING.pod`. It is the real, tracked, shipped contributor
guide - the one a GitHub visitor and a CPAN tarball recipient both
actually see.

## Reviewing a change against this

- **Never recreate `CONTRIBUTING.md`.** If a future change wants a
  Markdown contributor guide specifically, that decision needs a fresh
  owner call (track it and exclude it from the tarball deliberately),
  not a quiet recreation of the file this card removed.
- **A file matching a blanket `.gitignore` pattern with no history is a
  local artifact, not a repo asset** - before trusting anything a
  markdown file says about "the tarball" or "the repo", check
  `git log --oneline -- <path>`. Zero commits means the file has never
  been anywhere but the machine you're reading it on.
