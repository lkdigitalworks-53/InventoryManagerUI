# Test plan: NO3b, the New Order unit-price field (plain decimals, the 1e9 cap, a visible reason)

Branch `feat/2026-11-24-no3b-order-price-cap`. Design: `specs/2026-11-24-no3b-order-price-cap-design.md` (D-NO3b-1..8, Q-NO3b-1..3). Standard format (Skill 49).
Honesty note: the Node tests were RUN in the sandbox against the REAL function bodies (`_setLinePrice` and `formatCurrency` extracted from the QML text and run in a vm, the real `OrderFlow.js`, the real order normaliser and `OrderPlan.build`). The QML twin rows and the dialog itself (message `Text`, border, accessibility, focus order) could not run: no Qt in the sandbox, CI is the oracle. A CI correction round is normal for QML pushed without a local run; it is flagged here, not hidden.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/orderFlow.test.js` (F-8..F-13 added) | 6 new | RUN | F-8 plain decimals are prices (`007`, `5.`, `.5`, padding, the 1e9 boundary); F-9 ten-plus junk forms are `invalid` and never another number (`-5`, `+5`, `1e5`, `12abc`, `1.2.3`, `1,5`, `Infinity`, `0x10`, Arabic digits...); F-10 blank / non-string is `blank`, above the limit and a 400-digit paste are `large`; F-11 text equal to the stored price or the formatted display (padded too) is `unchanged`, the display of ANOTHER price is junk; F-12 one text per reason, limit from `RestockFlow`, unknown reason is `""`; F-13 never throws, always one of three kinds, for 12 odd values x 6 x 5 |
| `tests/tst_OrderFlow.qml` (5 functions added, CI) | 5 | CI | the same rows in the QML engine |
| `functions/test/newOrderDialog.guard.test.js` (D-7..D-9 added) | 3 new | RUN | `_setLinePrice` uses `OrderFlow.priceEdit` only (no `parseFloat`, no `.replace(`), the commit keeps the message on `null`, focus gain clears it, the message is visible danger-colour wrapped text, the field's description and red border follow it |

## 2. Functional tests (real dialog function body + real planner)
`functions/test/orderPriceCap.test.js` (new), 7 cases, RUN: P-1 a plain price is committed (new array, other line and fields untouched, old array not mutated); P-2 ten refused entries return their text and change nothing; P-3 the plain price, the formatted display, padding and `100.00` are `null`; P-4 Enter's second call (text now the formatted old price) is `null`, never a message; P-5 a bad index (NaN, undefined, null, `"0"`, 0.5, Infinity, an object, an empty cart) is `null` (found a real throw, fixed, D-NO3b-8); P-6 the field and `OrderPlan.build` agree on the limit (1e9 planned, 1e9 + 0.01 refused by both) and on 0; P-7 monkey: 20 000 random texts from a hostile alphabet never throw, never change a refused or unchanged entry, and every committed price is a plain decimal in range that the REAL order normaliser and planner accept.

### Review sweep 2026-11-25 (design section 8), all RUN unless marked CI
| File | Cases | Covers |
|---|---|---|
| `orderPriceCap.test.js` P-8..P-16, P-14b | 10 new | uncommitted valid price is ordered (3 focus behaviours); refused entry then Place order sends nothing (3 x 6); acknowledge then send; Enter keeps a plain focused field; focus loss formats; refusal survives rebuilds, leaves with its line; discount pill and stepper commit first; busy sheet does nothing; 800 random sessions (never a price other than the cart's, never while a refusal stands) |
| `orderFlow.test.js` F-14..F-16 | 3 new | `priceBlockedText`, `withPriceError`, `prunePriceErrors` (odd input, inherited names) |
| `newOrderDialog.guard.test.js` D-7, D-8 | rewritten | wiring: handlers, repeater id, binding, pruning, the three settle callers run before the cart is read |
| `tests/tst_OrderFlow.qml` | +3 (CI) | helper twins |
| `newOrderPickerWiring` NOW-18, `pickerS5e3Names` S5E3-21 | updated | stub for the new call; the new focus line |

P-1..P-7 now read the refusal from the dialog's record instead of a return value (`null` in their names means "touched nothing").
Current counts: functions **2420/2420** RUN (after the merge of #218), scripts **1199/1199** RUN, 29 of 29 sweep mutants killed. The counts in section 5 are the first version's.

## 3. Rules and regression
Rules and server: none changed. Regression: `pickerS5e3Names` S5E3-21 pinned the exact focus line of the price field; it is updated (a comment says why) and still pins the plain/formatted swap. The NO2/NO3a suites (`createOrderPlan`, `orderWire`, `orderFlow` F-1..F-7, `newOrderDialog.guard` D-1..D-6) still pass unchanged (the planner keeps its own 1e9 guard as the last line of defence); `AddProductFlow` callers are untouched (`moneyState` is an alias of the private reader).

## 4. E2E (emulator, CI only)
None added: the dialog has no headless e2e and the price rule is client-side only. The three order e2e suites rewired in NO3a place orders with plain prices and are unaffected.

## 5. Evidence
- Node files RUN: `orderFlow` 13/13 (7 before + 6 new), `orderPriceCap` 7/7 (new), `newOrderDialog.guard` 9/9 (6 + 3), `pickerS5e3Names` 41/41 (S5E3-21 updated: the focus line now also clears the price message). Full functions suite RUN after `npm ci`: 2383/2383 (main 2367 + 16 new). Scripts suite: see the PR.
- Hand mutants: 24 of 24 killed across `OrderFlow.js` (10: unchanged check off, shown-branch off, untrimmed shown, blank mapped to invalid, large mapped to invalid, large accepted, untrimmed text, a shortened text, an emptied text, a wrong default), `AddProductFlow.js` (2: alias returns a lenient reading, limit off by one) and `NewOrderDialog.qml` (12: index guard x2, no-change rule x2, refusal returns null, set returns null, line replaced by a bare object, message not guarded by null, focus does not clear, message hidden, description removed, red border removed). One first attempt matched twice and was re-run on the exact line; the first Node run also showed the 8th mutant left applied after a timeout, restored and re-run (the working tree was diffed before every commit).
- Not proven here: the QML twin and the delegate (section 4 of the design), the focus-loss order on a real device (check 11), the TalkBack reading (check 13).

## On-device test plan (Taher). Prerequisites: a build of this branch, owner login on a dev tenant with 3 products in stock (one priced above 1000), the New Order sheet reachable. No server deploy is needed: this slice is client only.
### Happy path
1. New order, add a product, tap its Price field. Expect: the plain number, selected. Type `250.5`, tap outside. Expect: the price shows `₹250.5`, the line and the totals update, no message.
2. Same, press Enter on the keyboard (emulator or hardware keyboard). Expect: the same result and still no message (Enter fires two handlers).
3. Type `0` on a line. Expect: price `₹0`, totals drop, the order can be placed (Q-NO3b-1: a free line is allowed).
4. A product priced above 1000 (shows `₹1,200`): tap the field and leave it without typing. Expect: nothing changes, no message, the price is still `₹1,200`.
### Negative
5. Type `abc`, tap outside. Expect: the old price comes back, a red line under the row "Price must be a plain number, like 120 or 99.5", the field has a red border, the totals do not move.
6. Delete the text (empty), tap outside. Expect: the old price, "Enter the price of one unit, 0 or more".
7. Type `1000000001`. Expect: the old price, "Price is too large. Enter the price of ONE unit, up to 1000000000". Type 25 nines: the same message.
8. Type `-5`, then `1e5`, then `12abc`, then `1,5`. Expect each: refused with the "plain number" text, the price never becomes 5, 15, 12 or 15.
9. Type `1000000000` exactly. Expect: accepted (the limit is inclusive); then Place order succeeds (or the stock check speaks, never a price message).
### Edge cases
10. Refuse an entry (check 5), then tap the field again. Expect: the message disappears when the field gets focus; type a good price: no message.
11. Refuse an entry with Enter. Expect: the message STAYS (the second handler must not wipe it). On a touch keyboard use its Done key (same test).
12. Refuse an entry (check 5), then tap the + stepper of the same line. Expect: the quantity rises, the price is the real one and the message STAYS under that line. Remove the line with -, add the product again: no message.
13. TalkBack on: focus the Price field after a refusal. Expect: "Price of <name>" and the reason read as its description; the message line is readable as text. Without a screen reader the red border AND the text carry the message (colour is not the only cue).
14. Large system font (Settings > Display > Font size > Largest): trigger the message on a 3-line cart. Expect: the text wraps, the row grows, nothing overlaps or truncates; the Place order button stays reachable.
15. A line with two decimals (`19.99`), re-tap and leave: unchanged, no message; the display is `₹20` (one-decimal display, KNOWN-ISSUES 152).
### Multiple scenarios
16. Three lines in the cart: refuse a price on line 2 only. Expect: the message under line 2 only, lines 1 and 3 untouched; fix line 2: its message goes.
17. Refuse a price, then Place order. Expect: NOT placed; the bottom line names the item and the price it still has. Tap that price field (the red message goes), tap Place order: placed at the old price.
18. Dark theme and light theme: the red text and border are readable in both.
### Added by the review sweep
21. Type `250` in a price field and, with the keyboard still open, tap Place order. Expect: the order has 250 on that line.
22. On a 500 line type `1,200` and tap Place order directly. Expect: NOT placed, message under the row and at the bottom, price still ₹500.
23. Type `250` and, without leaving the field, tap the % pill of the same line, then repeat with its + button. Expect: price 250 kept both times. (On a device a button may need a second tap when the first one commits a price: note it if so.)
24. Refuse an entry with Enter. Expect: the field shows the plain old number, selected; typing replaces it and the message goes.
25. Type a price on line 1, then tap line 2's price field directly. Expect: line 1 updates; line 2 may need a second tap (rows are rebuilt). No crash, no wrong price.

### Monkey (2 minutes)
19. Type junk (letters, symbols, emoji, a 400-character paste, a pasted `₹1,20,000`) into every price field, switch between fields, rotate, press Enter and back repeatedly, tap + and - between edits. Expect: no crash, no freeze, no price outside 0 to 1000000000, the totals always equal the visible lines.
### Affected areas (smoke)
20. New order end to end (customer, channel, staff, Place order, auto-approve ON and OFF), the product picker (add, + / -, remove), the discount field (unchanged here, still lenient: KNOWN-ISSUES 154), Edit Order price and discount fields (unchanged, still lenient and uncapped: KNOWN-ISSUES 151), Add Product and Restock price fields (unchanged).
### Not changed here
The discount field; the Edit Order sheet's price and discount fields (KNOWN-ISSUES 151, recommended next slice NO3c); a decimal-places limit (Q-NO3b-2); the planner, the server, the rules.
