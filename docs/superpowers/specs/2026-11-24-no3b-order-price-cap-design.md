# Step 3, slice NO3b: the New Order unit-price field reads plain decimals, caps at the app's price limit and says why it refused

Date 2026-11-24. Branch `feat/2026-11-24-no3b-order-price-cap`, cut from `main` @ `fc4eee5` (#217, NO3a, merged and device tested by the owner). Contract: `specs/2026-11-23-no3a-create-order-wire-design.md` section 1 ("Not built (NO3b)") and KNOWN-ISSUES 114.

## 0. Where the roadmap stood (read from `main`, 2026-11-24)
Done: step 1 restock (R1..R5b), step 2 add product (AP1..AP3b), step 3 new order: NO1 server (#208), NO2 planner (#212), NO3a wire (#217, device tested). Open: **NO3b (this)**; then `_tryAdjustOrder`, `_reverseCompletedOrder`, `completeImportedOrder` (each needs a design and the owner's rulings, Q-NO3-1); step 4 import chunking; G5 product delete and G9 account writes need their own designs; AP4 (the add-product device pass) is still the owner's.
NO4 (the device pass of the new-order arc) was done by the owner with #217; this slice adds one device check (section 7).

## 1. The problem (evidence, not memory)
`NewOrderDialog._setLinePrice` read the typed text with `parseFloat(String(value).replace(/[^0-9.]/g, ""))`:
| Typed | Stored (old) | What the person meant |
|---|---|---|
| `-5` | 5 | refused / 0 |
| `1e5` | 15 | 100000 or junk |
| `12abc` | 12 | junk |
| `1.2.3` | 1.2 | junk |
| `1,5` | 15 | 1.5 |
| blank, `abc`, `.` | old price kept, field reverts, **no word** | a correction |
| 20 digits | 1e20 (finite), planner refuses at Place order with a line-level text | a typo |
So a mistyped price was booked as a different price with no refusal, and a refusal was silent. NO2 added the planner guard (`bad-line` above 1e9) as the last line of defence; KNOWN-ISSUES 114 left the field itself for this slice.

## 2. Scope
**Built:**
- `OrderFlow.priceEdit(text, current, shown)` -> `unchanged | set(price) | refused(reason)`, and `OrderFlow.priceText(reason)` (`blank`, `invalid`, `large`). Pure, runs in Node and in qmltestrunner.
- `AddProductFlow.moneyState(text)`: a public name for the existing `_moneyState` (Add Product's one reading of a money field), so New Order reuses it instead of copying a regex.
- `NewOrderDialog`: `_setLinePrice` goes through `priceEdit`; a refusal keeps the old price and shows the text under the price row (danger colour, red 2 px border, announced as the field's description); the index guard is hardened.
**Not built (judged, section 5):** the discount field (same lenient reading, harm bounded by the totals' clamps), a decimal-places limit, any change to the planner or the server.

## 3. Decisions (all vetoable in the PR)
**D-NO3b-1 one reading of a price: Add Product's plain decimal** (digits, optional fraction, `5.` and `.5` fine; no sign, no exponent, no comma, no letters) with the limit `RestockFlow.MAX_UNIT_COST` (1e9). Options: (A) reuse it (chosen); (B) keep the lenient strip and only add the cap; (C) a new, more forgiving reader (accept `1,200`). Trade-off: A refuses `1,200` that the old code read as 1200, but the same old code read `1,5` as 15, and a reader that is right for one comma and wrong for the other is worse than one that asks. B keeps every silent mis-price in the table above. C needs a locale rule the app has nowhere else. A also makes the three money fields of the app (Add Product, Restock, New Order) agree, so a price accepted in one is accepted in the others.
**D-NO3b-2 text the field already shows is "nothing to commit", never parsed.** The field swaps its text between the plain number (focused) and the formatted display `₹1,20,000` (not focused), and `editingFinished` and `activeFocusChanged` can run in either order on a focus loss; Enter fires `accepted` AND `editingFinished`. Parsing the display would refuse `₹1,20,000` as junk and wipe a good price. So a text equal to the stored price or to the formatted display is `unchanged`: no parse, no message. Cost: a person who types exactly the old price gets no feedback (correct: nothing changed).
**D-NO3b-3 the message is inline under the price row, state kept in the row.** Options: (A) a `Text` under the row, delegate-local `priceError` (chosen); (B) a `Toast`; (C) one dialog-level `errorLabel` line. A: the message sits next to the field it is about, stays until the person acts, and the red border plus the text means colour is not the only cue. B: a toast disappears after a few seconds, names no line, and a screen reader user may miss it. C: with three lines in the cart it cannot say which price. Cost of A: the state lives in a row that is rebuilt whenever the cart changes (any quantity tap), so the message goes away then; that is acceptable because a refusal changes no line and the field has already reverted to the real price. The message clears when the field gets focus again and when a price is committed.
**D-NO3b-4 a price of 0 is allowed** (as before; the planner allows it too, `lp.price < 0` is the refusal). A free line is real (a gift, a sample). Recommendation against refusing: the Add Product form refuses a price of 0 because a catalogue price of 0 is almost always a typo, but an order line is a deliberate edit of one sale. Veto point: Q-NO3b-1.
**D-NO3b-5 no decimal-places limit.** `10.999` is accepted as before (Add Product accepts it too; `computeOrderTotals` rounds every total to 2 places). The display shows one decimal (`formatCurrency`, KNOWN-ISSUES), so a stored `10.999` shows as `₹11`: the old "rounded display is not the stored value" trap, unchanged here. Veto point: Q-NO3b-2.
**D-NO3b-6 the discount field is NOT changed in this slice.** It has the same lenient reading (`-5` stores 5, `1e2` stores 12) but the totals clamp it (a percentage to 0..100, a flat amount to the line's gross), so the worst outcome is a wrong discount, not a corrupt total or a refused order. Different field, different limits (percent vs amount), a separate decision. Logged in KNOWN-ISSUES.
**D-NO3b-7 `AddProductFlow.moneyState` is a public alias, not a copy.** One regex, one limit, one set of states. The alias is one line; `moneyFromText` keeps its callers.
**D-NO3b-8 the index guard is hardened as part of this function.** `_setLinePrice(NaN, ...)` used to fall through the bounds check and throw on `cur.price`. Real callers pass the Repeater's integer index, so this is defensive, but the function is the one being rewritten and the guard is one line (`!(idx >= 0 && idx < n) || Math.floor(idx) !== idx`). Found by test P-5.

## 4. Data flow
```
TextField (price)  --editingFinished / accepted-->  _commitPrice()
  _commitPrice: msg = dlg._setLinePrice(index, text)
     OrderFlow.priceEdit(text, line.price, InventoryStore.formatCurrency(line.price))
        unchanged -> null          (cartRow.priceError untouched)
        set       -> new array, price replaced, ""       (priceError cleared)
        refused   -> OrderFlow.priceText(reason)         (priceError = text, line unchanged)
  the field text is reset to the formatted real price in every case (as before)
Place order -> OrderPlan.build still guards price > 1e9 (bad-line): the field and the planner use the SAME constant (tested).
```

## 5. Judged and left (written down, not fixed)
- Discount field (D-NO3b-6). The edit-order path (`EditOrderDialog` price editing, if any) was not read here: noted as a check for the owner's next slice, not a finding.
- `formatCurrency` shows one decimal (existing comment in `InventoryStore`).
- A price typed while another row is committing: the row's index is the Repeater's, and the commit reads the cart at call time; the hardened guard returns null for a row that is gone.

## 6. Tests (all RUN in the sandbox unless marked CI)
- `functions/test/orderFlow.test.js` F-8..F-13: the reading table, the three reasons, unchanged text, the three texts, never throws for any value.
- `functions/test/orderPriceCap.test.js` P-1..P-7 (new): the REAL `_setLinePrice` and `formatCurrency` bodies in a vm; a refusal changes nothing; Enter's second call is null; bad index; the limit equals the planner's (the top price is planned, the next is refused by both); a 20 000-input monkey probe: never throws, never changes a refused or unchanged entry, every committed price is a plain decimal in range and is plannable through the REAL order normaliser and `OrderPlan.build`.
- `functions/test/newOrderDialog.guard.test.js` D-7..D-9: the source wiring (no lenient reading, `msg !== null`, focus clears, visible danger text, accessible description).
- `tests/tst_OrderFlow.qml` (CI): the helper rows in the QML engine.
- Hand mutants: see the test plan, section 5.

## 7. Open questions for the owner
- **Q-NO3b-1** a price of 0 on an order line: keep allowing (recommended) or refuse like Add Product?
- **Q-NO3b-2** limit a price to 2 decimals? Recommended: yes, as its own small slice across Add Product, Restock and New Order together, so the three fields stay equal (changing one now would break D-NO3b-1's agreement).
- **Q-NO3b-3** should `1,200` (comma as a thousands separator) be accepted? Recommended: no (D-NO3b-1, `1,5` ambiguity).
- Unchanged owner items: Q-NO3-1 (which stock-touching path next; recommended `_tryAdjustOrder`), Q-NO2-2, the commit address (KNOWN-ISSUES 111, 118), AP4.
