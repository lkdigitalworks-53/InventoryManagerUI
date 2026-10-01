# CHECKPOINT — 2026-10-01: DELETE-FEATURE-ROADMAP item 1 part B — S3 (Discard + resync) IMPLEMENTED, CI PENDING

**Branch:** `feat/2026-10-01-s3-discard-parked-writes`, PR #110 -> `main`. #106 (S2b) and #109 (S3 design) are both merged into `main` (squash); this branch was rebased onto `main` 2026-10-01 (S3 commit only). CI on #110 pending.
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-30-s3-design-CHECKPOINT.md`.
**Skills invoked by Taher:** brainstorming, qt-qml, qt-ui-design, ponytail; caveman FULL (chat replies only).
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>`.

## Standing instructions (unchanged)
Branch only, push without asking (PAT only in the push URL, never in `.git/config`), no build/run, no Qt tooling in the sandbox (CI is the QML signal), tests toward 100% + test plan + SKILLS/AGENTS/README, honest advisor, small scope per session (other accounts resume from the remote branch).

## Step log
1. (earlier) Design written, PR #109. Taher answered **A on all five** (Q-S3-1..5) on 2026-10-01; recorded in the design doc.
2. Code: `StuckWrites.entitiesOf`; `Gateway.discardParked` + `parkedWriteDiscarded` + `_failDeltaCallbacks`; `DataModel._resyncStoreByEntity/_storesToResync/_resyncForDiscard` + `Connections{target: Gateway}`; `StuckWritesSheet` Discard button (rejected rows, online only) + local `ConfirmDialog` + `busy: discardConfirm.opened`. No `Main.qml` change (busy guard replaces the Back-list reorder).
3. Tests: `tst_StuckWrites` +9, `tst_Gateway` +23 (incl. 400-step monkey), new `tst_DataModel_discardResync` 14 (network-free via `loadingMore`/`_resetPending`). Node-ran `entitiesOf` + mapping mirror: 630 assertions OK. **No QML test executed.**
4. Docs: design (resolved decisions + implementation notes), test plan + index row, SKILLS 90, AGENTS, README, roadmap + plan status. Pushed, PR #110 opened.
5. #106 and #109 squash-merged; #110 rebased onto `main` (clean, no conflicts) and force-pushed with lease.

## Deviations from the design proposal (Taher can overrule in the PR)
- Delta callbacks are also answered on discard (not in the proposal).
- Parked check reads the persisted item, not in-memory state.
- Local confirm in the sheet, not Main's `confirmDlg`; no `Main.qml` edit.
- Extra failure toast when the tap-time re-check refuses.

## NEXT SESSION — start here
1. Read CI on the S3 PR first (first real run of 46 new QML cases). Likely trouble spots: `tst_Gateway` delta coalesce test (assumes the second `recordDelta` merges into the first), operation waiter / timer tests, `tst_DataModel_discardResync` (first test file that flips `loadingMore` on six singletons; `cleanup()` resets them).
2. Taher on device: section 3 of `docs/superpowers/test-plans/2026-10-01-s3-discard-parked-writes-test-plan.md`. Blocker: no verified recipe for a real `write-rejected`; ask whether to add the debug-only emulator flag.
3. Merge #110 now: S2b is already on `main`, so rejected writes park with no Discard exit until it lands. Do not cut a release from `main` before then.
4. Then S4 cleanup (roadmap / KNOWN-ISSUES closed, test plans consolidated). Do not combine with S3.
5. Open, not built: photos on discard of a parked product create (roadmap item 4); `removed_staff` tombstone stays in memory until relaunch.
