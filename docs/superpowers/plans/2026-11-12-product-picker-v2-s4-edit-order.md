# Product Picker v2, Slice S4: Edit Order wired Plan

**Goal:** Replace the combo and the add button of `OrderDetailDialog` with the searchable sheet (`ProductPickerSheet`, wired into New Order in S3), and close the requirements S1 to S3 carried to this slice. After S4 both order dialogs use the same sheet, the same hide rules (design D2) and the same plan-then-apply flow.

**Design:** `docs/superpowers/specs/2026-11-03-product-picker-v2-design.md` (approved). **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md`. **Branch:** `feat/2026-11-12-picker-s4-edit-order`, cut from `main` @ `3c03306` (PR #194 S3 and PR #193 P1 S4a merged). **Previous slice plan:** `2026-11-11-product-picker-v2-s3-new-order.md`.

## What Edit Order does differently from New Order (read from code)

1. **Three stock formulas, decided by the order's SAVED status** (`_orderStatus`, not the status combo): pending and processing = on-hand minus what the order holds; completed = on-hand plus the units the order held at completion minus what it holds now (its units are already out of stock).
2. **Booked tax on a completed order.** A product that was on the order at completion and is re-added returns at its BOOKED rate (time of supply). Before S4 this rule lived only inside the dialog's add handler, and `tests/tst_CompletedOrderTaxTimeOfSupply.qml` re-implements it instead of calling it, so the real code was untested.
3. **The order is a `ListModel`** (`products`, field `quantity`), not an array of lines. Existing rows carry `taxable`, `taxPercent`, a per-line discount and an edited price that the picker must never touch.
4. **Completion path differs.** A pending or processing order completes through `CompletionPlan` (capped at 200 changes). A completed order's edit goes `adjustRequested` then `ConfirmReturnSheet` then `DataModel._tryAdjustOrder`, the legacy per-line chain, which has no operation cap (KNOWN-ISSUES, picker carried item 2).
5. **`catalog` is still read** by `openFor` to seed a legacy order that has no line items.

## Decisions taken in this slice (vetoable in the PR)

| # | Decision | Trade-off, honestly |
|---|---|---|
| S4-D1 | New pure helper `qml/helper/EditOrderPicker.js` (`linesOf`, `availableFor`, `seedOf`, `applyPlan`, `commitCheck`, `cartQty`, `skippedNote`) that REUSES `NewOrderPicker.applyPlan` through one new OPTIONAL lookup hook `availableOf(id, product, lines)`. | Alternatives: copy `applyPlan` (about 40 lines of money logic twice, two places to drift), or one shared base with a mode flag (touches the just-merged New Order path more). The hook is 12 lines in `NewOrderPicker`, absent hook = the old code path, proven by NOP-28..30 and all 27 older NOP cases unchanged. Cost: New Order's file changed in a slice about Edit Order; EOP-26 (200 seeded plans) pins that both helpers agree for a pending order. |
| S4-D2 | The dry run (`commitCheck`) applies to pending and processing orders only; a completed order is always ok. | A pending order will complete through `CompletionPlan`, so the size check is true for it. A completed order's edit never meets that cap, so refusing at 50 two-batch lines would block an edit that the legacy chain could do. The cost: nothing in the picker stops a completed-order edit that is big in a way the legacy chain handles badly (it is a multi-step chain with compensations, no transaction). `MAX_LINES = 60` stays as the early stop. Real limit of that chain: UNKNOWN, unmeasured (KNOWN-ISSUES 29). |
| S4-D3 | The sheet's plan is applied to the model IN PLACE: `setProperty(index, "quantity", n)` for a bump, `append` for a new row, then ONE `recomputeSubtotal()`. The helper returns `sets` (by row index) and `appends`, never a rebuilt list. | Alternative: rebuild the model from the helper's lines (simpler to reason about) would drop every existing row's tax flags, discount and `consumption`-related state unless copied field by field, and rebuilds every delegate (a focused price field loses focus). In-place keeps all of it by construction (EOW-05 pins that `price`, `discount*`, `taxable`, `taxPercent` are never set on an existing row). |
| S4-D4 | Every hook reads the LIVE rows (`_pickerLinesNow()` = `Edit.linesOf(_lineItemArray())`); `_pickerLines` exists only so the sheet's `orderLines` binding fires. It is refreshed in `recomputeSubtotal`. | The delete button removes the row first and recomputes later (`Qt.callLater`), so a cached copy can be stale for one tick. Reading the rows costs O(lines) per hook call (60 at most), negligible. EOW-16 pins it. |
| S4-D5 | `catalog` stays but is built once, in `openFor`, without names and availability; `catalogNames` and `_availableStock` are deleted; `recomputeSubtotal` no longer rebuilds it. | Before, every recompute (every stepper tap) scanned the whole catalog and formatted a label per product for a combo that no longer exists. The only reader of `catalog` is the legacy seed right after the one build (EOW-01 pins both). Risk: a later reader would see an old catalog; it is documented on the property. |
| S4-D6 | Completed-order availability counts WHOLE units and sums all lines of a product (`_whole(stock) + origQty - cartQty`). The old `_availableStock` used raw `inv.stock` and the LAST row's quantity. | Matches the design's whole-units rule and New Order. A fractional stock such as 2.5 now offers 2 where the old combo said 2.5 (and its `+` would have gone to 2.5 + 1). One line per product is the normal case, so sum and last-row agree. The row stepper (`+` on a cart row) still uses its own raw formula: not changed here (KNOWN-ISSUES 28). |
| S4-D7 | The trigger is one `GhostButton`, off only while `busy` (as the old add button). It is NOT gated on the order lock. | Gating on `_lockState` would stop a person building edits they cannot save, but it changes behaviour the rest of the dialog documents on purpose ("reads are never gated, only `_save()` checks the lock"). Left as is; observation in KNOWN-ISSUES 31. |
| S4-D8 | No emulator E2E in this slice. | The design planned one E2E (build from a draft, complete through the real gateway). Writing it blind (the emulator cannot run in this sandbox, CI is the only oracle) risks a red CI with no way to iterate; the picker only produces plain rows that go through the unchanged save paths. Not cut silently: it is S5's first item (KNOWN-ISSUES 34). |

## Files

| File | Responsibility |
|---|---|
| `qml/helper/EditOrderPicker.js` (create) | The rules above. `.pragma library`, imports `NewOrderPicker.js`. |
| `qml/helper/NewOrderPicker.js` (modify) | `_capOf` and the optional `availableOf` hook in `applyPlan`; `opsCheck` inherits it through `applyPlan`. |
| `qml/pages/OrderDetailDialog.qml` (modify) | Combo, add button, `catalogNames`, `_availableStock`, the per-recompute catalog rebuild deleted; `_pickerLines`, `_pickerLinesNow`, `_pickerCtx`, `_pickerLookup`, `_pickerHooks`, `_pickerRevision`, `_applyPicked`, the button and the sheet added; `onClosed` closes the picker first. |
| `functions/test/editOrderPicker.test.js` (create) | `EOP-01..31` (EOP-24 deleted in the second sweep); QML twin `tests/tst_EditOrderPicker.qml` derived (29 cases, EOP-26 is Node only). |
| `functions/test/editOrderPickerWiring.test.js` (create) | `EOW-01..19`: source pins, and the dialog's real functions and literals run against a fake `ListModel`. |
| `functions/test/newOrderPicker.test.js` (modify) | `NOP-28..30` for the hook; twin regenerated. |
| `functions/test/newOrderPickerWiring.test.js` (NOW-09), `pickerSheetWiring.test.js` (WIRE-15), `restockWire.test.js` (W-20), `pickerDormancy.test.js`, `testSupport/pickerTwin.js` (modify) | Allow-lists and pins changed on purpose (Edit Order is wired now); the new twin registered. |

## Not in S4

Accessibility, themes, big-catalog performance and the full device pass (S5); the emulator E2E (S5); a "No price" reason on the row; a bigger touch target for the cart-row stepper; changing the cart-row stepper's own stock formula; any server or rules change; a build or run of the app (Taher decides).

## Verification

Node: `node --test functions/test/picker*.test.js functions/test/newOrderPicker*.test.js functions/test/editOrderPicker*.test.js`, then the whole `functions` suite and the `.github/scripts` suite. 27 hand mutants (script kept out of the repo) over `EditOrderPicker.js` and the new hook: first run 3 survivors, two real gaps (a fractional held quantity left a fractional limit; a product that vanishes between the stock read and the tax read was added untaxed) fixed with tests, the third equivalent (`full.batchesOf = undefined` and a missing reader reach `opsCheck` as the same refusal). QML twins and the Felgo layer: CI and the device plan only.
