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
- [ ] 5. `tests/tst_DataModel_movementKinds.qml` (return, damaged=no row, reopen, exchange add, rollback; harness = `tst_DataModel_adjustOrderSyncGuard`, server answers simulated with `Gateway._answerDeltaCallbacks` + `OutboxStore.markSent`).
- [ ] 6. e2e rows (emulator) for restock receipt + return sales_return.
- [ ] 7. Design doc, test plan (Skill 49 format), Skill entry + SKILLS-INDEX regen, AGENTS, README, KNOWN-ISSUES, test-plans README row.
- [ ] 8. Read CI on PR head, fix red. Count tests from CI, not predictions.
- [ ] 9. Taher: veto/accept defaults (clamp stays adjustment; reopen+rollback = sales_return; damaged return = no row until S2e Q4); decide S2d-2.

## Open, unverified
- `enqueueDelta` does not skip parked items when coalescing (pre-existing; not checked whether other paths guard it).
- restock success-path QML tests assume the batch mint fails quietly offline.
