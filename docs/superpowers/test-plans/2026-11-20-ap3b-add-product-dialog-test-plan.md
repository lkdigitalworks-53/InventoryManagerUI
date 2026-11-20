# Test plan: AP3b, the Add Product sheet (strict form, limits, "Use" supplier, safe submit)

Design: `specs/2026-11-20-ap3b-add-product-dialog-design.md`. Branch `feat/2026-11-20-ap3b-add-product-dialog`.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/addProductForm.test.js` (new) | 15 | RUN 15/15, mutation-checked | FM-1/2 parsers (accept, refuse, hostile); FM-3 exact arguments; FM-4 each refusal text; FM-5 all errors in field order; FM-6 markup; FM-7 price vs cost; FM-8 tax and stock edges; FM-9 limits on trimmed text at the edge; FM-10 supplier; FM-11 hostile whole form; FM-12 pill and its parity with Save; FM-13 constants and the largest form through the real planner and server; FM-14 4000-form monkey with an independent oracle, both outcomes and every error text reached; FM-15 source guard (no lenient parser, no clock, no store) |
| `functions/test/addProductDialogSubmit.test.js` (new) | 16 | RUN 16/16, mutation-checked | the REAL `trySubmit` and `_useTypedParty` in a vm: SB-1 happy; SB-2 refusal never raises busy; SB-3 to SB-6 refused, queued, unconfirmed, applied with a photo; SB-7/8 supplier; SB-9/10 throw before and after the answer; SB-11 values captured at the tap; SB-12/13 Use; SB-14 to SB-16 source pins and the real `addProduct` parameter list |
| `tests/tst_AddProductForm.qml` (new, CI) | 10 functions | CI only (twin run in a throwaway Node harness: 10 of 10) | the pure cases in the QML engine |
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
7. Stock "2.5", Save. Expect "Enter the opening stock as a whole number (0 if none)"; nothing saved.
8. Cost "12abc", then "1e3", then "1,5", then "-5". Expect "Enter a valid cost" each time and the pill "Markup —".
9. Cost 30, price 29. Expect "Price < cost".
10. Type "Foo" in the new-supplier field and Save without Use. Expect "You typed a new supplier name. Tap Use to add it, or clear the field".
11. Tax: Taxable with the % blank, then 101. Expect "Enter a valid tax % (0–100)".
12. Empty name, empty SKU, junk cost. Expect all three messages joined by " · ".

### Edge cases
13. Paste 150 characters into Name, 60 into SKU, 600 into Description. Expect each cut at 100, 40, 500 (device check of `maximumLength` on paste).
14. Stock 1000000 saves; typing a 7th digit is not accepted (or 1000001 is refused).
15. Leave Reorder blank, Save, open the product: reorder 0.
16. Use "Temp Co", close the sheet without saving, reopen. Expect no "New:" label.
17. After Use, pick a supplier from the combo. Expect "New:" disappears and the picked supplier is saved.
18. Add a photo and Save online. Expect the photo attached. On a very slow link expect the toast to say the photo was not attached.
19. Double tap Save fast. Expect ONE product.

### Affected areas / Regression
20. Restock dialog "Use" row, Edit product, New order picker, Suppliers list behave as before.

### Monkey
21. For two minutes: paste junk into every field, rotate, switch apps mid-Save, toggle airplane mode, tap Save repeatedly. Expect no stuck overlay, no duplicate product, no crash, every message readable.

## 5. CI result
Head `ffe3a28` (rebased onto main@6951b1d): QML, Functions, Rules, E2E and PR Test Summary all green; the QML twin `tst_AddProductForm.qml` ran in CI. The dialog itself is device-only (steps above).
