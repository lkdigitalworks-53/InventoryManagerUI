# Test plan: NO3a, a new order is ONE createOrder operation (store, DataModel, dialog callback, e2e helpers)

Branch `feat/2026-11-23-no3a-create-order-wire`. Design: `specs/2026-11-23-no3a-create-order-wire-design.md` (D-NO3-1..11). Standard format (Skill 49).
Honesty note: Node tests were RUN in the sandbox against the REAL function bodies (extracted from `OrdersStore.qml` and `DataModel.qml` and run in a vm) and the REAL server code. The QML twins and the three emulator suites could not run (no Qt in the sandbox, by rule); the real qmltestrunner and emulator result is CI's (section 5). Nothing was built or run on a device.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/orderFlow.test.js` (new) | 7 | RUN 7/7 | F-1 key is a valid create key and unique; F-2 `localDay`; F-3 `classify`; F-4 `refusalText` (a line names itself, NaN or missing index = empty cart, app problems ask for a report); F-5 drift: every reason `OrderPlan.build` can give has a text; F-6 `doneText`; F-7 fixed texts plain and distinct |
| `tests/tst_OrderFlow.qml` (new, CI) | 6 functions | CI | the same rows for the QML engine |

## 2. Functional tests (real store and DataModel bodies + real server)
`functions/test/orderWire.test.js` (new), 15 cases, RUN 15/15: W-1 live apply once (the local order IS the server's, CAS base, revision, signal after it does nothing); W-2 `qty` = `quantity`, tax from inventory (the deleted loop); W-3 slow answer = `queued`, then the signal adds once; W-4 replay (live and late) adds nothing, re-reads, no auto-approve; W-5 a sync landed it first; W-6 offline (and `isOnline` undefined, null, "yes", 1, {} all read as offline); W-7 refusals even offline (empty cart, null cart, blank customer, price 2e9, qty 0 on line 2, 1.1 MB name); W-8 invalid date falls back to the store's own day; W-9 rejections (conflict, request-id-in-use, invalid-order; live not announced twice; late once with the customer; discard silent); W-10 unreadable answers = `unconfirmed`, no retry; W-11 two taps, two keys, server numbers, a refusal burns none; W-12 monkey 150 seeded carts (random lines, discounts, tax, `{{ord}}` text) through store, planner, server: local list == server docs; W-13 source order pins; W-14 `DataModel.onAddOrder` four outcomes to the right signal; W-15 `_autoApproveNewOrder` (id, setting, order present, refused completion text).
`tests/tst_OrdersStore_addOrder.qml` (new, CI): offline, refusals, live apply, live rejection, replay, unreadable, slow answer then signal, late rejection announced once, DataModel route (added, failed, deferred, auto-approve only after the answer). `tests/tst_OrdersStore_mutations.qml`: the old async smoke test became a synchronous refusal test.

## 3. Rules and regression
Rules: none changed. Regression: `operationLogic.createOrder.test.js` G-1 and `createOrderPlan.test.js` G-1 are now WIRING guards (they name the exact files allowed to use the op and the planner: a page or dialog naming either fails), `createOrderPlan` P-1 (2500 carts through the real normaliser) and the whole functions suite pass unchanged.

## 4. E2E (emulator, CI only)
`tst_OrdersE2E`, `tst_ReturnAfterMetadataEditE2E`, `tst_OrdersStoreE2E`: `_addOrder` and the concurrent-add and 55-order pagination tests now place orders through `_withOnline` and the operation URL (OrdersStoreE2E points it at the emulator). `functions/test/orderE2eHelpers.guard.test.js` (10 cases, RUN) pins the source: fixture captured before going online and restored after, online restored in `finally`, every `addOrder` call inside the wrapper with the new arguments, the wait inside the window. The concurrent test now proves two simultaneous operations get two numbers from the server.

## 5. Evidence
Functions suite 2290/2290 RUN (2258 on `main` + 32 new; both dormancy guards replaced one for one). Scripts 1199/1199 RUN. **28 hand mutants** over `OrdersStore.qml`, `OrderFlow.js` and `DataModel.qml` (settled flag, replay add, re-read, online check, name kept, duplicate guard, CAS base, revision, replay id, discard text, late prefix, both settled checks, date, status, offline check, queued branch, unconfirmed, names, replay local add, await, NaN index, queued text, `localDay`, bad-customer, limit text, auto-approve order check, auto-approve setting, route name): the first run left 3 alive (online check loosened, two auto-approve guards in `DataModel`); they became W-6's odd `isOnline` values and W-14/W-15; rerun 28/28 killed. CI result of the pushed head: recorded below after the run.

## On-device test plan (Taher). Prerequisites: functions with `createOrder` deployed to dev (NO1 merged; confirm the deploy ran), a build of this branch, owner login on a fresh dev tenant with 3 products in stock (one taxable), at least one channel and one staff member.
### Happy path
1. Settings: auto-approve OFF. Orders > New order: customer "Asha", add 2 products (qty 2 and 1), pick a channel and a staff member, Place order. Expect: the busy overlay "Placing order", then the sheet closes, the order appears as `ORD-nnn` (next number), status pending, totals as the sheet showed, no toast.
2. Open the order. Expect: customer "Asha", the channel, the staff member, the lines, tax and discount as before.
3. Approve it. Expect: stock down, a sale row in History, as before.
4. Settings: auto-approve ON. Place another order. Expect: created, then completed by itself; stock down; the stock check still applies (see the negative list).
5. Place two orders one after the other. Expect: consecutive numbers, no gap, no duplicate.
### Negative
6. Customer of 1 character: the sheet's own message, nothing sent. No product: "Add at least one product".
7. Flight mode, Place order. Expect: the sheet stays open with "Placing an order needs an internet connection. Connect and try again", the cart is kept, nothing in the stuck-writes sheet. Turn the connection on, tap again: it is placed.
8. Auto-approve ON, an order for more than the stock of one product (set the stock by editing it first). Expect: the order is created pending, then the completion message about stock; the order is NOT lost.
9. A unit price of 20 digits in a line, Place order. Expect: "Line 1 (name): ... A price can be at most 1000000000" and nothing sent. (The field cap with its own message comes in NO3b.)
10. Two phones, same shop, place an order at the same moment. Expect: two different numbers, never an error about the number.
### Edge cases
11. Customer typed `{{ord}}` or with spaces around it. Expect: stored without the spaces, braces shown as typed (changed to a look-alike if the planner neutralised them); the order is created.
12. Slow link (throttle to ~50 kbit or airplane toggled right after the tap): Expect either the sheet closes with the toast "Order saved. It appears in your list when it syncs" and the order shows up when the link recovers (and auto-approves if ON), or a clean refusal. Never two orders.
13. Place an order and kill the app during the busy overlay. Relaunch. Expect: the order appears once (or not at all if the server never got it); the stuck-writes sheet, if opened, labels the item "New order" with the customer name.
14. 20 products in one order. Expect: created; the doc is well under the size limit.
15. Place an order, then immediately Edit it. Expect: no conflict message (the server image is the edit base).
### Multiple scenarios
16. Restock a product (queued offline), then place an order with it online. Expect: the order is created; approving it is refused with the restock-pending text, as before.
17. Auto-approve ON, a line whose product has an unsynced edit: created, completion refused with the unsynced-edit text.
### Monkey (2 minutes)
18. Rapid double-tap on Place order: exactly ONE order. Rapid open/close of the sheet, change channel/staff while busy, rotate: no crash, no duplicate, no stuck busy overlay.
### Affected areas (smoke)
19. Orders list, order detail, return/exchange, Sales Analysis by channel and staff, Activity (an order create has no feed row, by design Q-NO-4), CSV import of orders, product restock and add product: unchanged.
### Not changed here
The price field cap and its message (NO3b); `_tryAdjustOrder`, imported completion, reverse (their own designs).
