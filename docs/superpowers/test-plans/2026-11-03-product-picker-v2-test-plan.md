# Test plan: product picker v2 (searchable sheet with quantity steppers, New Order and Edit Order)

Design: `specs/2026-11-03-product-picker-v2-design.md` (approved 2026-11-03). Audit and trade-offs: `specs/2026-11-03-product-picker-v2-audit-and-decisions.md`. First plan: `plans/2026-11-03-product-picker-v2-s1-pure-helpers.md`. Standard format (Skill 49).

**Honesty note.** Written before implementation. Slices S1 and S2 are now built and their status is below (RUN means run in the sandbox, with the count from that run). Everything for S3 to S5 is still PLANNED and nothing there has been run. The QML twins have NOT been run (no Qt in the sandbox): CI is their only oracle, and a "CI OBSERVED" line is added below once CI has answered. Counts are recounted with `grep -c "function test_"` for QML and by counting `test(` rows for Node, never copied from this plan.

**What 100% means here (Skill 83).** The three pure helpers (`ProductSearch.js`, `ProductPickability.js`, `PickerDraft.js`) and `PickerRowGeometry.js` are covered at 100% of lines and branches, checked in Node with `c8` against the real helper text. The Felgo-dependent QML (`ProductPickerSheet.qml`, `ProductPickerRow.qml`, the trigger button, `BottomSheet.scrollBody`, the two dialogs) cannot be loaded by `qmltestrunner`, so line coverage cannot be measured there. That layer is covered by wiring tests that read the QML source and run the pure helpers, plus the on-device plan below. This plan does not claim 100% for code that cannot be measured.

## Slices and status

| Slice | What lands | Behaviour change | Status |
|---|---|---|---|
| S0 | Audit, decisions, design, this plan, S1 plan | none (docs) | docs pushed |
| S1 | `ProductSearch.js`, `ProductPickability.js`, `PickerDraft.js`, dormancy test | none (nothing calls them) | BUILT on `feat/2026-11-03-picker-s1-pure-helpers`, reviewed and hardened 2026-11-04; Node RUN 132/132 (picker files); QML twins CI only |
| S2 | `PickerRowGeometry.js`, `PickerSheetModel.js` (added, plan S2-D1), `ProductPickerSheet.qml`, `ProductPickerRow.qml`, `BottomSheet.scrollBody` and `guardClose` | none (nothing opens the sheet) | BUILT on `feat/2026-11-04-picker-s2-sheet-component` 2026-11-04; Node RUN 189/189 (picker files); QML twins and the Felgo layer CI and device only Review sweep of #187 (2026-11-09): functions suite 1354/1354, 22 further hand mutants all killed (first run 21, one test added), QML, Functions and Rules CI green on `5144722`. |
| S3 | New Order wired; `productNames`, `_pickerProducts`, `_rebuildPickerNames` deleted; dry run of the completion size (`commitCheck`); `StockBatchStore.mintRevision` | New Order picker changes | BUILT on `feat/2026-11-11-picker-s3-new-order` 2026-11-11; Node RUN (picker and New Order files 251/251, functions suite below); QML twins and the Felgo layer CI and device only |
| S4 | Edit Order wired; `catalog` kept for legacy seeding and the booked-tax rule | Edit Order picker changes | PLANNED |
| S5 | Sweep, accessibility, performance, full on-device pass | none or fixes | PLANNED |

## 1. Unit tests

