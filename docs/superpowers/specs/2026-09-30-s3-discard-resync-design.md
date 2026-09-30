# Gateway stuck writes, part B, slice S3: Discard + resync — design

**Date:** 2026-09-30. **Branch:** design `design/2026-09-30-s3-discard-resync` (PR #109), code `feat/2026-10-01-s3-discard-parked-writes` (stacked on it, on PR #106).
**Status:** IMPLEMENTED 2026-10-01, CI pending. **Q-S3-1..5 DECIDED by Taher 2026-10-01: option A on all five** (see Resolved decisions). Nothing built or run (no Qt in sandbox).
**Plan:** `2026-09-29-gateway-park-retry-discard-plan.md` (P1, P2, P3; slice S3). **Builds on:** S2b design (`parked = stuck && terminal`, parked holds its keys).
**Out of scope:** photo cleanup (roadmap item 4), any server change, a Discard for non-rejected stuck writes (P1).

## Goal
A parked (server-rejected) write gets an exit: the user discards it, the outbox forgets it, and the local stores are re-read from Firestore so the app matches the server again. Ship with S2b: without it a rejected write is a dead end.

## Size call
Small in code (about 70 lines across `StuckWrites.js`, `Gateway`, `DataModel`, `StuckWritesSheet`), medium in tests/docs. One PR, no split. Nothing new in `OutboxStore`: `markSent(requestId)` already removes an item.

## Code facts traced 2026-09-30 (nothing run)
1. A merged edit keeps the parked item's `requestId` (`OutboxStore.enqueue` spreads the candidate). So Discard throws away the original write AND every later edit merged into it (P3). The confirm text must say so.
2. `OutboxStore.markSent` + `Gateway._reschedule()` (which runs `_pruneStuck`) already clear the item, the stuck count and the parked count, and re-arm the drain timer. Same-record siblings that D4 held behind the parked item become due right after.
3. `_resetAndFetch()` on every paginated store coalesces via `_resetPending`, so a resync fired mid-fetch is not lost.
4. `DataModel` already re-syncs `ordersModel` on `OrdersStore.revision`; the handler need not call `_syncOrdersModel()`. `SalesStore` is derived, not fetched.
5. `StaffStore.syncFromFirebase()` resets `staff` + `activities` and refetches `staff` and `removed_staff`, BUT the `removed_staff` fetch MERGES into `removedNames` (never replaces, by design). **A discarded `removed_staff` create leaves its tombstone in memory until relaunch.** Harmless name cache, but the resync does not fully revert it. Accepted, documented.
6. `recordOperation` has no production caller yet (C-3 pending); `DescribeItem` already knows `completeOrder`. An operation item can only be parked once C-3 lands. Handling it now costs about 3 lines (`_finishOperation`), so it is included.
7. No client-side single-record GET exists (P2): resync is the full store reset. A discard makes the list refill from page one and hides other pending edits until they land.

## Proposed design
| # | Decision | Why | Cost |
|---|---|---|---|
| D1 | `StuckWrites.entitiesOf(item)` (pure): distinct entity names of a single / batch / delta / operation item. | One place knows the four shapes; Node-testable to 100%. | One more helper. |
| D2 | `Gateway.discardParked(requestId) -> bool`. Re-checks at execution time: gateway mode, item still queued, `StuckWrites.isParkedItem`, not in flight, `AuthService.isOnline`. Then `OutboxStore.markSent`, `_finishOperation(item, {ok:false, error:"discarded"})` for operation items, emit `parkedWriteDiscarded(requestId, entities)`, `_reschedule()`. | The row was parked when drawn; the outbox can change before the tap lands (Retry, another path). Re-check makes a stale tap a no-op. | `false` gives the sheet nothing to say beyond "nothing to discard". |
| D3 | Signal carries `(requestId, entities)`, not the plan's `(entity, entityId, action)`. | Resync is full-store, so id and action are unused. YAGNI. Batch and operation items span entities; one list covers them. | Deviates from plan text; overrule in the PR. |
| D4 | One `Connections { target: Gateway }` in `DataModel`: each entity -> `InventoryStore` / `StockBatchStore` / `OrdersStore` / `StaffStore` (staff and removed_staff) / `SupplierStore` / `TransactionStore` `.syncFromFirebase()`, once per distinct store. `stock_movement` has no store: ignored. | P2. Stores stay untouched. | The map must track `Gateway._collections`; a test asserts every Gateway entity is mapped or explicitly ignored. |
| D5 | Sheet: `Discard` on rejected rows only, beside `Retry`; disabled while offline or in flight. Tap opens a `ConfirmDialog` (Q-S3-2). Success toast "Change discarded". | P1: only server-rejected writes are discardable. | A `write-failed` 500 that never clears still has no exit (accepted in P1). |
| D6 | Order of effects: remove first, resync second, fire-and-forget (Q-S3-4). | The server has said it will not accept this write; keeping it buys nothing. | If the network drops in that instant the list can stay stale until the next sync or launch (same as any failed sync). |

## Decision questions (as asked)

**Q-S3-1 What does Discard throw away?**
- **A (recommended):** exactly the one queued item, merged later edits included (fact 1). Same-record writes queued behind it (D4) survive and send afterwards.
  Cost: a survivor was built on the assumption the discarded write applied, so its CAS `before` is probably stale -> 409 -> existing `mutationConflicted` reconcile (toast, store reconciled; 409 never counts as stuck). A survivor updating a record that was never created may be rejected and park -> user discards again. Converges, but can be noisy.
- B: also drop the survivors for the same record(s). Cleaner outcome, loses edits the user never saw rejected.
- C: refuse Discard while survivors exist. Safest, but a stuck record can become undiscardable until the blockers clear, which they cannot (D4).

**Q-S3-2 Confirm UI**
- **A (recommended):** `ConfirmDialog` (the app-wide destructive idiom, bottom sheet, room for the "later edits are lost too" sentence). Cost: a modal over a sheet; `Main.qml`'s back-button list checks `stuckWritesSheet` before `confirmDlg`, so Back may close the sheet under the confirm. Same ordering exists for other sheet+confirm flows; verify on device, fix = list order.
- B: inline two-step in the row (state held on the sheet root by requestId, because the Repeater model is rebuilt on every outbox change). No stacking, no back-button issue; cramped for the warning copy and a new pattern in this app.

**Q-S3-3 Who may be discarded?** P1 stands (rejected only) unless you say otherwise. Widening to every stuck write lets a 3-minute outage tempt the user into throwing away a write the server would accept. Recommend keep P1. Confirm.

**Q-S3-4 Resync failure handling**
- **A (recommended):** remove first, resync after, fire-and-forget.
- B: resync first, remove on success. Needs a completion callback from six stores (they have none), so it is a bigger slice, and on failure the user keeps a write the server rejects.

**Q-S3-5 Photos on discard of a parked product create**
- **A (recommended):** leave to roadmap item 4 (plan says "handle together"). Photos queued for that product then 404 and end `failed`, with their own Retry/Discard tile (PR #94). Noisy, no data loss.
- B: purge the product's queued photos at discard (reuse the delete purge in `InventoryStore`). Small, but touches photo code owned by the photos session.

## Test outline (full plan comes with the implementation, Skill 49 template)
- `tst_StuckWrites`: `entitiesOf` for all four shapes, malformed, empty `ops`, duplicates.
- `tst_Gateway`: discard removes the item and clears stuck + parked counts; emits once with the right entities; refuses a non-parked / in-flight / unknown / already-discarded id; refuses offline; operation item finishes waiters with `discarded` and fires `operationRejected`; siblings become due; relaunch after discard; monkeys (double tap, discard during Retry, 20+ parked, sign-out mid-flow).
- New `tst_DataModel_discardResync`: per entity, the right store resets (observable: `products = []` or `_resetPending`, since `syncFromFirebase` is read-only on singletons); one resync per store for a multi-entity item; unmapped entity ignored; every `Gateway._collections` entity is covered.
- Sheet: on-device only (Qt UI); plan lists the steps. Server untouched -> no Node/rules tests, stated in the plan.
- Hard on-device gap (carried from #106): **no verified recipe forces a real `write-rejected`.** S3's happy path cannot be exercised on a device until one exists. Option to add in the test plan: a debug-only Functions emulator flag; needs your call at implementation time.

## Risks
- Destructive and irreversible (no Undo; rejected Undo as YAGNI: the server already refused the write).
- The `removed_staff` tombstone stays in memory until relaunch (fact 5).
- S3 is unverifiable on device without a rejection recipe (above).
- Stacked on #106: if #106 changes in review, this branch rebases.

## Resolved decisions (Taher, 2026-10-01): A on all five
Q-S3-1 A (discard exactly the one item; later merged edits go with it; queued-behind writes survive), Q-S3-2 A (`ConfirmDialog`), Q-S3-3 P1 stands (rejected only), Q-S3-4 A (remove first, resync after, fire-and-forget), Q-S3-5 A (photos left to roadmap item 4). The on-device rejection recipe was not a lettered question: default taken, **no emulator flag built**; S3's happy path is CI-only until a recipe exists.

## Implementation notes (what differs from the proposal)
- **Local `ConfirmDialog` inside `StuckWritesSheet`**, not `Main.qml`'s `confirmDlg` (precedent: `ManageCategoriesDialog`, whose comment says the outer sheet hides a global confirm). Back / Close / tap-outside on the sheet are blocked while it is open via `busy: discardConfirm.opened` (Main's Back list already honours `busy`). **No `Main.qml` change**, so the list-order risk in Q-S3-2 A is replaced by this guard; verify on device.
- **Delta callbacks are answered too** (`Gateway._failDeltaCallbacks`, `{ok:false, error:"discarded"}`). Not in the proposal: a parked delta item can have `recordDelta` callers waiting; removing the item silently would leave them hanging until relaunch (the same reason operation waiters are finished).
- **The parked check reads the queued item** (`StuckWrites.isParkedItem`), not the in-memory state, so Discard works right after a relaunch before `resumeStuck()` has rebuilt the state.
- **Failure toast** when `discardParked` returns false at confirm time ("Could not discard. Check your connection and try again."): the row may have been retried, sent, or gone offline while the confirm was open.
- DataModel keeps a `_resyncStoreByEntity` map + pure `_storesToResync`; a test asserts every `Gateway._collections` entity is mapped or ignored (`stock_movement`).
