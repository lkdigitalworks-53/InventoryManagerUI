# Pending batch-id mints: scope the durable queue to the tenant that queued it

**Date:** 2026-10-26. **Status:** implemented (stacked on the sign-out guard, PR #167). Small fix, so the design is short; defaults marked **vetoable**.
**Parent:** `E2E-TESTING-ROADMAP.md` item 1, Decision 1 (retry a failed batch-id mint on reconnect, keep the product out of order pickers meanwhile). Found while reading what sign-out clears for the sign-out guard (`2026-10-26-signout-guard-design.md`, D-S0-5). Skills used: `superpowers:brainstorming`, `ponytail`, `qt-qml`.

## 1. The defect (read from code on `main` @ `b494d52`; not run on a device)

`StockBatchStore._pendingMints` is a durable (`Settings`) queue of `addBatch` calls whose `nextBatchId()` mint failed: `{ id, productId, supplierId, qty, unitCost, note }`. It is device-local and **tenant-blind**:

- `Main.qml onSignedOut` calls `StockBatchStore.clear()`, which empties `batches` only. The queue survives sign-out (rightly: the product's stock delta already landed, the batch is still owed).
- `retryPendingMints()` runs on every offline->online flip and once at startup. It does not look at the tenant. `nextBatchId` builds `counters/stockBatches-<year>` and `Gateway.recordMutation("stock_batch", ...)` from the tenant signed in **at call time**.
- So: tenant A queues a mint (airplane mode), A signs out, B signs in, the device goes online -> B's counter is minted and a `stock_batch` is written into **B** for **A's product id**. Product ids repeat across tenants (`P-001`), so it can even attach FIFO cost to an unrelated product of B. Also `hasPendingMint(productId)` hides B's product with the same id from B's order pickers.
- Second window: A's retry is in flight, the person switches account, the mint answers, the write goes to the new tenant.
- Third (found while fixing): the startup retry runs from `Component.onCompleted`, often before the tenant is known, so a queue left from the last session waits for the next offline->online flip.

Taher device-tests every PR on a new tenant, so tenant switches on one device are routine for this project.

## 2. Options

| Option | Cost | Verdict |
|---|---|---|
| A. Clear the queue on sign-out | Loses a batch the stock already counts, the exact drift Decision 1 exists to prevent | Rejected |
| B. Tag each item with its tenant; only that tenant sees, hides for, or retries it; a result that answers under another tenant is dropped and the item stays queued | Small; keeps the owed batch for when its own tenant signs back in | **Chosen** |
| C. Store the queue server-side or per `uid + tenant` in the outbox | Right long-term (the restock design, `2026-10-16-restock-atomic-operation-design.md`, makes the server mint ids inside the transaction and retires this queue) | Not now |

## 3. Design

- `qml/helper/PendingMints.js` (pure): `normalize`, `forTenant`, `has`, `due`, `sameTenant`, `without`. `StockBatchStore` calls these directly, so the tests exercise shipped code, not a mirror.
- `addBatch` captures `AuthStore.tenantId` BEFORE the mint (it is the tenant the mint is made under) and queues with it. No tenant -> not queued (nobody could ever replay it).
- `retryPendingMints` starts only `PendingMints.due(...)` for the signed-in tenant. The retry callback re-checks `sameTenant(item.tenantId, AuthStore.tenantId)`; on a mismatch it drops the minted id (a gap in a counter is harmless) and leaves the item queued.
- `hasPendingMint` counts only the signed-in tenant's items.
- `AuthService.tenantContextReady` also triggers a retry (the startup pass above).
- On load, items without a tenant (queued by an older build) or damaged are **dropped** with a warning. **Vetoable.** Cost: a pre-fix leftover on a dev device is lost. There is no production and no real data (Taher, 2026-10-25), and adopting an untagged item into whichever tenant is signed in is the bug itself.

## 4. Not done, on purpose
Moving the queue server-side (option C, the restock design); a UI for pending mints; clearing other tenants' items after N days (an item owed to a tenant nobody signs into again stays on the device; harmless, tiny).

## 5. Risks
- The store wiring (capture, callback check, `tenantContextReady` hook) cannot run under `qmltestrunner` (singleton read-only methods, `AuthStore` compile gap in the sandbox's Qt): on-device plan items cover it.
- `tenantContextReady` fires several times per sign-in; the retry is idempotent (`due` skips in-flight ids).
- The existing mirror test `tst_PendingMintAndTopUpSafety.qml` models the queue WITHOUT tenants; it still tests what it tested (queue/retry/top-up), and the tenant rules live in `tst_PendingMints.qml`.
