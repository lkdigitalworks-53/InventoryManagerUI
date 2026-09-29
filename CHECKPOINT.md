# CHECKPOINT — 2026-09-29: DELETE-FEATURE-ROADMAP item 1 part B, slice S1 (dialog + Retry now) — IMPLEMENTED, CI PENDING

**Branch:** `feat/2026-09-29-stuck-writes-dialog-retry-now`, off `main` @ `1a81554`.
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-29-gateway-park-retry-discard-scope-CHECKPOINT.md`.
**Skills invoked by Taher:** brainstorming, qt-qml, qt-ui-design, ponytail; caveman FULL (chat replies only).
**Commit identity:** `Taher (via Claude session) <taher.lkdw53@gmail.com>` (email per Taher's instruction this session; earlier sessions used a different address).

## Standing instructions (unchanged)

Branch only, push without asking (PAT only in the push URL, never in `.git/config` or the repo), no build/run, no Qt tooling in the sandbox (CI is the QML signal), tests toward 100% + test plan + SKILLS/AGENTS/README, honest advisor, small scope per session.

## Step log

1. Read memory + plan doc (`2026-09-29-gateway-park-retry-discard-plan.md`), roadmap, test-plan README. Cloned repo, stripped the PAT from `origin`, archived old checkpoint.
2. Traced `OutboxStore`, `StuckWrites.js`, `Gateway` (`_noteFailure`, `_pruneStuck`, `drainNow`, `_send` no-auth guard), `GlassHeader`, `Main.qml` back-button list, `BottomSheet`, `NotificationsSheet`.
3. Wrote: `DescribeItem.js`; `StuckWrites.isStuck/rows`; `OutboxStore.retryNow/isInFlight/inFlightCount`; `Gateway.stuckRows/retryStuck`; `StuckWritesSheet.qml`; `Main.qml` wiring; `GlassHeader` tap.
4. Tests: new `tst_DescribeItem.qml`; extended `tst_StuckWrites`, `tst_OutboxStore`, `tst_Gateway` (42 new cases).
5. Ran in Node (not Qt): pure-JS test files 51/51 + 40/40; real `OutboxStore.qml` function bodies via a mirror 57/57. Found and fixed 2 test bugs. `tst_Gateway.qml` NOT executed.
6. Docs: design doc (D1-D8), test plan + index row, roadmap + plan status, AGENTS, README, SKILLS Skill 85. Pushed.
7. PR #97 on-device review (Taher): forced a stuck write (temp wrong `functionUrl`), dialog showed; stuck list did NOT survive relaunch. Confirmed intentional in S1 (in-memory `_stuckState`; write itself survives in `OutboxStore`). Found the test-plan setup line is wrong (a rules change cannot fail a Functions write: Admin SDK bypasses rules; emulator down = status 0 = offline, not stuck). Working setups: member `status` inactive -> 403 `no-tenant-context`, or temp wrong `functionUrl` -> 404.
8. **Decision P5 (Taher):** S2 persists the stuck flag for ALL stuck writes, amending P1's persistence scope (park stays terminal-only). Docs only, on stacked branch `docs/2026-09-29-s2-persist-stuck-decision` (base = PR #97's branch): plan (P5 row, alternatives, open S2 questions a-d), S1 design "Next", roadmap. No code.

## Deviation from the plan (for Taher to overrule in the PR)

Retry now keeps the stuck flag (design D1) instead of dropping it from `StuckWrites` state. Reason: silent 3-minute window after a rejected retry. S2's Retry (parked items) uses the plan's original wording.

## NEXT SESSION — start here

1. Check CI on the S1 PR. Likely trouble spots: `tst_Gateway.qml` new cases (real singleton graph, never run), `readonly property int inFlightCount` binding in `OutboxStore`, `StuckWritesSheet` load (Felgo-free CI does not load it).
2. Taher on-device: run the S1 checklist in `docs/superpowers/test-plans/2026-09-29-stuck-writes-dialog-retry-now-test-plan.md` section 3.
3. Start **S2 only** (persist stuck for all per P5 + park terminal only) on a new branch off `main` AFTER S1 and the P5 docs PR merge. Do not combine slices. S2 opens with the brainstorming gate: plan questions P5 (a)-(d) are undecided.
4. Still open, not done: fix the S1 test plan's section 3 setup line (see step 7). Not fixed here to keep this branch decision-only.

## Not done

Nothing built or run on a device. No server change. No Discard / park / persistence.
