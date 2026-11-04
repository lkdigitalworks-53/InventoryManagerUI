# Test plan: product picker v2 (searchable sheet with quantity steppers, New Order and Edit Order)

Design: `specs/2026-11-03-product-picker-v2-design.md` (approved 2026-11-03). Audit and trade-offs: `specs/2026-11-03-product-picker-v2-audit-and-decisions.md`. First plan: `plans/2026-11-03-product-picker-v2-s1-pure-helpers.md`. Standard format (Skill 49).

**Honesty note, written BEFORE implementation: NOTHING IN THIS PLAN HAS BEEN RUN.** Every status column says PLANNED. When a slice lands, its owner changes the status to RUN (with the count from the run) or CI ONLY, and adds a "CI OBSERVED" line, as the R3 plan does. Counts are recounted with `grep -c "function test_"` for QML and by counting `test(` rows for Node, never copied from this plan.

**What 100% means here (Skill 83).** The three pure helpers (`ProductSearch.js`, `ProductPickability.js`, `PickerDraft.js`) and `PickerRowGeometry.js` are covered at 100% of lines and branches, checked in Node with `c8` against the real helper text. The Felgo-dependent QML (`ProductPickerSheet.qml`, `ProductPickerRow.qml`, the trigger button, `BottomSheet.scrollBody`, the two dialogs) cannot be loaded by `qmltestrunner`, so line coverage cannot be measured there. That layer is covered by wiring tests that read the QML source and run the pure helpers, plus the on-device plan below. This plan does not claim 100% for code that cannot be measured.

## Slices and status

| Slice | What lands | Behaviour change | Status |
|---|---|---|---|
| S0 | Audit, decisions, design, this plan, S1 plan | none (docs) | docs pushed |
| S1 | `ProductSearch.js`, `ProductPickability.js`, `PickerDraft.js`, dormancy test | none (nothing calls them) | PLANNED, not started |
| S2 | `PickerRowGeometry.js`, `ProductPickerSheet.qml`, `ProductPickerRow.qml`, `BottomSheet.scrollBody` | none (nothing opens the sheet) | PLANNED |
| S3 | New Order wired; `productNames`, `_pickerProducts`, `_rebuildPickerNames` deleted | New Order picker changes | PLANNED |
| S4 | Edit Order wired; `catalog` kept for legacy seeding and the booked-tax rule | Edit Order picker changes | PLANNED |
| S5 | Sweep, accessibility, performance, full on-device pass | none or fixes | PLANNED |

## 1. Unit tests

