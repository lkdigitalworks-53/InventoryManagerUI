# Atomic operations — what exists, what does not, what is next

Written 2026-10-16 from a code read of `main` @ `6c6f358` (greps are reproducible, commands at the end). Anchor for handovers between sessions; update it when a path moves from "not atomic" to "atomic".

## 1. What was built (merged)

| Piece | Where | What it gives |
|---|---|---|
| `recordMutation` | `functions/lib/gatewayLogic.js`, `Gateway.recordMutation` | one doc, compare-and-set on `before`, one audit row, idempotent per `requestId` |
| `recordDelta` | same | atomic increment with floor/clamp on the server's current value (stock, batch `qtyRemaining`), idempotent |
| `recordOperation` / `applyOperation` | `functions/lib/operationLogic.js`, `Gateway.recordOperation` | N mutation/delta ops in ONE Firestore transaction, `audit_log/<requestId>` marker makes a retry a replay, per-op audit rows, all-or-nothing |
| Outbox | `OutboxStore.qml` | durable (Settings-backed) queue, key claims so writes to one record stay ordered, parked items, retry with backoff, request timeouts (`SendPolicy`) |
| Gateway signals | `Gateway.qml` | `operationApplied` / `operationRejected` fire even if the caller's callback died; `awaitServer` option |
| Stuck-writes sheet | PR #75, #97 | Retry now / Discard for parked writes |
| `completeOrder` | `CompletionPlan.js`, `DataModel._tryCompleteOrder`, PR #90 | the one operation type in production: FIFO deltas + drift repair + stock deltas + order update + sale docs, key `completeOrder:<orderId>:<epoch>` is stable across relaunch and sign-in |
| Completion UX | #139, #144 | cause text for a failed completion; "Saved. Syncing…" caption |
| Unsynced-edit ledger | `TransactionStore` `dependsOn` | orders a ledger row after its parent edit is acked. Ordering, not atomicity |
| Pending-mint retry queue | `StockBatchStore._pendingMints` | patch for a failed client id mint (batch only) |

## 2. Gaps (each with evidence)

| # | Gap | Evidence | Closed by |
|---|---|---|---|
| G1 | **One opType only.** `OP_TYPES = ["completeOrder"]`. Every other multi-write action is still N independent calls. | `operationLogic.js`; section 3 | this arc, one consumer per PR |
| G2 | **Ids are minted by separate client calls**, outside any transaction, for five counters (`products`, `suppliers`, `stockBatches-<year>`, `orders`, `staff`). A mint can time out, be repeated (burned number) or be lost; seeds come from the client's local max. | `FirebaseService.mintCounterValue/Batch`, 5 callers listed in section 3 | `mint` op (design v2) |
| G3 | **ActivityLog is a direct client PUT** (`activity_log/<id>`), 13 call sites, not a gateway entity, lost if the app dies before the callback. | `ActivityLog._pushOneToFirebase` | `activity_log` entity in the operation (Q-A3 yes) |
| G4 | **A random-key operation is lost on sign-out.** `OutboxStore.clear()` runs on sign-out on purpose. `completeOrder` survives that because its key is derived from order + epoch, so a re-run resends the same key. A restock key created at tap is random, so a queued restock cleared by sign-out is gone while the UI said done. | `OutboxStore.clear`, `LockManager` comment, `OperationKeys.completeOrderKey` | sign-out warning popup (design 4b, Q-A6 answered); loss stays possible if the user chooses discard; per-account outbox is the real fix, deferred |
| G5 | **Product delete cannot join an operation.** `cascade-delete-not-allowed` is enforced inside `validateOperationRequest` (the PH3 cleanup marker is not written by the transaction). | `operationLogic.js` | later PR; needs the marker in the transaction or a deliberate carve-out |
| G6 | **Server limits unverified.** `MAX_OPS = 200` and the ~500-write ceiling (and whether `serverTimestamp()` counts extra) are marked unverified in the source. Bulk import can never be one operation. | source comment, BC1 review R3 | chunked operations (one `requestId` per chunk) |
| G7 | **Optimistic state and undo exist only for completion** (`_applyPredicted`). Other paths mutate the local cache directly and rely on resync. | `DataModel._applyPredicted` | each consumer PR |
| G8 | **Conflict handling only for completion.** A `mutation` op with a stale `before` returns 409 `conflict`; only completion re-plans. | `applyOperation`, `DataModel._onCompletionRejected` | each consumer PR |
| G9 | **Account and config writes are sequential puts with hand-written compensation** (tenant, user, member docs; `config/categories`; `config/orderChannels`). The compensating `remove` can itself fail. | `AuthService.qml` 558-580, 904-929; `CategoryStore`, `OrderChannelStore` | out of scope here; same bug class, needs its own design (tenant/user docs are outside the tenant-scoped gateway) |
| G10 | **Import is chunked `recordMutations`**, atomic per chunk at best, not across chunks. | `InventoryStore.upsertMany` | step (4) in the plan |

