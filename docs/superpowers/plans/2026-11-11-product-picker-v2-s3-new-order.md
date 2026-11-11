# Product Picker v2, Slice S3: New Order wired Plan

**Goal:** Replace the combo and the add button of `NewOrderDialog` with the searchable sheet (`ProductPickerSheet`, built dormant in S2), and close the requirements S1 and S2 carried to this slice. After S3 the New Order picker behaves as design D1 to D7 say; Edit Order (S4) is untouched and still uses its combo.

**Design:** `docs/superpowers/specs/2026-11-03-product-picker-v2-design.md` (approved). **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md`. **Branch:** `feat/2026-11-11-picker-s3-new-order`, cut from `main` @ `977cde0` (PR #187 merged).

## Decisions taken in this slice (vetoable in the PR)

| # | Decision | Trade-off, honestly |
|---|---|---|
| S3-D1 | New pure helper `qml/helper/NewOrderPicker.js`: `cartQty`, `availableFor` (the stock formula that used to be `_inCartQty` and `_availableStock` in the dialog), `priceOf`, `applyPlan`, `skippedNote`, `opsCheck`. | One more file, against leaving the rules in QML where the sandbox cannot run them (Skill 83). Chosen because every rule here is money or stock. S4 will need a sibling for its three stock formulas; sharing a base is S4's call, not guessed now. |
| S3-D2 | The dry run (KNOWN-ISSUES, carried item 1) is an OPTIONAL hook `commitCheck(plan)` that `PickerSheetModel.build` calls after the cheap gate passes, on every rebuild. A refusal closes the gate (`reason: "check-failed"`) and shows the hook's words in the footer. | Alternatives: check only at the Add tap (cheaper, but the note appears late and the logic would sit in QML), or memoise by plan (fastest, more state). The cost is up to 60 `StockBatchStore.forProduct` scans and sorts per tap, UNMEASURED: device check 64 decides; memoising is the fallback. Absent hook means no check, so S4 and every S2 test are unchanged. |
| S3-D3 | `opsCheck` refuses ONLY on `too-many-ops`, using the real `CompletionPlan.build` with stand-in hooks (the sale-document stand-in is pinned to `TransactionStore.buildSaleDocs`, NOW-11). A stock shortfall (`clampStock: true`) and a line whose product is gone do not refuse; a missing or throwing lookup does (fail closed). | Fail-open on stock and gone products because the submit check and `CompletionPlan` at approval own them, and refusing here would block unrelated picks because of an old line. The dry run is best effort: batches change between now and approval, and `CompletionPlan` stays the final authority. |
| S3-D4 | `applyPlan` re-reads each product at the Add tap, clamps to what is left, refuses what is gone or sold out, and reports it. An "add" for a product already on the order is a bump and a "bump" for one that is not is an add, so a stale plan never makes a duplicate line. | A little more logic than "append", against a drift (another device sold the product while the sheet was open) silently overselling. The sheet already re-reads before it hands the plan over; this is the second line of defence at the point where the order is changed. |
| S3-D5 | A NEW line needs a selling price that is a finite number >= 0 (0 stays allowed). Anything else is refused and reported ("has no selling price"). | Before, a product with no price became a line with an undefined price and a NaN total. The cost: such a product cannot be sold from New Order until its price is fixed, and the sheet row does not say why (the dialog reports after Add): KNOWN-ISSUES item 23. |
| S3-D6 | `StockBatchStore.mintRevision`, ticked by `on_PendingMintsChanged` (carried item 7). | The alternative, a `Connections` in the dialog on the store's private `_pendingMints`, reaches into a private property. A public counter is one line and matches `revision` on the other stores. |
| S3-D7 | `revision` handed to the sheet is `InventoryStore.revision + StockBatchStore.revision + StockBatchStore.mintRevision + OutboxStore.revision`. | Every term only grows, so the sum changes exactly when one term does. `InventoryStore.syncStates` is refreshed synchronously from the outbox items, before the sheet's deferred rebuild, so `OutboxStore.revision` covers it. NOW-04 pins the four terms. |
| S3-D8 | The trigger is one full-width `GhostButton` (48 dp, "Add products" or "Add more products", off while `busy`). The sheet lives inside the dialog and is closed by the dialog's `onClosed`. What was not added goes to the dialog's existing red error label. | Simplest thing that works. The label sits at the bottom of the scrolling body and may be off screen after a long order (device check 65); a toast is the alternative. |

Not changed on purpose: no `isDeleting` hook (a deleted product leaves the catalog at once, see the `ProductPickability.js` header); the parity gap of carried item 3 needs no code (a held row is never sent, so it can never be parked; the two outbox queries can differ only for a damaged saved row, and then completion refuses with a message).

## Files

| File | Responsibility |
|---|---|
| `qml/helper/NewOrderPicker.js` (create) | The rules above. `.pragma library`, imports `CompletionPlan.js`. |
| `qml/helper/PickerSheetModel.js` (modify) | Optional `commitCheck` hook, `check-failed` gate reason. |
| `qml/model/StockBatchStore.qml` (modify) | `mintRevision`. |
| `qml/pages/NewOrderDialog.qml` (modify) | Combo, add button, `productNames`, `_pickerProducts`, `_rebuildPickerNames`, `_inCartQty`, `_availableStock`, `addSelectedProduct` deleted; `_pickerLookup`, `_pickerHooks`, `_pickerRevision`, `_applyPicked`, the button and the sheet added. |
| `functions/test/newOrderPicker.test.js` (create) | `NOP-01..24`; QML twin `tests/tst_NewOrderPicker.qml` derived. |
| `functions/test/pickerSheetModel.test.js` (modify) | `SHEET-32..40` for the hook; twin regenerated. |
| `functions/test/newOrderPickerWiring.test.js` (create) | `NOW-01..16`: source pins, and the dialog's real hook literal and `_applyPicked` body run against the real helpers. |
| `functions/test/pickerDormancy.test.js`, `pickerSheetWiring.test.js` (WIRE-15), `restockWire.test.js` (W-20), `testSupport/pickerTwin.js` (modify) | Allow-lists changed on purpose; the old combo-loop pin re-pointed at the hook; the new twin registered. |

## Not in S3

Edit Order (S4); accessibility, themes, big-catalog performance and the full device pass (S5); a "No price" reason on the row; a bigger touch target for the cart-row stepper (KNOWN-ISSUES 24); any server or rules change; a build or run of the app (Taher decides).

## Verification

Node: `node --test functions/test/picker*.test.js functions/test/newOrderPicker*.test.js`, then the whole `functions` suite. 43 hand mutants (script kept out of the repo): first run 1 survivor, a real gap (a stock shortfall could hide an oversize order), fixed with a test; final run all killed. QML twins and the Felgo layer: CI and the device plan only.
