# CHECKPOINT — 2026-10-28 P1 S2d-1 typed movement kinds on client deltas (resume here)

**Branch:** `feat/2026-10-28-p1-s2d1-movement-kinds`, cut from `main` @ `9c010f0` (PR #165 merged).
**Commit identity:** `taher.lkdw@gmail.com`. PAT comes from the chat prompt only (`git -c http.extraHeader=...`), never in remote URL, config, repo or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML oracle); push without asking; tests + test plan for every change; caveman FULL in chat only.
**Skills used:** brainstorming (decisions defaulted, vetoable: Taher asked for one turn), qt-qml, ponytail.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-28-pr165-merged-prev-CHECKPOINT.md`.

## Slice
S2d-1 (client only; server S1a/S1b already deployed): restock => `receipt`; return, reopen, failed-exchange rollback => `sales_return`; exchange/modify-up addition => `sale` (reject mode). Imported-order clamp deduction stays derived `adjustment` (explicit row + clamp = terminal 409 = lost deduction). S2d-2 (server kind hint for derived rows) needs Taher's call.

## Steps
- [x] 1. Read memory, repo, P1 designs, client + server code.
- [x] 2. `qml/helper/StockMovements.js` + Node parity/unit test `functions/test/stockMovementsParity.test.js` (10/10 run, helper 100% line/branch, 16/16 mutants killed).
- [x] 3. `OutboxStore.enqueueDelta` (explicit only coalesces with explicit, concatenates), `Gateway.recordDelta` 7th arg `movements` + local refusal + `_sendDelta`, `InventoryStore` restock/deductStock/creditStockNoBatch, 4 `DataModel` call sites. Server: only exports `MAX_REASON`.
- [x] 4. QML tests written, NOT run: `tst_StockMovements`, `tst_OutboxStore_movements`, `tst_Gateway_movements`, `tst_InventoryStore_movementKinds`.
- [x] 5. `tests/tst_DataModel_movementKinds.qml` (return, damaged=no row, reopen, exchange add, rollback; harness = `tst_DataModel_adjustOrderSyncGuard`, server answers simulated with `Gateway._answerDeltaCallbacks` + `OutboxStore.markSent`).
- [x] 6. e2e: 2 restock tests in `tst_InventoryE2E` (first CI run failed: file never redirected `Gateway.deltaFunctionUrl`; fixed + recordDelta warm-up). Returns already covered by `tst_ReturnAfterMetadataEditE2E`.
- [x] 7. Design doc, test plan (Skill 49 format), Skill entry + SKILLS-INDEX regen, AGENTS, README, KNOWN-ISSUES, test-plans README row.
- [x] 8. PR #170 CI GREEN @ c438881: QML 2415, Functions 876, Rules 106, E2E 103 = 3500/3500 (observed). First run failed only on my 2 new e2e tests (URL not redirected), fixed. Merged main (PR #167); my skill renumbered 140.
- [ ] 9. Taher (only open step): veto/accept defaults (clamp stays adjustment; reopen+rollback = sales_return; damaged return = no row until S2e Q4); decide S2d-2.

## Open, unverified
- `enqueueDelta` does not skip parked items when coalescing (pre-existing; not checked whether other paths guard it).
- restock success-path QML tests assume the batch mint fails quietly offline.

## Review sweep of PR #170 (session 2, 2026-10-28, resume here if interrupted)
**Commit identity this session:** `tsadmin@gmail.com` (Taher's chat instruction overrides the line at the top). Skills run: requesting-code-review, ponytail-audit, qt-ui-design, qt-qml-review.
**Sweep result so far:** qmllint-style linter on PR-added lines = 0 real findings (77 JS-1 `var` = house style; 7 JS-2 are `!==` false positives; ORD-1/STY-1 only in tests, house style). Server contract re-read (movementLogic.js, gatewayLogic.js applyDelta): client helper matches.
- [x] S1. Clone, checkout PR branch, read design + test plan + all production diffs.
- [x] S2. Lint on changed QML. Nothing real.
- [x] S3. Fix F1: `OutboxStore.enqueueDelta` never merges into a parked item or one with attempts > 0 (timed-out send may already be applied; same requestId => server replays old answer => merged qty lost).
- [x] S4. Fix F2: explicit-movement items only coalesce when floors are equal (merge keeps the LATEST floors: a sale's floor is dropped by a later restock, or a restock is rejected together with a floored sale).
- [x] S5. Fix F3: `InventoryStore` movement label can never lose the stock change: invalid kind/direction degrades to the server-derived row (helper `_movementsFor`).
- [x] S6. Fix F4: restock refusal toast says why (`Quantity must be greater than zero`), not "try again".
- [x] S7. Tests: Node parity SM-11 RUN 11/11, 8/8 mutants; QML StockMovements +5, OutboxStore_movements +9, InventoryStore_movementKinds +12 (two old merge-pinning tests rewritten). Gateway_movements untouched. QML CI-only, NOT RUN here.
- [x] S8. Docs (done, 95e9d4c + next commit): test plan, design (K11-K13), KNOWN-ISSUES (close parked-coalesce item, add legacy derived floors drift), Skill 140, SKILLS-INDEX regen, AGENTS/README if they mention counts.
- [ ] S9. Push, wait CI, record observed counts.

**Pushed:** 30cdff3 (code + Node), 95e9d4c (QML tests + design/KNOWN-ISSUES/Skill 140), then test plan/README/AGENTS/checkpoint. S9 open: read CI comment on PR #170, fix any QML test I mis-wrote (none run locally), record observed counts here and in the test plan.
**Risk to watch in CI:** the sent-or-parked merge guard applies to derived deltas too; any legacy tst_Gateway/tst_OutboxStore case that merged after a failure would break.
**CI round 1 on 71d1ee4:** QML failed 1 test: `Gateway_movements::test_two_explicit_calls_coalesce...` (pinned restock + floored sale merging; I missed it, grep for `tst_Gateway_movements` had not been done). Rewritten as equal-floor merge + different-floor separate-answers test. Lesson: after changing a merge rule, grep EVERY suite that calls `recordDelta`, not only the ones named after the feature.
