# Open decisions (FT68)

The one place a question waits for the person who must answer it.

**Rules for this page (do not relax them):**

- **Append-only.** Answered rows stay here with the answer visible. New questions extend
  the table. A change that shortens this page or drops a row is wrong by definition.
- **Versioned.** This file is whitelisted in `.gitignore` on purpose so its history
  survives an overwrite. It is excluded from the release tarball (`dist.ini`) because it
  is internal project record, not shipped documentation.
- **One page for everybody**, sectioned by asker.
- A question here is **blocking** only if the asking card sits in `blocked-by-michael`.
  Otherwise the agent proceeds on the stated assumption and the row records it.

---

## Asked by: Claude (agent)

| # | Date | Question | Status | Answer |
|---|---|---|---|---|
| 1 | 2026-08-08 | Single-agent or multi-agent mode for this board? | Answered | Single agent |
| 2 | 2026-08-08 | Which columns, in which order? | Answered | backlog → buglist → new-enhancements → researching → analysing → blocked-by-dependency → blocked-by-michael → todo → planning → documentation → ready → in-progress → vulnerability-scan → unit-test → platform-test → final-check → git-gate → release-to-pause → discard |
| 3 | 2026-08-08 | Which column means finished, which means abandoned? | Answered | `release-to-pause` is done; `discard` is abandoned |
| 4 | 2026-08-08 | Is `release-to-pause` "ready to release" or "has been released"? | Answered | **Has been released to PAUSE** — so no agent may move a card into it without the explicit `dashboard pause-release` go-ahead |
| 5 | 2026-08-08 | Carry the old Hermes board records into Tira? | Answered | Remove the Hermes remains |
| 6 | 2026-08-08 | If migrating, how much fidelity? | Answered | Full fidelity — moot in practice: the old board had **0 open tickets** at cutover, so nothing live was carried |
| 7 | 2026-08-08 | Ref prefixes per layer? | Answered | `DD-NNN` ticket, `DDE-NNN` epic, `DDS-NNN` SOW |
| 8 | 2026-08-08 | Map our DD SDLC gates onto Tira's G0–G13, or replace them? | Answered | Map (see `docs/gate-map.md`) |
| 9 | 2026-08-08 | Where does the project's skill copy live? | Answered | `.claude/rules/kanban-management.md` (master in `~/skills/` stays read-only) |
| 10 | 2026-08-08 | How far does the Hermes removal go? | Answered | Remove `_hermes/` and anything related to Hermes |
| 11 | 2026-08-08 | Where does the FT68 page live? | Answered | `docs/open-decisions.md` — this file |
| 12 | 2026-08-08 | What is FT99 for this project? | Answered | Check and verify cards are in the correct column |
| 13 | 2026-08-08 | At what level is the v4.24 version gate recorded? | Answered | Epic |
| 14 | 2026-08-08 | May the install happen now, or wait for the restart? | Answered | Now |
| 15 | 2026-08-08 | Name for `--assignee` / `--author`? | Answered | Michael Vu |
| 16 | 2026-08-08 | Write our hard-won lessons into the project copy of the skill? | Answered | Yes |
| 17 | 2026-08-08 | The next epic ships **v4.25** (v4.24 is tagged and pushed). Confirm, or is a different number wanted for the pending backlog epic? | Open — proceeding on the assumption `v4.25` | |
| 18 | 2026-08-08 | Should FT99 run on a cron timer, or only when a session is active? | Decided by me, tell me if wrong | **Scheduled**, hourly at minute 7 — you asked to resume the loop, and the discipline you installed requires FT99 to run hourly. One crontab line added for this project only; the 37 pre-existing lines (zen-framework, mt5-ai) are byte-identical, checked by hash |
| 19 | 2026-08-08 | Tira's ticket counter started at 1, which would have issued `DD-001` for new work while `DD-001` already means something in git history. Set it to continue the existing series instead. | Decided by me, tell me if wrong | Counter set to **449** before the first card, so refs continue rather than collide. Counters cannot be rewound after a ref is issued |
| 20 | 2026-08-08 | "Remove anything Hermes-related" — does that include the `dist.ini` / `MANIFEST.SKIP` / `.gitignore` entries that exclude `_hermes/` and `.hermes/` from the tarball? | Decided by me, tell me if wrong | **Kept.** Those are leak protection, not Hermes tooling, and `t/15` asserts them. The Hermes runtime tree itself (2.0 GB) is gone; its board history is archived at `~/dd-archive/hermes-kanban-final-2026-08-08.db.gz` |
| 21 | 2026-08-08 | v4.23 also never published a signed release. Backfill its assets, or let it stand and publish from v4.24 onward? | Open — proceeding on "let v4.23 stand", recorded on DDE-001 | |
| 22 | 2026-08-08 | The Hermes board had one finished state; this board's only finished column is `release-to-pause`, which you defined as "has been released to PAUSE". The 96 migrated finished cards went there. Some were completed after the last PAUSE release, so for those the column overstates what happened. Do you want a separate "Done — not yet released" column? | Open — proceeding as migrated | Every migrated card carries a comment saying its column is inherited from Hermes, not re-verified here |
| 23 | 2026-08-08 | **Row 21 needs re-asking, because its fallback turned out to be impossible.** Row 21 proposed "let v4.23 stand and publish from **v4.24** onward". v4.24 is now proven unpublishable too, for two independent reasons: (a) a tag push runs the workflow **frozen at that tag**, and v4.24's copy pins the node20 `actions-setup-perl` v1.32.0, so DD-449's fix on master cannot reach it and a re-run replays the same failure; (b) v4.24's tree fails the all-metric coverage gate on a runner — `PageStore.pm` is byte-identical between v4.24 and dc07197, whose run measured 99.8. Publishing it would need the coverage gate weakened or the published tag rewritten, and I will do neither. **So: do v4.23 and v4.24 both stand unpublished, with v4.25 the first published release since v4.22?** | Open — **blocking**, DDE-001 is in `blocked-by-michael` | Recommendation: **yes, let both stand.** Master at `1265c4b` is the first commit since v4.22 with working pins *and* a green coverage step on a runner, so v4.25 publishes normally with nothing further needed. Evidence on DDE-001 CMT-003. Separately, DD-492 has landed the recovery path so a *future* tag whose frozen workflow cannot run is publishable from master instead of lost — it does not rescue these two, because it deliberately still runs every gate against the tagged tree |

---

## Asked by: Michael

*(none outstanding)*
