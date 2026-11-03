# CHECKPOINT — 2026-11-02 R4 restock wiring (atomic-ops arc) — resume here

**Branch:** `feat/2026-11-02-r4-restock-wire`, cut from `main` @ `4c88ed9` (PR #181 R3 merged, deployed and device-tested by Taher).
**Commit identity:** author email `dextran52@gmail.com` and the same address in every commit message (Taher's instruction of 2026-11-02, replaces earlier identities). The PAT comes from the chat prompt only; pass it per command with `git -c http.extraHeader=...`, never in a URL, `.git/config`, the repo, or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs; tests and a test plan for every change; update skills, AGENTS, README as needed; caveman FULL in chat only, documents in normal prose; out-of-scope findings go to the roadmap doc (status doc section 10), not into code.
**Skills used:** `brainstorming` (design section 2 of the R4 design doc; the architecture was approved with #147, this slice makes the wiring decisions R4-D1..D10, vetoable in the PR), `qt-qml`, `qt-ui-design` (one dialog wording change only), `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-02-r3-merged-prev-CHECKPOINT.md`.

## Scope (from status doc section 8 + 9)
R4 = `InventoryStore.restock` rewrite onto `RestockPlan` + `Gateway.recordOperation`, durable per-product latch, parked-write refusal kept, picker hide + sale refusal for a queued restock (Q-A2), `DataModel` route for `operationApplied/Rejected` opType `restock` (relaunch case), replay re-read (O3), O1 supplier resolution, O2 `amount || 10` removed, O4 one `Date` for `now`/`date`. NOT in R4: dialog redesign, `activity_log` entity inside the op, `ActivityLog.record` id param, wording for too-large/reserved-text (all R5); deploy is already done (R2).

## Steps
- [x] 1. Read memory, skills, status doc, restock design v2, R3 design, `InventoryStore.restock`, `RestockPlan`, `Gateway.recordOperation`, `DataModel` completion wiring, `OutboxStore`, `RestockDialog`, `NewOrderDialog` picker.
- [x] 2. Branch, checkpoint archived, this file written.
- [x] 3. Design doc `specs/2026-11-02-r4-restock-wire-design.md` (decisions R4-D1..D10).
- [x] 4. Pure `qml/helper/RestockFlow.js` + Node tests (run locally).
- [x] 5. `OutboxStore.hasQueuedOperationFor`, `InventoryStore.restock` rewrite + settle hooks, `DataModel` route + sale guard, `NewOrderDialog` picker filter, `RestockDialog` wording.
- [x] 6. QML tests (CI only): rewrite restock tests in `tst_InventoryStore_movementKinds`, `tst_ParkedWriteGuard`; new `tst_InventoryStore_restock`, `tst_DataModel_restockRoute`, `tst_OutboxStore_queuedOperation`, `tst_RestockFlow`.
- [x] 7. Test plan, Skill 151, SKILLS-INDEX, AGENTS pointer, README row, status doc section 10.
- [ ] 8. Push, open PR, read CI, fix only what CI shows.

## State at push
Node: functions 1029/1029, scripts 741/741, 23/23 hand mutants killed. QML tests and the emulator e2e case are CI-only and UNSEEN. Open items P1-P6 are in `ATOMIC-OPERATIONS-STATUS.md` section 10.
**Resume:** read CI for the PR; fix only what CI shows (QML compile errors are the likeliest: the new QML tests were never run). Then Taher's veto window for R4-D1 and R4-D4, then R5.
