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
- Gate to start build: spec approval (#147) + Q-A7 (order) + Q-A8 (accept F7 open through the arc). Engine work (R1+) may start after those; S0 can start right after Q-A7.
