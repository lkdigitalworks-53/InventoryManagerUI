# Product delete: stop destroying batches / activity / queued photos before the server acks — design

**Status:** design only, decisions OPEN (Q-BC-1..Q-BC-7 below, Taher answers in the PR). No code written.
**Branch:** `docs/2026-10-04-product-delete-batch-cascade-design` (off `main` @ `157dc6b`).
**Roadmap:** new item 5 in `docs/superpowers/DELETE-FEATURE-ROADMAP.md`. Source: `KNOWN-ISSUES.md` "Product delete is destroy-before-ack" (items 1-3 still open after the photo part was fixed in #113/#115).
**Test plan:** `../test-plans/2026-10-04-product-delete-batch-cascade-test-plan.md`.
**Evidence rule:** everything marked READ was read in the code on `main` @ `157dc6b` this session. UNVERIFIED = not checked.

## Why this item (honest ranking)

Candidates on the pending list, as found in the roadmap, checkpoints and design docs:

| Candidate | Design done? | Kind | Verdict |
|---|---|---|---|
| Item 1 S4 cleanup (roadmap / KNOWN-ISSUES / test-plan consolidation) | trivial | docs only | Do last, own PR. Not "important", just closes item 1 |
| PH3b scheduled sweeper | yes (Q-E..Q-I decided) | server, Node-testable | Next after this one. Gets MORE useful if this design is accepted (it becomes the retry path for batch sweeps too) |
| PH4 rest (403 terminal, `Qt.uuid`, "already deleted" toast, L1) | yes | client, small | Cheap. 403 impact UNVERIFIED (not checked whether the photo UI is already gated to owner/admin, which would make a manager 403 rare) |
| PH5 legacy `photoUrl` removal | yes | cleanup | Later |
| PH3 remaining e2e (E03, E05, E06, E09, E12) | yes | tests only | Taher decided: stacked PR |
| **Product delete destroys batches before the ack** | **NO** (options listed in KNOWN-ISSUES, no decision) | **data integrity** | **This session. Only item where a normal concurrent edit leaves wrong data, and the only one with no design.** |

Pushback on myself: the app is dev-only with no production data (Taher's project facts), so "data integrity" is a cost for later, not today. The reason to do it first anyway: it is the only open item that needs a decision before anyone can code it, and it changes what PH3b has to do. If you would rather ship the cheap PH4 pieces first, say so; nothing here blocks them.

## The bug, restated with code evidence (READ)

`InventoryStore.deleteProduct(productId)` (`qml/model/InventoryStore.qml` L1050+) does, in one synchronous call:

1. removes the product from the local list;
2. `Gateway.recordMutation("inventory", id, "delete", before, null)` (queued, answered later);
3. `ActivityLog.record("product_deleted", ...)` at click time;
4. one `Gateway.recordMutation("stock_batch", batchId, "delete", b, null)` per local batch, plus removes them from `StockBatchStore.batches`;
5. `PhotoQueue.discard()` for every queued photo of the product.

Steps 3-5 do not wait for step 2. Server side, the product delete is a strict compare-and-set on the whole record (`applyMutation`, `_deepEqual(current, before)`), so it answers 409 when anything about the product changed (stock, price, `photoIds` after another device's upload: F5). The batch deletes have their own CAS on the batch records and commit independently. Result after a 409: product survives, its stock batches are gone (FIFO cost layers lost, inventory value and realised profit wrong), Activity says "Product deleted", this device's queued photos are discarded.

Also READ: exhausted batches are never pruned anywhere in `StockBatchStore` (no prune/compact code), so batches per product only grow.

## Options

| | What | For | Against |
|---|---|---|---|
| (a) Gate batch deletes on an ack | New per-mutation "applied" signal from `Gateway`, send batch deletes only after the product delete is acked | Smallest idea | New ack plumbing per mutation; still N independent writes (partial failure mid-way = some batches left); still driven by the client's possibly stale batch list. A patch (KNOWN-ISSUES agrees) |
| (b) One atomic `recordOperation` (new `opType` `deleteProduct`: product + every batch in one transaction) | All or nothing. The path the roadmap and Q11 earlier pointed at | Strictly atomic; reuses the outbox, park, retry and discard work already merged | (1) Hard cap: `MAX_OPS = 200` ops, so a product with more than 199 batches **cannot be deleted at all**, and batches are never pruned, so heavy products hit it. (2) Works from the client's local batch list: a batch another device created and this device has not synced is left behind, orphaned. (3) Every batch CAS must match, so a concurrent sale on any batch rejects the delete. (4) `operationLogic` rejects inventory deletes today (`cascade-delete-not-allowed`, Q11) so the marker must be shared. (5) **No production caller of `recordOperation` exists on `main`** (READ: only comments mention it; the only caller is PR #90, open since 2026-09-26, "mergeable unknown"). This would be its first real use, on the delete path |
| (c) Accept for dev | Do nothing | Free | Wrong data on any concurrent edit; fix is harder later |
| **(d) Server cascade: batches are removed by the server AFTER the product delete commits, driven by the existing `pending_cleanup` marker (recommended)** | Product delete stays the existing single `recordMutation`. In its transaction the marker is already written (PH3). The post-commit sweep (and PH3b later) deletes the product's Storage prefix **and** its `stock_batches` (queried server side by `productId`), then removes the marker | Batches are destroyed only after a committed delete (fixes the root cause the same way photos were fixed). No cap tied to ops. Uses the server's own batch list, not the client's, so unsynced batches are covered. Reuses marker, sweep, retry (PH3b), role gate, outbox, park, discard. Client loses its batch loop (less code, not more) | Not atomic: between the commit and the sweep, batches of a deleted product exist (safe direction: extra rows, retried until gone; today's failure is the unsafe direction). Server writes the batch audit entries itself (new code path, see Q-BC-4). A late `stock_batch` create for the deleted product (queued restock on another device) can land after the sweep and orphan (same family as the restock decision in KNOWN-ISSUES, not made worse) |

**Recommendation: (d).** I am recommending against the direction written earlier in Q11 and the roadmap ("atomic product + batches via one `recordOperation`"). Reasons, in order of weight: the 199-batch cap turns into "cannot delete this product" for long-lived products; (b) needs the client batch list to be complete and it is not guaranteed to be; (b) would be the first production use of an unproven path; and the marker infrastructure to do (d) already shipped in #113. What you give up is strict atomicity, replaced by "eventually consistent in the safe direction". If you need strict atomicity (an auditor reading the ledger mid-sweep, say), (b) is the answer and the cap needs its own decision (Q-BC-1).

## Proposed design (option d)

### Server
1. `photoCleanup.buildMarker` gets no new field. The batch step is implied by the marker's existence (marker = "this product was deleted, finish cleaning up"). Rename in docs only: it is now a product-delete cleanup marker, still `pending_cleanup/{productId}`.
2. `sweepMarker(deps, tenantId, marker)` order, each step idempotent: (i) unsafe-prefix guard (unchanged); (ii) `productExists` recheck, id reused => drop the marker, delete nothing (unchanged, and it now also protects the NEW product's batches from the batch sweep: this guard must stay first); (iii) **new** `deps.sweepBatches(productId)`: query `tenants/{t}/stock_batches` where `productId == id` (single-field equality, no composite index), delete in chunks of at most 200 docs with a per-batch audit entry (`action: "delete"`, `entity: "stock_batch"`, `before` = the batch, deterministic id `cascade~{productId}~{batchId}` so a retry never duplicates the audit); (iv) delete Storage prefix (unchanged); (v) delete the marker. Any failure keeps the marker with `attempts + 1` (unchanged mechanics). Order of (iii) vs (iv) matters little; batches first because they carry the money.
3. `index.js` `deleteProduct` handler path (`recordMutation` inventory delete): `deps.sweepBatches` wired next to `deleteFiles`. Same awaited post-commit sweep (Q-H).
4. `recordMutation` role handling: unchanged (not re-read this session; no change in this slice).
5. Batch deletes **stop being sent by the client**. The sweep queries what exists, so an older client that still sends its own `stock_batch` deletes just leaves the sweep less to do.

### Client (`InventoryStore.deleteProduct`, `StockBatchStore`, `DataModel`)
1. Remove the `recordMutation("stock_batch", ..., "delete", ...)` loop. Local `StockBatchStore.batches` still drops the product's batches optimistically (so valuation and pickers do not show ghosts).
2. On `Gateway.mutationConflicted(entity="inventory", action="delete")` (product survives): call `StockBatchStore.syncFromFirebase()` (READ: `DataModel._resyncForDiscard(["stock_batch"])` from #110 does exactly this call) to restore the batches. Because batches are not touched on the server before the ack, the resync gets them all back.
3. `ActivityLog.record("product_deleted")` moves from click time to the success path. Needs a success signal for a single mutation. **READ: `Gateway` has `mutationConflicted` and `batchMutationFailedPermanently` but no per-mutation "applied" signal.** Options in Q-BC-3.
4. `PhotoQueue.discard` for queued photos moves to the same success path (Q-BC-3), or stays at click time and is accepted (Q-BC-5).

### Rules / indexes
`firestore.rules`: no change (marker already server-only). `firestore.indexes.json`: none for this slice (equality on one field). PH3b's collection-group exemption is its own slice.

## Decisions for Taher (grill list; each with my default)

**Q-BC-1 Approach.** (a) patch, (b) atomic op, (c) accept, (d) server cascade. **Default: (d).** If you pick (b): you must also decide what happens above 199 batches: refuse the delete with a message, or raise the server cap (Firestore's per-transaction write ceiling is UNVERIFIED: the repo assumes 500 and my search did not reach an authoritative statement of it; the Q11 comment says adding a marker "would break the write-ceiling arithmetic", but its own numbers give 2x200 + 1 + 1 = 402, under 500, so that claim looks wrong, UNVERIFIED either way).

**Q-BC-2 Where do batch audit entries come from under (d)?** Today each batch delete is a client `recordMutation`, so the server writes the audit entry. Under (d) the sweep writes them. Options: A) one audit entry per batch, deterministic id (default; keeps the "working doc goes, audit stays" rule from the earlier cascade design), B) one summary entry for the whole cascade (cheaper, loses per-batch `before`). Default A. Cost: up to N extra writes in the sweep, chunked.

**Q-BC-3 Success signal for Activity and queue purge.** A) add `Gateway.mutationApplied(entity, entityId, action)` fired from `_send` on a 2xx (small, one signal, also usable by other stores later), B) write Activity at click time as today and add a second "delete rejected" entry on conflict, C) leave Activity as is. **Default A.** Trade-off: A touches `Gateway` (hot shared file, 1185 lines) for one signal; a relaunch between click and ack loses the in-memory "what to log", so the Activity entry is skipped in that case (the server audit entry still exists). B is the least code but the feed then tells a lie first and corrects itself.

