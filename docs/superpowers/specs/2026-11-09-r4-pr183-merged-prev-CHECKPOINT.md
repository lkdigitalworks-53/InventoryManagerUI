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
- [x] 7. Test plan, Skill 155, SKILLS-INDEX, AGENTS pointer, README row, status doc section 10.
- [x] 8. Pushed, PR #183 opened, CI read, two test-only fixes (c4575cb, f61396b). CI ALL GREEN on f61396b: 3968/3968.

## State at push
Node: functions 1029/1029, scripts 741/741, 23/23 hand mutants killed. QML tests and the emulator e2e case are CI-only and UNSEEN. Open items P1-P6 are in `ATOMIC-OPERATIONS-STATUS.md` section 10.
**Resume:** read CI for the PR; fix only what CI shows (QML compile errors are the likeliest: the new QML tests were never run). Then Taher's veto window for R4-D1 and R4-D4, then R5.

**Final:** PR #183 green. No product code changed after CI turned up red; the fixes were test fixtures (emulator URL, a re-read race in one QML test, the R4-D1 wait in one e2e test). Waiting for Taher's review and vetoes (R4-D1, R4-D2, R4-D4), device test, then R5.

## REVIEW SWEEP 2026-11-04 (same PR, no stacked PR) - resume here
Ask (Taher): deep full-sweep review of PR #183 (requesting-code-review, qt-qml-review, ponytail-audit), fixes in the SAME PR, work split to finish in one chat turn, robustness first. Commit identity `taher.lkdw@gmail.com`, named in every commit message. Baseline: PR was `dirty` against `main` (L4a #182 merged after it was cut).
- [x] RV-1. Fresh clone into `/home/claude/repo`, PAT only per command (never in `.git/config`). Read memory + the three review skills.
- [x] RV-2. Merged `origin/main` (17db878) into the branch. Conflicts only in docs: AGENTS.md (kept R4 + R3 + L4a entries), SKILLS-INDEX.md and SKILLS.md (main keeps Skill 151 = L4a; this PR's skill renumbered to **Skill 153**), CHECKPOINT.md (branch version kept). Code files auto-merged. Merge commit `5dd45dc`.
- [x] RV-3. Read the merged code against L4a: `InventoryStore.restock`, `_applyRestock`, `DataModel` route, `OutboxStore.hasQueuedOperationFor`, `RestockFlow.js`, dialogs.
- [x] RV-4. Node suites on merged tree: functions 1029/1029, scripts 905/905 (after D-1: functions 1043/1043).
- [x] RV-5. D-1 fixed: `restockHoldMessage`, `updateRefusal` + `deleteProduct` refuse while a restock is queued. Node `functions/test/restockHold.test.js` (14, 7/7 mutants killed, real-server 409 proof), QML twin `tests/tst_InventoryStore_restockHold.qml` (CI only).
- [x] RV-5b. D-2 fixed: RestockDialog turned a blank/typo/negative cost into 0 before RestockPlan's bad-cost refusal could run (free batches). New pure `RestockFlow.costFromText` (blank = product cost, number = itself, junk = -1 so the plan refuses). Node D2-1..3 (6/6 mutants killed) + QML twin in tst_RestockFlow.qml. Commit after f1ab2f3.
- [x] RV-6 (read-based, no Qt toolchain): qml-review checks on changed QML (brace/paren balance, no new bindings/loaders), ponytail-audit: nothing to delete; `supplierFor.newName` has no app caller until R5 (kept, tested). qt-qml-review phase 1 lint on changed lines, ponytail-audit pass.
- [x] RV-7. Docs: design section 6, test plan, KNOWN-ISSUES, status doc, Skill 155, README, AGENTS.
- [x] RV-2b. 2026-11-04: `main` moved again (#184, picker v2 docs took Skill 152). Merged it; this PR's skill is now **Skill 153**. Branch CHECKPOINT kept. Pushes while the PR was `dirty` ran NO CI (GitHub does not run pull_request workflows on a conflicting PR), so CI evidence starts after this merge.
- [x] RV-8. Pushed `45f0143`; PR #183 `mergeable: clean`; CI all green: QML 2761/2761 (incl. the new tst_InventoryStore_restockHold + tst_RestockFlow cases), Functions 1046/1046, Rules 108/108, E2E 111/111 = 4026/4026.
- [x] RV-2c. 2026-11-04: Taher asked to REBASE the branch onto `main` (#185 picker S1 now at the tip, skills up to 154). Merge commits dropped, history linear, CHECKPOINT.md kept as this branch's version, other docs unioned. This PR's skill is now **Skill 155**. Pushed with --force-with-lease (history rewritten, old tip b54c5b3).
- [x] RV-2d. Rebased tip `4015b12` pushed; PR #183 `mergeable: clean`; CI green (QML, Functions, Rules, E2E).
- [ ] RV-9 (open, for Taher): veto window on D-1 (edit/delete held while restock queued) and D-2 (blank cost = recorded cost). Then merge #183; next slice R5.