## 3. Write paths still not atomic (as of this read)

| Path | Separate calls today |
|---|---|
| Restock | supplier mint + create (new name), batch mint, batch create, stock delta, purchase tx, ActivityLog PUT |
| Add product (`InventoryStore.addProduct`) | supplier mint/create, product mint, product create, ActivityLog PUT, "created" tx, batch mint, batch create |
| New order (`OrdersStore` create) | order mint, order create (plus completion if auto-approve) |
| Adjust order / return / exchange (`_tryAdjustOrder`, C-1) | stock deltas, credit without batch, order update, tx rows |
| `completeImportedOrder`, `_reverseCompletedOrder` | stock deltas, batch restore, order update, tx rows |
| Staff create/delete | staff create/delete, `removed_staff` tombstone, auth docs (G9) |
| Supplier create/update/delete | single mutation each (atomic as one doc; only the mint is outside) |
| Price adjust, product edit | single mutation (atomic as one doc) plus ledger row via `dependsOn` |

## 4. Order of work

0. Sign-out guard (gap G4): pure helper + sheet, independent of the engine. Proposed first (Q-A7).
1. Engine (`mint`, placeholders, `activity_log` entity) + restock. Design: `specs/2026-10-16-restock-atomic-operation-design.md`.
2. Add product with opening stock.
3. New order, then `_tryAdjustOrder`, `completeImportedOrder`, `_reverseCompletedOrder`.
4. Import with chunking. Product delete (G5) and account/config writes (G9) need their own designs first.
Each step: own branch, own PR, device-tested before the next.

## 5. Re-run the evidence

```
grep -n "OP_TYPES" functions/lib/operationLogic.js
grep -rn "Gateway\.record\(Mutation\|Delta\|Operation\)" qml --include=*.qml | grep -v Gateway.qml
grep -rn "FirebaseService\.\(put\|putMany\|patch\|remove\|mintCounter\)" qml/model --include=*.qml
grep -rn "ActivityLog.record(" qml --include=*.qml | grep -v ActivityLog.qml | wc -l
```

## 6. Update 2026-10-26 (P1 standing, after #161)
- Merged and deployed: #146 (S1a), S2f-1/2/4/5 (#161); Taher confirmed rules + functions deployed, device passes N6/E4 done. Open: #165 (S2f-7). Queued P1 tail: S2f-3 (client wording), owner-demotion slice, S2d, S2e (parked on CA, do not wait for it).
- New gap **G11:** `counters` and `activity_log` are on the client-writable allow-list; they leave it only after the last mint / activity-row caller moves into an op (design 7b items 2-3).
- `mint` = S2f-6: one implementation, built in R2.
- Gates: Q-A7 answered by action (S0 started in its own session); Q-A8 answered by Taher ("yes keep it as recommended"); spec approval = merge of #147. After the merge, the only gate left for R1+ is the implementation plan. Engine work (R1+) may start after those; S0 can start right after Q-A7.

