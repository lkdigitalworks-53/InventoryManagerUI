# CHECKPOINT — PR #113 device bug: product delete vs concurrent photo upload (2026-10-04)

**Branch:** `fix/2026-10-04-pr113-upload-delete-race` (stacked on `feat/2026-10-03-photos-ph3-server`). **Commit identity:** `taher.lkdw@gmail.com`.
**Skills invoked by Taher:** systematic-debugging, qt-qml, ponytail. Caveman FULL (chat only).
**Rules:** branch only; push without asking; no build/run; no Qt tooling (CI is the QML/e2e signal).

## Report (device test, negative case "device A uploads a photo while device B deletes the product")
Product had 9 photos. After: product still in inventory, only 3 photos in the app, 4 objects in Storage, Activity log says "Product deleted", the product's batches are gone.

## Step log
1. Read memory + skills, cloned repo, checked out PR #113 head (`4b3646e`).
2. Phase 1 (evidence, code trace only; no device logs, no emulator in sandbox):
   - Server `uploadProductPhoto` txn returns 404 for a missing product -> it can NOT resurrect a deleted doc. Ruled out.
   - `gatewayLogic.applyMutation` delete: CAS compares the client `before` (whole record, incl. `photoIds`) to the server doc. Upload from device A appends a photoId -> B's `before` is stale -> 409, zero writes, product survives.
   - `InventoryStore._onMutationConflicted` (action delete, `current` != null) pushes the server row back and toasts "Couldn't delete -- ... restored". This is the "product reappeared".
   - `InventoryStore.deleteProduct` fires, independent of that ack: (a) batch delete mutations (own CAS, unchanged -> commit), (b) `ActivityLog.record("product_deleted")` (local), (c) `StorageService.removeProductPhoto` per cached photoId = direct HTTP to `deleteProductPhoto`, which succeeds against the surviving product (removes the id + both Storage objects).
3. Phase 2: design `specs/2026-09-30-photos-s3-s4-design.md` PH4 item 3 already says "delete the removeProductPhoto loop ... photos are only destroyed after a committed delete". PR #113 is PH3 (server) only; PH4 is not built, so the loop is still live. The design sentence "PH3-before-PH4 keeps every intermediate state free of the destroy-before-ack bug" was wrong: the bug lives in the client loop and stays until PH4 item 3 ships.
4. Phase 3 hypothesis: ROOT CAUSE = client `deleteProduct` destroys confirmed photos before the server acks the delete (PH4 item 3 missing). A's concurrent upload merely makes the delete 409.
5. Phase 4: removed the loop + legacy `removeLocalCopy` branch from `deleteProduct` (PH4 item 3 only, nothing else from PH4). Kept the `PhotoQueue` purge. Added e2e `test_stale_delete_409_keeps_the_product_and_every_photo` (test-plan E04). Updated unit-test comments. Docs: KNOWN-ISSUES, design spec, test plan, SKILLS 92.

## NOT verified
Nothing run (QML/e2e are CI-only; no device). The exact 9 -> 3 / Storage 4 split is NOT derivable from code: it depends on how many of the concurrent `deleteProductPhoto` transactions won vs aborted under contention. Needs Cloud Functions logs from the test to confirm per-call outcomes.

## Still broken after this fix (same family, NOT fixed, see KNOWN-ISSUES)
- Batches are deleted before the product delete is acked: after a 409 the product survives WITHOUT its stock batches (FIFO cost layers lost).
- `ActivityLog` says "Product deleted" for a delete that was rejected.
- `PhotoQueue.discard` of this device's queued photos also runs before the ack.
- Delete CAS includes `photoIds` (F5): any concurrent upload/remove makes a delete 409.

## Next
1. Read CI on this branch (e2e new case is the signal).
2. Decide with Taher how to handle batches/activity (see KNOWN-ISSUES options) before PH4 proper.
