# Test plan: NO3c, order price and discount fields (Edit Order and New Order)

Branch `feat/2026-11-26-no3c-edit-order-money-fields`. Design: `specs/2026-11-26-no3c-edit-order-money-fields-design.md` (D-NO3c-1..8). Standard format (Skill 49).
Honesty note: Node tests RUN in the sandbox against the real `OrderFlow.js` and the real dialog function and handler text of both sheets over stand-in rows. QML twin and anything a person sees or hears: CI and device only. No server, rules or deploy change.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/orderDiscountFlow.test.js` (new) | 13 | RUN | `isRow`; `discountEdit` set / refused / unchanged / blank, edges 0, 100, line amount; float tolerance; texts; `discountSwitch` (free-line case, typed text under new type); `lineProblems` (refusals, misfit, saved-line skip, old orders without ids); 20 000-text monkey against the REAL `computeOrderTotals` (an accepted discount is never clamped) |
| `tests/tst_OrderFlow.qml` | +6 | CI | the same rows in the QML engine |

## 2. Functional tests (real dialog code)
`functions/test/orderMoneyFields.test.js` (new), 25 cases, RUN. M-1..M-10 run for BOTH sheets: refusal keeps the old value; Enter's double commit; uncommitted entry sent (3 focus behaviours); refused entry then submit sends nothing; flat-to-percent free-line case; pill with typed text; same-side tap; pill commits another row first; lowered price under a flat discount; 600-session monkey each. M-11..M-15: Edit price rules and both focus orders; `_save` order and row roles; no lenient reading left; legacy saved line; commit after row removal.
Limit: M-12 checks the order of calls inside `_save` from source; `_save` itself is not executed.

## 3. Rules and regression
Rules, server, planner: unchanged. Updated pins: `orderPriceCap` (renamed `_settleFieldEdit`, `settleField`, type switch), `newOrderDialog.guard` D-8, `newOrderPickerWiring` NOW-18, `editOrderPickerWiring` EOW-05/14 (two new row roles), `pickerS5e3Names` S5E3-21.

## 4. E2E (emulator, CI only)
None added: dialogs have no headless e2e; the saved document shape is unchanged. Existing order e2e suites are the regression.

## 5. Evidence
- Functions suite RUN: before 2437/2437 on `main` @ `5c41b8f`; after 2475/2475 (+38). Scripts suite 1199/1199.
- Hand mutants: 48 over `OrderFlow.js` (20), `NewOrderDialog.qml` (12), `OrderDetailDialog.qml` (16). First run killed 47; the survivor (Edit Order price field showing formatted text after Enter while still focused) got a case in M-11 and is now killed: 48 of 48.
- qt-qml-review linter: new hits only in kinds the two files already carry (`var`, `property var`, imperative text assignment, attribute order); the two new `JS-2` hits are on lines that use `===`/`!==`. The six-domain agent review was not run.
- CI on PR #222 @ `150f2f7`, RUN and green: QML 3422/3422 (includes the six new `OrderFlow` twins), Functions 2475/2475, Rules 129/129, E2E 124/124 (total 6150/6150).

## 6. On-device test plan (owner). Build of this branch, owner login on a dev tenant, products A (price 100) and B (price 1200), one old pending order and one completed order.
Run 1 to 14 on **Edit Order**; run 5 to 14 again on **New Order**.
### Happy path
1. Edit a pending order, tap Price: plain number selected. Type `250.5`, tap outside: `₹250.5`, totals move, no message.
2. Type a price, tap **Save changes** without leaving the field: the typed price is saved (reopen to check).
3. Price `0`: accepted. 4. Tap a `₹1,200` price and leave: nothing changes, no message.
5. Discount `50` flat, then `10` percent: totals correct, no message.
6. Type a discount and tap Save / Place order without leaving the field: it is in the saved order.
### Negative
7. Price `abc`, `-5`, `1e5`, `1,5`, blank, `1000000001`: old price returns, red border and red text under the row, totals unchanged.
8. Discount `-5`, `abc`, `101` on %, more than the line amount on ₹: refused with its reason, old value shown.
9. Type a bad value and tap Save / Place order directly: nothing is sent; a line at the bottom names the product. Tap the field, then Save: goes through.
10. ₹ discount 500 on a line of 1000, tap `%`: discount shows 0 with "It is now 0"; Save is blocked until the field is tapped. The line is never free.
### Edge and multiple scenarios
11. Type `15` in the discount field and, without leaving it, tap `%`: the line has 15%. Tap the selected side again: nothing changes.
12. Flat 150 on 2 x 100, step quantity down to 1, Save: blocked, "from 0 to the line amount". Lower the discount: saves.
13. Completed order: change a price, Save: the return sheet opens with the new price. Change only the customer name: saves with no return sheet. Return units from a line with a big flat discount: blocked until lowered.
14. Remove a row while its price field is open: no crash, other rows unchanged. Close the sheet while typing: reopening shows saved values, no message.
15. Old order with an odd stored discount (edit it in Firestore to 150 on a 1 x 100 line): changing only the name saves.
### Monkey
16. Two minutes of fast typing, pill taps, steppers, Add products, Back key, rotate, offline toggle on both sheets: no crash, no line total below 0, no free line without a message.
### Accessibility and layout
17. TalkBack reads the field name then the refusal. 18. Largest system font: messages wrap, Save stays reachable. 19. Edit Order with 8 lines: scroll to a middle row, refuse, check the message is under the right row.
