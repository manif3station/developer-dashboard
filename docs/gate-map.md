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
  What stands in for it: `~/dd-tg/dd-tg-bundle.sh` writes a complete
  `git bundle --all` to `~/dd-archive` daily, verifies it, and keeps a fortnight —
  deleting the bundle and failing loudly if it does not verify, because a bundle
  that cannot be verified is a file rather than a backup. **That covers git-level
  accidents only** (a bad reset, a deleted branch, a botched rebase); the bundles
  sit on the same disk, so it is not equivalent to an off-machine push and must not
  be read as one. This records the current state, not a decision that it should
  stay so — whether that repository gets a remote is open on
  `docs/open-decisions.md` row 24, and if one is added these cards rejoin the
  ordinary rule above.

- **`done-not-released` is where finished ticket work rests.** A ticket that is
  committed, pushed and gated has passed everything an agent can gate it against,
  but it is not released until the owner says so. Without a column for that state
  finished cards queued at `git-gate` and read as stalled, so the board could not
  distinguish "waiting at a gate" from "through every gate, waiting on a person".
  Added 2026-08-09 against open-decisions row 26, which the owner had not answered;
  removable with `d2 tira.column.remove --type ticket --name done-not-released`.
  **The move from `git-gate` is not direct.** Tira's own column sequencing
  requires passing through `admin-done` first — `tira.ticket.move` rejects a
  direct `git-gate` → `done-not-released` move with `Cannot move ... - the next
  column should be admin-done`. Reconciling a card stalled at `git-gate` is
  therefore two moves: `git-gate` → `admin-done` → `done-not-released` (found
  2026-08-20 when DD-612 and DD-631 sat at `git-gate` for hours under an
  unrelated invented rationale rather than this undocumented hop).
- **`release-to-pause` means "has been released to PAUSE"** (open-decisions row 4).
  Only the owner's explicit `dashboard pause-release` puts a card there. An agent moving a
  card into that column on its own is a rule violation, not a status update.

## Which columns the reminder watches (DD-510)

The stale-card reminder is per-column, not per-board: each column carries a `watched`
flag, and `dwell_list` skips an unwatched column however old its cards are. This
project sets them as follows on all three boards, and the reasoning matters more than
the values because **the board configuration is not versioned** — it lives in
`$TIRA_HOME/.tira/<type>/config.yml`, outside any git repository, so if that file is
lost this section is the only record of what it should say.

| Column | Watched | Why |
|---|---|---|
| `backlog` | no | Holds work nobody has committed to yet; age there is not a fault |
| `done-not-released` | no | Through every gate an agent can apply, waiting only on the owner |
| `release-to-pause` | no | Terminal: already released, nothing left to act on |
| `discard` | no | Terminal: abandoned on purpose |
| everything else | **yes** | A card there is mid-flight, and age is a real signal |

`blocked-by-michael` stays **watched** deliberately. It is the one resting column that
is not terminal — a card there is waiting on a person, and going quiet about it would
turn "blocked" into "forgotten". Restore it with
`d2 tira.column.update --type ticket --name blocked-by-michael --watch`.

`blocked-by-michael` is the one column that pins its own `notify_after`: **1440
minutes**, a day, against a project default of 15. Every other column inherits the
default, so the working threshold is still changed in one place.

The day is not a rounder number chosen for tidiness. Fifteen minutes is a sensible
limit for a card the agent itself is meant to be moving, and a nonsensical one for a
question only a person can answer: it produces about ninety-six reminders a day about
a decision that will reasonably take days, and it produced them for a card whose own
text says it is **not blocking**. That is the same crying-wolf failure DD-510 was
raised to fix, one column over — a reminder nobody can act on, arriving often enough
to train the reader to ignore the ones they can.

Two things follow, and both are the reason this is written down rather than just set:

- A reminder **cannot be answered in place**. `_dwell_start` counts only moves, so the
  reminder's own advice — "leave a comment saying what it is waiting for" — does not
  quiet it. For a column that by definition waits on somebody else, the only honest
  lever left is the threshold. Moving the card out and back would reset the clock and
  would be a lie about its status.
- The threshold is the whole escalation control here. Do not "fix" a noisy
  `blocked-by-michael` by unwatching it: that is how a blocked card becomes a
  forgotten one, and `reminder-column-guard` fails loudly if anyone tries.

`.claude/tools/reminder-column-guard` asserts the table above hourly and fails loudly
if it drifts, because the table describes **data**, and data has no test unless
something asserts it. It checks both directions — a terminal column that has become
watched, and `blocked-by-michael` that has stopped being — and also that a watched
column actually has a limit: `dwell_list` only considers columns it has a
`notify_after` for, so a watched column with no limit and no project default is
skipped in silence and reads as correct in the config while chasing nobody. That last
case is not hypothetical; it is how the guard's own first draft passed a board that
sent no reminders at all.

**A comment does not reset a card's clock — only a move does.** `_dwell_start` scans
the card's journal for the last `"op":"move"` on the `column` field and ignores every
other entry, so "leave a comment saying what it is waiting for" reads as activity to a
human and as nothing at all to the reminder. Two consequences, and neither is
cosmetic: a card can be under active discussion and still be reported as stalled, and
a reminder cannot be answered in place — the only ways to quiet one are to move the
card or to unwatch its column. Changing that behaviour would mean editing the shared
skill at `~/.developer-dashboard/skills/tira/lib/Tira.pm`, which is read-only for this
project (it backs every project on this machine), so it is recorded here rather than
fixed. If it needs fixing it is a change to the skill upstream, requested explicitly.

## Direction of travel

Forward only on evidence — a gate moves when its proof is attached, never because it
"should pass". Backwards is normal: a defect found at gate N caused by gate M sends the
card back to M, and every gate from M+1 is revalidated.
