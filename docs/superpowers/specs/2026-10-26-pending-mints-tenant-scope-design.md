# Pending batch-id mints: scope the durable queue to the tenant that queued it

**Date:** 2026-10-26. **Status:** implemented; hardened by the PR #168 final sweep on 2026-10-27 (stacked on the sign-out guard, PR #167). Small fix, so the design is short; defaults marked **vetoable**.
**Parent:** `E2E-TESTING-ROADMAP.md` item 1, Decision 1 (retry a failed batch-id mint on reconnect, keep the product out of order pickers meanwhile). Found while reading what sign-out clears for the sign-out guard (`2026-10-26-signout-guard-design.md`, D-S0-5). Skills used: `superpowers:brainstorming`, `ponytail`, `qt-qml`.

## 1. The defect (read from code on `main` @ `b494d52`; not run on a device)

`StockBatchStore._pendingMints` is a durable (`Settings`) queue of `addBatch` calls whose `nextBatchId()` mint failed: `{ id, productId, supplierId, qty, unitCost, note }`. It is device-local and **tenant-blind**:

- `Main.qml onSignedOut` calls `StockBatchStore.clear()`, which empties `batches` only. The queue survives sign-out (rightly: the product's stock delta already landed, the batch is still owed).
- `retryPendingMints()` runs on every offline->online flip and once at startup. It does not look at the tenant. `nextBatchId` builds `counters/stockBatches-<year>` and `Gateway.recordMutation("stock_batch", ...)` from the tenant signed in **at call time**.
- So: tenant A queues a mint (airplane mode), A signs out, B signs in, the device goes online -> B's counter is minted and a `stock_batch` is written into **B** for **A's product id**. Product ids repeat across tenants (`P-001`), so it can even attach FIFO cost to an unrelated product of B. Also `hasPendingMint(productId)` hides B's product with the same id from B's order pickers.
- Second window: A's retry is in flight, the person switches account, the mint answers, the write goes to the new tenant.
- Third (found while fixing): the startup retry runs from `Component.onCompleted`, often before the tenant is known, so a queue left from the last session waits for the next offline->online flip.
- Fourth (found in the 2026-10-27 sweep): the SUCCESS path of `addBatch` had the same window as the second one. A mint can retry for seconds (`mintCounterValue` re-resolves the tenant path on every attempt, up to 8 attempts, plus the 15 s timer); if the account switched meanwhile, the id came from the old tenant's counter and `Gateway.recordMutation` wrote the batch into the new tenant.
- Fifth (sweep): `nextBatchId` seeds a missing counter doc from the highest LOCAL batch id. A retry that runs before the tenant's `batches` are loaded seeds from nothing and can reissue a used id; the server rejects the duplicate `create` (CAS conflict, `_onMutationConflicted` keeps the existing row) but the owed batch is then lost, because the queue item was already removed.

Taher device-tests every PR on a new tenant, so tenant switches on one device are routine for this project.

## 2. Options

| Option | Cost | Verdict |
|---|---|---|
| A. Clear the queue on sign-out | Loses a batch the stock already counts, the exact drift Decision 1 exists to prevent | Rejected |
| B. Tag each item with its tenant; only that tenant sees, hides for, or retries it; a result that answers under another tenant is dropped and the item stays queued | Small; keeps the owed batch for when its own tenant signs back in | **Chosen** |
| C. Store the queue server-side or per `uid + tenant` in the outbox | Right long-term (the restock design, `2026-10-16-restock-atomic-operation-design.md`, makes the server mint ids inside the transaction and retires this queue) | Not now |

## 3. Design

- `qml/helper/PendingMints.js` (pure): `make`, `normalize`, `appendRejected`, `forTenant`, `has`, `due`, `sameTenant`, `without`. `StockBatchStore` calls these directly, so the tests exercise shipped code, not a mirror.
- `addBatch` captures `AuthStore.tenantId` BEFORE the mint (it is the tenant the mint is made under). When the mint answers, a changed tenant is treated like a failed mint: the id is dropped (a counter gap is harmless) and the batch is queued for the tenant that asked. Compared with `!==`, not `sameTenant`, so a context with no tenant at both ends (headless store tests) still writes.
- `_queuePendingMint` builds the item with `PendingMints.make`: no tenant, no product or a bad qty is not queued; a numeric-string qty is coerced instead of being queued and thrown away at the next launch.
- `retryPendingMints` starts only `PendingMints.due(...)` for the signed-in tenant, and only when `sameTenant(_loadedTenant, AuthStore.tenantId)`, i.e. that tenant's batch ledger is fully loaded. If it is not, the pass starts the load (`_resetAndFetch`, unless one is running) and returns; the load's completion in `_fetchFromFirebase` sets `_loadedTenant` and calls the retry again. `clear()` and `_resetAndFetch()` reset `_loadedTenant`. A failed load is retried on the next offline->online flip.
- The retry callback re-checks `sameTenant(item.tenantId, AuthStore.tenantId)`; on a mismatch it drops the minted id and leaves the item queued.
- `hasPendingMint` counts only the signed-in tenant's items, allocation-free (it is called per picker row).
- The first version of this PR hooked `AuthService.tenantContextReady` for the post-sign-in retry. Removed: the store's handler runs before `Main.qml`'s resync handler, so it hit the empty-ledger window above. The ledger load's completion is the correct trigger.
- On load, items without a tenant (queued by an older build) or damaged are **quarantined**, not replayed and not destroyed: `PendingMints.appendRejected` keeps them in the `rejectedJson` setting (newest 50); a file that is not a JSON list is kept as `{ raw }` before the next save overwrites it. Nothing reads the quarantine in the app; it exists so support can recover an owed batch by hand. **Vetoable**, see section 6.

## 4. Not done, on purpose
Moving the queue server-side (option C, the restock design); a UI for pending mints or the quarantine; clearing other tenants' items after N days (an item owed to a tenant nobody signs into again stays on the device; harmless, tiny); `without` by `(tenant, id)` (ids are `Date.now()_random`, a clash is not expected on one device; the behaviour is pinned by a test).

## 5. Risks
- The store wiring (capture and re-check in `addBatch`, the ledger gate, the quarantine) cannot run under `qmltestrunner` (singleton read-only methods, `AuthStore` compile gap in the sandbox's Qt). The driver in `tst_PendingMints.qml` models that control flow with the real helper; the on-device plan covers the real store. The KNOWN-ISSUES entry therefore says "fixed in code, device verification pending".
- `retryPendingMints` is now also called from the ledger load's completion and from the online flip; `due` skips in-flight ids, so overlapping triggers are idempotent for items already out. There is no cross-tenant dedupe beyond the tenant filter, by design.
- A load that never completes (offline sign-in) keeps owed mints waiting, and their products hidden from the pickers, until a reconnect or the next sign-in loads the ledger. Before this change they would have minted against an empty ledger. Hidden-until-loaded is the safe side.
- The mirror test `tst_PendingMintAndTopUpSafety.qml` models the queue WITHOUT tenants; it now carries a drift note and pins only the single-tenant behaviour (queue/retry/top-up).

## 6. Open question for Taher (default applied, vetoable)
Pre-fix items (no tenant) and damaged queues: **quarantine** (default, applied) or **adopt** each untagged item into the first tenant that signs in and owns a product with that id?
- Quarantine: zero risk of a wrong-tenant write, but the owed batch is not replayed; stock stays unbacked until someone adds the batch by hand. Hits only a device that upgrades with a failed mint pending.
- Adopt: recovers the common single-account case, but product ids repeat across tenants (`P-001`), so a second account on the same device can receive another tenant's batch with a plausible id. That is exactly the bug this PR removes.
Claude recommends quarantine. Taher said on 2026-10-25 there is no production data, which lowers the cost of either choice.