| File | Cases | Slice | Status | Covers |
|---|---|---|---|---|
| `functions/test/pickerSearch.test.js` | 27 (`SRCH-01..27`) | S1 | PLANNED | Empty, blank, null and undefined query keep catalog order. Case-insensitive. Match by ID, by SKU, by category. Every word must match, words may match different fields. Ranking: exact ID or SKU, ID or SKU prefix, word prefix in name, substring in name or category, substring in ID or SKU; ties by name then catalog order. Regex characters are literal (`.*`, `(`, `[`, `\`). Devanagari. NFC against decomposed accents, both directions. Missing fields, numeric ID. Junk entries (`null`, `5`, `"x"`, `[]`) skipped. Category filter (`All`, empty, unknown). Query of 10,000 characters returns in under 50 ms. Input frozen, never mutated. Seeded monkey of 400 rounds. |
| `functions/test/pickerPickability.test.js` | 25 (`PICK-01..25`) | S1 | PLANNED | Enabled with stock; disabled out of stock for 0, negative, NaN, string, Infinity; fractional stock floors. Hidden for pending mint, queued restock, unsynced edit (`pending` and `parked`), delete in flight. Precedence of the four hide reasons, and hidden beats out-of-stock. Order-full only when the limit is reached AND the product is neither in the order nor in the draft; out-of-stock beats order-full. Fail closed: no `availableFor`, no context, a throwing hook, junk products. `inOrder` and `inDraft` junk becomes 0. `summarize`: counts, order preserved, `inStockOnly`, junk input, junk entries. Input frozen. Seeded monkey of 400 rounds. |
| `functions/test/pickerDraft.test.js` | 30 (`DRFT-01..30`) | S1 | PLANNED | `parseQty`: digits only, 15 junk shapes refused, 6-digit cap. `setQty`: normal, clamp to `maxQty`, zero deletes, junk text leaves the draft, `maxQty` 0 or junk removes the key, hostile IDs (`__proto__`, empty, number, null). `step`: up, down to zero, cap, below zero, junk delta. `totals`: items, lines, amount rounded to 2 decimals, junk prices. `commitPlan`: adds versus bumps, sorted by product ID, corrupt draft entries ignored, `qty` and `quantity` lines both recognised. `lineCountAfter`, `lineLimitReached`. `reconcile`: clamp, remove, missing function drops everything. **Drift guard `DRFT-26`:** reads `MAX_OPS` from `qml/helper/CompletionPlan.js` and `functions/lib/operationLogic.js`, requires them equal and `3 * MAX_LINES + 1 <= MAX_OPS`. Seeded monkey of 400 rounds. |
| `functions/test/pickerDormancy.test.js` | 3 (`DORM-01..03`) | S1 | PLANNED | Nothing outside the helpers and their tests mentions them (S3 changes this on purpose, in its own PR). Pragma-library shape: no Felgo, no singleton tokens. Names absent from `qml/helper/qmldir`. |
| `tests/tst_ProductSearch.qml`, `tst_ProductPickability.qml`, `tst_PickerDraft.qml` | same rows, except `DRFT-26` (needs the file system) | S1 | PLANNED, CI ONLY | The Node rows again in the QML engine, because number and string handling can differ (the R3 `var long` compile error is the proof). Avoid reserved words in test code. |
| `functions/test/pickerRowGeometry.test.js` and `tests/tst_PickerRowGeometry.qml` | about 15 | S2 | PLANNED | Touch target at least 48 dp for the stepper buttons and the row, spacing sums, the row height at large font scale, narrow-width layout. |
| `functions/test/pickerSheetWiring.test.js` | about 20 | S2 | PLANNED | Source pins on the sheet: the list is a `ListView` (not a `Repeater` inside a `ScrollView`), delegates use `required property` and no implicit `index` (Skill 78), the rows re-read on the store revision signals, the sheet imports only the three helpers for decisions, `BottomSheet.scrollBody` default is true and only the picker sets false, every other `BottomSheet` user is unchanged (a grep over the other sheets). |
| `functions/test/pickerNewOrderWiring.test.js` | about 20 | S3 | PLANNED | The dialog passes its own `availableFor` (stock minus units in the cart), `inOrderQty`, `lineLimitReached`; the commit applies `commitPlan` through the existing add-line code; `productNames` and its helpers are gone; the double-submit guard is untouched. |
| `functions/test/pickerOrderDetailWiring.test.js` | about 25 | S4 | PLANNED | `availableFor` is `_availableStock` for all three order states (pending, processing, completed); the completed-order commit goes through the existing add handler so booked tax is kept; `catalog` is still used for legacy seeding; the picker never calls a remove or reduce path (D4). |
| `tests/tst_NewOrderDialogSubmitGuard.qml`, `tst_DataModel_completeOrderParkedGuard.qml` and the completed-order tax tests | existing | S3, S4 | EXISTING, must stay green | Regression. See section 3. |

Mutation checks, by hand in a Node shim, run per slice (scripts not committed, results written here): every precedence swap in `classify`, every dropped fail-closed branch, the clamp, the zero-delete, the digit rule, the 6-digit cap, the sort order, the NFC step, the lower-case step, the token rule (any versus every), the `MAX_LINES` value, the `bumps` versus `adds` split. A mutant that survives gets a new test before the slice merges. Target: all killable mutants killed, survivors listed with the reason.

## 2. Functional, rules, e2e

- **Functional:** the pure helpers are driven together in Node: a catalog of 300 generated products through `filter`, then `summarize` with every guard, then a `PickerDraft` build, then `commitPlan` applied to an order, then the result through the REAL `CompletionPlan.build` (loaded as text, Skill 83) to prove the order completes, and that `MAX_LINES` new lines stay under `MAX_OPS`. Planned in S1 as Task 4b (added to the S1 plan when it is executed) `functions/test/pickerFlow.test.js` (about 8 cases: happy path, hidden products never reach the draft, a draft that outlives a filter change, a product that goes out of stock mid-draft and is reconciled, an order at the line limit, a product spread over many batches that exceeds `MAX_OPS` and is refused by `CompletionPlan` as `too-many-ops`, repeated product across two commits, completed-order edit). Status: PLANNED.
- **Rules:** unchanged. The picker reads data the app already reads and writes through the same add-line code, so no Firestore rule changes. A rules test is not written, and this plan says so rather than pretending.
- **E2E:** one emulator test in S4, `tst_PickerOrdersE2E` (CI only): build an order from a `PickerDraft` commit and complete it through the real gateway path, checking stock, batches and the sale record. Planned, CI only. A second one for Edit Order on a completed order checks the booked tax stays on existing lines.

## 3. Regression (must stay green on every slice)

`tst_NewOrderDialogSubmitGuard`, the order completion double-submit and parked-write guards (`tst_DataModel_completeOrderReentrancy`, `tst_DataModel_completeOrderParkedGuard`), the completed-order tax tests, the pending-mint and top-up tests (`StockBatchStore`), `tst_ParkedWriteGuard`, the `BottomSheet` footer and sheet tests (`SheetFooter`), the full Node suites (`functions` after `npm ci`, and `node --test .github/scripts/__tests__/*.test.js`), and the QML suite in CI. A new regression test pins that a pending-mint product is never pickable (`PICK-05`, and an S3 wiring pin).

## On-device test plan (Taher, after S3 and again after S4; needs an app build, which Taher decides)

### Prerequisites

| # | Prerequisite |
|---|---|
| P1 | A tenant with at least 60 products across 3 or more categories, SKUs set on some and not on others, one product with a Devanagari name, one with an accent in the name, one with a name containing `(` and `.`. |
| P2 | At least 3 products with stock 0, 2 with stock 1, and 1 with stock 500. |
| P3 | At least 3 products with a photo and 3 without. |
| P4 | A way to go offline (airplane mode) and back. |
| P5 | One pending order with 2 lines, and one completed order with a discount and booked tax on a line. |
| P6 | For the hidden cases: a product with an unsynced edit (edit it while offline and do not reconnect), a product with a restock just queued (after R4, otherwise skip and note it), a product just created while offline (pending mint). |

### Happy path
1. New Order, tap the product trigger. Expect the sheet to open at 92% height with the search field, category chips, in-stock-only toggle and the list. The footer is pinned and shows "0 items" with the Add button disabled.
2. Tap `+` on three different products, then `+` twice more on one. Expect the row counts 1, 1, 3 (as set), the footer shows the right item count and total, the Add button is enabled.
3. Type in the number field of a row, `7`. Expect 7 (or the cap if stock is lower, with a visible "max" state).
4. Tap Add to order. Expect the sheet to close and the order to hold exactly those lines and quantities, the total to match the footer, and any existing line to be increased, not replaced.
5. Open the sheet again. Expect "in this order: N" on the products just added and the row counts reset to 0.
6. Repeat steps 1 to 5 in Edit Order on a pending order. Expect the same, with available stock = stock minus units already on the order.
7. Edit Order on the completed order from P5: add 2 of a product already on it. Expect the line quantity to rise by 2, the discount and booked tax of that line unchanged, and no line removed.
8. Place or save the order. Expect it to complete (or stay pending) exactly as it did before the picker.

### Negative
9. Search for text that matches nothing. Expect a plain empty state with the text and a way to clear it, not a blank sheet.
10. Open the sheet with the draft empty and tap outside or the close control. Expect it to close with no question.
11. Set a quantity, then close. Expect a confirmation "Discard N items?". Cancel keeps the sheet and the draft. Discard closes and leaves the order unchanged.
12. Try to raise a row past its stock. Expect the quantity to stop at the maximum, never above.
13. Try the out-of-stock products from P2. Expect them shown, disabled, with the words "Out of stock". They cannot be incremented.
14. Products from P6 (unsynced edit, pending mint, queued restock). Expect them hidden in BOTH New Order and Edit Order, the same way, and the footer line "N products hidden while they sync" when the search matches one. Reconnect and wait. Expect them to appear without reopening the sheet (live refresh).
15. Type letters, `-`, `.`, `e`, an empty string and 7 digits into a quantity field. Expect the draft to ignore everything except a valid whole number up to 6 digits.

### Edge cases
16. Search by product ID, by SKU, by category word, by two words that match different fields (`cherry veg`), by a Devanagari prefix, by an accented word typed without the accent in the same form, and by `(`, `.*`, `[`. Expect sensible matches, no crash, regex characters taken literally.
17. Search, set a quantity on a row, change the search so the row disappears, clear the search. Expect the quantity still there (the draft survives filtering).
18. Change the category chip with a draft. Expect the draft to stay. In-stock-only on and off with a draft. Same.
19. While the sheet is open, change stock from another device (or complete another order) so a drafted product goes out of stock. Expect the draft to be clamped or the row removed, never a quantity above stock.
20. Add 60 different new products to one order. Expect the "order full" state on the 61st new product: disabled with the reason, while rows already on the order or in the draft stay usable. Complete the order. Expect success.
21. A product with a very long name, a very long category, an ID of 20 characters. Expect clean truncation, no overlap with the stepper.
22. Font scale at the largest system setting, and a narrow phone. Expect no clipped text and touch targets of at least 48 dp.
23. Rotate the phone with the sheet open and a draft. Expect the draft kept (or, if the app is portrait-only, no crash).
24. Dark and light themes. Expect readable contrast on the disabled and hidden-count text, and states that are never shown by colour alone.
25. TalkBack on: each row reads name, ID, price, availability and quantity; the stepper buttons say what they do.

### Multiple scenarios
26. Two orders in a row: New Order with a picker commit, then Edit Order on the same products. Expect "in this order" and the stock numbers to agree between the two dialogs.
27. Open New Order, go offline, add products, come back online. Expect nothing lost and no duplicate lines.
28. Switch tenant or sign out and in with the sheet closed, then open it. Expect the catalog of the current tenant only.
29. Add the same product twice in one session, once through the picker and once through the old cart quantity control. Expect one line with the sum.

### Monkey
30. Tap `+` and `-` as fast as possible on one row for 20 seconds. Expect no crash, the count always between 0 and the maximum, the footer always equal to the sum.
31. Type and clear the search rapidly, switch chips and the toggle at the same time. Expect no flicker loop and no blank list that stays blank.
32. Open and close the sheet 30 times quickly, with and without a draft. Expect no stuck dim layer and no second sheet.
33. Background the app with the sheet open for a minute, return. Expect the sheet and draft as left, or a clean close with no crash.
34. Kill the app with a draft. Expect the order unchanged on restart (the draft is not saved, by design).
35. Scroll a 60+ row list fast with a draft and images loading, on a weak network. Expect smooth scrolling, rows showing the initial avatar until the photo arrives.

### Affected areas
| Area | What to check |
|---|---|
| New Order totals and discount | A picker commit gives the same totals as adding the same lines by hand. |
| Auto-approve on New Order | Stock is deducted once, never twice. |
| Edit Order on a completed order | Booked tax and discount are unchanged on existing lines. |
| Order approval (completion) | A picker-built order completes; one with too many lines is refused with the "too many changes" cause, not a crash. |
| Other bottom sheets | Open every sheet that uses `BottomSheet`: scrolling and footers behave as before (`scrollBody` default is true). |
| Inventory page, restock, product delete | Unchanged. |

### Regression
Run the existing New Order, Edit Order, approve-all and restock checks from the previous on-device plans after S3 and after S4. Any difference from before is a bug in this slice.

## Verification status block (fill in per slice)

| Slice | Node RUN | QML CI | Mutants | Coverage | On-device |
|---|---|---|---|---|---|
| S1 | not yet | not yet | not yet | not yet | n/a (dormant) |
| S2 | not yet | not yet | not yet | not yet | n/a (dormant) |
| S3 | not yet | not yet | n/a | n/a (view layer) | not yet |
| S4 | not yet | not yet | n/a | n/a (view layer) | not yet |
| S5 | not yet | not yet | n/a | n/a | not yet |

## Known gaps stated up front
- No line coverage number exists for the Felgo view layer.
- The real device scroll performance with images is only observable on a device (step 35).
- The "queued restock" hide reason cannot be exercised until R4 lands; until then only its helper hook is tested.
- Keyboard behaviour over a nested sheet on a device has never been verified (audit section 12).
