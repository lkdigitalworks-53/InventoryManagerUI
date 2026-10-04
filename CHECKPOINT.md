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
2. Branch created, checkpoint rotated, decisions filed in memory.