| File | Cases | Slice | Status | Covers |
|---|---|---|---|---|
| `functions/test/pickerSearch.test.js` | 39 (`SRCH-01..38` plus `SRCH-10b`) | S1 | RUN 39/39 | Empty, blank, null and undefined query keep catalog order. Case-insensitive. Match by ID, by SKU, by category. Every word must match, words may match different fields. Ranking: exact ID or SKU, ID or SKU prefix, word prefix in name, substring in name or category, substring in ID or SKU; ties by name then catalog order. Regex characters are literal (`.*`, `(`, `[`, `\`). Devanagari. NFC against decomposed accents, both directions. Missing fields, numeric ID. Junk entries (`null`, `5`, `"x"`, `[]`) skipped. Category filter (`All`, empty, unknown). Query of 10,000 characters returns in under 500 ms (was 50 ms; loosened because a loaded CI runner could flake it). Input frozen, never mutated. Seeded monkey of 400 rounds. |
| `functions/test/pickerPickability.test.js` | 34 (`PICK-01..34`) | S1 | RUN 34/34 | Enabled with stock; disabled out of stock for 0, negative, NaN, string, Infinity; fractional stock floors. Hidden for pending mint, queued restock, unsynced edit (`pending` and `parked`), delete in flight. Precedence of the four hide reasons, and hidden beats out-of-stock. Order-full only when the limit is reached AND the product is neither in the order nor in the draft; out-of-stock beats order-full. Fail closed: no `availableFor`, no context, a throwing hook, junk products. `inOrder` and `inDraft` junk becomes 0. `summarize`: counts, order preserved, `inStockOnly`, junk input, junk entries. Input frozen. Seeded monkey of 400 rounds. |
| `functions/test/pickerDraft.test.js` | 43 (`DRFT-01..42` plus `DRFT-10b`) | S1 | RUN 43/43 | `parseQty`: digits only, 15 junk shapes refused, 6-digit cap. `setQty`: normal, clamp to `maxQty`, zero deletes, junk text leaves the draft, `maxQty` 0 or junk removes the key, hostile IDs (`__proto__`, empty, number, null). `step`: up, down to zero, cap, below zero, junk delta. `totals`: items, lines, amount rounded to 2 decimals, junk prices. `commitPlan`: adds versus bumps, sorted by product ID, corrupt draft entries ignored, `qty` and `quantity` lines both recognised. `lineCountAfter`, `lineLimitReached`. `reconcile`: clamp, remove, missing function drops everything. **Drift guard `DRFT-26`:** reads `MAX_OPS` from `qml/helper/CompletionPlan.js` and `functions/lib/operationLogic.js`, requires them equal and `3 * MAX_LINES + 1 <= MAX_OPS`. Seeded monkey of 400 rounds. |
| `functions/test/pickerDormancy.test.js` | 6 (`DORM-01..03`, `PAIR-01..03`) | S1 | RUN 6/6 | `PAIR-01` fails if a QML twin differs from what the Node test derives, `PAIR-02` if a case ID is missing. Nothing outside the helpers and their tests mentions them (S3 changes this on purpose, in its own PR). Pragma-library shape: no Felgo, no singleton tokens. Names absent from `qml/helper/qmldir`. |
| `tests/tst_ProductSearch.qml`, `tst_ProductPickability.qml`, `tst_PickerDraft.qml` | 39, 34 and 42 functions (every Node row except `DRFT-26`), derived from the Node files by `functions/test/testSupport/pickerTwin.js`; shared data in `tests/pickerFixtures.js` | S1 | WRITTEN, CI ONLY | The Node rows again in the QML engine, because number and string handling can differ (the R3 `var long` compile error is the proof). Avoid reserved words in test code. |
| `functions/test/pickerRowGeometry.test.js` and `tests/tst_PickerRowGeometry.qml` | 13 (`GEOM-01..12` plus `GEOM-08b`) | S2 | Node RUN 13/13; twin CI only | `digitsOf` 1 to 6 and junk. Junk width or unit gives `ok: false`. Every touch target at least 48 units at six unit scales. Field widens for six digits. Stepper is three targets plus two gaps of at least 8. Pills beside the stepper at exactly the 64-unit floor and wrapped one unit below it, widths adding up exactly. `fits` false only when the stepper alone is wider than the card. Large system font widens the field and heightens the row; small or junk font scale counts as 1. Row at least one target plus padding high, taller when the pills wrap. Sizes scale with the unit. Seeded monkey of 1000 rounds with every invariant, asserting it reached both layouts and a too-narrow card. |
| `functions/test/pickerSheetModel.test.js` and `tests/tst_PickerSheetModel.qml` | 28 (`SHEET-01..26` plus `02b`, `05b`) | S2 | Node RUN 28/28; twin CI only | The sheet's view model. Junk input never throws. Catalog order, every row flat with every key and the right types. Exact plain row. Name falls back to the id, price prefers `sellingPrice`, photo is the first string id. Availability pill (N left, Low, a non-numeric minimum never makes a product low). The four hide reasons hide and are counted, with the note in singular and plural; the count only covers products matching the search and chip. Out of stock shown disabled with words, the toggle drops it, and an empty in-stock list says no match when the search is the cause. Order full disables only new products. The draft survives a search that hides its row. Reconcile clamps, drops products that left the catalog, went out of stock or became hidden. Totals. Commit gate (empty, ok, more than 60 lines) with its words. Six empty states. A long query is cut to 40 characters. Categories: All first, case-insensitive, sorted, junk skipped. `sameOrder`. Missing, partial or throwing hooks fail closed with words. Frozen inputs. Seeded monkey of 300 rounds asserting every outcome was reached. |
| `functions/test/pickerSheetWiring.test.js` | 16 (`WIRE-01..16`) | S2 | Node RUN 16/16 | Source pins for what qmltestrunner cannot load: `BottomSheet` opt-ins default off; the two `Binding`s act only when `scrollBody` is false; every close path goes through `requestClose`, busy first; nothing else in the app sets `scrollBody`, `guardClose` or `requestClose`; the sheet is a `BottomSheet` with the picker settings; the list is a `ListView` over a `ListModel`, never a `Repeater` or `ScrollView`; the row's required properties equal the view model's row keys and read no implicit `index` or `modelData`; the sheet calls the tested helpers and does not import the S1 helpers it no longer needs; the sheet reads only `InventoryStore.formatCurrency` from any store; every external input schedules one coalesced rebuild; commit order is re-read, gate, plan, hand over, close, with no discard question; close, discard question and reset on close; row targets come from the geometry, digits only and six at most, asks instead of editing; geometry and draft agree on six digits; dormancy of the new files; brace, parenthesis and bracket balance of the new and changed files. |
| `functions/test/newOrderPicker.test.js` and `tests/tst_NewOrderPicker.qml` | 24 (`NOP-01..24`) | S3 | Node RUN 24/24; twin CI only | `cartQty` (string id matches numeric line id, junk), `availableFor`, `priceOf` (0 allowed, every other non-number refused), `applyPlan` (add, bump, mixed order, clamp and report, sold out, gone, no price, invalid entries, two entries sharing stock, stale plan, input never changed, numeric ids, junk arguments), `skippedNote`, `opsCheck` (boundary 197 fits, 201 refused, exactly 200 fits, existing lines counted, size only, fail closed), seeded monkey with an exact oracle on a 60-product shop. |
| `functions/test/pickerSheetModel.test.js` (added) | +9 (`SHEET-32..40`) | S3 | Node RUN 42/42 | The optional `commitCheck` hook: absent is unchanged, asked once with the plan, refusal closes the gate with the words, junk results and throws refuse, not asked for an empty or full draft, sees the reconciled draft, footer lines survive, seeded monkey. |
| `functions/test/newOrderPickerWiring.test.js` | 16 (`NOW-01..16`) | S3 | Node RUN 16/16 | Combo and old helpers gone; one sheet with five inputs and one output; the six hooks wired to the owning stores; the revision is the four counters; `mintRevision`; `_applyPicked`; the button; close handling; only New Order uses the sheet; submit check intact; the dry run's sale stand-in pinned to `buildSaleDocs`; real planner, no copied limit; balanced files; AND the real hook literal and `_applyPicked` run against the real helpers (hidden by the three guards, cart counted, plan applied, bump, drift clamped and reported, 49 lines fit and 50 refused through the sheet). |
| `functions/test/pickerOrderDetailWiring.test.js` | about 25 | S4 | PLANNED | `availableFor` is `_availableStock` for all three order states (pending, processing, completed); the completed-order commit goes through the existing add handler so booked tax is kept; `catalog` is still used for legacy seeding; the picker never calls a remove or reduce path (D4). |
| `tests/tst_NewOrderDialogSubmitGuard.qml`, `tst_DataModel_completeOrderParkedGuard.qml` and the completed-order tax tests | existing | S3, S4 | EXISTING, must stay green | Regression. See section 3. |

Mutation checks, by hand in a Node shim, run per slice (scripts not committed, results written here): every precedence swap in `classify`, every dropped fail-closed branch, the clamp, the zero-delete, the digit rule, the 6-digit cap, the sort order, the NFC step, the lower-case step, the token rule (any versus every), the `MAX_LINES` value, the `bumps` versus `adds` split. A mutant that survives gets a new test before the slice merges. Target: all killable mutants killed, survivors listed with the reason.

CI OBSERVED (S1): first push run: Functions 1083/1083, Rules 108/108, E2E 110/110 green; QML 2743/2744 red on ONE compile error, `tst_ProductSearch` had a method named `P` (QML refuses a method name starting with an upper-case letter). Fixed by renaming to `prod` in the Node file and regenerating the twin; `PAIR-03` added so Node catches it from now on (functions suite 1084, 97 picker tests). Second run (`ef2cd2a`): ALL GREEN. QML 2772/2772 (the three twins ran in the real QML engine and passed), Functions 1084/1084, Rules 108/108, E2E 110/110.

**S1 review sweep, 2026-11-04 (PR #185 rebased onto `main` @ `3a45c8b`, then reviewed by reading every changed line plus the code the helpers will be injected into; two independent read-only passes: one on the tests and the twin generator, one on the helper contracts against the dialogs).** What changed, and why:
- Helpers: product ids must be non-empty strings (numeric ids made a row that the draft silently refused to step); `hasPendingMint` and `unsyncedState` are required hooks (a missing one gives a disabled "unavailable" row, no longer "not hidden"); any `unsyncedState` answer other than `""` hides (an object or a typo cannot open the guard); `lineLimitReached` counts any truthy value; legacy order lines without a product id count one each toward the cap; `reconcile` and `totals` survive a throwing callback (drop / price 0); new `PickerDraft.canCommit` gate (`empty`, `too-many-lines`). Redundant guards deleted (an explicit hook typeof check, `_validId` and `Math.max` inside `step`, two `typeof` checks).
- Tests: 97 -> 132 picker Node tests (`SRCH` +11, `PICK` +9, `DRFT` +13, `FLOW` +2, `PAIR-02` stricter). The pickability monkey had never produced an enabled row; it now asserts that every outcome was reached. The `SRCH-10b` case had been missing from the QML twin since S1 (the id regex could not read `10b`); the twin now has it, and `PAIR-02` compares the raw `test(` count with the parsed count. The twin generator refuses a body that uses a Node-only name.
- Hand mutants: 99 (a script kept out of the repo); the first run left 10 survivors (1 real gap, 6 redundant guards that were deleted, 3 equivalent), after the fixes 3 survive, all equivalent (`n >= 0` before a `<= 0` check, a `__proto__` id guard whose assignment is a no-op on a number, a zero price adding 0).
- Carried to S3 and S4, not fixed here because the dialogs are not wired yet: see `docs/superpowers/KNOWN-ISSUES.md` ("Product picker v2: carried requirements"). The main one: `MAX_LINES = 60` is only an early stop, a line over two batches costs 4 operations (`FLOW-09` pins it), so the dialogs must dry-run `CompletionPlan`.
- Unrun until CI: the three regenerated QML twins (new cases use `JSON.parse`, `\u` escapes, `Number()`, `Array.join`).

**S2 build, 2026-11-04.** Hand mutants: 80 listed in a script kept out of the repo (geometry constants and boundaries, every branch of `build`, `sameOrder`, `categories`, the empty states, every row field). First run: 62 killed, 18 survivors. Five were test gaps and got cases (`inOrder` of 0 must not print "In this order: 0"; an enabled row must have blank reason text; a string `minStock` of "9" must not make a product Low; the exact 64-unit pill boundary; an `atMax` that must be false on a disabled row, and the in-stock toggle with a search that matches nothing). Six survivors were redundant code and were deleted (a `Math.max(1, ...)` around `String(n).length`, an `inDraft > 0` next to `enabled`, an `_has` in front of a lookup that already returns 0, an `_has` in front of a comparison of whole numbers). One fallback (words for an unknown reason code) became its own function `reasonTextFor` so a test can reach it. Six survivors were stale patterns in the mutant list itself ("NOT FOUND" is not a kill); the list was corrected. Final run: every listed mutant that applies was killed.

CI OBSERVED (S2): first push (`c135dbc`): QML 2926 passed, 1 failed. The one failure was `tst_PickerSheetModel::test_SHEET_26` in the QML engine, `Uncaught exception: Type error`, caused by the monkey writing `draft["__proto__"] = n` (Node ignores that write, the QML engine throws). Test-only fix `c12465d`: the monkey uses the own key `constructor`; the hostile-id cases stay in `DRFT-10` and `DRFT-10b`. Second run: ALL GREEN. QML 2927/2927 (both new twins ran in the real QML engine), Functions, Rules and E2E success. PR #187 `mergeable_state: clean`.

Not run until a device: `BottomSheet` with the new properties, the sheet and row as painted, the Back key. (The two derived twins ran in CI, see above.)

Was, before CI: the two derived twins; `BottomSheet` with `scrollBody: false` and `guardClose: true`; the sheet and row as painted; whether the Android Back key reaches the sheet's `Keys.onBackPressed` (if it does not, Back does nothing while the sheet is open: nothing is lost, but it is a defect to fix in S5).

## 2. Functional, rules, e2e

- **Functional:** the pure helpers are driven together in Node: a catalog of 300 generated products through `filter`, then `summarize` with every guard, then a `PickerDraft` build, then `commitPlan` applied to an order, then the result through the REAL `CompletionPlan.build` (loaded as text, Skill 83) to prove the order completes, and that `MAX_LINES` new lines stay under `MAX_OPS`. Built in S1 as `functions/test/pickerFlow.test.js`, `FLOW-01..10`, RUN 10/10 ( happy path, hidden products never reach the draft, a draft that outlives a filter change, a product that goes out of stock mid-draft and is reconciled, an order at the line limit, a product spread over many batches that exceeds `MAX_OPS` and is refused by `CompletionPlan` as `too-many-ops`, repeated product across two commits). The completed-order edit is covered in S4. Status: RUN 8/8.
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

### Slice S2 checks (need a build with the sheet reachable: S3 or a temporary entry point, Taher's call)
36. BottomSheet regression first, with no picker involved: open every sheet that uses `BottomSheet` (filters, export, notifications, sign-out, staff, product edit, restock, order detail). Expect scrolling, the pinned footer, the busy state, X, Cancel and tap-outside to behave exactly as before. `scrollBody` defaults to true and `guardClose` to false, so any difference is a bug in this slice.
37. Picker sheet, scrolling: with 60 or more products, scroll the list. Expect the list to scroll alone, the title, search, chips and footer to stay put, and no double scrolling.
38. Stepper taps: tap `+` on a row far down the list. Expect the list not to jump to the top and the row to update in place. Same for typing a number.
39. Back key (Android): with an empty draft expect the sheet to close; with a draft expect the discard question. Note what happens if nothing happens.
40. Tap outside the sheet with a draft: expect the discard question, not a close. Same for X and Cancel.
41. Keyboard: tap the search field, then a quantity field. Expect the footer and Add button to stay reachable (not hidden behind the keyboard), and the quantity the field shows to match the footer.
42. Type 50 into a row whose stock is 8. Expect the field to show 8 at once. Clear the field: expect it to come back to the row's quantity when you leave it.
43. Row at the largest system font and on a narrow phone: the pills drop under the text, the three stepper targets stay at least 48 dp, no clipped text.
44. Offline: rows show the initial letter instead of a photo, no broken image.
45. Open the picker and watch the first frames. Expect the rows to be there from the first frame of the slide-in, never a blank list that fills at the end (KNOWN-ISSUES item 13, fixed in sweep 3; if it still fills late, `Connections.onAboutToShow` did not fire).
46. Search with a very large catalog (the scale data), type fast. Expect the list to update about a moment after you stop typing, not per key, and no stutter. Note the delay and whether 150 ms feels slow or still janks (KNOWN-ISSUES item 14). Tap Clear search and close the sheet while typing: both must act at once and nothing rebuilds after close.
47. Double tap Add quickly, then single tap. Expect exactly one plan: the order gets the quantities once (not doubled), and no "Discard?" question appears while the sheet fades. Then reopen at once after Add: the sheet starts empty.
48. Tap `+` many times and type in a quantity field while watching the chips. Expect the chips not to flicker or jump back to the left.
49. TalkBack on: focus the "In stock only" row and double tap. Expect it to announce checked and filter the list; do it twice to switch back.
50. A kg product, a pcs product and a product with no unit: the price line reads "/ kg", "/ pcs", "/ pcs"; the pill reads "N kg left"; the field is announced "Quantity of X, in kg" by TalkBack. Try a long unit ("dozen boxes") at the largest font: the pill may wrap, the row must not clip.
51. Pick two items, tap Cancel and Discard, and reopen the picker at once during the fade. Expect an empty draft (no quantities, `0 items`), not the discarded one. Open it, change the catalog from another device while the sheet slides in: the list shows the new value without reopening.
52. Add, and while the sheet fades have the order change (a sync tick). Expect the fading sheet not to jump to the top or repaint.
53. TalkBack: swipe through the "In stock only" row. Expect ONE stop, announced "In stock only, checkbox", and one double tap to switch the filter once (twice would be KNOWN-ISSUES 19a). With a hardware keyboard, Tab must not land on a bare switch.

Covered in Node (no device): SHEET-27 `sameList`, SHEET-28 `changedRows` (happy, junk, length change, key sets, frozen inputs), SHEET-29 tap and refresh change one row, SHEET-30 seeded monkey of 300 rounds (patching the changed rows always equals the full rows), SHEET-31 unit (blank, junk, trimmed, long, labels, key set stable, input unchanged), GEOM-03/09/11/12 rewritten for the slimmer geometry (exact heights 128 and 160), WIRE-20 debounce, WIRE-21 unit in the row, WIRE-11, 12, 17 to 19 (latch order, close guards, reset, chips guard, changed-rows sync, one toggle function with both accessibility actions). Happy path, negative (junk lists and rows), edge (empty, length change, undefined values), multi-scenario (SHEET-29), monkey (SHEET-30). 22 + 17 hand mutants, all killed (one survivor, the row height, got an exact test).

### Slice S3 checks (New Order wired; needs a build, Taher decides)
54. Open New Order. Expect one full-width "Add products" button where the combo was; after a line exists it reads "Add more products". No combo, no plus button.
55. Open the sheet, search, set quantities with the stepper and by typing, tap Add to order. Expect the sheet to close and the lines to appear in the order with the product's selling price, the quantity picked, discount flat 0, and correct subtotal and total.
56. Open the sheet again and pick a product already on the order. Expect its quantity to go UP by the amount picked (not replaced) and its edited price and discount to stay. The row says "In this order: N".
57. A product with a mint outstanding, a queued restock, or an unsynced or parked edit must not be listed; the footer says how many are hidden. While the sheet is open, let the mint or restock land (go online): expect the product to appear without reopening the sheet.
58. A product with stock 0 is shown disabled with "Out of stock"; "In stock only" removes it.
59. Drift: with the sheet open and a quantity set, reduce that product's stock another way (a sale on a second device). Tap Add. Expect no more than is left on the order and a red line "Not added as picked. ..." on the order sheet.
60. A product with no selling price (edit one in the data if needed): expect it to be refused after Add with "has no selling price" and no line (KNOWN-ISSUES 23).
61. Close the sheet with a draft (X, Cancel, outside, Back): the discard question; "Keep picking" keeps it; Discard closes and the order is unchanged.
62. Open the sheet, then force the order sheet to close (sign out, session lock). Expect the picker to close with it and nothing to be left open.
63. Place an order after picking: unchanged flow (busy overlay, double tap guard, success closes). While placing, "Add products" is disabled.
64. Size check, needs seed data: a shop where products span two batches each. Pick 50 such lines (49 fit, 50 do not). Expect the footer to say the order has too many items (with counts) and Add to be off; remove lines and it comes back. On a big batch ledger, tap steppers quickly and note any lag (KNOWN-ISSUES 25).
65. After a long order, is the red "Not added" line visible without scrolling? If not, say so (KNOWN-ISSUES 24b).
66. Regression: Edit Order still has its combo and behaves exactly as before (S4 changes it).

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
| S1 | 97/97 (`node --test functions/test/picker*.test.js`); functions suite 1083/1083 and script suite 741/741 after `npm ci` | QML 2772/2772 green on `ef2cd2a` (first push red on one compile error, fixed) | 53 of 55 killed; 2 equivalent survivors (tie-break behind a stable sort; `__proto__` guard is a no-op for number values) | V8 block coverage 100% of the three helpers (a preload gives the vm-loaded text a filename; per-process JSON merged by union) | n/a (dormant) |
| S2 | picker files 189/189; functions suite 1237/1237 and script suite 905/905 after `npm ci` | QML 2927/2927 green on `c12465d` and on `4461cb9` (first push red on one twin case, `__proto__` write, fixed); sweep 3 changes no QML twin | 80 listed; first run 62 killed, 18 survivors (5 test gaps fixed, 6 redundant guards deleted, 6 stale patterns); final run all applicable killed | not measured for the Felgo layer; the two new helpers are covered by the same mutants and cases (c8 not re-run) | n/a (dormant, checks 36 to 44 apply once reachable) |
| S3 | picker and New Order files 251/251; see the PR for the whole functions suite | not yet (push pending at the time of writing) | 43 listed; first run 1 survivor (a real gap, fixed), final all killed | n/a (view layer; 14 wiring cases run the real glue) | not yet |
| S4 | not yet | not yet | n/a | n/a (view layer) | not yet |
| S5 | not yet | not yet | n/a | n/a | not yet |

## Known gaps stated up front
- No line coverage number exists for the Felgo view layer.
- The real device scroll performance with images is only observable on a device (step 35).
- The "queued restock" hide reason cannot be exercised until R4 lands; until then only its helper hook is tested.
- Keyboard behaviour over a nested sheet on a device has never been verified (audit section 12).
