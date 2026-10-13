# Test plan — order completion refuses behind a parked write (decision B)

**Branch / PR:** `test/2026-10-04-order-completion-parked-delta-repro` (PR #121). Commit 1 = red-by-design E2E, commit 2 = guard + unit tests + docs.
**Design / decision:** `../specs/2026-10-04-product-delete-batch-cascade-design.md` (parked-write family) and `CHECKPOINT.md` "Taher's answers". Taher chose B (refuse) over the advised bypass.
**Status:** **written, NOT run** (no Qt toolchain in the sandbox, standing rule). CI is the first run. Commit 1 is EXPECTED to fail E2E on CI (`completion hung behind a parked write`); commit 2 is expected green.

## 0. What changed
`DataModel._tryCompleteOrder` checks, before setting `_completingOrderIds` and before any FIFO consumption, whether any line's product has a parked write (`InventoryStore.hasParkedWrite`). If so: `stockErrorMsg = "<product names>: " + InventoryStore.parkedWriteMessage`, `callback(false)`, return. The order stays `pending`. All three callers (`onCompleteOrder`, `onUpdateOrder` to completed, auto-approve in `onAddOrder`) already route a `false` to `dispatcher.orderCompletionFailed(orderId, stockErrorMsg)`, which `Main.qml` shows. No server, rules or storage change.

## 1. Unit / functional (QML, CI-only): `tests/tst_DataModel_completeOrderParkedGuard.qml` (new, 22)
Happy path (refusal): answers false synchronously; message names product + shared text; nothing changes (stock, batch qty, outbox length, order status, transactions); in-flight guard not left set; second tap refused again (not "already being completed"); no-callback does not throw.
Multi-line: one parked line refuses the whole order and consumes neither batch; two parked lines both named; same product on two lines named once.
Negative / edge: stuck-but-not-terminal and plain pending write do NOT refuse; park on another product / another entity with the same id does NOT refuse; proceeds after the parked write is discarded; completed order short-circuits true behind a park; unknown order false with no message; unresolvable line keeps the old "not found in inventory" failure.
Routing: `completeOrder` and `updateOrder(..., {status:"completed"})` signals emit `orderCompletionFailed` with the message; no park emits nothing.
Monkey: 60-step seeded park / unpark / complete on two products; refusal never touches state, proceed always sets the guard.
Not covered here (offline harness never resolves a delta): the real round trip, see section 3.

## 2. Rules / functions
Not applicable: no `firestore.rules`, `storage.rules` or `functions/` change. Existing suites run as regression only.

## 3. E2E (emulator, CI-only): `test/e2e/tst_OrdersE2E.qml` +1
`test_completeOrder_behind_a_parked_write_is_refused_not_hung`: seed a parked edit for a product with a pending order of 3 of 10 units. Expect the callback within 2 s with `false`, message contains `parkedWriteMessage`, order `pending` locally and on the emulator, product stock 10 locally and on the emulator, batch qty unchanged, outbox holds only the parked item, in-flight set clear. Then discard the parked write and complete again: callback true, emulator stock 7. On `main` this fails at the 2 s wait (the bug).

## 4. On-device (Taher)
Prereq: build with this PR; a product whose edit is parked (description over 1 MiB, wait for the rejected list, as in the PR #118 device test).
- **4.1 Happy path:** a pending order for the parked product: Approve shows the "Fix or discard the stuck change for this product first" dialog at once, order stays Pending, no spinner stuck, stock and batches unchanged in Firestore. Discard the parked edit in the stuck-writes dialog, Approve again: order completes, stock drops by the line qty once.
- **4.2 Negative:** an order for a product with no parked write completes as before. An order for a different product completes while the first is parked.
- **4.3 Edge:** Retry on the parked write (rejected again, still parked) still refuses. Park, relaunch the app, Approve: still refuses (state persists). Approve twice quickly on a refused order: refused twice, never "already being completed".
- **4.4 Multiple scenarios:** order with two lines, one product parked: whole order refused, the healthy line's stock and batch untouched. "Approve all" on the Orders page with a mix: the parked-product orders report failure, the rest complete (check the failure message appears once per order and the loop does not stall).
- **4.5 Monkey:** 5 minutes of random Approve / Retry / Discard / edit on two products; at the end `product.stock` equals the sum of `qtyRemaining` of its batches in Firestore for every product, and every completed order has exactly one sale per line.
- **4.6 Unchanged gap (expect old behaviour):** a return or exchange on a completed order for a parked product, and an imported order, are NOT guarded (KNOWN-ISSUES). Do not report as a regression.

## 5. Regression watch
`tst_DataModel_completeOrderReentrancy`, `tst_DataModel_adjustOrderSyncGuard`, `tst_ParkedWriteGuard`, `tst_OutboxStore`, `tst_Gateway`, `tst_OrdersE2E` (other two cases), `tst_StockBatchStoreE2E` (parked D2/D3 cases share `OutboxStore`).
