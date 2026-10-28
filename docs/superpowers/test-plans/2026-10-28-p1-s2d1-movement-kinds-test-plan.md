# Test plan — P1 S2d-1: typed stock-movement kinds on client deltas

Branch `feat/2026-10-28-p1-s2d1-movement-kinds`. Design: `specs/2026-10-28-p1-s2d-kinds-on-deltas-design.md`. Standard format (Skill 49).
CI observed on PR #170 @ c438881: QML 2415, Functions 876, Rules 106, E2E 103, total 3500/3500 green (all 77 new QML cases and both new e2e cases passed; the first e2e run failed because `tst_InventoryE2E` never redirected `Gateway.deltaFunctionUrl`, a test bug, fixed). Honesty note: in the sandbox only the Node file was RUN. Every QML case is written but CI-only; counts below are test functions grepped from the files (QML 15+18+15+22+7 = 77; Node 10; server suite 866 -> 876 RUN), CI adds +2 per new TestCase file (`initTestCase`, `cleanupTestCase`). Read the real totals from the CI comment.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/stockMovementsParity.test.js` | 11 | RUN 11/11; helper 100% line/branch/func; 16/16 + 8/8 (sweep floors rule) mutants killed | constants parity, `make` (trim, cut, no valueAtCost), `validate` (every error code, every kind and direction, float noise, non-object clamps), `canCoalesce`, `mergeMovements`; client vs server accept/reject matrix; seeded monkey 4000; SM-11 floors rule |
| `tests/tst_StockMovements.qml` | 20 | CI only | the same helper cases on the Qt side; review sweep: equal floors merge, different floors never, non-object floors = empty, undefined-valued keys, other rules still apply with equal floors, derived ignores floors |
| `tests/tst_OutboxStore_movements.qml` | 27 | CI only | explicit shape, empty array = derived, explicit+explicit coalesce, sum invariant, no input mutation, cap 50/51, explicit vs derived both orders, clamp never joins, derived pairs unchanged, stock_batch untouched, product isolation, in-flight item never mutated, skip incompatible first candidate, relaunch round trip; review sweep: floored sale vs unfloored restock both orders = 2 items, two floored sales merge and keep the floor, parked explicit/derived never a target, stuck-not-terminal never-sent still merges, sent-and-failed explicit/derived never a target, skipped candidate does not hide a fresh one |
| `tests/tst_Gateway_movements.qml` | 15 | CI only | queued with movements, derived unchanged, callback waits, coalesce joins callbacks, floor allowed, 8 refusal codes queue nothing, silent without callback, bad entity unchanged |
| `tests/tst_InventoryStore_movementKinds.qml` | 34 | CI only | restock receipt + reason, default 10, fractional, long reason cut, two restocks coalesce, negative / Infinity refused with no batch, unknown product; deductStock kind, derived, clamp ignores kind, zero/Inf, restock+sale net, clamp beside explicit; credit kind, derived, bad qty, unknown product, sale+rollback net 0 |; review sweep: restock + floored sale = 2 items, sale + rollback = 2 items netting 0, restock around a failed send never share an item, `_movementsFor` (valid, no kind, unknown kind, wrong direction, bad qty, adjustment both ways), credit/deduct with a bad kind still queue the stock change derived (floor kept), refused restock answers `Quantity must be greater than zero` (negative, text), NaN = default 10

## 2. Regression tests
- Clamped imported-order deduction stays derived and keeps its clamp (`test_deductStock_in_clamp_mode_ignores_a_kind`): the lost-deduction trap.
- Derived-only coalescing and `stock_batch` deltas unchanged (`test_derived_pairs_still_sum_exactly_as_before`, `test_stock_batch_deltas_never_gain_movements`; the old `tst_OutboxStore` cases still pin the legacy rule).
- Refused restock leaves no orphan batch (`test_a_negative_restock_is_refused_before_any_side_effect`).
- DataModel call sites: `tests/tst_DataModel_movementKinds.qml` (7, CI only): resellable return, damaged return = no row, full return, reopen, reopen without productId, exchange add (`sale`, floor not clamp), rollback (`sales_return`, failed line not undone).

