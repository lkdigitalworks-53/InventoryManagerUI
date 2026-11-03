# Product picker v2: approved design

**Date:** 2026-11-03. **Status:** APPROVED by Taher on 2026-11-03 (as a whole, after decisions D1 to D4). **Docs only so far; no code written.**
**Audit and trade-offs behind every choice:** `specs/2026-11-03-product-picker-v2-audit-and-decisions.md` (read it for why; this file is what to build).
**Supersedes:** `specs/2026-07-15-product-picker-search-design.md` (only on `origin/feature/product-picker-search`, never implemented, not safe to build).
**Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md`. **First plan:** `plans/2026-11-03-product-picker-v2-s1-pure-helpers.md`.

## 1. Goal

In New Order and Edit Order, replace the `AppComboBox` product picker with a searchable, detailed sheet where the person sets how many of each product to add, then adds them all at once. Robustness comes before everything else, so every rule that decides whether a product can be added lives in one tested place.

## 2. Final decisions

| # | Decision |
|---|---|
| D1 | The sheet stays open. Each row has a quantity stepper. A footer shows items and total with one "Add to order" button. Closing with a non-empty draft asks for confirmation. |
| D2 | Products that cannot be sold yet are **hidden, everywhere, the same way in New Order and Edit Order**: a batch-id mint outstanding (`StockBatchStore.hasPendingMint`), a restock queued (Q-A2, arrives with R4), a queued or parked unsynced edit (`OutboxStore.unsyncedByEntity("inventory")` state `pending` or `parked`), a product delete in flight. Out-of-stock products are shown **disabled** with the reason "Out of stock". Taher's answer on 2026-11-03: "hide all these, keep behaviour same across all use cases". |
| D3 | Row: photo (initial avatar when there is none or offline), name, `productId · SKU`, category, selling price, availability pill, "in this order: N" pill. Category chips and an in-stock-only toggle. No sorting, no barcode scan in v1. |
| D4 | A row quantity means "add N more". The picker only adds to the order. It never removes or reduces a line, and it never touches a line's discount or booked tax. |
| D5 | `BottomSheet` gains an opt-in `scrollBody` property (default true, so the other 20 sheets are unchanged). The picker sets it to false so its `ListView` owns scrolling and the footer stays pinned. |
| D6 | Delivery: pure helpers first, then the component, then the two dialogs one at a time (slices S1 to S5 in the audit brief section 9). |
| D7 | When the guards hide products that match the current search and category, the list ends with one quiet line, for example "2 products hidden while they sync". |
| Units | **Whole units only in v1.** Weight, length and other units are planned by Taher for a later release. Everything that decides what a valid quantity is lives in `PickerDraft.parseQty` and the `_whole` rounding of `maxQty`, so a later release changes those two places, not the sheet. |

## 3. Units of the design

Pure helpers (`.pragma library`, no Felgo, testable headless, Skill 83):

- `qml/helper/ProductSearch.js`: `tokenize`, `filter(products, query, { category })`. Every word of the query must match somewhere in product ID, SKU, name or category. Ranking: exact ID or SKU, then ID or SKU prefix, then word prefix in the name, then substring in name or category, then substring in ID or SKU. Ties: name ascending, then catalog order. An empty query keeps catalog order.
- `qml/helper/ProductPickability.js`: `classify(product, ctx)` and `summarize(products, ctx, { inStockOnly })`. Returns each row's `visibility` (`hidden`, `disabled`, `enabled`), a `reason` code, `available`, `maxQty`, `inOrder`, `inDraft`, plus `hiddenCount`. The dialog injects its own functions (`availableFor`, `hasPendingMint`, `hasQueuedRestock`, `unsyncedState`, `isDeleting`, `inOrderQty`, `inDraft`) and the flag `lineLimitReached`, so the helper stays pure and the three different stock formulas stay in their dialogs.
- `qml/helper/PickerDraft.js`: the draft (`productId` to whole quantity, never keyed by visible rows), `parseQty`, `setQty`, `step`, `totals`, `commitPlan` (adds and bumps only), `lineCountAfter`, `lineLimitReached`, `reconcile` (live refresh while the sheet is open), and `MAX_LINES`.
- `qml/helper/PickerRowGeometry.js` (slice S2): touch-target and spacing math, as `FailedTileGeometry.js` does.

Felgo-dependent QML, painting only: `qml/components/ProductPickerSheet.qml`, `ProductPickerRow.qml`, a trigger button, `BottomSheet.qml` `scrollBody`, and the wiring in `NewOrderDialog.qml` and `OrderDetailDialog.qml`.

## 4. Rules that must hold

1. **Fail closed.** A missing `availableFor` hook, a hook that throws, or a non-number stock never makes a row addable. A missing hide-hook (for example `hasQueuedRestock` before R4) means "not hidden", because that guard does not exist yet.
2. **Hidden beats disabled.** Precedence: pending mint, queued restock, unsynced edit, delete in flight, then out of stock, then order full.
3. **Order full.** `MAX_LINES = 60` new distinct lines per order. Each completed line costs at least a batch change, a stock change and a sale record, plus one change for the order, and the server refuses more than `MAX_OPS = 200` changes (`functions/lib/operationLogic.js`, `qml/helper/CompletionPlan.js`). 60 lines gives 181 changes with headroom. A drift test fails if `3 * MAX_LINES + 1` ever exceeds `MAX_OPS`. This is an early stop, not a guarantee: a product spread over many batches costs more, and `CompletionPlan` stays the final check at approval. Rows for products already on the order or already in the draft stay usable when the order is full.
4. **The draft survives filtering.** Changing the search text or a chip never changes a quantity already set.
5. **Live refresh.** While the sheet is open the rows re-read on the store revision signals (Skill 78), and `reconcile` clamps or removes any draft quantity whose product became unavailable.
6. **Commit is additive.** `commitPlan` returns `adds` (new line) and `bumps` (add to an existing line), sorted by product ID, never a removal. Each dialog applies it with its existing add-line code, so booked tax on a completed order, the stock caps and the double-submit guards keep working unchanged.
7. **Quantities are whole numbers.** Typed text must be digits only, at most 6 digits, then clamped to `maxQty`. Anything else leaves the draft unchanged.
8. **Search is literal.** Regex characters are plain text, text is NFC-normalised and lower-cased, a query longer than 200 characters is cut.

## 5. Not in v1

Sorting, barcode scan, weight or length quantities, a "set the total" mode, removing lines from the picker, any server or rules change.

## 6. Risks carried forward

See the audit brief section 11. The one to remember: line coverage is 100% for the pure helpers only; the Felgo view layer is covered by wiring tests plus the on-device plan (Skill 83), and the test plan states this per slice.
