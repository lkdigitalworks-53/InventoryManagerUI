# CHECKPOINT — 2026-10-05 session: PR #121 final sweep (resume here)

**Branch:** `review/2026-10-05-pr121-final-sweep` (stacked, base = `test/2026-10-04-order-completion-parked-delta-repro`, PR #121 head `fbcfe03`). Test + docs only; no `qml/` production change.
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>` (per -c, never in git config). Skills: requesting-code-review, ponytail-audit, qt-qml-review (linter on changed lines: only repo-wide style, `var`, `property var`, false `!==` hits).
**CI on `fbcfe03`:** E2E 63/63, Functions 329/329, Rules 45/45 green; QML 1909/1910. Only red: `InventoryStore_updateProductAfterAck::test_over_one_MiB_description_rejected_registers_no_transaction`.
**Root cause (code read, CI log not downloadable):** test written before the 1 MiB cap. PR #122 added `InventoryStore.updateRefusal`, so `updateProduct` with 1,048,577 chars is now refused and queues nothing; first `compare(_txItems().length, 1)` sees 0. Product behaviour is right (covered by `tst_InventoryStore_overlayAndCap::test_updateProduct_refuses_oversize_and_changes_nothing_device_obs_1`). Fix: test now uses 1,000,000 chars (under cap, accepted, then server-rejected) and asserts the accept.
**Code review (full diff main...fbcfe03, 10 qml files):** no Critical, no Important code defect found by read. NOT verified by run.
**Findings, not fixed on purpose:** (1) `Gateway.recordEdit` duplicates ~15 lines of `recordMutation` (ponytail: `reuse`); `hasUnsyncedEditForEntity`, `hasParkedForEntity`, `unsyncedByEntity` are three scans with one rule. Merging them is blind QML for a few lines; left. (2) Sale guard blocks offline sales behind any queued edit or create (Q1 = Z). (3) Bulk import has no size check (already in KNOWN-ISSUES).
**Docs fixed:** test plan prereq claimed an oversize description forces a server rejection; the cap makes 4.2/4.3/4.4/4.10 unreachable that way (marked OPEN). KNOWN-ISSUES updated. SKILLS/AGENTS/README unchanged: no new behaviour or convention.
**NEXT:** read CI on the stacked PR; merge it into the PR #121 head; then squash-merge PR #121. Taher: pick a way to force a server rejection for device cases 4.2/4.3/4.4/4.10.

---

# CHECKPOINT — 2026-10-05: unsynced product edit (PR #121 device-test follow-up)

**Branch:** `feat/2026-10-05-unsynced-edit-ledger` (off PR #121 head `e9403ec`; stacked on `test/2026-10-04-order-completion-parked-delta-repro`).
**Commit identity:** `lkdwtaher@gmail.com` (instruction in the 2026-10-05 PR #122 session; supersedes dextran52 and taher.lkdw53). Name `lkdwtaher`, passed per commit with `git -c`, never written to git config.
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

7. (PR #122 session, account 2) CI on `0d9b83c` was all green (QML, E2E, Functions, Rules). Code read of the PR; verified every Gateway send path (single / batch / delta / operation) ends in `_reschedule()` after conflict or permanent drop, so `pruneOrphans` runs.
8. Decisions (Taher, this session): overlay PARKED edits too; client-side 1 MiB cap now; other ledger kinds stay roadmap and are rolled into the atomic-operation work (documented in `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md` and `DELETE-FEATURE-ROADMAP.md`); order after this PR: PH3b, PH4, PH5, then atomic operation.
9. S4 done (NOT run), commit `15af7bc`: `OutboxStore.unsyncedByEntity`; `qml/helper/UnsyncedOverlay.js`; `InventoryStore` overlay per fetched page + `syncStates`/`syncStateOf`; `InventoryPage` ProductCard `syncPill`; `EditProductDialog` `syncNote`. Conflict handler deliberately does NOT overlay (the edit already left the outbox). Only changed fields are replayed (diff of before/after) so a server-side stock change is not undone.
10. Cap done (NOT run), same commit: `qml/helper/DocLimits.js` (Firestore size estimate, limit = 1 MiB - 4 KiB reserve, UTF-8 bytes); `InventoryStore.updateRefusal`/`tooLargeMessage`; `updateProduct` returns the refusal; `addProduct` refuses before minting an id (callback 3rd arg); `DataModel` reports via `errorOccurred("inventory", ...)`; Edit/Add dialogs pre-check and stay open.
11. Tests (134 new, none run), commit `178948d`: `tst_UnsyncedOverlay` (30), `tst_DocLimits` (30), `tst_OutboxStore_unsyncedByEntity` (30), `tst_InventoryStore_overlayAndCap` (44). Counts via `grep -c "^    function test_"`.
12. Docs: test plan (sections 0b, 1, 4.7-4.14), test-plans index, SKILLS Skill 101, AGENTS, README, KNOWN-ISSUES, atomic-operation plan, DELETE-FEATURE-ROADMAP order.

## NEXT (for the next session / account)
- Read CI on PR #122 (base = PR #121 head branch). Everything from step 9 on is blind QML; expect correction rounds. Check first: `tst_InventoryStore_overlayAndCap` `test_syncStates_is_not_republished...` (SignalSpy on `syncStatesChanged`), `test_dataModel_*` (role + `testLogic` harness), `test_addProduct_refuses_oversize...` (synchronous callback), `tst_DocLimits` boundary tests (1M-char string builds), `tst_OutboxStore_unsyncedByEntity` `enqueueOperation` call shape.
- Not covered by a QML test (no harness): the two UI pieces `syncPill` (InventoryPage ProductCard) and `syncNote` / pre-check (EditProductDialog). On-device plan 4.8-4.13 covers them.
- Known gaps (all documented in KNOWN-ISSUES): queued CREATE not injected into a read after a relaunch; bulk import has no size check; other ledger kinds (atomic-operation work); Activity `product_updated` is in-memory until the ack.
- Then, by Taher's order: PH3b, PH4, PH5 (see `docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md` and the photos test plan), then the atomic-operation work.
