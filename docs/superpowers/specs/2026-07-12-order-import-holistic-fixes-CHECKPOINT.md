# Checkpoint — fix/order-import-stock-and-holistic-bugs

**Date:** 2026-07-12 (original), rebuilt 2026-07-14
**Branch:** `fix/order-import-stock-and-holistic-bugs`, rebuilt off `main` @ `2748d1b` (the
original branch was off `d21a58b`; main moved 30 commits ahead in the meantime, including the
P0 compliance Gateway migration — PR #32, routing OrdersStore/StaffStore/SupplierStore/
InventoryStore mutations through `Gateway.recordMutation` — and a restock "reason" field
feature — PR #30). Rather than rebase the original 4 commits through those conflicts
mechanically, the branch was rebuilt from scratch off current main: same 4 logical commits,
same intent, re-integrated against the current code (see "Rebuild notes" below for exactly
what changed in the integration vs. what's unchanged).
**Status:** Critical #1–4 done (rebuilt). Nothing committed differently in intent from the
original — see the new commit messages for the specific integration deltas (Gateway.
recordMutation/recordMutations calls, the reason+callback parameter merge in restock,
upsertMany's move to the batch Gateway.recordMutations call).

## Rebuild notes (2026-07-14)
- Confirmed with Taher before rebuilding: the id-minting algorithm itself
  (`mintCounterValue`/`mintCounterBatch` in `FirebaseService.qml`) was already tested and
  confirmed working against real Firestore — ported verbatim, unchanged.
- Chose "fresh branch, re-derive against current main" over rebase/merge after diffing exactly
  what changed: only 7 of the ~18 touched files actually overlap with main's changes
  (`Main.qml`, `DataModel.qml`, `InventoryStore.qml`, `OrdersStore.qml`, `StaffStore.qml`,
  `SupplierStore.qml`, `RestockDialog.qml`); the rest ported verbatim with zero conflict risk.
  The 7 overlapping files needed *semantic* re-integration, not just textual conflict
  resolution — the P0 migration introduced a new `Gateway.recordMutations()` batch-mutation
  call that bulk-import's `upsertMany` should use (matching how `approveAllPending()` now
  works), which a mechanical conflict-marker resolution would likely have missed entirely.
- Per Taher's explicit choice: `upsertMany` (both `InventoryStore.qml` and `OrdersStore.qml`)
  now collects all new/renamed rows into one `Gateway.recordMutations()` call instead of firing
  `Gateway.recordMutation()` once per row.
- `InventoryStore.restock()` gained a `reason` parameter on main in the same argument position
  originally used for `callback` — resolved as `restock(productId, amount, party, unitCost,
  reason, callback)`. `RestockDialog.qml`'s new Reason field UI and the busy-guard/async-call
  changes were merged by hand in the same submit handler.
- Re-verified after rebuild: brace/paren balance across every touched file, no bare
  (no-callback) calls to the now-async id functions anywhere, no stale direct
  `FirebaseService.put`/`remove` calls left in the 4 model files (would indicate the Gateway
  migration got accidentally reverted), and the Node harnesses for `ImportMath` and both
  `mintCounterValue`/`mintCounterBatch` all still pass.
- **Still true, worth repeating: the NEW integration points added in this rebuild
  (`Gateway.recordMutation`/`recordMutations` calls, the reason+callback merge, the batch-aware
  bulk-import path) have not been tested against a live Firestore backend.** The underlying
  counter algorithm's real-world validation stands; the wiring around it is new since that test
  and needs its own pass.

## Fix order (Taher's call: one branch, priority order)

### Critical
1. [x] Import order-row stock check crash + broken search loop (was `d915a7b`) — rewrote as
   tested pure functions `ImportMath.findOrderLineByProductId` / `ImportMath.checkOrderLineStock`
   (14 new tests in `tests/tst_ImportMath.qml`, all passing — verified via a Node port since
   qmltestrunner isn't available in this sandbox, see chat). Wired into
   `ImportPreviewDialog.qml._validateOrderRows`, correctly ordered AFTER pid/inv resolution (main
   already had that ordering right — the buggy version only existed on `pr_taher_bug_fixes`).
   Also fixed the status-gating asymmetry (both branches now gated on `status === "completed"`
   consistently) — see "Design decisions" below for reasoning, flagged for pushback.
2. [x] (same fix as #1 — the two Critical bugs found in `d915a7b` share one root cause / one fix)
3. [x] `OrderDetailDialog.qml:487` name-based line match when adding a product to an order being
   edited — fixed to `productId`. While in there, also re-applied `efd2bfd`'s intent cleanly
   across this branch (main didn't have it yet): removed `InventoryStore.findByName()` and every
   name-based product lookup/fallback in `OrderDetailDialog.qml` (_availableStock, _save,
   _findOriginalLine — now productId-only, single-arg), `DataModel.qml` (_resolveInventory,
   _findLine — now productId-only), and `NewOrderDialog.qml` (_inCartQty — dropped the
   unreachable name-fallback branch). Deliberately did NOT re-apply efd2bfd's removal of the
   0-stock product filter in NewOrderDialog's picker — that was unrelated scope creep in the
   original commit and introduced a UX gap (item shown, Add silently no-ops); simplest fix is to
   just not make that change, so it wasn't.
   Left `SalesPage.qml`'s two `.name ===` filter-chip lookups (staff/supplier) alone — read-only
   UI filtering, not a data mutation, lower-risk, and out of scope for this pass (still tracked as
   part of Minor item #10's supplier-name-consistency finding).
4. [x] ID generators reuse ids after deletion + concurrent-add race — **DONE for all four entity
   types (Staff, Orders, Products, Suppliers).**
   Core primitives in `FirebaseService.qml`: `mintCounterValue(path, seedValue, callback)` (mints
   one id) and `mintCounterBatch(path, seedValue, count, callback)` (atomically reserves N
   consecutive ids in ONE round-trip — added mid-work, see below). Both verified via mocked-
   Firestore Node harnesses (control-flow only, not real Firestore precondition semantics — see
   the repeated caveat below).
   **Staff**: `nextStaffId`/`addStaff` async. Found and fixed a real race in `Main.qml`'s
   credential-provisioning flow (was reading `StaffStore.lastAddedId` synchronously right after
   an now-async add) via a `_pendingStaffLogin` stash, and added a `logic.errorOccurred` listener
   to `AddStaffDialog.qml` so a mint failure doesn't leave the sheet stuck spinning forever.
   **Orders**: `nextOrderId`/`addOrder` async. `DataModel.onAddOrder`'s auto-approve chain
   (`_tryCompleteOrder`) now correctly uses the real minted id from the callback instead of
   `orders[orders.length-1]`.
   **Products + Suppliers**: `nextProductId`/`addProduct`, `nextSupplierId`/`addSupplier`,
   `restock` all async; `InventoryStore._resolveSupplierId` now callback-based throughout (used
   by `addProduct` and `restock`). Fixed the two live call sites — `AddProductDialog.qml` (moved
   the photo-upload dependency, which was reading `addProduct`'s return value synchronously, into
   the callback — this would have silently dropped every pending photo otherwise) and
   `RestockDialog.qml` — plus their inline "add new supplier" flows. Added `busy`/error handling
   to both dialogs (they're `BottomSheet`s, so this piggybacks on an existing property).
   **Mid-work discovery — bulk import was a materially different problem, and I'd broken it**:
   `InventoryStore.upsertMany`/`OrdersStore.upsertMany` (the CSV/XLSX import apply path) mint ids
   in a tight synchronous loop — one call per new row. Converting the underlying mint functions to
   async broke this immediately (would have thrown calling `undefined(...)` on the missing
   callback the moment either function's "new row" or "rename" branch ran). A per-row async
   round-trip would also have been slow for a large import. Fixed by extending the primitive to
   `mintCounterBatch`: pre-scan the whole batch for how many fresh ids are needed (and, for
   products, which supplier NAMES are new — added `SupplierStore.addSupplierWithId(id, name)` for
   this, a synchronous variant that skips minting since the id was already batch-reserved), reserve
   all of them in one round-trip (two for products: one for productIds, one for new supplierIds),
   then run the original loop synchronously again pulling from the pre-reserved pool. Both
   `upsertMany` functions and `ImportPreviewDialog.qml._apply()` are now async with a `busy` guard
   against double-submission. Verified the batch-reservation control flow (including a forced
   concurrent-conflict-then-retry case) with its own Node harness.
   **Also discovered while wiring this: `onAddProduct`/`onRestockProduct` in `DataModel.qml` are
   dead code** — `AddProductDialog.qml`/`RestockDialog.qml` call `InventoryStore` directly,
   bypassing these RBAC-gated handlers entirely, the same pattern as `OrdersStore.deleteOrder()`
   (finding #7) and matching the already-known `RestockDialog` RBAC-bypass (finding #11) — now a
   confirmed second instance (`AddProductDialog` too). Fixed the dead handlers for correctness
   (so they're not obviously broken if ever wired up) but did NOT route the live dialogs through
   them — that's the pre-existing, separately-tracked architectural question in #11, not something
   to fold silently into this fix.
   **Standing limitation, repeated because it matters: I cannot verify Firestore's actual
   server-side precondition enforcement from this sandbox (no network access to Firestore, can't
   build/run the app this session). Everything above is verified as far as client-side control
   flow goes (Node-mocked harnesses) and by careful tracing of every caller — but the core
   assumption (Firestore's `currentDocument` precondition actually serializes concurrent commits
   the way its documentation says) needs a real Firestore environment to confirm before this
   ships.** Also: every "Add"/"Restock"/"Import" action now takes a real network round-trip where
   it used to be instant — worth a UX pass (the dialogs affected already have `busy`-gated
   spinners via `BottomSheet`, but hasn't been visually verified since the app can't be run this
   session).

### Important
5. [ ] `onUpdateOrder` revert path (completed→non-completed) has no RBAC gate.
6. [ ] `_tryAdjustOrder`'s added-units path has no stock-sufficiency guard (architecture gap).
7. [ ] `OrdersStore.deleteOrder()` no guard against deleting a completed order (currently dead
   code — UI never calls it — but fixing before it's wired up).
8. [ ] `ActivityLog` unbounded Firestore growth — no pruning of old docs past the 50-cap.
9. [ ] `OrdersStore.upsertMany()` silent no-op (no `counts.skipped`, no issue) when "overwrite"
   targets a non-completed order.

### Minor
10. [ ] `SupplierStore.updateSupplier()` no rename-time uniqueness re-check.
11. [ ] `RestockDialog.qml` bypasses the RBAC-gated `logic.restockProduct` path (mitigated by UI
    hiding the button, but inconsistent).
12. [ ] `onAddOrder`/`onAddProduct` last-array-element pattern (dormant — no listener today, but
    same landmine class `StaffStore.lastAddedId` was built to prevent).
13. [ ] `OrdersStore.pendingOrderCount` hardcoded default `2` → should be `0`; Orders-import
    README overclaims SKU-based resolution — fix the doc text, not the code.

Also carried over from `efd2bfd` (re-applying cleanly on this branch, not inherited):
14. [ ] Remove `InventoryStore.findByName()` and its call sites — same change as `efd2bfd`, plus
    its own two minor findings (stale `_resolveInventory` comment, `NewOrderDialog` 0-stock
    picker UX gap from the same commit).

## Design decisions made while implementing (flagged for pushback)
- **#1 status-gating unification**: original `d915a7b` code only gated the "existing order line"
  branch on `status === "completed"`; the "brand-new line" branch had no status gate at all. I'm
  treating the asymmetry as an oversight (not intended behavior) and gating both branches the
  same way, since it matches (a) the explicit comment describing both cases as one concern, and
  (b) the app's existing philosophy elsewhere that stock is enforced at completion time, not at
  pending/processing creation time. **Flagging this because it changes import behavior for
  pending/processing orders with a brand-new understocked line — they'll now import without a
  stock check, same as they would via manual order creation.** Tell me if that's wrong.
- **#1 existing-line behavior**: kept the original author's intent (clamp qty back to what's
  already booked + flag issue, keep the line on the order) rather than dropping the line —
  dropping would look like "remove this product from the order" to `OrderAdjust.diffLines`,
  which is worse than not honoring a quantity increase.

## Progress log
- Branch created off main.
- This checkpoint file created.
- Next: TDD on `ImportMath.js` (findOrderLineByProductId, checkOrderLineStock) → wire into
  ImportPreviewDialog.qml → re-apply efd2bfd's productId-based lookup fix → OrderDetailDialog fix.
