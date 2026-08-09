# Gate map — DD SDLC ↔ Tira G0–G13 ↔ board columns

Decided 2026-08-08 (open-decisions row 8: **map**, not replace). The DD SDLC GATES in
`CLAUDE.md` stay authoritative for *what must be proved*; Tira's G-numbers and this
board's columns are how that proof is tracked. Where the two differ, DD wins and the
extra requirement is listed under "DD-only gates" below.

## The map

| Tira | DD SDLC step | Board column | Evidence that closes it |
|---|---|---|---|
| G0 SOW | SOW | (SOW board) `planning` | A `DDS-NNN` record with its own acceptance criteria |
| G1 EPIC | EPIC | (epic board) `planning` | A `DDE-NNN` record; criteria **not** the sum of its tickets' |
| G2 TICKET | TICKET: SCOPE + PLAN + IMP_DETAILS | `planning` → `todo` | Scope, plan and implementation detail written on the card |
| G3 TDD | TDD (RED tests) | `in-progress` | A failing test committed under `t/` **before** the fix |
| G4 BDD | BDD | `in-progress` | Behaviour expressed as a test, not prose |
| G5 ATDD | ATDD | `in-progress` | Acceptance criteria expressed as a runnable check |
| G6 CODING | IMPLEMENTATION | `in-progress` | The smallest coherent change that turns the RED test green |
| G7 SOW ALIGNMENT | (parent check) | `final-check` | Parent card confirms the child actually served the parent's criteria |
| G8 100% TEST PASS | 100% TESTED | `unit-test` | `prove -lr t` fully green, warnings-as-errors, run uncontended |
| G9 100% COVERAGE | 100% CODE COVERAGE | `unit-test` | `lib/` at 100.0 on **all four** Devel::Cover metrics (statement, subroutine, branch, condition) |
| G10 REGRESSION | (implicit in 100% TESTED) | `unit-test` | Full suite, not just the touched file |
| G11 E2E | E2E TEST (platform tests included) | `platform-test` | QEMU guest for macOS/Windows, Docker for other Linux distros — behaviour **and** process/state verified |
| G12 DOCUMENTATION | (POD + Changes + README regen) | `documentation` | POD updated, `README.md` regenerated from POD, `Changes`/`FIXED_BUGS.md` prepended |
| G13 PUBLISH | GIT COMMIT → GIT PUSH → VERSION GATE → RELEASE TO PAUSE | `git-gate` → `release-to-pause` | See "the two-stage publish" below |

## DD-only gates (no Tira G-number — do not drop them)

| DD step | Board column | Why it is separate |
|---|---|---|
| **100% CVE FREE** | `vulnerability-scan` | `script/cpan-audit-declared-chain` against the declared runtime closure — that gate's subject **is** the product, so it is the one to trust on a shared machine. `script/cpan-audit-project` audits an *isolated* root only (CI builds one at `local/lib/perl5`) and refuses anything else with exit 3, so never point it at `$HOME/perl5/lib/perl5`. Plus the `SECURITY_CHECKS.md` three-tier protocol. A bare host-tree `cpan-audit` is **not** a blocker — judge the product, not the host interpreter (DD-499) |
| **Operator-file containment** | `git-gate` | No operator/rule file may enter the tarball; `dist.ini` `exclude_filename`/`exclude_match` is the only real protection (`.gitignore` does not protect the tarball) |

## The git gate for the operator repository

**Cards whose work lands in `~/dd-tg` satisfy the git gate at COMMIT, not at push,
because that repository has no remote to push to.**

This is a statement of fact rather than a relaxation. `git remote -v` there returns
nothing and `git rev-list @{u}..HEAD` cannot even be asked — it fails with "no
upstream configured". So for those cards the gate map's "commit, tag and push"
would otherwise assert a push that is not merely outstanding but impossible, and a
column that asserts something impossible is worse than one that asserts nothing:
it reads as satisfied.

What stands in for the push, and what it is worth:

- A complete `git bundle --all` is written to `~/dd-archive` daily by
  `~/dd-tg/dd-tg-bundle.sh`, verified with `git bundle verify`, and kept for a
  fortnight. A failed verify deletes the bundle and exits non-zero rather than
  leaving a file that looks like a backup.
- **That is protection against git-level accidents only** — a bad reset, a deleted
  branch, a botched rebase. The bundles are on the same disk as the repository, so
  it is not protection against the disk failing. Nothing here should be read as
  equivalent to an off-machine push.

**This is the current state, not a decision that it should stay this way.**
Whether the operator repository gets a remote is open on `docs/open-decisions.md`
row 24. If one is added, this section goes and those cards join the ordinary
"commit, tag and push" rule with the rest.

---

## The two-stage publish

Tira collapses publishing into G13; DD splits it across two levels, and the split is binding:

- **Ticket level → `git-gate`.** Commit title `DD-NNN: summary + details`, pushed via
  `~/bin/git-push-mf`. **No version bump on a ticket commit.**
- **Epic level → version gate.** Only once *every* ticket in the epic is done: bump
  `lib/**` `$VERSION` + `dist.ini` + main POD + `t/15`, commit, tag `vX.XX`, push. The tag
  fires the signed GitHub Release.
- **Operator-repo cards satisfy the git gate at COMMIT, not at push.** Most tickets
  land in this checkout, which has a remote, so "commit, tag and push" means what it
  says. A minority land in the operator repository at `~/dd-tg` — the round wrappers,
  the park, the session guard, the Telegram bridge — and that repository has **no
  remote configured at all**. For those cards the push half of the gate does not
  exist, so requiring it would leave them permanently short of a bar nothing can
  clear, and the column would imply a push that is never going to happen (DD-504).

  This is a statement of the current arrangement, not an endorsement of it. Sixteen
  commits of automation live on exactly one disk. A daily verified `git bundle`
  (`~/dd-tg/dd-tg-bundle.sh`, 04:17, retained a fortnight) protects against
  git-level accidents — a bad reset, a deleted branch — and against **nothing else**:
  the bundles sit on that same disk, so a disk failure takes them too. Whether that
  repository should gain a remote is open-decisions row 24, and if the answer is yes
  this clause should be deleted rather than amended.

- **`release-to-pause` means "has been released to PAUSE"** (open-decisions row 4).
  Only the owner's explicit `dashboard pause-release` puts a card there. An agent moving a
  card into that column on its own is a rule violation, not a status update.

## Direction of travel

Forward only on evidence — a gate moves when its proof is attached, never because it
"should pass". Backwards is normal: a defect found at gate N caused by gate M sends the
card back to M, and every gate from M+1 is revalidated.
