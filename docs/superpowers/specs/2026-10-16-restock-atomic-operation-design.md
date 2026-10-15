# Design — Restock as one atomic, replay-safe operation

**Status:** DRAFT, awaiting Taher's answers to Q-RS-1..7. No product code written.
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

## 3. Proposed design

**One operation, `opType: "restock"`, `requestId: "restock:<restockId>"`, three ops in one transaction:**
1. `delta` `inventory/<productId>` `{ stock: +qty }` (no floor, no clamp);
2. `mutation create` `stock_batch/<batchId>` with the batch doc;
3. `mutation create` `transaction/<txId>` with the purchase doc (`txId = "tx-p-" + restockId`, same pattern as `OperationKeys.saleTxId`).

Server change: add `"restock"` to `OP_TYPES` plus tests. Nothing else is needed for atomicity. (Optional hardening: Q-RS-5.)

**Client flow (`InventoryStore.restock`):**
- keep the parked-write refusal and supplier resolution as they are (supplier failure handling unchanged, per KNOWN-ISSUES lead);
- build the three docs with pure builders (no Gateway side effects), like Task 9's `buildSaleDocs`;
- `Gateway.recordOperation("restock", ops, key, { awaitServer: online }, cb)`;
- on applied (result or `operationApplied` signal): set local stock from the server's `after.stock`, add batch and purchase docs locally, write the ActivityLog entry;
- on rejection or Discard: nothing was written server-side, undo any optimistic local state, tell the user why (existing `FailureCause` texts);
- queued (offline or await window elapsed): show as done, "Saved. Syncing…" caption follows the Task 11 pattern only if cheap; otherwise a plain toast (Q-RS-6).

**Removed by this design:** the parallel `addBatch` + `recordDelta` pair inside `restock`, and the callback-gated purchase and ActivityLog writes. `addBatch` itself stays for create-product and import (out of scope).

**Interaction with PR #146 (P1 S1a, open, branch `feature/2026-10-16-p1-s1a-server-movements`):** it changes `operationLogic.js`, makes every `inventory` delta op write a movement row, and defaults the kind by opType: `DEFAULT_KIND_BY_OPTYPE = { completeOrder: "sale" }`, anything else defaults to `adjustment`. A restock must be a `receipt`. Two ways: the client sends `movements: [{kind:"receipt", qty, reason, valueAtCost}]` on the delta op (no server file edit beyond `OP_TYPES`), or add `restock: "receipt"` to the default map. Both touch the same lines as #146, so **build after #146 merges** (Q-RS-7).

## 4. Open questions (grill)

Each has options, the real trade-off, and what I would pick. Overrule me if you have a reason; I will say if I think the reason is weak.