**Q-BC-4 Queued photos (KNOWN-ISSUES item 3).** Purge them on ack (default, same signal as Q-BC-3) or keep purging at click time. Cost of purging on ack: queued photos of a deleted product may try to upload and 404 in the gap (404 is terminal in `PhotoQueueLogic`, so they fail once and park as `failed`; the existing code comment says that state has no UI and keeps the local files, which is why the purge exists). Cost of purging at click time: a rejected delete loses the user's pending photos. **Default: on ack.**

**Q-BC-5 F5 (delete 409s on any `photoIds` change).** Not in this slice. Accepted earlier (Q2). Restated so it is not forgotten: after this fix a 409 is harmless (nothing destroyed) but still annoying.

**Q-BC-6 Slicing.** BC1 = server (`sweepBatches`, wiring, Node tests, rules untouched, e2e). BC2 = client (remove loop, resync on conflict, signal, activity, queue purge, QML tests). BC1 is deployable alone and safe (nobody calls it differently); BC2 depends on BC1 being deployed (Taher deploys functions manually: record the deploy in the checkpoint). **Default: two PRs, BC1 first.** One PR would be ~half the review size of S3 but mixes Node-verifiable and CI-only work.

**Q-BC-7 Do we also fix a stale comment?** `operationLogic.js` says a product-delete marker "would break the write-ceiling arithmetic". If (d) is chosen it stays true that `recordOperation` rejects cascade deletes (correct, keep), but the justification comment should be softened to what is verified. Default yes, one comment edit in BC1.

