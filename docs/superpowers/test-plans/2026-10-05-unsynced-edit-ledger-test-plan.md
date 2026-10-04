# Test plan — unsynced product edit: ledger rows after ack, overlay, sale refusal (PR #121 follow-up)

**Branch:** `feat/2026-10-05-unsynced-edit-ledger` (stacked on PR #121 head `e9403ec`).
**Decisions (Taher, 2026-10-05):** Q1 = Z (optimistic local edit + overlay on server reads + "not synced" badge + refuse sale of a product with ANY unsynced edit); Q2 = outbox `dependsOn`; Q3 = product edit only. See `CHECKPOINT.md`.
**Status:** **written, NOT run** (no Qt toolchain in the sandbox). CI is the first run. **Slices done in this branch: S1 (outbox `dependsOn`), S2 (ledger rows + Activity after ack), S3 (sale guard). NOT done: S4 (overlay on server reads + "not synced" badge)**, so device bug 3 (reopen shows 25) is made SAFE (sale refused) but not yet fixed (price still shows 25 after a relaunch until the edit syncs).

## 0. What changed
- `OutboxStore`: an item may carry `dependsOn` (a held item). `dueItems` / `nextDueInMs` skip held items. `markAcked(id)` removes the parent and releases its dependents in ONE save. `pruneOrphans()` deletes held items whose parent left unacked (also run at load). `hasUnsyncedEditForEntity` = a single create/update/delete is queued (deltas, batches, operations and held rows excluded).
- `Gateway`: `recordEdit` (returns the STORED item's requestId, which differs from the call's when the edit merged into an older queued item); `recordMutation(..., dependsOn)`; `_ackSingle` uses `markAcked` and emits new `writeAcked(requestId, entity, entityId, action)`; `_reschedule` prunes orphans and emits new `heldWritesDropped(items)`. `mutationApplied` is unchanged (3 args).
- `InventoryStore.updateProduct`: enqueues the edit FIRST; `field_change` / `stock_adjustment` rows hang off it; the Activity `product_updated` entry waits in memory for `writeAcked` (dropped on discard / conflict). New `hasUnsyncedEdit`, `unsyncedEditMessage`.
- `TransactionStore`: `recordFieldChange` / `recordStockAdjustment` take `dependsOn`; removes the optimistic local row when `heldWritesDropped`.
- `DataModel._tryCompleteOrder`: refuses a line whose product has an unsynced edit (message `unsyncedEditMessage`); a parked write keeps its own message and wins.

## 1. Unit / functional (QML, CI-only)
- `tests/tst_OutboxStore_dependsOn.qml` (new, 33): stored `dependsOn`, empty string not held, no merge, merged edit keeps first requestId; held never due (parent queued / in flight / parked / orphan); `nextDueInMs` ignores held (no timer spin); `markAcked` releases, is one persisted state, unknown id no-op; `pruneOrphans` (drops, keeps live, no save when nothing, empty, at load after crash, keeps live parent at load); `hasUnsyncedEditForEntity` (update, create, delete, in flight, parked, NOT delta, NOT held, NOT batch/op, other product/entity, after ack); monkey 120 steps (held never handed out, no dangling `dependsOn`).
- `tests/tst_InventoryStore_updateProductAfterAck.qml` (new, 20): edit queued first, rows held behind it, local rows optimistic, stock-only, no-change, unknown product, Activity deferred; ack releases rows + writes Activity; merged edits release together; edit during in-flight depends on the second item; edit merged into a queued create flushes on the create ack; rejected edit drops rows from outbox AND `TransactionStore.entries` and writes no Activity; over-1-MiB description rejected registers nothing (device bug 1); discard / conflict drop pending Activity; no stale Activity after discard; other entity / delete acks ignored; monkey 40 acked-or-gone.
- `tests/tst_DataModel_completeOrderUnsyncedEditGuard.qml` (new, 27): queued edit refuses at once with the unsynced message; nothing changes; real `updateProduct` then sale refused (device bug 2); still refused after outbox reload (device bug 3 made safe); in-flight, queued create; second tap; no callback; multi-line (one line, two lines, same product twice, parked + unsynced, parked wins); NOT refused: no edit, stock delta only, other product, other entity, held ledger row, after ack, after discard, completed order, unresolvable line; routing via `completeOrder` / `updateOrder`; monkey 60 steps.
- `tests/tst_DataModel_completeOrderParkedGuard.qml`: two edge cases FLIPPED (plain pending / retrying edit used to proceed, now refused as unsynced).

## 2. Rules / functions
Not applicable: client-only (decision Q2). No `firestore.rules`, `storage.rules`, `functions/` change.

## 3. E2E (emulator)
Not added in this slice (no verified recipe for a real `write-rejected`; the emulator accepts oversize descriptions only if rules allow). Existing `tst_InventoryE2E` `test_updateProduct_persists_to_emulator` is the regression for the ack path (edit, then rows released, then sent).

## 4. On-device (Taher)
Prereq: build with this branch, gateway mode, clean new user + tenant; a product to edit; oversize Description (> 1 MiB) is the way to force a server rejection (confirmed on device in PR #110).
- **4.1 Happy path:** change price 25 to 30 online; after a moment the product history shows ONE `field_change` row and Activity shows "Product updated". A sale right after sells at 30.
- **4.2 Obs 1 (negative):** edit a product with a Description over 1 MiB. Expected: the edit is rejected (stuck list), the product history shows NO new `field_change` row after the rejection is classified, Activity has NO "Product updated" entry. Discard it: still no rows; Firestore `transactions` has no row for it.
- **4.3 Obs 2 (edge):** make the edit stick (oversize description + price 25 to 30), then try to complete an order for it inside the 3 minutes: refused with "This product has a change that hasn't synced yet. Wait for it to sync first" (parked: "Fix or discard the stuck change for this product first"). Order stays Pending.
- **4.4 Obs 3 (edge):** same as 4.3, then force-close and reopen inside the 3 minutes. The list may still show 25 (S4 not done). Completing the order must STILL be refused, never sold at 25.
- **4.5 Multiple scenarios:** edit price then stock in one save (two ledger rows, both appear only after the ack); two quick edits of one product (one outbox item, all rows after ONE ack); edit while offline, go online, rows appear after the ack; order with two lines, one product unsynced: whole order refused, other line untouched.
- **4.6 Monkey:** 5 minutes of random edit / Approve / Retry / Discard / airplane toggles on two products; at the end every product's history rows match edits the server accepted, no row for a discarded edit, no stuck "already being completed".
- **4.7 Expected (not regressions):** other ledger kinds (created, purchase, photo, sale, return, price_adjust) still register at once (roadmap). Activity entry lost if the app dies between edit and ack (in-memory by design). Badge / overlay not present yet (S4).

## 5. Regression watch
`tst_OutboxStore`, `tst_Gateway` (`test_ackSingle_*`, `mutationApplied` cases), `tst_InventoryStore_deleteProductCascade` and `tst_ActivityLog_deleteEntries` (still emit 3-arg `mutationApplied`), `tst_DataModel_completeOrderParkedGuard`, `tst_ParkedWriteGuard`, `tst_InventoryE2E`, `tst_StockBatchStoreE2E`.
