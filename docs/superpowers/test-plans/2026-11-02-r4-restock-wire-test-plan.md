# Test plan: R4, restock goes through one atomic operation

Branch `feat/2026-11-02-r4-restock-wire`. Design: `specs/2026-11-02-r4-restock-wire-design.md` (R4-D1 to R4-D10). Standard format (Skill 49).
Honesty note: this is the first slice where the app behaves differently. Every Node test below was RUN in the session that wrote this plan. The QML tests and the emulator e2e case are WRITTEN and run in CI only (no Qt, no emulator in the sandbox). CI result is recorded in the PR, not here.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/restockFlow.test.js` | 26 | RUN 26/26 (23 + D2-1..3 from the review sweep) | `RestockFlow.js` with its real text: key, local date (including a UTC-vs-local split), `supplierFor` (empty, `SUP-` id known and unknown, known name any case and spacing, new name, whitespace-only refused, number, junk supplier lists), `makeInput` (cost default, one `Date`, bad product, bad time, bad supplier), `classify` (applied, queued, pending, rejected, discarded, unreadable), `refusalText` for every planner reason (drift guard reads the planner's `_refuse` list), `activityText`, end to end through `RestockPlan` and the REAL server for known, new and no supplier, a replay, every planner refusal, and a 600-tap seeded monkey. |
| `functions/test/restockWire.test.js` | 21 | RUN 21/21 | The REAL bodies of `restock`, `_applyRestock`, `_restockFailureText`, `onRestockApplied`, `onRestockRejected`, `applyRestockResults` and `OutboxStore.hasQueuedOperationFor`, with fake stores and the real server answering. Online and answered; offline then late answer; await window over then answer; replay (live and late); unreadable answer; rejected live; rejected after the caller left; discard (silent, and its own text for a waiter); relaunch rejection with no name; every refusal; unknown product; no callback on every path; parked beats queued; double tap; operation shapes for none, known, id and new supplier; cost default; one `Date`; unique keys; awaiting follows connectivity; source pins for the DataModel route, the sale guard, the picker, the dialog; a 400-round seeded monkey asserting one answer per tap, at most one Activity entry, and no leftover marks. |
| `functions/test/restockSurface.test.js` | 15 | RUN 15/15 | P-1 rewritten from "dormant" to "exactly one caller of the planner, one `recordOperation`, none of the legacy writes in `restock`". The rest unchanged. |
| `tests/tst_RestockFlow.qml` | 11 functions | WRITTEN, CI only | QML-engine copy of the helper cases, plus `costFromText` (review D-2). |
| `functions/test/restockHold.test.js` (review D-1) | 14 | RUN 14/14 | REAL server code proves a stale-`before` edit and delete get 409 after a restock landed (H-1..H-3, control H-2); the REAL bodies of `restockHoldMessage`, `updateRefusal`, `deleteProduct` (C-1..C-8); pins that no other whole-record inventory writer exists and that `updateProduct` asks the refusal before any change (P-1..P-3). 7 of 7 hand mutants killed. |
| `tests/tst_InventoryStore_restockHold.qml` (review D-1) | 13 functions | WRITTEN, CI only | Same cases in the QML engine: hold message (queued, parked, other product), edit and delete refused with nothing changed or queued, hold wins over the size message, hold ends when the restock leaves the outbox, and through `DataModel` (error text, no `productUpdated`/`productDeleted`). |
| `tests/tst_OutboxStore_queuedOperation.qml` | 5 functions | WRITTEN, CI only | Type, entity and id match; a plain edit and a delta do not count; parked still counts; released on ack. |
| `tests/tst_InventoryStore_restock.qml` | 14 functions | WRITTEN, CI only | The glue in the QML engine with a real `DataModel`: offline queue shape, key, mints, known-name resolution, latch, refusals, live answer applied once although the signal follows, live rejection, late answer, late rejection announced once, silent discard, replay, unreadable answer, sale refused with a queued restock and released after. |
| `tests/tst_InventoryStore_movementKinds.qml` (changed) | restock cases rewritten | WRITTEN, CI only | Receipt movement now read from the operation's delta op; default quantity removed (0 and NaN refused); second restock refused while queued; sale delta stays a separate item. |
| `tests/tst_ParkedWriteGuard.qml` (changed) | callback shape | WRITTEN, CI only | `(ok, queued, refusal)`. |

Mutation checks (by hand, scripts not committed): 23 mutants over `InventoryStore.qml`, `RestockFlow.js`, `DataModel.qml`, `OutboxStore.qml` (drop the latch, drop the parked check, drop or invert the settled mark in either handler, replay applies stock, drop a resync, drop the discard text or silence, wrong `awaitServer`, a queued answer reported as done, wrong Activity guard, leaked name, classify shortcuts, UTC date, case-sensitive name match, empty-name check removed, cost default zero, supplier text dropped, route removed, opType check removed). All 23 killed after three survivors got new tests (UTC date, DataModel route, outbox type check).

CI OBSERVED: first push (e9299b5) QML 2719/2720 (one test read a product the replay re-read had just emptied: test fixed) and E2E 69/71 (`tst_InventoryE2E` did not point `Gateway.operationFunctionUrl` at the emulator; the second restock test tapped again while the first was still queued, which R4-D1 refuses: both fixed in the test files, no product change). Fix push c4575cb: QML 2720/2720, Functions 1029/1029, rules 108/108, E2E 70/71 (the second-tap test). Final test push f61396b: ALL GREEN, 3968/3968 (QML 2720, Functions 1029, rules 108, E2E 111).

## 2. Functional / rules / e2e
- Functional: `restockFlow.test.js` E-1 to E-3 and `restockWire.test.js` run the plan through the real transaction logic and the strict fake DB.
- Rules: unchanged. The operation writes the same collections the old path wrote (`suppliers`, `stock_batches`, `inventory`, `transactions`, `stock_movements`).
- E2E (emulator, CI): `test/e2e/recordOperation.e2e.test.js` gained one case: a plan built by the client code (`RestockFlow` + `RestockPlan`) with a new supplier lands supplier, batch, stock, purchase and marker in one operation; `reflect` reads the answer; a replay returns the same ids and applies once; the counters and documents are restored in `finally`. WRITTEN, CI only.

## 3. Regression
- Old restock tests were rewritten, not deleted: each old behaviour either has a new assertion or a deliberate change listed in the design (R4-D1 coalescing is gone, R4-D2 default quantity is gone, R4-D3 callback shape).
- After merging `main` (L4a #182) and the review fixes: `functions` 1043/1043 and the script suite 905/905 pass (run in the sandbox). `SKILLS-INDEX.md` is current.
- `TransactionStore.recordPurchase` and its tests are untouched (still used by the R3 drift guard).

## On-device test plan (Taher, after merge; needs a build of this branch)
Prerequisites: P1 signed in as owner on a dev tenant (new user and tenant); P2 product A (stock 10, cost 12) and product B (stock 4); P3 supplier `Acme`; P4 Firestore console open on `tenants/<t>`; P5 a second product C that appears in no order.

### Happy path
1. Restock A by 5, supplier `Acme` (pick it), cost 12, reason `box 7`. Expect the toast "Restocked +5 units", stock 15, ONE new batch (supplier `Acme`, qty 5, remaining 5, cost 12, note `box 7`), one purchase row `tx-p-<batch id>`, one `receipt` movement, one Activity entry "Restocked: A" with `+5 · now 15 in stock · from Acme · box 7`.
2. Use the dialog's add-new-party path to create `Zed`, then restock A by 2 with it. Expect stock 17, a supplier `Zed` exists once, the batch points to it. (The dialog still creates the supplier first through the old mint; the atomic new-name path is covered by the tests and moves into the dialog in R5.)
3. Restock B by 3 with no supplier. Expect stock 7, batch with empty supplier, purchase row with empty party.
4. Complete an order of 1 x A. Expect stock 16 and the order Completed.
5. Open the stuck-writes caption. Expect nothing stuck.

### Negative
1. Quantity 0 or empty. Expect "Quantity must be greater than zero", no batch, no purchase row, no outbox item.
2. Cost `-1`. Expect "Unit cost is not a valid amount". Cost `1e308` (if the field allows it): same text, nothing saved.
3. Reason containing `{{batch}}`. Expect the short "Remove any {{ or }} from the text and try again" text, nothing saved.
4. Make a write for A get stuck and parked (as in the PR #119 device steps), then restock A. Expect "Fix or discard the stuck change for this product first" and nothing saved.
5. Turn the network off, restock A by 1. Expect "Restock saved. Stock updates when it syncs", stock UNCHANGED, no new batch, no Activity entry. Try to restock A again. Expect "A restock for this product is still syncing. Wait for it to finish first".
6. While step 5 is queued, open New Order. Expect A is NOT in the product picker. Complete an existing pending order that contains A. Expect it refused with "A: A restock for this product is still syncing. Sell it after it syncs" and the order stays pending. Restock B meanwhile. Expect it works (other product).
7. Turn the network on. Expect within a few seconds: stock of A +1, one batch, one purchase row, one Activity entry, A back in the picker, the pending order completable.

- **Review D-1.** Turn the network off, restock A, then open A's edit sheet, change the name and Save. Expect the sheet to STAY open with "A restock for this product is still syncing. Wait for it to finish first" and nothing queued. Then try Delete on A: same text, A still listed. Turn the network on, wait for the restock, then edit and delete A: both work. Park the restock (as in step 4) and try to edit A: expect the "stuck change" text, not the wait text.
- **Review D-2.** Clear the cost field and confirm. Expect the batch to carry A's recorded cost, not 0. Type `abc`, `1,5` or `-1`: expect "Unit cost is not a valid amount", the sheet stays open, nothing saved. Type `0`: expect it accepted (free sample, cost 0).

### Edge cases
- Fractional quantity 2.5 and cost 0. Expect accepted.
- A 600-character reason. Expect accepted; the movement row reason is cut at 500, the batch note keeps the text.
- Restock while offline, kill the app, reopen online. Expect the restock still queued, then applied once (one batch, one Activity entry). This is the relaunch path.
- Delete product A on a second device, then let a queued restock of A send. Expect it rejected, nothing created, and one message "A queued restock was not saved. A: this product is no longer on the server ... Nothing was added".
- Discard a parked restock from the stuck-writes sheet. Expect no message and A back in the picker.

### Multiple scenarios
- Review D-1: offline, restock A, edit B (a different product). Expect B's edit goes through and queues normally; only A is held.
- Restock A, then complete an order of A as soon as the toast shows. Expect stock arithmetic correct and FIFO consuming the new batch last.
- Two devices restock A at the same moment. Expect both applied (the second may wait behind the first on its own device), two batches, no duplicate supplier when the same existing supplier is picked.
- Restock A offline on two devices and sync both. Expect two batches; if both typed the same NEW name, two suppliers with that name (known limit, design R4-D5).

### Monkey
- Rapid double and triple taps on the Restock button online and offline. Expect exactly one batch per intended restock, never two.
- Rotate the screen, background and foreground the app during the save. Expect no crash, no duplicate, no half restock (stock and batch always arrive together).
- Toggle airplane mode three times during a restock. Expect one batch at the end and a consistent stock.

Expected result of the whole list: stock, batch, purchase row and Activity entry always arrive together or not at all; nothing is double-applied; a queued restock holds its product back from sales until it settles.
