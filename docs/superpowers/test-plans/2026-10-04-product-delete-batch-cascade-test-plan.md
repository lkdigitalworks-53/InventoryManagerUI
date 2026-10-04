# Test plan — product delete: batches removed by the server after the ack (BC1 server, BC2 client)

**Design:** `../specs/2026-10-04-product-delete-batch-cascade-design.md` (decisions Q-BC-1..7 DECIDED 2026-10-04: defaults, option d).
**Branches (planned):** `feat/2026-10-05-bc1-server-batch-sweep`, `feat/2026-10-05-bc2-client-ack-gating`.
**Status:** written BEFORE implementation. **Nothing built or run.** No Qt toolchain in the sandbox (standing rule); Node tests can run in-session, QML / rules / e2e are CI-only. If Q-BC-1 is ever reopened to option (b), sections 1-2 must be rewritten.
**Updated 2026-10-05 (design review R1-R8):** rows marked *(R#)* are new or changed; Q-BC-8 = yes (server role gate) and Q-BC-9 = no (replay does not re-sweep) were decided 2026-10-05; rows below reflect that.

## 1. Unit

### BC1 (Node, `functions/test/`, runnable in the sandbox)
| Area | Cases (happy / negative / edge) |
|---|---|
| `sweepMarker` order | batches swept before Storage; product exists => nothing swept, marker dropped (id reuse); unsafe prefix => nothing swept; `productExists` throws => nothing swept, `attempts + 1`; `sweepBatches` throws => Storage not touched, marker kept, `attempts + 1`, `lastError` truncated; Storage throws after batches swept => marker kept, second pass finds 0 batches and finishes; `deleteMarker` throws => swallowed; *(R2)* marker without `actorUid`/`actorRole`/`requestId` (written by #113) => sweep proceeds, audit uses `system`; marker with actor fields => audit carries them and `cascadeOf` = marker `requestId`; `buildMarker` stores the three fields and rejects non-string actor values |
| `sweepBatches` | 0 batches (no-op); 1; *(R3)* 99; 100; 101 (two chunks); 1000 (ten chunks); `SWEEP_CHUNK` pinned to 100 (a test fails if it grows, so write count per commit stays <= 300 even if `serverTimestamp` counts extra); each chunk is one `WriteBatch` holding deletes + audits;  batch of another product untouched; batch of another tenant untouched; exhausted batch (`qtyRemaining` 0) deleted too; one audit entry per batch with `before`; audit ids deterministic `cascade~{productId}~{batchId}`; replay produces no duplicate audit; *(Q-BC-9)* two `sweepBatches` runs started together over the same batches (handler + future PH3b scheduler) => each batch deleted and audited exactly once, no throw on already-missing docs; chunk 2 fails => chunk 1 stays deleted, error reported |
| Query scoping | filter is `productId ==` exactly; tenant comes from the marker path, never the body; a marker body with a forged `tenantId` is ignored |
| Handler | inventory delete 200 => marker written in the txn (with actor fields), sweep awaited, batches gone, audit present; 409 => no marker, no sweep, batches untouched (**the regression this item exists for**); *(Q-BC-9 = no)* idempotent replay => returns early, no sweep, no second marker (PH3 behaviour pinned); *(Q-BC-8 = yes)* staff/manager `inventory` delete => 403 `role-not-allowed`, no txn, no marker, no sweep, batches untouched; owner and admin allowed; `stock_batch` delete by staff still allowed (unchanged); a batch or operation request carrying a product delete is still rejected (unchanged) |
| Monkey | 2000 random sequences of {delete product, restock, id reuse, failing sweep, replay}: invariant "a batch of a live product is never deleted; a batch of a deleted product is deleted at most once audited"; fixed seeds printed |

### BC2 (QML, CI-only: `tests/`)
| File | Cases |
|---|---|
| `tst_InventoryStore_deleteProductCascade.qml` (update) | no `stock_batch` delete sent; local batches dropped optimistically; queued photos NOT discarded before the ack (Q-BC-4 default); product with 0 batches; product with queued photos only |
| `tst_InventoryStore_deleteAck.qml` (new) | `mutationApplied` for the delete => Activity entry once and queued photos purged; `mutationConflicted` (action delete, current non-null) => batches resynced, no Activity entry, queue intact; `current` null => product stays removed, batches stay removed; unrelated `mutationApplied` ignored; duplicate signal => one Activity entry; signal for another product ignored |
| `tst_Gateway.qml` (update) | `mutationApplied(entity, entityId, action)` fired once on 2xx, never on 409/5xx, never on idempotent replay twice for one call |
| `tst_DataModel_*` (update) | conflict on inventory delete triggers exactly one `StockBatchStore.syncFromFirebase()`; *(R1)* `_storesToResync(["inventory"])` returns `["inventory", "stock_batch"]`; discarding a parked inventory delete resyncs inventory once and stock_batch once; `["order"]`, `["stock_batch"]` and `[]` unchanged; `["inventory", "stock_batch"]` does not resync stock_batch twice; non-inventory discard never touches stock_batch unless listed |
| Monkey | 400-step random mix of delete / conflict / applied / relaunch (state reset) asserting no crash and Activity count <= deletes |

## 2. Functional / rules / e2e
- **Functional:** BC1 handler tests run real `gatewayLogic` + `photoCleanup` with the harness; BC2 uses real singletons.
- **Rules:** `firestore.rules` unchanged => existing marker rules tests stay; add one R-test only if a rule changes.
- **e2e (emulator, CI):** (E1) delete a product with 3 batches and 2 photos => product gone, 0 batches, 0 Storage objects, marker gone, audit entries present. (E2) **stale delete 409 keeps product + all batches + all photos** (extends the existing `test_stale_delete_409_keeps_the_product_and_every_photo`). (E3) delete, recreate same id, then run the sweep => new product's batches intact. (E4) 250 batches => all removed across chunks. (E5) a failing sweep leaves the marker, a second run completes. *(R6)* (E6) old-client flow: product delete then the old client's `stock_batch` deletes => each answers 409 with `current: null`, nothing written, no batch resurrected, audit has exactly one entry per batch (the sweep's). (Crashed-sweep recovery, formerly E7, is the PH3b scheduler's case and moves to the PH3b test plan, Q-BC-9 = no.)
- **Mutation checks (planned):** drop the `productId` filter; drop the exists-guard; swap batch/Storage order; drop the audit write; wrong tenant; *(R2)* drop the actor fields from the marker; *(R3)* raise `SWEEP_CHUNK`; *(R1)* drop the `stock_batch` addition in `_storesToResync`; each must fail at least one test.

## 3. On-device checklist (Taher; only coverage for toast, activity feed, valuation)
Prerequisite: BC1 deployed first (`firebase deploy --only functions --project <dev>`), deploy recorded in the checkpoint. New tenant per PR.
- **3.1 Happy path:** product with 3 batches and photos => delete => gone from list; Inventory Value drops by the batch value; Activity shows one "Product deleted"; Firestore: no batches for the id, Storage prefix empty, no marker (after ~1 min).
- **3.2 Negative (the bug):** device A edits product (price) while device B deletes it (stale) => B shows the "restored" toast, product AND its batches reappear after the resync, Inventory Value unchanged, no "Product deleted" entry, B's queued photo for it still queued.
- **3.3 Edge:** product with no batches; product with only exhausted batches; product with 1 queued photo not yet uploaded; delete then immediately create a product with the same SKU (not same id); 200+ batches (seed with a script) deletes fully.
- **3.4a Discard path (R1):** park a product delete (server rejects it), then Discard in the stuck-writes dialog => product AND its batches are back, Inventory Value unchanged.
- **3.4 Multiple scenarios:** two devices delete the same product at once (one wins, other gets "already deleted"); delete while offline (app is disabled offline: confirm the existing behaviour is unchanged); relaunch between click and ack (Activity entry may be missing, server audit present, batches gone).
- **3.5 Monkey:** 5 minutes of random add / restock / sell / delete / undo-adjacent taps on two devices; at the end compare Inventory Value and batch count per live product with Firestore.
- **3.6 Verification gaps (stay open until observed):** real Storage plan sweep time; Cloud Functions logs for the sweep; marker age after a forced failure (needs a way to force failure, none exists today).

## 4. Regression watch
Existing delete cascade tests; `tst_StockBatchStore_*` sync tests; photo cascade e2e; Gateway discard/park tests (they share the resync helper).
