# Step 3 design: a new order is ONE atomic operation (slice NO1 = server, dormant)

Date 2026-11-21. Branch `feat/2026-11-21-no1-create-order-server-op`, cut from `main` @ `68afa5c` (#206 merged; #207 AP3b merged). Source: `ATOMIC-OPERATIONS-STATUS.md` sections 3 and 4 (step 3: "new order, then `_tryAdjustOrder`, imported completion, reverse"), section 17 "Next".

## 0. Where the roadmap stood (read from `main`)
Done: step 1 restock (R1-R5b), step 2 add product (AP1, AP2, AP3a, AP3b). AP4 is the device pass of the whole add arc, which is yours, not code. Open and next: step 3, in the order the roadmap gives: new order, `_tryAdjustOrder`, `completeImportedOrder`, `_reverseCompletedOrder`; then step 4 (import chunking, G5, G9). Small follow-ups waiting: KNOWN-ISSUES 62 (Edit Product lenient parsing), 54, 50. The two AP3b questions (D-AP3b-2 whole-number stock, D-AP3b-9 no selling below cost) were not vetoed in the merged PR, so they stand.

## 1. Problem (evidence, read from `main`)
`OrdersStore.addOrder` (called by `DataModel.onAddOrder`, from `Main.qml` `NewOrderDialog.onOrderCreated`) does two things in two independent steps:

| # | Step | How | Failure today |
|---|---|---|---|
| 1 | order id | `FirebaseService.mintCounterValue("counters/orders", seedMax)`, REST, OUTSIDE any transaction, seed = highest local id | a timeout burns a number or repeats one; two phones race the seed; a lost answer leaves a gap |
| 2 | `orders/<id>` create | `_commit` -> `Gateway.recordMutation("order", id, "create", null, doc)` | durable and idempotent per request id, but the id it carries came from step 1 |

Nothing else is written: no feed row (`order_deleted` is the only order kind in Activity), no ledger row, no transaction row. With auto-approve ON, `DataModel` then starts `_tryCompleteOrder` as a SECOND operation (`completeOrder`), keyed on the order id.

Honest value check: after the mint, a new order is already ONE document write, so this slice buys less than restock or add product did. It closes G2 for orders (no burned or repeated number, the id minted in the same transaction as the doc, a retry is a replay), moves the order counter to a single minter (G11 needs this for `counters` to leave the client-writable allow-list, together with import and staff), and gives the later steps a server `order` id space. It does NOT reduce risk on the paths that touch stock: `_tryAdjustOrder`, imported completion and reverse are multi-doc and are where a half-applied write corrupts stock or the ledger. See question Q-NO-1.

## 2. The operation (what the server accepts)
`opType: "createOrder"`, key `createOrder:<nonce>` (client key helper in NO2). Ops, in this order:

```
mint    order -> {{ord}}
create  order/{{ord}}    after: the order doc (orderId {{ord}}, status "pending" ...), exactly what OrdersStore._normalizeOrder builds
```

Nothing in `applyOperation` changes. The audit row for op 1 and the marker come from the existing engine. No ledger row (an order is not an inventory write), no feed row.

## 3. Decisions (all vetoable in the PR)
**D-NO-1: slice the step, server first and dormant** (same reasoning as D-AP-1 / KNOWN-ISSUES 33). NO1 (this PR) server only. NO2 client pure layer (`OperationKeys.createOrderKey/Nonce`, `OrderPlan.build/reflect`, `FailureCause.forCreateOrder`, `DescribeItem` label; dormant). NO3 wire `OrdersStore.addOrder` + `DataModel.onAddOrder` + `NewOrderDialog` callback + the `DataModel` route for `operationApplied/Rejected`. NO4 docs + device test. Cost: more PR cycles; benefit: every slice device-testable while open.

**D-NO-2: a new opType, not a generic `create`.** The audit trail, the `createOrder:` replay namespace and later per-opType rules key on it. One allow-list entry, deployed before any client by construction.

**D-NO-3: the order id comes from a server counter (`order` registry entry), `ORD-` + number padded to 3 digits, counter doc `counters/orders`.** Byte-identical to `OrdersStore.nextOrderId` and to the bulk import's `mintCounterBatch` formatter, pinned by `counterRegistry.guard.test.js` (5 new rows, 5 new source mutants). The import keeps minting from the same doc over REST until step 4; the engine's collision probe and one-jump heal already handle two writers (B-5, B-6, B-11).

**D-NO-4: no feed row.** A new order writes none today, so the operation must not invent one. Whether order creation belongs in Activity is a product question (recorded, KNOWN-ISSUES 77), not an atomicity one. Consequence: `activity` entity stays restricted to `restock` and `addProduct` (V-9 pins it).

**D-NO-5: no per-opType shape check on the server** (same as D-AP-6). The planner (NO2) is the shape authority and its tests run against this real server code. Pinned as documented gaps K-1 (an empty doc is accepted), K-3 (stock deltas may ride along), K-4 (an id with an embedded token is accepted). Each op is still validated by the shared validators (entity allow-list, create-only conflict, id safety, write budget).

**D-NO-6 (for NO3): auto-approve stays a SECOND operation.** `completeOrder` is keyed on the order id plus an epoch, and its FIFO plan is built from stock the client reads. With a server-minted id the client cannot plan the completion before the answer, and one combined operation would make a stock shortage refuse the order itself. Today the order is created pending and a completion failure shows its cause; that stays. Options: A (recommended) two operations, as today; B one combined operation planned on the server (rejected: moves FIFO planning into the server, a second source of truth); C pre-allocate the id (rejected: that is the burned-number problem again). Cost of A: a crash between the two leaves a pending order, exactly as today.

**D-NO-7 (for NO3, grilled below): creating an order needs a connection.** Today an offline tap already ends in "Could not add order" (the REST mint fails), so refusing offline with a clear text loses nothing. Options: A (recommended) refuse with a clear text, same pattern as D-AP-7; B queue the operation and show the order when the answer lands (the cart is cleared, the person sees "saved" and no order, a second tap makes a duplicate sale); C provisional local id remapped on the answer (rejected: touches order lines, locks, completion keys).

**D-NO-8: no legacy client fallback** (AGENTS rule 4). Queued `order` creates written by the old path are plain `recordMutation` items and are still sent by the unchanged Gateway.

**D-NO-9: order mint seeding at scale.** The engine lists the whole `orders` collection ONLY when the counter doc is damaged or an id collides (B-7, B-5/B-6), never for a healthy counter (B-8 pins `listCalls == []`). A shop with tens of thousands of orders pays that listing once per damaged counter. Recorded (KNOWN-ISSUES 74), not changed: a counter-only heal would change the engine for every op type.

## 4. Deploy and compatibility
Additive: `OP_TYPES` gains one entry, the registry gains one key. No client sends it, so nothing observable changes; old clients keep working; a revert is safe. Functions deploy on merge after your one-tap approval, which can be given at once because it is dormant. A guard test (G-1) fails the day any QML names `createOrder` without a decision.

## 5. What changes in NO1
- `functions/lib/counterRegistry.js`: `order` entry.
- `functions/lib/operationLogic.js`: `createOrder` in `OP_TYPES` (+ comment).
- Tests: new `operationLogic.createOrder.test.js` (35); `counterRegistry.guard.test.js` (+5 rows, +5 mutants); `index.handlers.recordOperation.test.js` (+2); `index.handlers.ownerOnlyWrites.test.js` (+1 endpoint row, +1 role regression); three one-line pins flipped (`order` was the "not a registered counter" example; now `customer` / `staff`); three emulator cases in `test/e2e/recordOperation.e2e.test.js` (CI only).
- Docs: this design, test plan, README, AGENTS, Skill 180 + index, ATOMIC-OPERATIONS-STATUS section 18, KNOWN-ISSUES 74-78, CHECKPOINT.
- No QML, no rules, no `functions/index.js` change (a new order is not an owner/admin-only write; the role regression pins all four roles).

## 6. Not in this slice
NO2 to NO4 above; `_tryAdjustOrder`, `completeImportedOrder`, `_reverseCompletedOrder` (each needs its own design: stock deltas, credit without batch, order update, tx rows); import chunking (step 4); an order feed kind; `addOrder`'s `callback(true, id)` signature change (NO3).

## 7. Questions for Taher (recommendation taken above; veto in the PR)
1. **Q-NO-1 order of step 3.** Roadmap order (taken): new order first. Risk-first alternative: design `_tryAdjustOrder` + reverse before NO2/NO3, because they touch stock and the ledger across several docs and a half-applied write there is the one that corrupts data. Trade-off: new order is small and mechanical (three more small PRs, the pattern is proven twice); the adjust/reverse designs are large and need your product rulings (credit without batch, return conditions). I would finish NO2 and NO3 first (cheap, unblocks removing the order mint from the client) and start the adjust design right after; say so if you want it the other way.
2. **Q-NO-2 D-NO-6** auto-approve as a second operation (A) or a combined one (B, rejected).
3. **Q-NO-3 D-NO-7** offline new order: refuse (A), queue (B), provisional id (C, rejected). Do you ever take orders with no signal and enter them later? If yes, B or a different design is needed and I want to hear it before NO3.
4. **Q-NO-4 D-NO-4** should creating an order appear in the Activity feed? Today it does not. Adding it is a product change plus a feed kind in the shared kind table.