## 7. Update 2026-10-28 (R1+R2 built)
- Merged since section 6: #167 (S0 sign-out guard), #168 (pending-mint tenant scope), #170 (S2d-1 kinds on deltas). In flight: #171 (S2f-3).
- **Built (branch `feat/2026-10-28-r2-mint-engine`, server only):** `mint` op, `{{name}}` substitution, `counterRegistry.js` (supplier + stock_batch), collision skip, seed from ids, `restock` opType, replay results. G2 is closed on the SERVER only: no client calls it. Design `specs/2026-10-28-r2-mint-engine-design.md`.
- R1 evidence (counter doc shape, formats, doc id = entity id) is in that design, section 1; a source guard test pins it.
- Next: R3 (`OperationKeys.restockKey`, pure `RestockPlan.build`, apply-from-results hooks), then R4 (`InventoryStore.restock` rewrite + latch + picker hide), R5 (dialog, `FailureCause`, `activity_log` id). Deploy functions BEFORE the client.


## 8. Update 2026-11-01 (R3 built, dormant)
- Merged and deployed since section 7: #172 (R1+R2 server `mint` op; Taher confirmed deploy and device test), #175 (L3 design), #176 (Node 24), #177 (IAM docs).
- **Built (branch `feat/2026-11-01-r3-restock-plan`, client pure layer, nothing calls it):** `OperationKeys.restockNonce/restockKey/isRestockKey/purchaseTxId`, `qml/helper/RestockPlan.js` (`build` and `reflect`), `FailureCause.forRestock` (+ the R2 codes as app problems in `forRejection`), the restock label in `DescribeItem`, `SupplierStore.addLocalSupplier`, `InventoryStore.applyRestockResults`. Design `specs/2026-11-01-r3-restock-plan-design.md` (T1-T10, vetoable in the PR), test plan `test-plans/2026-11-01-r3-restock-plan-test-plan.md`, Skill 150.
- Evidence: the planner runs in Node against the REAL server code (`functions/test/testSupport/qmlHelpers.js` loads the `.pragma library` helpers), so "the client plans what the server accepts" is tested, not assumed. QML tests are CI-only.
- G4 still open (sign-out clears the outbox, so a queued restock abandoned by sign-out is gone); R4 decides how the sign-out sheet reports it.
- Next: R4 (`InventoryStore.restock` rewrite with the key made at the tap, a synchronous per-product latch, picker hide for a queued restock, a `DataModel` route for `operationApplied` with opType `restock` into `applyRestockResults(results, {replay})`; refresh the product's stock after a replay), then R5 (dialog wording, `activity_log` entity inside the operation, `ActivityLog.record` id parameter), then R6 (docs and device test). Deploy status: functions already deployed.

## 9. Review sweep of PR #181 (2026-11-01): fixed in the PR, and roadmap observations
- **Fixed in PR #181 (same branch, no stacked PR):** F1 overflowing `qty * unitCost` is refused (`bad-cost`, T12); F2 a doc over Firestore's 1 MiB is refused (`too-large`, T11); F3 thirteen server validator codes are app problems in `FailureCause`, with a drift test over the server's whole code list; F4 `OperationKeys` entropy comment; F5 design T7 wording. Evidence: functions 985/985, scripts 470/470, six of six hand mutants killed; QML twins run in a throwaway Node harness, CI is the QML oracle.
- **Observations for R4 (not done here, by scope):**
  - O1 supplier resolution: `{ id }` vs `{ newName }` must follow `_resolveSupplierId` (a `SUP-` prefix is an id, a known name matches case-insensitively). Two offline devices typing the same new name still make two suppliers; the server does not dedupe by name and the old path had the same race. Decide whether a server-side name check belongs to a later slice.
  - O2 `amount || 10`: the old `restock` turned amount 0 into 10; the planner refuses 0. R4 decides.
  - O3 a replayed answer carries the batch and supplier as of the first application; R4 re-reads the product and must not trust a replayed `qtyRemaining` for FIFO figures until the next sync.
  - O4 `now` and `date` are format-checked only; R4's caller test pins that both come from one `new Date()`.
- **Observations for R5 (wording and field limits):** person-facing texts for `too-large`, `reserved-text` and an overflowing `bad-cost`; a `maximumLength` on the restock reason field on top of the planner guard; the cost field accepts `1e308` through `parseFloat`.

## 10. Update 2026-11-02 (R4 built: restock is one operation)
- Merged since section 9: #181 (R3 planner), deployed and device-tested by Taher.
- **Built (branch `feat/2026-11-02-r4-restock-wire`):** `InventoryStore.restock` plans with `RestockPlan` and sends ONE `recordOperation("restock", ...)`; `qml/helper/RestockFlow.js` (supplier resolution O1, one `Date` O4, outcome classification, refusal and Activity texts); `OutboxStore.hasQueuedOperationFor` as the durable per-product latch; `InventoryStore.onRestockApplied/onRestockRejected` called from the `DataModel` Connections for opType `restock` (late answers, relaunch, replay with a re-read, O3); the product is hidden from the New Order picker and refused at completion while a restock is queued (Q-A2); `amount || 10` removed (O2); callback `(ok, queued, refusal)`. Design `specs/2026-11-02-r4-restock-wire-design.md` (R4-D1 to R4-D10, vetoable), test plan `test-plans/2026-11-02-r4-restock-wire-test-plan.md`, Skill 155.
- Evidence (after the review sweep and the merge of L4a): functions 1043/1043, scripts 905/905; the real bodies of the new `InventoryStore` functions run in Node against the real server code; 23 of 23 hand mutants killed. QML tests and one emulator e2e case are CI-only.
- **Observations found while building, NOT done (scope):**
  - P1 The restock dialog's "add new party" still creates the supplier through the old separate mint (`SupplierStore.addSupplier`) BEFORE the restock. A restock that then fails leaves an orphan supplier. R5 should pass the typed name so the supplier joins the operation.
  - P2 `TransactionStore.recordPurchase` has no production caller now. It stays only for its own tests and the R3 doc-shape drift guard (D-1); remove it when R5 moves the guard to the planner.
  - P3 G4 is unchanged: sign-out clears the outbox, so a queued restock abandoned by sign-out is gone. The sign-out sheet describes it (R3 `DescribeItem` label) but does not block it; decide in R5 or a sign-out slice.
  - P4 The New Order picker rebuilds on open and on cart change only. A restock that settles while the sheet is open stays hidden until the next rebuild; the completion guard is the backstop. A binding on `OutboxStore.items` would fix it; not done to keep the slice small.
  - P5 Two offline devices typing the same NEW supplier name still make two suppliers (O1, unchanged).
  - P7 A replayed or unreadable answer re-reads the inventory with `syncFromFirebase`, which empties the list until the fetch answers (same as the discard resync), so the inventory list can flash empty in that rare case. A merge-in-place re-read would avoid it; not done.
  - P8 FIXED in the review sweep (design section 6, D-1): an edit or delete of a product with a queued restock was sent with a stale `before` and got 409. Now refused while the restock is queued.
  - P9 FIXED in the review sweep (design section 6, D-2): the restock dialog booked a blank or mistyped cost as 0; now blank = recorded cost, junk = refused.
  - P6 `_restockSettled` keeps a few bytes for a key whose signal never comes (sign-out mid-flight).
- Next: R5 (dialog wording and `maximumLength`, the typed name passed into the operation (P1), `activity_log` entity inside the operation with an id parameter on `ActivityLog.record`, P2), then R6 (docs and device test of the whole arc). Taher's veto window for R4-D1 (one open restock per product) and R4-D4 (hidden from sales while queued) is the PR.

## 11. Update 2026-11-10 (R5a built: the dialog's new supplier joins the operation)
- Merged since section 10: #183 (R4) with its review sweeps, #188, #190 (toasts above dialogs, busy overlays).
- **R5 was split** (design `specs/2026-11-10-r5a-restock-dialog-design.md`, D-R5-1). **Built (branch `feat/2026-11-10-r5a-restock-dialog-supplier-in-op`, client only, no deploy):** P1 closed (the sheet's "Save" that minted and created a supplier BEFORE the restock is now "Use": the name is held and travels in the operation, so a refused or cancelled restock leaves no orphan supplier and burns no number); `RestockFlow.supplierFor` accepts `{ id }` and `{ newName }`, `partyFor`, `newPartyChoice`; field limits (reason 500 = the server's movement-reason limit, supplier name 100, unit cost 1e9) in the dialog and again at the tap; texts for the three new refusals; `AuthTextField.maxLength`. Test plan `test-plans/2026-11-10-r5a-restock-dialog-test-plan.md`, Skill 164. Evidence: functions 1327/1327, scripts 905/905, 26 of 26 hand mutants killed; QML twin and the dialog itself are CI and on-device.
- **Found while building, fixed here:** the reason was cut at 500 characters in the ledger row only, whole in the batch note and the purchase row (one restock, three reasons). The field limit makes them equal.
- **Still open (R5b, next branch):** the `activity_log` entry inside the operation (Q-A3) with an operation-only server entity map (do NOT add it to `ENTITY_COLLECTIONS`, five other endpoints read that map), server-stamped `actorUid` and timestamp, `ActivityLog.record` id parameter; P2 (`TransactionStore.recordPurchase` removal, doc-shape guard moved to the planner). Server deploy BEFORE the client. Then R6 (docs and device test of the whole arc).
- **Still open, other slices:** `AddProductDialog` has the same inline "add new party" row and still creates the supplier by the separate mint (belongs to step 2, add product with opening stock); P3/G4 sign-out; O1 two offline devices typing one new name; P4, P6, P7 of section 10.
- **PR #191 review sweep (same branch):** nine defects fixed with tests (functions 1327 -> 1343, QML twins +11): `costFromText` read hex, binary, octal and exponent text as a price and kept a negative zero; a known supplier name over 100 characters was refused; a name typed but never sent with "Use" was dropped at Confirm; the stock line and the SpinBox text could differ from what Confirm books; supplier names had no single spelling (accent forms, zero-width, whitespace); the purchase total was not rounded to 2 places. Details: test plan section 8, Skill 164 rules 8 to 14.
- **PR #191 review pass 3 (2026-11-11, CI red: 2 of 2944 QML tests):** `tst_RestockFlow.qml` did not compile (`var long` is a reserved word in QML's JavaScript, so none of its tests ran) and `tst_InventoryStore_movementKinds` still expected the old cut at 500; both fixed, plus `functions/test/qmlReservedWords.guard.test.js` so the Node job catches a reserved word first. Product fix: U+200C and U+200D (needed by Indic and Persian scripts) are no longer stripped from a stored supplier name (D-R5-13). **Decided by Taher (option A, built, D-R5-14):** a restock whose NEW supplier name equals the name a still-queued restock creates is refused (`RestockFlow.queuedNewSupplierClash` over `OutboxStore.items`), so one phone cannot create the same supplier twice; two-phone case (O1) stays open. Functions 1413 -> 1434 (+8 pass 3 earlier, +13 option A).

## 12. Update 2026-11-11 (P1 compliance: S4a register read model)
- Not an atomic-operations change; recorded here because this file is the P1 anchor too (sections 6 and 7). P1 standing: S1a, S1b, S2a-c, S2d-1, S2f-1..7 merged; S2d-2, S2e, S3 open; S4 split into S4a (built now: `computeStockRegister`, server, read-only), S4b (client page), S4c (CA column layout).
- Nothing in the app reads the ledger yet. `stock_movements` read is still `isMember` in the rules (KNOWN-ISSUES, P1 S4a item 1): restrict it before S2e writes real `valueAtCost`.
- NEXT TASK after #193 merges: the S4a follow-ups in one PR, `plans/2026-11-11-p1-s4a-followups-one-pr-plan.md` (older-handler context `try`, ledger `productName`, ledger read rule, `count()` pre-check).
- Design `specs/2026-11-11-p1-s4a-stock-register-design.md`; the R5a PR (#191) and R5b are independent of it.

## 13. Update 2026-11-12 (R5b built: the feed row is inside the restock operation)
- Merged since section 12: #191 (R5a), #193 (S4a), #194 (picker S3), #195 (S4a follow-ups).
- **Built (branch `feat/2026-11-12-r5b-activity-log-in-op`):** an operation-only entity `activity` in `operationLogic.js` (NOT in `ENTITY_COLLECTIONS`; create-only, `restock` only, one fixed seven-key shape, the server stamps `actorUid` and an ISO `timestamp`, `{{$stock}}` filled from the same operation's delta); `RestockPlan` builds the row last (id `act-{{batch}}`) and `reflect` reads it; `ActivityLog.adopt` shows the server's row without a second write; `InventoryStore` adopts it and keeps the old client row only for an answer to a restock queued by the previous build; P2 closed (`TransactionStore.recordPurchase` deleted, doc-shape guard pinned to a key list). Design `specs/2026-11-12-r5b-activity-in-operation-design.md` (D-R5b-1..8), test plan `test-plans/2026-11-12-r5b-activity-in-operation-test-plan.md`, Skill 166.
- Evidence: functions 1711/1711, scripts 1049/1049, 16 of 16 hand mutants killed; QML twins and two emulator cases are CI-only.
- **Deploy order: functions FIRST.** A new client against an old server gets 400 `unsupported-entity` for the feed op. Rules unchanged.
- G3 is closed for the restock path only: 12 other `ActivityLog.record` call sites are still direct client PUTs (they move with their own operations). `activity_log` stays on the rules allow-list (KNOWN-ISSUES 27).
- **Next (arc order):** R6 (docs and device test of the whole restock arc), then step 2 (add product with opening stock, which also takes `AddProductDialog`'s inline supplier row), step 3 (new order, `_tryAdjustOrder`, imported completion, reverse), step 4 (import chunking; product delete G5 and account writes G9 need designs). P3/G4 sign-out is unchanged.

## 14. Update 2026-11-13 (step 2 started: AP1, add product, server only)
- Merged and deployed since section 13: #197 (R5b; `deployed-main` = `024a6f6`, read 2026-11-13), so the restock arc is fully on the server and R6 (device test of the whole restock arc, test plan sections 7 and 10) is Taher's and unblocked. KNOWN-ISSUES 33 (restock toast "server cannot accept this request") was a sequencing problem of the open PR, not a code defect: the deploy that carries R5b's server half has now happened.
- **Built (branch `feat/2026-11-13-ap1-add-product-server-op`, server only, dormant):** opType `addProduct`, registry key `product`, the feed entity open to two op types with one kind each. G2 is now closed on the server for products too (no client calls it yet). Design `specs/2026-11-13-add-product-atomic-operation-design.md` (D-AP-1..10), test plan `test-plans/2026-11-13-ap1-add-product-server-test-plan.md`, Skill 168. Evidence: functions 1754/1754 (+34), 100% line/branch/function on both changed files, 16 of 16 hand mutants killed; the three emulator cases are CI-only.
- **Step 2 is sliced (design D-AP-1):** AP1 server (this) -> AP2 client pure layer (`OperationKeys.addProductKey`, `AddProductPlan.build/reflect`, `FailureCause`, `DescribeItem`; dormant) -> AP3 wire `InventoryStore.addProduct` + `AddProductDialog` (takes the dialog's inline supplier row: the R5a "Use" pattern) + the `DataModel` route -> AP4 docs and device test.
- **Gates for AP3 (Taher):** D-AP-7 offline add (recommended: refuse with a clear text; the id is server-minted so offline there is nothing to show or attach a photo to) and D-AP-8 (photo attached from the live answer only).
- **Gap lines:** G1 now has two op types beside `completeOrder` (`restock`, `addProduct`); G3 stays closed for restock only (`product_added` still a client PUT until AP3); G2 closed on the server for suppliers, batches and products.
- **Next (arc order):** AP2, AP3, AP4, then step 3 (new order, `_tryAdjustOrder`, imported completion, reverse), step 4 (import chunking; G5 and G9 need designs). P3/G4 sign-out unchanged.
