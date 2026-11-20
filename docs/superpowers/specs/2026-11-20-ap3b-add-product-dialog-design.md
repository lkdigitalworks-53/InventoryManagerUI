# Step 2, slice AP3b: the Add Product sheet stops what the planner refuses, and the typed supplier joins the operation

Date 2026-11-20. Branch `feat/2026-11-20-ap3b-add-product-dialog`, cut from `main` @ `0ce6534` (#202, #203, #204 merged). Contract: `specs/2026-11-13-add-product-atomic-operation-design.md`, `specs/2026-11-16-ap3a-add-product-wire-design.md` section 6 (the AP3b checklist). This file records only what AP3b decides on top of them. All decisions are vetoable in the PR.

## 1. Scope
**Built:**
- `AddProductFlow.fromForm` (pure): reads the sheet's field TEXT and returns the arguments of `InventoryStore.addProduct`, or every problem at once. `moneyFromText`, `wholeFromText`, `priceSummary` (the live pill) and the limits (`MAX_NAME`, `MAX_SKU`, `MAX_SIZE`, `MAX_DESCRIPTION`, `MAX_MONEY`, `MAX_STOCK`).
- `AddProductDialog`: Save reads the form through `fromForm`; the inline supplier row is R5a's "Use" (a typed new name is held and travels in the operation; nothing is minted before the add); `trySubmit` has the `try/catch` + `settled` shape of `RestockDialog._confirm`; `maximumLength` on the text fields; digits hint on the stock fields; the dead `productCreated` signal and `getSellingPrice` are removed.
- Closes KNOWN-ISSUES 44 (dialog values the planner refuses) and 47 (supplier minted before the add), and 56(b) (dead signal).

**Not built (on purpose):** fractional stock (D-AP3b-2), an offline check in the dialog, a role guard in the dialog, the Edit Product sheet (same lenient parsing, own slice), a photo for a queued add (needs an id; AP4 / later).

## 2. Evidence read
`AddProductDialog.qml` whole, `AddProductFlow.js`, `AddProductPlan.js` (what it refuses), `RestockFlow.js` (`costFromText`, `partyFor`, `newPartyChoice`, `unusedPartyText`, limits), `RestockDialog.qml` (`_confirm`, `_useTypedParty`), `InventoryStore.addProduct`, `AuthTextField` (`maximumLength` alias), `sheetBusyOverlay.test.js` (pins the old submit), `restockDialogConfirm.test.js` (the vm technique).

## 3. Decisions (trade-offs stated; each vetoable)
**D-AP3b-1: all form decisions move into one pure function.** Alternative: patch the QML in place (fewer files). Rejected: the old `trySubmit` could not run in Node, so every earlier bug in it was found on a device. Cost: one more helper surface (about 110 lines).

**D-AP3b-2: stock and reorder level are WHOLE numbers; "2.5" is refused, not cut.** The old `parseInt("2.5")` stored 2 with no message (silent data loss). Options: (A) whole only [chosen]; (B) fractions allowed for Kg, Litres, Metres; (C) fractions always. Why A: Restock takes whole units (SpinBox 1 to 9999), the picker and the Save check use whole units (S5b), and KNOWN-ISSUES 58 (Q4) shows a fractional stock already produces orders that complete but cannot be saved untouched. B is a real product feature (restock, picker, orders, reports) and needs its own design. Cost of A: a person who sells by weight cannot enter 2.5 kg. **Question for Taher: do you sell any item by weight or volume?** If yes, B is the next slice and A is only the stop-gap that makes the loss visible.

**D-AP3b-3: numbers are plain decimals only.** No sign, no exponent, no hex, no comma ("1,5" is refused, not read as 1). Same rule as the restock cost field. Cost: a keyboard that types a decimal comma cannot enter a fraction; the app's own `Constants` and the pills already use ".".

**D-AP3b-4: the app's own limits.** Price and cost at most 1e9 (= `RestockFlow.MAX_UNIT_COST`, one source), stock and reorder at most 1,000,000, name 100, SKU 40, size 40, description 500 characters, supplier name 100 (R5a). No server rule exists for any of them; the planner only refuses an overflow, so a finite 30-digit price was stored. Cost: a legitimate larger value is refused (raise the constant). Old and imported products may already exceed the text limits; the Edit sheet is unchanged.

**D-AP3b-5: blank reorder level is 0, and the hint now says 0** (it said 2 while the code stored 0). Alternative: make the default 2 (a product decision, changes stored data). Blank opening stock stays refused ("0 if none"): an explicit 0 beats a forgotten field.

**D-AP3b-6: the supplier row is "Use" (R5a).** Old "Save" minted and created the supplier before the add, so a failed add left an orphan supplier and burned a number. Cost: the new supplier is not in the picker until the add syncs; a second add with the same new name while the first is queued is refused by the store (D-AP3-8).

**D-AP3b-7: `trySubmit` catches.** A throw between `busy = true` and the answer left the full-sheet overlay on forever (the PR #183 bug class, fixed for Restock only). Values are read once at the tap; the answer handler uses those, not the controls (the old one re-read the category combo).

**D-AP3b-8: the pills use the same parser as Save**, so a pill never shows a price Save refuses or reads differently (`1e3` showed 1000 before).

**D-AP3b-9: pre-existing rules kept, not decided here:** "Price < cost" refuses a sale price below cost; markup mode rounds to a whole rupee; the sale price must be above 0. **Question for Taher: should a clearance item below cost be allowed?**

**D-AP3b-10 (review sweep 1 of PR 207): the markup price is never below the cost.** `Math.round` alone put a cost of 10.40 at 0% markup at 10, below the cost, and Save refused "Price < cost" for a markup the person had set to zero. Options: (A) `max(round, cost)` [chosen]: only results that were refused before change (cost 10.40 at 0% is 10.40; every accepted price is the same whole rupee as before); (B) `Math.ceil`: never below cost, but changes accepted prices (cost 100 at 10.4% gives 111, not 110); (C) keep the refusal and reword it: leaves 0% unusable on a fractional cost. Cost of A: in that one edge the stored price is not a whole rupee. Same sweep: one resolver (`_resolvePrices`) reads the cost and price fields for both Save and the pill, so the pill cannot show a price Save refuses; too-large values get their own texts that name the limit.

## 4. What the tests prove
`addProductForm.test.js` (15): parsers by table, every refusal, all errors in field order, markup, tax, limits at the edge, supplier cases, pill parity with the price Save sends, the largest accepted form through the real planner and server, a 4000-form monkey whose independent oracle agrees on accept or refuse, every accepted form accepted by the real server, every error text reached. `addProductDialogSubmit.test.js` (16): the REAL `trySubmit` and `_useTypedParty` bodies in a vm: arguments and order against the real store signature, every answer, supplier cases, throws before and after the answer, values captured at the tap, source pins. `tst_AddProductForm.qml` (10) for the QML engine (CI). 12 hand mutants on the new code: 11 killed, 1 proven equivalent and the redundant line removed.

## 5. Deploy and compatibility
Client only. No functions deploy, no rules change, no stored-data change. Revert is safe.
