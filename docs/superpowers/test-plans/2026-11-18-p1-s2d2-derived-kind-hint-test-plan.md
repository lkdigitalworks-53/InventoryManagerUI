# Test plan: P1 S2d-2, a kind hint for server-derived stock rows (imported-order sales count as `sale`)

Branch `feat/2026-11-18-p1-s2d2-derived-kind-hint`. Design: `specs/2026-11-18-p1-s2d2-derived-kind-hint-design.md` (H1..H11). Standard format (Skill 49).
Honesty note: the Node tests were RUN in the sandbox against the real server code and the real QML function bodies (run in a vm). The QML twins and the e2e emulator suites are CI only (no Qt in the sandbox, by rule). I did not build or run the app.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/kindHint.test.js` (new) | 20 | RUN 20/20 | KH-1 the hint list is exactly the kinds needing no reason and no value; KH-2..KH-6 validator (none, listed, every other value, with movements, wrong entity, no stock delta); KH-7 the fix: a clamped deduction with hint `sale` writes ONE derived `sale` row of the APPLIED quantity; KH-8 default unchanged (`adjustment`); KH-9 direction mismatch degrades to `adjustment`, never refuses; KH-10 other hints; KH-11 a clamp that applies nothing writes no row; KH-12 explicit movements win over a stray hint; KH-13 replay writes nothing twice; KH-14 full pipeline for the imported-order case; KH-15..KH-17 recordMutation, batch and operation refuse a hint; KH-18, KH-19 the handler forwards a good hint and never reaches apply with a bad one; KH-20 monkey, 4000 random deltas, ledger equals applied change |
| `functions/test/kindHintClient.test.js` (new) | 16 | RUN 16/16 | the REAL `StockMovements`, `Gateway`, `OutboxStore`, `InventoryStore` function bodies in a vm, fed to the real server: KC-1 list mirror; KC-2 same code and order as the server; KC-3 monkey, 4000 calls, client and server agree on accept versus refuse (the codes can differ for a faulty movement, see KNOWN-ISSUES); KC-4 coalescing needs an equal hint; KC-5 Gateway queues a good hint, refuses a bad one before queueing; KC-6 outbox stores it, survives JSON, never merges into a sent or parked item; KC-7 `deductStock` hints only in clamp mode and drops a refused kind while keeping the stock change; KC-8 the app's own calls reach the server as one `sale` row; KC-9 source wiring pins; KC-10 error codes are app problems; KC-11 monkey, 2000 imported-order lines |
| `tests/tst_StockMovements.qml` (+9 functions, CI) | | CI only | `HINT_KINDS`, `validateKindHint`, `canCoalesce` with hints |
| `tests/tst_OutboxStore_movements.qml` (+5) | | CI only | hint stored, equal hints merge, unequal queue apart, JSON round trip |
| `tests/tst_Gateway_movements.qml` (+6) | | CI only | 8th argument queued, refused before queueing, silent without callback |
| `tests/tst_InventoryStore_movementKinds.qml` (1 replaced by 6) | | CI only | clamp mode sends the hint and no movements; no kind = no hint; refused kind dropped, stock change kept; exact mode sends movements and no hint; coalescing of equal and unequal hints |
| `tests/tst_FailureCause.qml` (+3 data rows) | | CI only | the three new codes are app problems |
| Hand mutants | 21 | 21 of 21 killed | each guard in the validator, apply, handler, coalescing and wiring was broken once; the suite failed each time |

## 2. Regression tests
Full functions suite RUN 1999/1999 green (36 of them new in this slice; no existing test file was edited, so no existing assertion was weakened). `.github` scripts suite RUN 1061/1061. Restock, order completion, import, delete, register and reason-policy suites unchanged and green.

## 3. E2E (emulator, CI only)
No new e2e case: the imported-order completion path is covered by the existing import/order e2e files, which still pass through `deductStock(..., true, "sale")`. If CI shows red there, the first suspect is a test that asserted `adjustment` for an imported order.

## 4. Rules
Unchanged (no rules or index change).

## On-device test plan (Taher; requires functions deployed to dev FIRST, then a build of this branch)
### Happy path
1. Import an order file with product A (stock 10), order quantity 4. Complete the order. Expect: stock 6. Open History (or the register once S4b-2 exists): one row `sale`, quantity -4, not `adjustment`.
2. Complete an ordinary (non-imported) order of 2. Expect a `sale` row -2, as before.
### Negative
3. Import an order for product A (stock 2), quantity 5. Complete. Expect: stock 0 (not negative), no error toast, one `sale` row of -2 (what actually left), not -5.
4. Complete an imported order for a product that does not exist. Expect the order's usual "product not found" behaviour, no ledger row, no crash.
### Edge cases
5. Same imported order completed twice quickly (double tap). Expect one deduction and one row.
6. Airplane mode, complete an imported order, kill the app, go online and reopen. Expect the deduction to sync once, as one `sale` row.
7. Two imported orders for the same product completed back to back offline: expect both to sync; rows are `sale` for both (equal hints merge; the stock total is right).
### Multiple scenarios
8. Deploy order check: with the OLD functions deployed and this build, complete an imported order. Expect stock deducted correctly and the row still `adjustment` (no failure, no stuck write in Settings). Then deploy functions and repeat: row is `sale`.
### Affected areas
Imported-order completion; the stuck-writes sheet (must stay empty); the register `sale` and `adjustment` columns.
### Regression
Complete a normal order, edit an order (exchange), return goods, reopen an order, restock a product, add a product: each must produce the same rows as before.
### Monkey
Two minutes of rapid import / complete / cancel / restock while toggling airplane mode: no crash, no stuck write, stock never negative, rows only `sale`, `receipt`, `sales_return` or `adjustment`.

## 5. CI result
See CHECKPOINT.md (CI is the oracle for the QML twins; not read at the time of writing).
