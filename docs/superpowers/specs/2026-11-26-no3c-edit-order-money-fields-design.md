# Step 3, slice NO3c: one reading for the order price and discount fields, with a reason the person sees

Date 2026-11-26. Branch `feat/2026-11-26-no3c-edit-order-money-fields`, cut from `main` @ `5c41b8f` (#219, NO3b, merged and device tested by the owner; CI on that commit green). Baseline before any change: functions 2437/2437 RUN.
Scope source: CHECKPOINT "Next slice" and ATOMIC-OPERATIONS-STATUS section 21: Edit Order price and discount fields (KNOWN-ISSUES 151), New Order discount field (154, 158). Client only; no server, planner, rules or deploy change.

## 1. Problem
| Field | Old reading | Result |
|---|---|---|
| Edit Order price | strip non-digits + `parseFloat`, no cap | `-5` stores 5, `1e5` stores 15, `1,5` stores 15, 20 digits stores 1e20; blank silently ignored |
| Edit and New Order discount | same strip; junk or negative becomes 0 | `-5` stores 5, `1e2` stores 12, no message |
| Both pills | value carried to the other type | flat 500 switched to `%` is clamped by the totals to 100%: **a free line, with no word** |
| New Order discount | not committed before Place order or a row tap | typed discount can miss the order (158) |
| Edit Order | Save does not commit the field in use; focus handler overwrites typed price if it runs first | the NO3b sweep defects, still on this sheet |

## 2. Approaches
- **A (chosen): pure decisions in `OrderFlow.js`, thin appliers in both dialogs.** Reuses `priceEdit`; one place for limits and texts; runs in Node and qmltestrunner.
- B: a shared `MoneyField.qml` component. Removes delegate duplication, but cannot load headless, rewrites four pinned fields and their names/targets tests, and mixes a refactor into a money fix. Not now.
- C: Qt `validator` on the fields. Blocks keystrokes with no reason shown, and locale rules differ. Rejected.

## 3. Decisions (vetoable in the PR)
- **D-NO3c-1** Edit Order price uses `OrderFlow.priceEdit` / `priceText`, exactly as New Order.
- **D-NO3c-2** `discountEdit(text, current, type, gross)`: plain decimal only. Blank means no discount (0), as before. The text the field already shows is "unchanged".
- **D-NO3c-3** limits: percent 0..100; flat 0..line amount (price x quantity, 1e-6 tolerance for float noise). Trade-off: a flat discount above the line was clamped before; now it is refused with the line amount shown.
- **D-NO3c-4** switching ₹/%: the typed (uncommitted) text, else the stored value, is read under the NEW type. If it does not fit, the discount becomes 0 and the row says why. Options: (A) this; (B) refuse the switch (a person with flat 500 could never switch without clearing first); (C) keep the value and clamp (the free-line bug). Tapping the selected side does nothing.
- **D-NO3c-5** Save / Place order first commits the field in use, then refuses while any line has an unread refusal (same rule as D-NO3b-9).
- **D-NO3c-6** at submit, a discount that no longer fits (quantity or price lowered after it was entered) is refused with the line named. Edit Order skips lines identical to the saved ones, so a legacy order with an odd stored discount can still have its customer name or status saved. Cost: on a completed order, returning units from a line with a large flat discount needs the discount lowered first (before: the line silently became free).
- **D-NO3c-7** where a refusal lives. Edit Order: two `ListModel` roles on the row (`priceError`, `discountError`): rows are updated in place, an old order can hold blank or repeated product ids, and a role dies with its row. New Order: a second dialog map `_discountErrors` beside `_priceErrors` (rows are rebuilt; one row per product).
- **D-NO3c-8** no new abstraction in QML; the four fields stay four fields.

## 4. Data flow
```
field commit -> dlg._setLinePrice / _setLineDiscountValue -> OrderFlow.priceEdit / discountEdit -> unchanged | set | refused(text on the row)
pill         -> dlg._setLineDiscountType(i, type, typed or null) -> OrderFlow.discountSwitch -> { value, message }
Save/Place   -> _settleFieldEdit() -> OrderFlow.lineProblems per line + stock checks -> block or send
```
Every setter ignores an index that is not a row (a row removed while its field commits).

## 5. Tests
Node (RUN): `orderDiscountFlow.test.js` (pure helpers, monkey), `orderMoneyFields.test.js` (REAL dialog bodies and delegate handlers of both dialogs over stand-in rows, both focus-loss orders, monkey), updated `orderPriceCap`, `newOrderDialog.guard`, `pickerS5e3Names`. QML twin: `tests/tst_OrderFlow.qml` (CI). Dialog rendering, real signal order and TalkBack: device only.

## 6. Open questions for the owner (defaults taken)
- **Q-NO3c-1** D-NO3c-6 on completed orders: block (default) or clamp as before?
- **Q-NO3c-2** a switched discount that does not fit: set 0 (default) or refuse the switch?
- Unchanged: Q-NO2-2, commit address (KNOWN-ISSUES 111), AP4.

## 7. Plan (executed in this session)
1. Spec (this file). 2. Failing tests for the helpers, then helpers. 3. Failing dialog tests, then New Order, then Edit Order. 4. Monkey + hand mutants. 5. Docs, push, PR, CI.
