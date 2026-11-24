# Step 3, slice NO3a: wire `OrdersStore.addOrder` to the atomic `createOrder` operation

Date 2026-11-23. Branch `feat/2026-11-23-no3a-create-order-wire`, cut from `main` @ `5948767` (#212 merged). Contract: `specs/2026-11-21-create-order-atomic-operation-design.md` (D-NO-1..9) and `specs/2026-11-22-no2-create-order-client-plan-design.md` section 3 (the NO3 checklist). Shape copied from AP3a: `specs/2026-11-16-ap3a-add-product-wire-design.md`.

## 0. Where the roadmap stood (read from `main`, 2026-11-23)
Done: step 1 restock (R1..R5b), step 2 add product (AP1..AP3b), NO1 server (#208), NO2 planner (#212). Open: NO3 (this), NO4 device test; `_tryAdjustOrder`, `completeImportedOrder`, `_reverseCompletedOrder` (each needs a design and rulings); step 4 import chunking; AP4 (Taher's device pass of the add arc). Q-NO2-1/2/3 were not answered; the recommended answers stand because #212 merged without a veto.

## 1. Scope
**Built (NO3a):**
- `qml/helper/OrderFlow.js` (new, pure): `newKey`, `localDay`, `classify`, `refusalText` (a person-facing text for EVERY planner refusal, a bad line names itself; closes KNOWN-ISSUES 115), `doneText`, five fixed texts.
- `OrdersStore.addOrder(customer, date, email, phone, orderProducts, orderChannel, staffId, callback)`: ONE `Gateway.recordOperation("createOrder", ..., { awaitServer: true })`. New `_createFailureText`, `_applyCreateOrder`, `applyCreateOrderResults`, `_addLocalOrder`, `onCreateOrderApplied`, `onCreateOrderRejected`, `createDoneMessage`, `createOfflineMessage`.
- `DataModel`: `onAddOrder` follows the callback's five outcomes; `Connections` on Gateway route `operationApplied/Rejected` for `createOrder`; `_autoApproveNewOrder` (after the answer only).
- `Logic.qml`: `addOrder` signal loses `items`, `total`, `status`; new `orderCreationDeferred(status)`. `Main.qml` passes the new shape.
- `NewOrderDialog`: payload loses the same three fields; a `Connections` handler closes the sheet with a toast on `orderCreationDeferred`.
- e2e: `_withOnline` in the three suites that create orders; `OrdersStoreE2E` points the operation URL at the emulator.
- Guards: both dormancy guards become wiring guards (they name the files that may use the planner).

**Not built (NO3b, next):** `NewOrderDialog._setLinePrice` cap at `RestockFlow.MAX_UNIT_COST` with a visible message (KNOWN-ISSUES 114), the device pass (NO4).

## 2. Decisions (all vetoable in the PR)
**D-NO3-1 split NO3 into NO3a and NO3b.** One chat turn cannot carry the wire, the e2e rewiring, the tests and the dialog polish at the quality bar. Cost: for one merge window the dialog can send a price above 1e9; the planner refuses it with a text that names the line and the limit (`Line 1 (Tomato): ... A price can be at most 1000000000`), so nothing is lost silently, it is just found at Place order instead of at the field.

**D-NO3-2 pure refusals come before the connection check** (AP3a D-AP3-2). A person offline with an empty cart sees "Add at least one product", not "needs a connection" followed by the same refusal online.

**D-NO3-3 nothing is shown locally before the server answers.** The order number does not exist until the transaction runs (D-NO-1), so there is nothing to show; the dialog's busy overlay ("Placing order") covers the wait. Trade-off against the old path (instant local order, sync later): offline order taking is gone, which Taher ruled (Q-NO-3, option A). Honest note: restock and completion DO queue offline, so New Order is now the one sales-path write that does not (KNOWN-ISSUES 79).

**D-NO3-4 five outcomes, one callback `(ok, id, refusal, status)`:** `applied`, `replayed` (the server had ALREADY made the order: a resend after a lost answer; added in the 2026-11-24 review sweep, see D-NO3-5), `queued` (slow link: the operation stays in the outbox), `unconfirmed` (the server answered, `OrderPlan.reflect` refused the answer: the list is re-read, NO plain retry because a new tap is a new key and a SECOND order), and a refusal text. The dialog closes on `applied` and `replayed`, closes with a toast on `queued` and `unconfirmed`, and shows the text in its error line on a refusal (the sheet stays open and the cart is kept).

**D-NO3-5 a replayed answer never adds the order from the answer** (AP3a D-AP3-5): it is as of the FIRST application and the order may have been completed or edited since. The list is re-read. Consequence (KNOWN-ISSUES 126): auto-approve is NOT started after a replay or an unreadable answer; the order is in the list as pending and the person approves it by hand. Alternative (approve after the re-read): needs a callback after the fetch, which `syncFromFirebase` does not offer; not worth a new mechanism for a rare case. **Review sweep 2026-11-24:** the rule held for a LATE replay only. A LIVE replay (the waiter still waiting when the resend is answered) came back as `applied`, and `DataModel` then auto-approved it whenever a sync had already put the order in the list: which replays were approved depended on a race with the orders sync. The live replay now has its own status, `replayed`: the sheet closes like `applied`, no auto-approve starts, in every case.

**D-NO3-6 auto-approve starts after the answer, also for a late (queued) answer.** The setting means "approve new orders by itself"; a slow link must not change what it does. Risk: a sale completes with nobody looking (stock is checked by the completion itself, and a refusal is announced). Alternative: auto-approve only for a live answer. Q-NO3-2 asks.

**D-NO3-7 the dead arguments are deleted:** `items`, `total` and `status` (the planner refuses non-pending, `_normalizeOrder` computes items and totals). Cost: `Logic.addOrder`, `Main.qml`, the dialog payload, one QML smoke test and four e2e call sites change in this slice; benefit: no argument that lies (`total` was ignored whenever there were lines). A source pin (W-13) keeps `items:`, `total:` and `subtotal:` out of the store's own doc.

**D-NO3-8 the per-line loop in `addOrder` is deleted.** It copied each line and resolved tax from inventory, which `_normalizeOrder` already does for every line it is given (`qty` or `quantity`, inventory tax, discount parsing). W-2 proves `qty` and `quantity` lines give the same order and that tax still comes from inventory.

**D-NO3-9 `nextOrderId` stays as dead code with a comment** (the AP3a D-AP3-9 precedent): `operationLogic.createOrder.test.js` R-1 pins the server counter's format to its body. Delete both together (KNOWN-ISSUES 127).

**D-NO3-10 the e2e helpers go online for the add** through one `_withOnline` per file (AP3a's trap: going online runs `AuthService.init()`, which wipes the hand-set fixture token; the fixture is captured first and put back). Nesting is safe, so the 55-order pagination test uses one window. CI-only (unproven locally): KNOWN-ISSUES 128. A guard test (`orderE2eHelpers.guard.test.js`) pins the source.

**D-NO3-11 the typed text is trimmed** (D-NO2-5): a customer typed with a trailing space is stored without it. Orders made before and after differ by that only (KNOWN-ISSUES 108).

## 3. Data flow
tap -> `trySubmit` (busy = true) -> `orderCreated` -> `logic.addOrder` -> `DataModel.onAddOrder` -> `OrdersStore.addOrder`: `_normalizeOrder` makes the doc (one author of every total) -> `OrderPlan.build` (refusal = callback now) -> online check -> `Gateway.recordOperation(createOrder, awaitServer)`. Answer: live -> `_applyCreateOrder` -> `_addLocalOrder` (list, revision, CAS base) -> callback `applied` -> `DataModel`: `orderAdded` (dialog closes) + `_autoApproveNewOrder`. Late -> `Gateway.operationApplied` -> `onCreateOrderApplied` (no-op if the live callback settled it) -> returns the id -> `_autoApproveNewOrder`.

## 4. Deploy and compatibility
The server half (`createOrder`, NO1) must be deployed BEFORE this client: an older server answers 400 `unsupported-op-type` and no order can be placed. Rules unchanged. An order already queued by the PREVIOUS build used a plain mutation and drains as before. Revert is safe; an operation already in the outbox would stay queued with the "New order" label until the stuck-writes sheet discards it.

## 5. Questions for Taher (recommendation taken above; veto in the PR)
1. **Q-NO3-1 order again (Q-NO2-1 was only merged past).** Honest value check: after the mint a new order was already one document write, so this slice buys less than restock or add product did (no burned number, one minter of `counters/orders`, a text for every refusal). The stock-touching paths (`_tryAdjustOrder`, imported completion, reverse) are where a half-applied write corrupts stock or the ledger. Recommendation: after NO3b and the device pass, design `_tryAdjustOrder` next, before anything else on orders. Say so and the next session starts there.
2. **Q-NO3-2 D-NO3-6** auto-approve for an answer that arrives after the sheet closed: keep (recommended) or live answers only?
3. **Q-NO3-3** the toast for a slow link reads "Order saved. It appears in your list when it syncs". Is "saved" right when nothing is on the server yet? Alternative: "Order sent. It appears in your list when the server confirms".
4. **Q-NO2-2 / Q-NO2-3** still stand (a completed order can never be created by this operation; an empty customer is the only customer refusal in the planner).

## 6. Review sweep 2026-11-24 (requesting-code-review, qt-qml-review, ponytail-audit; one reviewer, no parallel agents)
Read: the whole diff, `Gateway.recordOperation/_finishOperation/discardParked`, `OrderPlan.build/reflect`, `FailureCause.forCreateOrder`, `OperationKeys` nonce, `_commit/_setOrders/applyRemoteOrder`, the server role gate (`recordOperation` has none for order creates, so staff can still place orders), every `addOrder` caller (all moved to the new shape). `qt_qml_lint.py` on the changed lines: no real finding (the hits are the project's `var`/`property var` style, `ORD-1` on the existing end-of-file `Connections`, and two `JS-2` false positives on `=== true ? :`).
**Fixed here:** (1) a live replay is `replayed` and never auto-approves (above); (2) the dialog's new `onOrderCreationDeferred` handler and the busy/emit rules had no test: `newOrderDialog.guard.test.js` pins the real source (D-1..D-6) and the replica test gained the deferred handler.
**Not changed (KNOWN-ISSUES 132):** see there.
