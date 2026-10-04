# Product delete: stop destroying batches / activity / queued photos before the server acks — design

**BC2 (client) IMPLEMENTED 2026-10-04** on `feat/2026-10-04-bc2-client-ack-gating` (see "BC2 implementation + device-test observations"; needs BC1 deployed before merge). **BC1 (server) IMPLEMENTED 2026-10-05** on `feat/2026-10-05-bc1-server-batch-sweep` (see the test plan header for results and deviations). BC2 (client) not started: it waits for BC1 merged AND deployed (Q-BC-6). Original status line follows.
**Status:** design only. **Decisions Q-BC-1..Q-BC-7 DECIDED 2026-10-04 by Taher: default option on all seven** (ledger below). No code written. Implementation starts with BC1 once the order vs the photos items is settled (see ledger, "Order").
**Reviewed 2026-10-05** (post-merge review of PR #116, see "Design review 2026-10-05"): 2 High + 3 Medium + 4 Low findings; text fixed in this file. **Q-BC-8 and Q-BC-9 DECIDED 2026-10-05 (Taher: gate = yes; replay re-sweep = no, because PH3b is designed and built right after BC1). Order BC1 -> PH3b -> PH4 rest confirmed.** Design is complete for BC1.
**Branch:** `docs/2026-10-04-product-delete-batch-cascade-design` (off `main` @ `157dc6b`).
**Roadmap:** new item 5 in `docs/superpowers/DELETE-FEATURE-ROADMAP.md`. Source: `KNOWN-ISSUES.md` "Product delete is destroy-before-ack" (items 1-3 still open after the photo part was fixed in #113/#115).
**Test plan:** `../test-plans/2026-10-04-product-delete-batch-cascade-test-plan.md`.
**Evidence rule:** everything marked READ was read in the code on `main` @ `157dc6b` this session. UNVERIFIED = not checked.

## Decision ledger (Taher, 2026-10-04: "go with default option for all")

| # | Decision | Note |
|---|---|---|
| Q-BC-1 | **(d) server cascade** via the `pending_cleanup` marker. Not the atomic `recordOperation` | Taher accepted my advice against the earlier Q11 / roadmap direction. Gives up strict atomicity (safe-direction eventual consistency). If a 200+ batch product ever needs strict atomicity, reopen (b) |
| Q-BC-2 | **A**: one audit entry per batch, deterministic id `cascade~{productId}~{batchId}`, written by the sweep | Extra writes in the sweep, chunked at <= 200 |
| Q-BC-3 | **A**: new `Gateway.mutationApplied(entity, entityId, action)` fired once on a 2xx; Activity entry and queue purge hang off it | Touches `Gateway.qml` (hot file). A relaunch between click and ack skips the Activity entry (server audit still exists): accepted |
| Q-BC-4 | Queued photos purged **on ack**, not at click time | Gap: queued photos may 404 once and park as `failed` before the ack lands; accepted |
| Q-BC-5 | F5 (delete 409s on any `photoIds` change) stays out of scope | After this fix a 409 destroys nothing; still annoying |
| Q-BC-6 | **Two PRs: BC1 server first, BC2 client after BC1 is merged AND deployed** | Taher deploys functions manually; record the deploy in the checkpoint. BC2 before the deploy = batches never deleted, ghosts in valuation |
| Q-BC-7 | Yes: soften the `operationLogic.js` "write-ceiling arithmetic" comment in BC1 | Its own numbers give 2 x 200 + 2 = 402 < 500 (500 itself UNVERIFIED), so the comment's claim looks wrong. `recordOperation` still rejects cascade deletes (kept) |
| Q-BC-8 | **Yes (2026-10-05)**: server owner/admin gate on `inventory` delete in `recordMutation` | Same shape as the staff gate / `canManagePhotos`. Returns 403 `role-not-allowed` before any read or txn. Client already gates the same way, so the UI path never hits it. `recordMutationsBatch` / `recordOperation` already reject product deletes (cascade guard), so `recordMutation` is the only door |
| Q-BC-9 | **No (2026-10-05)**: an idempotent replay does NOT re-run the sweep (PH3 behaviour kept) | Taher: PH3b is designed and implemented immediately after BC1, and its scheduler is the retry path for every marker, replay-orphaned ones included. See "PH3b implications". My first advice was yes; reversed after the PH3b timing was known (reasons in the section) |

**Verified this session (code read, nothing run), closes two items from the "Not verified" list:**
- P1 stock-movements ledger (S1a/S1b) is NOT built on `main`: `gatewayLogic.js` only has the `stock_movement` collection-name map entry, no derivation code. So BC1 has no ledger interaction today. If P1 lands later, the sweep must emit its rows or P1 must exclude cascade deletes; note this in the P1 design then.
- Photo UI is already owner/admin only: `ProductPhotoGallery` is `editable: root.editMode` in `EditProductDialog`, and the Edit action only shows when `AuthStore.canManageInventory` (owner/admin). A manager/staff 403 is therefore rare in the UI, so PH4 item 1 (403 terminal) is low urgency, not blocking.

**Still unverified:** Firestore per-transaction write ceiling; `recordMutation` role handling for `stock_batch` delete: READ 2026-10-05, none (R5, Q-BC-8). UNVERIFIED still: how the stuck-writes dialog words a parked 403 `role-not-allowed` for a product delete (the staff delete already parks the same error; check the string when BC1 is on a device).

## Code review 2026-10-05 (PR #118, BC1 implementation)

Method: read the full diff against `main` @ `6077c46`, traced every new call site, ran `cd functions && npm ci && node --test` (483 -> 491 with the fix), mutation-checked the fix. Skills: requesting-code-review, ponytail-review, qt-qml-review (no QML in the diff: nothing to lint; BC2 will need it). READ = code read, nothing deployed.

| # | Sev | Finding | Status |
|---|---|---|---|
| C1 | Med | Cascade audit ids `cascade~{p}~{b}` share the `audit_log` keyspace with client-chosen `requestId`s, and `validateMutationRequest` / `validateDeltaRequest` / the batch validator / the photo endpoints accept ANY non-empty requestId. A member could pre-claim a cascade id: the sweep's unconditional `set` then overwrites that audit entry (ledger tamper of their own record), or the sweep's entry makes their write answer as an idempotent replay | FIXED: `cascade~` reserved, 400 `invalid-request-id` (`invalid-request` on photo endpoints); tests RES-G1..G3, RES-B1, RES-U1..U2, RES-H1, RES-P1 |
| C2 | Low | PH3b implication #1 wrongly said the scheduler needs no extra code; `sweepBatches` is a REQUIRED dep bound only in `index.js` | FIXED in text (item 1 above) |
| C3 | Low | PR title still said "WIP: tests next", body empty | FIXED (title + body) |
| C4 | Low | Test plan section 3 (on-device) assumed BC2 (client ack gating). With BC1 alone the stale-delete case 3.2 CANNOT pass (old client still sends its batch deletes before the ack) | FIXED: new section 3.0 (BC1-only on-device plan) |
| C5 | Info | Checkpoint listed CI as "NOT verified"; CI is green on `f222a44` (QML 1601, Functions 323, Rules 45, E2E 58). Functions count differs from `node --test` (483) because the CI junit summary counts differently; not a missing-test signal, not investigated further | NOTED in checkpoint + test plan |
| C6 | Info | The three BC1 commits carry `lkdwtaher@gmail.com`; this account's identity is `lkdigitalworks@gmail.com`. History not rewritten (PR already open, CI green); review-session commits use the right one | NOTED |
| C7 | Pre-existing | `recordMutation` / `recordDelta` do not validate `requestId` / `entityId` charset (`/`, length) the way `operationLogic.isSafeDocId` does; an id containing `/` builds a bad doc path. Only the cascade prefix is restricted now | FLAGGED in KNOWN-ISSUES, not fixed here (own branch) |

Checked and found fine: collection name `stock_batches` and field `productId` match the client; single-field equality needs no index (`firestore.indexes.json` empty); `FieldValue` is imported; write batch is 200 writes (300 worst case) per commit; role gate sits before the prefix build and before any transaction; replay path unchanged; old-client 409 path matches R6; no leftover `sweepProductPhotos` in code.

## Design review 2026-10-05 (post-merge review of PR #116)

Method: re-read every claim against `main` @ `1c5a521` (READ = code read this session, nothing run). Skills: requesting-code-review (findings, severity), ponytail-audit (over-engineering), qt-qml-review (BC2 QML surface, read-only; no QML written yet so no linter run).

| # | Sev | Finding | Status |
|---|---|---|---|
| R1 | High | Discard of a parked product delete restores the product but not its batches (`entitiesOf` -> `["inventory"]` only once batch deletes leave the outbox). Design only covered the 409 path | FIXED in text (client item 2) + test plan |
| R2 | High | Per-batch audit entries (Q-BC-2 A) need actor / back-link but marker had none and PH3b has no request context; design said "no new marker field" | FIXED in text (server item 1) + test plan |
| R3 | Med | Chunk of 200 docs = 400 writes (600 if `serverTimestamp` counts extra) vs UNVERIFIED ~500 ceiling; Q-BC-7 called the existing arithmetic wrong without evidence | FIXED: `SWEEP_CHUNK = 100` (300 writes even in the strict reading), Q-BC-7 reworded |
| R4 | Med | Handler sweeps only when `!idempotentReplay`. A request that commits but dies before/while sweeping (client timeout is 30 s, function default is 60 s) is retried as a replay and never swept; with batches in the sweep that leaves money data waiting for PH3b | DECIDED **Q-BC-9 = no**: PH3b scheduler closes it |
| R5 | Med | `recordMutation` has NO server role gate for `inventory` delete (only staff / removed_staff). Client gate is owner/admin (READ `DataModel.onDeleteProduct`). Test-plan case "role-rejected delete => no sweep" has nothing to test. No capability is added by (d): a token could already delete product + batch docs | DECIDED **Q-BC-8 = yes**: gate added in BC1 |
| R6 | Low | "Old client just leaves the sweep less to do" had the order backwards (sweep first, then old client's batch deletes 409 with `current: null`) | FIXED in text + e2e E6 |
| R7 | Low | Relaunch between click and ack skips not only the Activity entry (accepted) but also the queued-photo purge: those photos then upload, 404, park as `failed` with no UI and keep local files (the exact state the purge comment describes) | NOTED here; mitigation is PH4 rest ("already deleted" handling), no extra code in BC2 |
| R8 | Low | Sweep reads batches then deletes without a transaction, so audit `before` can lag a concurrent delta. Only reachable by a stale offline device because the UI blocks delete while open orders reference the product | ACCEPTED, documented |
| R9 | Low | Root `CHECKPOINT.md` of the design session still named commit identity `taher.lkdw53@gmail.com`; current rule is `dextran52@gmail.com` | FIXED in the new checkpoint |

ponytail-audit: nothing to delete. Option (d) removes the client batch loop and adds one server dep; no new abstraction. `SWEEP_CHUNK` constant is the only addition and is needed. `mutationApplied` (Q-BC-3) is the one new signal and has two consumers (Activity, queue purge), so it is not speculative.

Verified correct (no change): marker written after the CAS check inside the same transaction; 409 writes no marker; ids whitelisted before any prefix delete; exists-guard runs first; `mutationConflicted` already carries `action`; `DataModel._resyncForDiscard` exists and calls `StockBatchStore.syncFromFirebase()`; client owner/admin gate; `recordOperation` has no caller outside `Gateway.qml` on `main`; exhausted batches never pruned.

### Decisions on the review findings (Taher, 2026-10-05)

**Q-BC-8 DECIDED yes** (server owner/admin gate on product delete). Trade-off kept for the record: a new 403 on a path that returned none; the client parks 4xx as terminal (#93). The UI never sends it for non-owner/admin, so only a direct token call or a stale role cache sees it. Not gating would have meant the sweep trusts every caller.

**Q-BC-9 DECIDED no** (replay does not re-sweep). Reasoning with the PH3b timing Taher gave:
- The hole is narrow: the function awaits the sweep, so a client timeout (30 s) does not stop it; only a function crash or instance kill between commit and sweep leaves an un-swept marker, and only a replay of that exact request then skips it.
- PH3b's scheduler sweeps every surviving marker anyway, so a replay re-sweep would be a second retry path covering a subset of what PH3b covers, in the hottest handler, with new tests and an extra read per replay. Once PH3b ships it would be dead weight (ponytail: do not build what the next slice makes redundant).
- Overlap safety is needed regardless (handler sweep vs scheduler sweep can run together), and deterministic audit ids already give it, so nothing is lost by skipping.
- Cost accepted: from BC1 deploy until PH3b deploy, a crashed sweep waits. Dev only, no production data. Condition: this holds only because PH3b follows immediately; if PH3b slips, reopen and add the replay sweep.

**Testing effect:** BC1 gets smaller (no replay-sweep handler cases, no E7). The handler test pins the PH3 behaviour (replay returns early, no sweep). Overlapping-sweep safety is tested on `sweepBatches` directly. The crashed-sweep recovery case (old E7) moves to the PH3b test plan, where it is the scheduler's core case.

### PH3b implications (input for the PH3b design, not built here)
1. The scheduler calls the same `sweepMarker`, but `deps.sweepBatches` is REQUIRED and is bound only inside `index.js` `sweepProductCleanup` (PR #118 review correction: this item used to say "no extra scheduler code"). The scheduler must reuse that binding (or an equivalent one); a scheduler that builds its own deps without `sweepBatches` fails EVERY marker loudly, by design. It must also pass the marker's actor fields (R2) through.
2. **The attempts cap (PH3b design Q12) must not silently abandon a marker.** A capped marker that still has batches leaves money orphans; park it visibly (marker flag + log line) instead of dropping it. Decide in the PH3b design.
3. Scheduler and handler can sweep the same marker concurrently: both must be safe (deterministic audit ids; deletes of missing docs are no-ops).
4. Old-format markers from #113 (no actor fields) must keep working (`system` actor).
5. Take over the crashed-sweep case (old E7) in its test plan.
6. The `cascade~` audit-id prefix is RESERVED (PR #118 review): `recordMutation`, `recordDelta`, `recordMutationsBatch` and the two photo endpoints reject a client `requestId` starting with it. Any new endpoint that takes a client `requestId` and uses it as an `audit_log` doc id must apply `PhotoCleanup.isReservedAuditId` too.

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
1. `photoCleanup.buildMarker` gets **three new fields (review R2)**: `actorUid`, `actorRole`, `requestId` of the product delete (all already in `applyMutation` params). Reason: the per-batch audit entries (Q-BC-2) need an actor and a back-link, and the PH3b scheduler has no request context. The batch step itself is still implied by the marker's existence (marker = "this product was deleted, finish cleaning up"). Rename in docs only: it is now a product-delete cleanup marker, still `pending_cleanup/{productId}`. Old markers without the fields (written by #113) are swept with `actorUid: "system"`, `actorRole: "system"`, no `requestId`.
2. `sweepMarker(deps, tenantId, marker)` order, each step idempotent: (i) unsafe-prefix guard (unchanged); (ii) `productExists` recheck, id reused => drop the marker, delete nothing (unchanged, and it now also protects the NEW product's batches from the batch sweep: this guard must stay first); (iii) **new** `deps.sweepBatches(productId)`: query `tenants/{t}/stock_batches` where `productId == id` (single-field equality, no composite index), delete in chunks of **at most `SWEEP_CHUNK = 100` docs (review R3)**, each chunk ONE `WriteBatch` holding the deletes and one audit entry per batch (`action: "delete"`, `entity: "stock_batch"`, `before` = the batch as read, actor fields from the marker, `cascadeOf` = marker `requestId`, deterministic id `cascade~{productId}~{batchId}` so two overlapping sweeps (R4) or a replay never duplicate the audit); (iv) delete Storage prefix (unchanged); (v) delete the marker. Any failure keeps the marker with `attempts + 1` (unchanged mechanics). Order of (iii) vs (iv) matters little; batches first because they carry the money.
3. `index.js` `deleteProduct` handler path (`recordMutation` inventory delete): `deps.sweepBatches` wired next to `deleteFiles`. Same awaited post-commit sweep (Q-H).
4. `recordMutation` role handling **(review R5, Q-BC-8 = yes)**: READ this session, the handler only gates `staff` delete and `removed_staff`; `inventory` and `stock_batch` deletes are open to any tenant member. BC1 adds an owner/admin gate for `entity === "inventory" && action === "delete"`, right next to the staff gate, before the cascade-prefix build and before any transaction. Rejected: 403 `role-not-allowed`, zero writes, no marker, no sweep. `stock_batch` delete stays ungated (restock / FIFO paths legitimately use it for non-owner roles; out of scope).
5. Batch deletes **stop being sent by the client**. Older client during BC1-only (review R6, corrected): the sweep runs inside the product-delete request, i.e. BEFORE the old client's queued `stock_batch` deletes are sent; those then answer 409 with `current: null` (CAS `before` != missing doc), write nothing, and `StockBatchStore._onMutationConflicted` (READ) just removes the already-absent row, no toast. Harmless but noisy; covered by e2e E6.

### Client (`InventoryStore.deleteProduct`, `StockBatchStore`, `DataModel`)
1. Remove the `recordMutation("stock_batch", ..., "delete", ...)` loop. Local `StockBatchStore.batches` still drops the product's batches optimistically (so valuation and pickers do not show ghosts).
2. On `Gateway.mutationConflicted(entity="inventory", action="delete")` (product survives): call `StockBatchStore.syncFromFirebase()` (READ: `DataModel._resyncForDiscard(["stock_batch"])` from #110 does exactly this call) to restore the batches. Because batches are not touched on the server before the ack, the resync gets them all back.
   **Review R1 (High): the Discard path needs the same restore.** `parkedWriteDiscarded` passes only `StuckWrites.entitiesOf(item)` = `["inventory"]` for a parked product delete once the batch deletes are gone from the outbox, so `DataModel._resyncForDiscard` (READ) would restore the product but NOT its locally-dropped batches (valuation wrong until the next full sync). Fix in BC2: `_storesToResync` adds `stock_batch` whenever `inventory` is present (one extra read per inventory discard, rare). Same hole for any other terminal path that rolls back only the product.
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

**Q-BC-7 Do we also fix a stale comment?** `operationLogic.js` says a product-delete marker "would break the write-ceiling arithmetic". If (d) is chosen it stays true that `recordOperation` rejects cascade deletes (correct, keep), but the justification comment should be softened to what is verified. Default yes, one comment edit in BC1. **Review R3 correction:** do NOT assert the arithmetic is wrong. The file's own numbers are 401 (200 + 200 + 1) vs a ~500 ceiling, but an older Firestore SDK reference (search this session) says each `serverTimestamp()` in a transaction counts as an extra write, which would make 200 ops = 601. The current quotas page excerpt did not state a writes-per-transaction limit at all. Both readings UNVERIFIED, so the comment is reworded to "unverified ceiling, rejected on purpose" and `MAX_OPS` / `MAX_BATCH_SIZE` get a line in the checkpoint as a latent question, not a fix.

## Risks and what could go wrong

- **Sweep touches money data.** A bug in `sweepBatches` that deletes the wrong batches (query on the wrong tenant or a reused product id) destroys cost layers. Mitigations: tenant from the marker's doc PATH (as for photos), product-exists guard first, query scoped to `tenants/{t}/stock_batches`, whitelist-validated ids (PH3). Needs mutation tests that kill: wrong tenant, missing guard, missing `productId` filter.
- **Chunking and partial progress.** Sweep deletes up to N batches in chunks; a crash mid-way leaves some. Next pass re-queries and finishes. Audit ids are deterministic so replays do not duplicate.
- **Race: product re-created with the same id before the sweep.** Covered by the exists-guard (marker dropped). Narrow window between guard and deletes accepted, same as photos.
- **Race: restock of the deleted product arrives after the sweep.** Orphan batch. Pre-existing family (restock is two independent writes, KNOWN-ISSUES, decided 2026-09-30). Not made worse; PH3b does not fix it either.
- **Deployed != main.** BC2 on a device with BC1 not deployed means batches never get deleted (client no longer sends them) and valuation shows ghosts after the next sync. Hence BC1 first and a deploy record. This is the biggest practical hazard.
- **PH3b interaction.** Until PH3b ships, a failed batch sweep waits indefinitely (same accepted limit as photos). Because batches are money data, that limit is less comfortable than for photos. PH3b is scheduled immediately after BC1 (Taher, 2026-10-05); Q-BC-9 = no relies on that.

## Not building

Strict atomic product+batches transaction (option b), unless Q-BC-1 says so. Batch pruning of exhausted batches. Fix for the restock two-write problem. F5. A generic operation journal. Any change to `recordOperation` / `OP_TYPES`. UI changes (no new strings except possibly the success toast text that already exists).

## Docs to update when implementing

`KNOWN-ISSUES.md` (the destroy-before-ack entry: items 1-3 closed or re-scoped; new "batch sweep waits for PH3b" limit), `DELETE-FEATURE-ROADMAP.md` item 5 status, `AGENTS.md` (marker now also drives batch cleanup; `sweepBatches` dep; runbook line for a stuck marker), `SKILLS.md` only for a lesson actually hit, test-plans `README.md`, design `2026-09-30-photos-s3-s4-design.md` PH3b section (marker also covers batches).

## Acceptance

BC1: functions suite green incl. new tests; sweep deletes exactly the product's batches and audits each once; reused id deletes nothing; failure keeps marker with `attempts + 1`; other tenant and other product untouched (mutation-tested). BC2: CI green; `deleteProduct` sends no `stock_batch` delete; a 409 leaves product, batches, activity and queued photos intact after the resync; **discarding a parked product delete also restores the batches (R1)**; a committed delete logs Activity once.

## BC2 implementation + device-test observations (2026-10-04)

**Built exactly as the design says (Q-BC-3 A, Q-BC-4, R1):** `Gateway.mutationApplied(entity, entityId, action)` fired by `_ackSingle` on a single-mutation 2xx; `deleteProduct` sends only the product delete and hides the product's batches locally; Activity entry and queued-photo purge run in `InventoryStore._onMutationApplied`; a delete conflict re-reads batches (`DataModel` `onMutationConflicted`) and a discard re-reads batches whenever inventory is re-read (`_storesToResync`). Deviations: (a) `tst_InventoryStore_deleteAck.qml` (planned) was NOT created, its cases live in `tst_InventoryStore_deleteProductCascade.qml` (same singletons, one file less); (b) `_ackSingle` is a 3-line helper only so the ack is testable without an XHR; (c) the remembered delete is in memory only (R7, accepted).

**The PR #118 device test found three things BC2 does not (and should not silently) cover.** Evidence and root causes: `KNOWN-ISSUES.md` section "PR #118 device test". Decisions for Taher, each with my honest default. I am NOT building any of these before you answer.

**D1 Description size.** Cap `description` (and `name`) length. Options: (a) client cap only (`FormValidator`, instant feedback, a patched/old client or a direct call still sends 1 MiB), (b) server cap only (safe, but the user finds out minutes later via the rejected list, which is the symptom you saw), (c) both. **Default (c)**, small numbers (for example 2,000 chars for description; pick yours). Cost: a server limit rejects old data that is already longer; the check must be on write, not read. Needs your number and whether existing long descriptions must still be editable.

**D2 Restock behind a parked write.** The dialog waits on a delta that cannot be sent. Options: (a) before sending, `restock` checks `OutboxStore` for a parked item on the same product and refuses with a toast ("Fix or discard the stuck change for this product first"), nothing is written, no drift; (b) let the dialog close on a "queued" answer after the 10 s foreground window (the delta still waits behind the park, so stock stays wrong and the batch is already created: drift), (c) skip the batch write too until the delta is sent. **Default (a)**: smallest, never creates drift, one new string. Against: it blocks restocking until the user clears the stuck write, which is the honest state. The same check is arguably needed for every awaited delta (order completion), UNVERIFIED how many callers hang the same way; I would grep them before building (ponytail: fix the shared place, not the dialog).

**D3 Delete queued behind a parked write.** After BC2 nothing is destroyed, but the product disappears locally while its delete cannot be sent, and a later discard of the park makes the delete 409 on the stale `before`. Options: (a) refuse the delete while the product has a parked write, same toast as D2 (the product stays visible, no ghost); (b) allow it (today) and accept the 409 + retry; (c) on discard of a parked write, drop a queued delete for the same record and restore the product. **Default (a)**, same helper as D2. Against: the user cannot delete a product with a stuck edit until they discard it (one extra tap, and it states the real reason).

**D4 Merge order.** BC2 must not merge before BC1 is deployed (Q-BC-6). Do you confirm BC1 is deployed to `inventorymanager-48392`? If not: deploy, record it in the checkpoint, then merge. I cannot verify this.

**D5 Next slice after BC2.** PH3b (scheduled sweeper, designed, and BC1's Q-BC-9 = no relies on it landing right after) vs the D1-D3 fixes. **Default: D2+D3 first (one small PR, data drift today), then PH3b**, because PH3b makes the sweeper the only retry path for money data and is bigger. Against: Q-BC-9 says PH3b follows BC1 immediately; each slice of delay widens the crashed-sweep window (dev only, no production data).