- Review sweep (PR #170): a delta never merges into a parked item or one with `attempts > 0` (also derived: `test_a_derived_item_that_was_sent_and_failed_is_never_a_merge_target`); explicit items need equal floors. The two old cases that pinned restock+sale and sale+rollback merging were rewritten to expect two items. Legacy derived floors drift stays open (KNOWN-ISSUES).

## 3. E2E (real emulator, CI)
- `test/e2e/tst_InventoryE2E.qml` +2: restock `receipt` accepted (stock +4, no conflict); two back-to-back restocks coalesce into one valid delta (stock +5). A 409 on a bad sum would leave stock unchanged.
- Returns with `sales_return`: already run by `tst_ReturnAfterMetadataEditE2E` (unchanged file, now exercises the new payload).
- Not written: reading the `stock_movement` rows back from QML (collection is closed to clients; server row content is pinned by `functions/test/movement*.test.js`).

## 4. Rules
None changed (`stock_movement` stays closed). Node `index.handlers`/`movement*` suites cover server acceptance of explicit kinds.

## On-device test plan (Taher, after merge; app build only, no functions deploy)
Prerequisites: P1 signed in as owner on a dev tenant; P2 two products A (stock 10, has a batch) and B (stock 5, batch qty 5); P3 one completed order with 2 x A; P4 Firestore console open on `tenants/<t>/stock_movement`.

### Happy path
1. Restock A by 4 with reason `box 1`. Expect stock 14; one new row kind `receipt`, qty +4, reason `box 1`.
2. Return 1 x A (resellable) from the completed order. Expect stock +1; row `sales_return`, +1, reason `Return - order <id>`.
3. Reopen the order. Expect stock back; row `sales_return`, reason `Order reopened - sale reversed - order <id>`.
4. Complete an order, then modify it up by 1 x B. Expect B stock 4; row `sale`, qty -1, reason `Exchange / modify - order <id>`.

### Negative
5. Return 1 x A as damaged. Expect NO stock row and stock unchanged.
6. Modify an order up by more units than B has. Expect a refusal toast, no `sale` row for B.
7. Airplane mode, restock A, reconnect. Expect one `receipt` row, stock +qty once (no double).

### Edge cases
8. Two quick restocks (3 then 2) offline, then reconnect. Expect stock +5 and two `receipt` rows (3 and 2). One request if no send had failed between the taps; two requests if the first tap's send already failed (a sent item is never merged into). Stock +5 either way, never +3.
9. Restock with a 600-character reason. Expect success; reason stored cut to 500.
10. Restock quantity 0 in the dialog: expect the existing default (10) behaviour, still a `receipt`.
11. Import orders that complete with a shortfall (imported-order path). Expect completion succeeds, stock floors at 0, row is `adjustment` (S2d-2 will type it).

### Affected areas
Restock dialog, order return/exchange/reopen flows, imported-order completion, stuck-writes dialog (a stuck explicit delta still shows and discards normally), stock register report totals (rows now typed).

### Regression
12. Exchange with two added products where the second fails: first product's stock is restored and a `sales_return` Rollback row exists, net stock unchanged.
13. Completed order approve/complete (recordOperation path) still writes its `sale` rows as before.

15. Restock A by 4 on a flaky network (toggle airplane mode right after tapping), then restock A by 2 before it syncs. Expect final stock = start + 6 exactly once each, two `receipt` rows (4 and 2), no stuck-writes entry.
16. Exchange adding B (floored sale) then restock B within seconds while offline. Expect two separate writes: B never goes below 0, restock lands even if the sale is refused.

### Monkey
14. 2 minutes of random restock / return / reopen / modify taps on 2 products, toggling airplane mode. Expect no crash, no stuck-writes entry, final stock = start + restocks + returns - sales; every row's kind matches the action.
