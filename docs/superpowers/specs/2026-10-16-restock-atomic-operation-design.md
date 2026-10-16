# Design — Restock as one atomic, replay-safe operation

**Status:** DECISIONS RECORDED 2026-10-16 (Taher answered Q-RS-1..7, section 4). Awaiting spec approval + one confirmation (D1 gaps). No product code written.
**Date:** 2026-10-16. **Branch:** `docs/2026-10-16-restock-atomic-operation-design`.
**Path:** architectural (new `opType` = server deploy, new client flow). Spec, then plan, then build.
**Origin:** `docs/superpowers/KNOWN-ISSUES.md` first entry (decided 2026-09-30: "make batch + stock delta ONE atomic operation"). Roadmap: `E2E-TESTING-ROADMAP.md` item "Order completion can double-consume the FIFO ledger" (status lines 2026-10-13/14).

## 1. Understanding (write-back, please correct)

**Said by Taher:** restock must land batch + stock together or not at all (decision 2026-09-30). Idempotency and atomicity for network calls generally, not one-off patches (2026-09-16).
**Assumed by me (check these):**
- Success = after any failure, relaunch or retry, Firestore never shows a batch without its stock or stock without its batch, and the purchase record and ActivityLog entry exist exactly once.
- Offline restock keeps working as today (queued, applied on reconnect).
- This session is restock only. Product-create-with-opening-stock and bulk import have the same `addBatch` shape and are unchecked (KNOWN-ISSUES says so). They are a follow-up, not this scope.

## 2. What the code does today (read, not assumed)

`InventoryStore.restock` (`qml/model/InventoryStore.qml:1207`):
1. refuses if the product has a parked write (D2, keep);
2. resolves supplier (`_resolveSupplierId`, may auto-create a supplier);
3. `StockBatchStore.addBatch` — mints a batch id over the network (`nextBatchId`, 15 s timeout, failure goes to a durable pending-mint queue), then `Gateway.recordMutation("stock_batch", create)`;
4. in parallel `Gateway.recordDelta("inventory", id, {stock:+qty})`;
5. only in the delta's in-memory callback: local stock update, `ActivityLog.record`, `TransactionStore.recordPurchase`.

Failure shapes this produces:
| # | Failure | Result |
|---|---|---|
| F1 | delta gets a 4xx, batch is retried forever | batch without stock (the on-device bug) |
| F2 | delta lands, relaunch before its callback | stock without ActivityLog or purchase record (callback is in memory) |
| F3 | batch id mint fails | stock without batch until reconnect retry; product hidden from pickers meanwhile |
| F4 | double tap or retry | two batches, two deltas (no shared key) |

The mechanism to fix this already exists and is merged: `Gateway.recordOperation(opType, ops, opKey, options, cb)` and server `applyOperation` (`functions/lib/operationLogic.js`): one Firestore transaction, `requestId` marker makes a retry a no-op, `operationApplied` / `operationRejected` signals fire even if the caller's callback died. It is generic (delta + mutation ops); only `OP_TYPES = ["completeOrder"]` is specific.

## 3. Design (after Taher's answers)

**One operation, `opType: "restock"`, `requestId: "restock:<batchId>"`, three ops in one transaction:**
1. `delta` `inventory/<productId>` `{ stock: +qty }` (no floor, no clamp), plus explicit `movements: [{kind:"receipt", qty, reason, valueAtCost}]` once #146 is in;
2. `mutation create` `stock_batch/<batchId>` (batch id minted by the existing sequential counter, D1);
3. `mutation create` `transaction/<txId>` with the purchase doc, `txId = "tx-p-" + batchId` (deterministic, same pattern as `OperationKeys.saleTxId`).

The key is derived from the minted batch id, so the id that is persisted in the outbox item IS the idempotency key: any retry, relaunch or resend of that outbox item sends the same `requestId` and the server replays the first result.

Server change: `"restock"` added to `OP_TYPES` plus tests. `recordOperation` itself is deployed and device-tested (Taher, 2026-10-16), so only this opType needs a deploy, and it must be deployed before the client ships.

**Client flow (`InventoryStore.restock`), in this order:**
1. refuse if the product has a parked write (D2, kept);
2. refuse if a restock for this product is already between tap and enqueue (new in-flight guard, D4);
3. resolve supplier (unchanged, failure handling unchanged);
4. mint the batch id (`StockBatchStore.nextBatchId`, 15 s timeout). **Mint fails: refuse with "Can't restock right now, check your connection" and write nothing** (D1: restock is online-only to start; no pending-mint queue entry);
5. build the three docs with pure builders, `Gateway.recordOperation("restock", ops, key, { awaitServer: online }, cb)`. The moment the outbox item is persisted the tap is durable;
6. applied: local stock from the server's `after.stock`, add batch + purchase docs locally, `ActivityLog.record` in the callback (D3);
7. rejected or Discard: nothing was written server-side; undo optimistic state, show cause text;
8. queued (await window elapsed, or connectivity lost after the mint): show as done, optimistic apply with undo (same pattern as completion `_applyPredicted`).