## Risks and what could go wrong

- **Sweep touches money data.** A bug in `sweepBatches` that deletes the wrong batches (query on the wrong tenant or a reused product id) destroys cost layers. Mitigations: tenant from the marker's doc PATH (as for photos), product-exists guard first, query scoped to `tenants/{t}/stock_batches`, whitelist-validated ids (PH3). Needs mutation tests that kill: wrong tenant, missing guard, missing `productId` filter.
- **Chunking and partial progress.** Sweep deletes up to N batches in chunks; a crash mid-way leaves some. Next pass re-queries and finishes. Audit ids are deterministic so replays do not duplicate.
- **Race: product re-created with the same id before the sweep.** Covered by the exists-guard (marker dropped). Narrow window between guard and deletes accepted, same as photos.
- **Race: restock of the deleted product arrives after the sweep.** Orphan batch. Pre-existing family (restock is two independent writes, KNOWN-ISSUES, decided 2026-09-30). Not made worse; PH3b does not fix it either.
- **Deployed != main.** BC2 on a device with BC1 not deployed means batches never get deleted (client no longer sends them) and valuation shows ghosts after the next sync. Hence BC1 first and a deploy record. This is the biggest practical hazard.
- **PH3b interaction.** Until PH3b ships, a failed batch sweep waits indefinitely (same accepted limit as photos). Because batches are money data, that limit is less comfortable than for photos. If you agree, PH3b priority should go up.

## Not building

Strict atomic product+batches transaction (option b), unless Q-BC-1 says so. Batch pruning of exhausted batches. Fix for the restock two-write problem. F5. A generic operation journal. Any change to `recordOperation` / `OP_TYPES`. UI changes (no new strings except possibly the success toast text that already exists).

## Docs to update when implementing

`KNOWN-ISSUES.md` (the destroy-before-ack entry: items 1-3 closed or re-scoped; new "batch sweep waits for PH3b" limit), `DELETE-FEATURE-ROADMAP.md` item 5 status, `AGENTS.md` (marker now also drives batch cleanup; `sweepBatches` dep; runbook line for a stuck marker), `SKILLS.md` only for a lesson actually hit, test-plans `README.md`, design `2026-09-30-photos-s3-s4-design.md` PH3b section (marker also covers batches).

## Acceptance

BC1: functions suite green incl. new tests; sweep deletes exactly the product's batches and audits each once; reused id deletes nothing; failure keeps marker with `attempts + 1`; other tenant and other product untouched (mutation-tested). BC2: CI green; `deleteProduct` sends no `stock_batch` delete; a 409 leaves product, batches, activity and queued photos intact after the resync; a committed delete logs Activity once.