### Q-RS-1. Where does the batch id come from?
| Option | For | Against |
|---|---|---|
| A. Mint first with `nextBatchId` (today's way), then build the operation | Keeps readable `BAT-2026-NNN` ids; no new id scheme | Mint needs network. Offline or a 15 s timeout means no operation yet, so either refuse restock offline (regression, today offline restock queues) or keep the pending-mint queue and a second durable queue next to the outbox (two mechanisms for one problem) |
| B. Client-generated deterministic id from the restock id (like `BAT-RPR-<order>-<epoch>-<line>`) | Works offline, no extra queue, retry reuses the same id so exactly-once holds, deletes the F3 failure entirely | Ids not sequential for restocks. Must verify nothing parses batch ids (`_seedBatchMaxForPrefix`, UI display, exports). `BAT-RPR-` already proves non-sequential ids exist |
| C. Server mints inside the transaction | Sequential ids kept, no client mint | Server must share the `counters/stockBatches-<year>` doc with the client mint path still used by create/import, so both writers race on one counter. Biggest change, new failure modes |

**My pick: B.** It is the only option that keeps offline restock and removes a failure class instead of moving it. Cost to check first (build step R1): grep every reader of `batchId`. If something parses the number, I downgrade to A. **Question for you: does anyone (accountant, export, label) rely on restock batch ids being sequential?**

### Q-RS-2. Purchase record: inside the operation or after it?
- **Inside (my pick):** a third op with a deterministic `txId`. Atomic, survives relaunch, exactly-once. Cost: one more doc in the transaction (trivial against `MAX_OPS` and #146's write budget: 3 working docs + 3 audit + 1 marker + 1 movement row = 8).
- **After applied:** keeps `TransactionStore.recordPurchase` as is, but it then needs the persisted-hook machinery to survive a relaunch, and that is exactly the F2 bug again.
Anything against putting it inside? (It makes the server validate a `transaction` doc shape it only checks generically today.)

### Q-RS-3. ActivityLog "Restocked" entry
It is not a gateway doc (`ActivityLog._pushOneToFirebase`, fire-and-forget). Options: (a) rebuild it from the `operationApplied` results (they carry stock-after and the batch doc; product name comes from `InventoryStore`), with a deterministic entry id so a replay cannot duplicate it; (b) accept that the entry can be lost on relaunch (today's behaviour, minus the 4xx case).
**My pick: (a)** — but it needs `ActivityLog.record` to accept an id, a small change to a widely used function. Is a durable activity entry worth that touch, or is losing it on a relaunch acceptable (it is a notification feed, capped at 50, not a ledger)? I lean (a) only if you consider the feed an audit trail; if it is just a feed, (b) is the lazier honest answer.

### Q-RS-4. Where is the restock id created?
At dialog open (one id per dialog session) or at confirm click. A double tap at confirm with a click-time id makes two restocks. With a dialog-open id a double tap is the same key and the server collapses it, which also closes ASYNC-REENTRANCY C-4. **My pick: dialog-open id**, plus the existing `busy` guard stays. Downside: the dialog must regenerate the id after a rejection that the user then edits and resubmits (rejected ops leave no trace on the server, so reuse is safe, but I want that pinned by a test).

### Q-RS-5. Server-side shape check for `restock`?
`recordOperation` is generic: a client sending `opType: "restock"` could carry any ops. Same is true of `completeOrder` today. Option: per-opType validator (exactly 1 positive delta on `inventory`, 1 `stock_batch` create whose `qtyReceived` equals the delta, 1 `transaction` create). More code and a server deploy per rule change; protects against a buggy or malicious client writing arbitrary docs under the restock key. Roles already limit who can call it. **My pick: skip for now** (YAGNI, same trust model as `completeOrder`), record it as `shortcut:` debt. Disagree if restock is available to roles you do not trust with arbitrary writes.

### Q-RS-6. User-facing feedback while queued
Today: dialog waits for the delta and shows "Could not restock" on failure. With `awaitServer` the dialog waits up to the await window, then closes as done. Do you want the Task 11 "Saved. Syncing…" caption for restock too? **My pick: no.** A restock has no detail screen to put it on; the stuck-writes sheet already shows a queued operation. Cost of skipping: a restock queued offline looks identical to a landed one until sync.

### Q-RS-7. Order of work and deploy
1. #146 merges first (shared `operationLogic.js`). 2. Server `OP_TYPES` + tests deployed by you. 3. Client release. A client that sends `restock` to an old server gets `400 unsupported-op-type`. Options: hard dependency (my pick: no fallback to the old two-write path, because the fallback keeps the bug alive) or a feature flag. Hard dependency means **you must deploy functions before shipping the client**; `recordOperation` deploy for `completeOrder` is still "not confirmed in any doc" (roadmap 2026-10-13). **Can you confirm the deploy state of `recordOperation` today?** That decides whether this work can be device-tested at all.

## 5. Build order (each its own branch off `main`, small PRs)

| Step | What | Where |
|---|---|---|
| R1 | Verify batch-id readers (Q-RS-1), then pure builder `RestockPlan.build(...)` (ops, key, ids) | `qml/helper/RestockPlan.js`, `OperationKeys.restockKey/restockBatchId/purchaseTxId` |
| R2 | Server: `OP_TYPES += "restock"`, receipt movement, tests | `functions/lib/operationLogic.js`, `functions/test/` (after #146) |
| R3 | Store hooks: apply-remote for batch and purchase docs (reuse `addLocalBatch`/`addLocalEntries`) | `StockBatchStore`, `TransactionStore` |
| R4 | `InventoryStore.restock` rewrite onto `recordOperation`, applied/rejected handling, parked guard kept | `InventoryStore.qml` |
| R5 | `RestockDialog` id lifecycle (Q-RS-4) and failure text | `RestockDialog.qml`, `FailureCause.js` |
| R6 | ActivityLog durable entry (only if Q-RS-3 = a), docs, device test | `ActivityLog.qml`, docs |

## 6. Risks I see
- **Deploy dependency** (Q-RS-7) is the largest. Nothing here is device-testable until the server side is live.
- **Pending-mint queue becomes dead for restock** if Q-RS-1 = B; it must stay for create/import. Do not delete it.
- **`MAX_OPS`/write ceiling** are "unverified" in the source comments; 3 ops is far below any plausible limit.
- **Local state on a queued operation:** completion uses `_applyPredicted` with an undo. Restock needs the same optimistic apply and undo, or it shows stale stock until sync. R4 must copy that pattern, not invent a new one.
- **Rejected op, same key reused** (Q-RS-4) must be proven by test.

## 7. Not in scope
Create-product opening stock, bulk import, C-1 `_tryAdjustOrder`, `completeImportedOrder`, `_reverseCompletedOrder`; the other ledger kinds; per-opType server validation (Q-RS-5); request timeouts app-wide.