**Removed:** the parallel `addBatch` + `recordDelta` pair in `restock` and the callback-gated purchase write. `addBatch` and the pending-mint queue stay for create-product and import.

**Interaction with PR #146 (open):** it changes `operationLogic.js` and defaults movement kind by opType (`completeOrder: "sale"`, else `adjustment`). Restock sends explicit `receipt` movements, so no second edit of that default map. Build after #146 merges.

## 4. Decisions (Taher, 2026-10-16) and the cost of each

| # | Decision | What it costs (accepted knowingly) |
|---|---|---|
| D1 (Q-RS-1) | Keep sequential `BAT-YYYY-NNN` ids; mint before the operation; restock is online-only. | (a) A restock offline is refused. Before this, an offline restock queued the stock delta. Warehouse receiving on a weak connection is where you will feel it. (b) "Sequential" means increasing, **not gapless**: the counter is consumed at mint, so a restock the server then rejects (suspended member, product gone) or a mint that succeeds but never enqueues leaves a hole. Today already works this way. Gapless numbering needs the server to mint inside the transaction, which was the rejected option C. **Confirm gaps are acceptable.** |
| D2 (Q-RS-2) | Purchase record is a third op inside the operation. | Server validates a `transaction` doc generically only. |
| D3 (Q-RS-3) | ActivityLog is not audit level: written in the operation callback, may be lost if the app dies before the answer arrives. | `shortcut: ActivityLog entry is in-memory-callback only, upgrade if the feed becomes an audit trail.` No `ActivityLog.record` change. |
| D4 (Q-RS-4) | No id created at dialog open. The id exists only after tap (the minted batch id). | See below. |
| D5 (Q-RS-5) | No per-opType server shape check. | Same trust model as `completeOrder`; debt comment on the validator. |
| D6 (Q-RS-6) | No "Saved. Syncing…" caption for restock. | An offline-then-queued restock looks like a landed one until sync (rare now, since the mint needs network). |
| D7 (Q-RS-7) | Hard dependency, no fallback to the two-write path. `recordOperation` deployed and device-tested. | Deploy `restock` opType before the client. |

**On D4, the honest answer to "what happens when the user cancels?":** with an id created at open, cancel only drops an in-memory value. Nothing is persisted and nothing reaches the server until tap, so cancel was harmless. I still accept the objection, because the real requirement is that **the tap is the durable event**, and with D1 the batch id is minted at the tap anyway, so it is the natural key. What an open-time id bought was double-tap protection, because a second tap reused the same id. Without it, two quick taps mint two ids and make two restocks. So the protection moves to the store: a per-product in-flight guard set synchronously at the start of `restock` and cleared when the outbox item is persisted or the attempt fails (the same pattern as `_completingOrderIds`), plus the dialog's existing `busy`. The guard window is only mint + enqueue; a deliberate second restock after that is legitimate and gets its own key. **Residual risk:** idempotency across a double tap now rests on that guard, not on the key. It must be pinned by a test that fires two `restock` calls in the same tick.

## 5. Build order (each its own branch off `main`, small PRs)

| Step | What | Where |
|---|---|---|
| R1 | Pure builder `RestockPlan.build(batchId, ...)` (ops, key, tx id) | `qml/helper/RestockPlan.js`, `OperationKeys.restockKey/purchaseTxId` |
| R2 | Server: `OP_TYPES += "restock"`, receipt movement, tests | `functions/lib/operationLogic.js`, `functions/test/` (after #146) |
| R3 | Store hooks: apply-remote for batch and purchase docs (reuse `addLocalBatch`/`addLocalEntries`) | `StockBatchStore`, `TransactionStore` |
| R4 | `InventoryStore.restock` rewrite: in-flight guard, mint-or-refuse, `recordOperation`, applied/rejected/queued handling, parked guard kept | `InventoryStore.qml` |
| R5 | `RestockDialog`: refusal text for mint failure, busy handling, `FailureCause` texts | `RestockDialog.qml`, `FailureCause.js` |
| R6 | Docs, device test | docs |

## 6. Risks
- **Online-only restock** (D1a) is a behaviour regression for weak-connection receiving. Revisit if it hurts.
- **Id gaps** (D1b), see D1.
- **Double tap rests on the in-flight guard** (D4). Test must prove it.
- **Pending-mint queue** stays for create/import; restock no longer feeds it. Do not delete it.
- **Local state on a queued operation:** copy completion's `_applyPredicted` + undo; do not invent a new pattern.
- **Mint succeeded, enqueue never happened** (app killed between): a burned number and no restock; the user sees no restock and can retry. Acceptable, document it.
- **`MAX_OPS`** is unverified in source comments; 3 ops is far below any plausible limit.

## 7. Not in scope
Create-product opening stock, bulk import, C-1 `_tryAdjustOrder`, `completeImportedOrder`, `_reverseCompletedOrder`; the other ledger kinds; per-opType server validation (Q-RS-5); request timeouts app-wide.
