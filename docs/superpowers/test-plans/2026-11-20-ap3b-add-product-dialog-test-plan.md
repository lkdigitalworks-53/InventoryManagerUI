# Test plan: AP3b, the Add Product sheet (strict form, limits, "Use" supplier, safe submit)

Design: `specs/2026-11-20-ap3b-add-product-dialog-design.md`. Branch `feat/2026-11-20-ap3b-add-product-dialog`.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/addProductForm.test.js` (new) | 19 | RUN 19/19, mutation-checked | (sweep 1 of PR 207 added FM-12b pill/Save grid parity, FM-12c markup never below cost, FM-12d too-large vs invalid texts, FM-13b floor price through the real server); FM-1/2 parsers (accept, refuse, hostile); FM-3 exact arguments; FM-4 each refusal text; FM-5 all errors in field order; FM-6 markup; FM-7 price vs cost; FM-8 tax and stock edges; FM-9 limits on trimmed text at the edge; FM-10 supplier; FM-11 hostile whole form; FM-12 pill and its parity with Save; FM-13 constants and the largest form through the real planner and server; FM-14 4000-form monkey with an independent oracle, both outcomes and every error text reached; FM-15 source guard (no lenient parser, no clock, no store) |
| `functions/test/addProductDialogSubmit.test.js` (new) | 18 | RUN 18/18, mutation-checked | (sweep 1: SB-17 a throw in setLastUsed, the photo queue or the toast after the answer never skips close; SB-18 source shape); the REAL `trySubmit` and `_useTypedParty` in a vm: SB-1 happy; SB-2 refusal never raises busy; SB-3 to SB-6 refused, queued, unconfirmed, applied with a photo; SB-7/8 supplier; SB-9/10 throw before and after the answer; SB-11 values captured at the tap; SB-12/13 Use; SB-14 to SB-16 source pins and the real `addProduct` parameter list |
| `tests/tst_AddProductForm.qml` (new, CI) | 12 functions | CI only (twin run in a throwaway Node harness: 10 of 10) | the pure cases in the QML engine |
| `functions/test/sheetBusyOverlay.test.js` SB-4 | edited | RUN | the submit pin now reads `!form.ok` and "settled, then busy dropped"; same invariant, not weakened |

## 2. Regression tests
Full functions suite RUN 2021/2021 (was 1990 on main plus 31 new); `.github/scripts` 1061/1061. QML suite is CI.

## 3. E2E (emulator, CI only)
No change: e2e helpers call `InventoryStore.addProduct` directly, which is unchanged.

## 4. Rules
Unchanged.

## On-device test plan (Taher; needs a build of this branch; functions with AP1 already deployed; online phone, owner login)
Prerequisites: at least one category, one supplier named "Acme Farms", the Inventory tab open.

### Happy path
1. Tap Add product. Expect: "Advanced" open, "Reorder at" hint 0, "Initial stock" shows a numeric keypad.
2. Name "Tomato", tap Gen, cost 20, price 30, stock 5, Save. Expect: overlay "Adding product", toast "Product added", sheet closes, list shows Tomato stock 5.
3. Add "Rice": cost 33, switch the pill to %, markup 10. Expect pill "Selling price ₹36 · profit ₹3.00". Save, open Rice: price 36.
4. Add "Beans", tap + beside Supplier, type "Zed Traders", tap Use. Expect: row closes, combo reads "New: Zed Traders", note says it will be added when you save. Save. Expect Suppliers lists Zed Traders once, Beans and its batch carry it.
5. Add "Peas", tap +, type "acme farms", tap Use. Expect the picker selects "Acme Farms"; no second supplier after Save.

### Negative
6. Add "Orphan", Use "Orphan Co", turn on airplane mode, Save. Expect the offline text and NO supplier "Orphan Co" in Suppliers (was an orphan before AP3b).
7. Stock "2.5", Save. Expect "Enter the opening stock as a whole number (0 if none)"; nothing saved. Then stock "5000000": expect "Opening stock is too large. Use at most 1000000" (NOT the whole-number text).
8. Cost "12abc", then "1e3", then "1,5", then "-5". Expect "Enter a valid cost" each time and the pill "Markup —".
9. Cost 30, price 29. Expect "Price < cost".
10. Type "Foo" in the new-supplier field and Save without Use. Expect "You typed a new supplier name. Tap Use to add it, or clear the field".
11. Tax: Taxable with the % blank, then 101. Expect "Enter a valid tax % (0–100)".
12. Empty name, empty SKU, junk cost. Expect all three messages joined by " · ".

### Edge cases
13. Paste 150 characters into Name, 60 into SKU, 600 into Description. Expect each cut at 100, 40, 500 (device check of `maximumLength` on paste).
14. Stock 1000000 saves; 1000001 is refused with "Opening stock is too large. Use at most 1000000"; reorder 1000001 is refused with "Reorder level is too large. Use at most 1000000".
15. Leave Reorder blank, Save, open the product: reorder 0.
16. Use "Temp Co", close the sheet without saving, reopen. Expect no "New:" label.
17. After Use, pick a supplier from the combo. Expect "New:" disappears and the picked supplier is saved.
18. Add a photo and Save online. Expect the photo attached. On a very slow link expect the toast to say the photo was not attached.
19. Double tap Save fast. Expect ONE product.

### Affected areas / Regression
20. Restock dialog "Use" row, Edit product, New order picker, Suppliers list behave as before.

### Monkey
21. For two minutes: paste junk into every field, rotate, switch apps mid-Save, toggle airplane mode, tap Save repeatedly. Expect no stuck overlay, no duplicate product, no crash, every message readable.


### Sweep 1 of PR 207 (price pill, markup floor, too-large texts, safe close)
22. Happy: cost 10.40, switch the pill to %, markup 0. Expect the pill "Selling price ₹10.4 · profit ₹0.00"; Save; open the product: selling price 10.4 (before the fix Save said "Price < cost").
23. Negative: cost 1000, markup 100000000. Expect the pill "Selling price —" (it used to show ₹1000001000) and, on Save, "Markup is too high. The selling price must be at most 1000000000".
24. Negative: cost 2000000000, then price 2000000000 (flat mode). Expect "Cost is too large. Use at most 1000000000" and "Price is too large. Use at most 1000000000", not "Enter a valid ...".
25. Edge: markup mode with cost 0 and markup 20. Expect "A markup needs a cost above 0". Flat mode, cost 10, price 0: the pill shows "Markup —" and Save says "Enter a valid price".
26. Multiple scenarios: markup 0.05 on cost 100.4 gives price 100.4; markup 10 on cost 33 gives 36; markup 12.5 on cost 7.5 gives 8. Switch between flat and % several times with the same digits; the pill and Save always agree.
27. Safe close: add a product with a photo, deny the storage permission, Save. Expect the product is added, the toast says the photo was not added, and the sheet CLOSES (no filled form left to tap Save on again).
28. Monkey: paste a 400-digit number into Cost, Price, Stock and Reorder; type "." "5." ".5" "0" "00"; Save each time. Expect a readable message each time, never a stuck overlay, never a crash.

## 5. CI result
Head `ffe3a28` (rebased onto main@6951b1d): QML, Functions, Rules, E2E and PR Test Summary all green; the QML twin `tst_AddProductForm.qml` ran in CI. The dialog itself is device-only (steps above).
