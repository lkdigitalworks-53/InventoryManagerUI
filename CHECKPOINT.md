# CHECKPOINT — 2026-10-05: unsynced product edit (PR #121 device-test follow-up)

**Branch:** `feat/2026-10-05-unsynced-edit-ledger` (off PR #121 head `e9403ec`; stacked on `test/2026-10-04-order-completion-parked-delta-repro`).
**Commit identity:** `dextran52@gmail.com` (standing instruction 2026-10-05; supersedes taher.lkdw53 in the archived checkpoint).
**Rules (standing):** branch only; push without asking (PAT only in push header via `/tmp/push.sh`, never in `.git/config`); no build/run; no Qt tooling in sandbox (CI = QML signal); small scope, resumable by another account; honest advisor; tests for every change + test plan from template; update SKILLS/AGENTS/README as needed.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-pr121-order-completion-parked-CHECKPOINT.md`.

## Device-test observations on PR #121 (Taher)
1. Product edit with description > 1 MiB: server rejects, but the ledger tx (`field_change`) is still registered. Tx must register LAST, after the edit is acked. Applies to all tx kinds.
2. Edit applied locally (price 25 -> 30), Firestore rejects, outbox retries ~3 min. Order placed in that window completes at 30.
3. App closed + reopened inside the 3 min: product re-read from Firestore = 25; order completes at 25. Local edit silently lost from the UI while still queued.
4. Rejection list denies completion: works as expected (PR #121).

## Decisions (Taher, 2026-10-05)
- Q1 = **Z**: keep optimistic local edit; overlay queued outbox edits on every server read (survives restart) + "not synced" badge; REFUSE sale of a product with ANY unsynced edit.
- Q2 = **Outbox `dependsOn`**: tx item persisted, sent only after parent edit acked, dropped if parent discarded. Client-only; touches `OutboxStore`.
- Q3 = **product edit only** (`field_change` + `stock_adjustment` + Activity `product_updated`). created/purchase/photo/sale/return/price_adjust = roadmap.

## Design traps found by code read (NOT run)
- `Gateway.recordMutation` returns the NEW call's requestId, but `OutboxStore.enqueue` may MERGE into an older queued item (keeps old requestId). `dependsOn` must use the STORED item's requestId.
- `markSent` is used for ack AND discard AND drop. Need `markAcked` = remove parent + clear dependents' `dependsOn` in ONE `_save()`; otherwise a crash between the two loses ledger rows. Orphan = `dependsOn` set, parent absent -> drop.
- "Any unsynced edit" for the sale guard must mean NON-delta items for `inventory/<id>`; stock deltas from earlier sales must not block the next sale.
- `ActivityLog.record("product_updated")` is local; must also move after ack (or be accepted as local-only; decide in slice 2).

## Slices (scope kept small)
- S1: `OutboxStore.dependsOn` core + `markAcked` + orphan prune + unit tests.
- S2: wire `InventoryStore.updateProduct` -> tx rows with `dependsOn`; Gateway ack path uses `markAcked`.
- S3: sale guard on any unsynced non-delta inventory edit (`DataModel._tryCompleteOrder`).
- S4: overlay of queued/parked edits on server reads + "not synced" badge.

## Step log
1. Cloned repo, read memory, PR #121 meta (draft, base main), OutboxStore, TransactionStore.recordFieldChange/_push, InventoryStore.updateProduct, Gateway.recordMutation/discardParked.
2. Branch created, checkpoint rotated, decisions filed in memory. Pushed.
3. S1 done (NOT run): `OutboxStore` `dependsOn` (enqueue, dueItems/nextDueInMs skip held, `markAcked`, `pruneOrphans` + at load, `hasUnsyncedEditForEntity`); `Gateway.recordEdit`, `recordMutation(..., dependsOn)`, `_ackSingle` -> `markAcked`, new signals `writeAcked` + `heldWritesDropped`, `_reschedule` prunes. `mutationApplied` kept 3-arg on purpose (tests emit it by hand; QML throws on fewer args).
4. S2 done (NOT run): `InventoryStore.updateProduct` enqueues edit first, rows depend on stored requestId, Activity deferred to `writeAcked` (in-memory, dropped on discard/conflict); `TransactionStore.removeLocal` on `heldWritesDropped`.
5. S3 done (NOT run): `DataModel._tryCompleteOrder` refuses unsynced edits (`InventoryStore.unsyncedEditMessage`), parked wins. Two old tests in `tst_DataModel_completeOrderParkedGuard.qml` flipped (plain pending / retrying edit now refused).
6. Tests (76 new, none run): `tst_OutboxStore_dependsOn` (31), `tst_InventoryStore_updateProductAfterAck` (19), `tst_DataModel_completeOrderUnsyncedEditGuard` (26). Test plan + index row, SKILLS 100, AGENTS, KNOWN-ISSUES, README done.

## NEXT (for the next session / account)
- Read CI on this branch's PR (base = PR #121 head branch). Expect failures only from blind QML: check first `test_nextDueInMs_ignores_held_items...` (jitter/backoff value), `test_edit_while_the_first_is_in_flight...` (`drainNow` in gateway mode offline), `test_conflict_drops_pending_activity...` (Toast / `_reschedule` Timer in test harness), `tst_Gateway` ack tests (`markAcked`).
- S4: overlay queued/parked inventory edits in `InventoryStore._fetchFromFirebase` / `_normalizeProducts` result + `_onMutationConflicted`, "not synced" badge in product list / EditProductDialog. Needs a decision: overlay PARKED edits too (advice: yes, badge says "rejected"), and what Discard does (S3 discard-resync already re-reads).
- Verify conflict + permanent-drop paths end in `Gateway._reschedule()` (pruneOrphans runs there).
- Roadmap: same dependsOn for created/purchase/photo/sale/return/price_adjust; client-side description size cap.
