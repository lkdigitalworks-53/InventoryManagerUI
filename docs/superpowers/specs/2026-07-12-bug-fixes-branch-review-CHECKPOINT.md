# Checkpoint — Review of `pr_taher_bug_fixes` (commits efd2bfd, d915a7b) + holistic pass

**Date:** 2026-07-12
**Branch:** none created — this session is read-only review (`/superpowers:requesting-code-review`
+ `/qt-development-skills:qt-qml-review`), no code changes made.
**Status:** Review of the 2 requested commits complete. Holistic review in progress —
scope not yet exhausted (see "Not yet reviewed" below).
**IMPORTANT:** This file is NOT committed or pushed (no go-ahead given this session). It exists
only in this sandbox's clone and will be lost when the session ends unless Taher asks me to
push it. Treat the chat transcript as the source of truth until then.

## Ground rules given this session (apply to all future review/implementation work)
1. Products/orders/staff/suppliers must be looked up/mutated by their unique ID, never by
   name or SKU (names/SKUs can legitimately duplicate).
2. Import/export must never overwrite existing data with wrong details — flag as an issue and
   skip instead.
3. Import must not let an order's product quantity exceed available inventory stock.
4. Goal: 0 bugs in core operations (add/update/adjust/revert/export/import) and their maths/UI.

## Commit-order correction (flagging per "be honest" instruction)
The two hashes given (`efd2bfd`, `d915a7b`) are real commits on `pr_taher_bug_fixes`, but by
actual git parent-chain (verified via `git rev-parse <sha>^`, not just `git log`), the branch's
true order is:
1. `0b73ffd` "fix: checking the status of the available stock while importing order" (**first**,
   parent = `main` tip `d21a58b`) — NOT in the requested list, but directly relevant: it's the
   1-line predecessor that `d915a7b` replaces.
2. `d915a7b` "fix: block importing orders with product qty more than available stock" (second)
3. `efd2bfd` "fix: remove invalid finding product by name" (third/newest)
Also: commit author-dates are out of chain order (`efd2bfd` is dated *earlier* than its own
parent `d915a7b`), suggesting history was rebased/reordered at some point. Not a code bug, just
a heads-up for branch hygiene.
I reviewed `efd2bfd` and `d915a7b` exactly as given, and looked at `0b73ffd` for context since
`d915a7b`'s diff only makes sense against it.

## Review findings — commit `efd2bfd` ("remove invalid finding product by name")
**Verdict: solid fix, ready with minor cleanup.** Correctly removes `InventoryStore.findByName()`
and all its call sites in favor of `getById()`. Confirmed via repo-wide grep: no dangling caller
of the removed function remains.
- Minor: `DataModel.qml` `_resolveInventory()` — comment still says "fall back to name" but the
  fallback code was removed; comment is now stale/misleading.
- Minor/scope-creep: `NewOrderDialog.qml` also dropped the "hide 0-stock products" filter in the
  same commit — unrelated to the name-lookup theme. Not a data bug (the add button still guards
  `p.stock <= 0`), but now a 0-stock product shows in the picker with "0 left" and clicking Add
  silently no-ops with zero user feedback — should either show an error or disable the row.

## Review findings — commit `d915a7b` ("block importing orders with product qty more than available stock")
**Verdict: NOT ready to merge — the added block has 2 confirmed crash/logic bugs, verified with
Node repros (see chat transcript), plus 2 further issues surfaced by tracing the surrounding code.**

1. **CRITICAL — crashes on every brand-new imported order.** `existingById[grp.key].products`
   assumes `grp.key` (the row's Order ID, or a synthetic `_anon_N` for ID-less rows) already
   exists in `existingById` (built from `OrdersStore.orders`). For any order not already in the
   system — i.e. the normal "bulk-import orders" case — `existingById[grp.key]` is `undefined`,
   and `.products` throws `TypeError: Cannot read properties of undefined`. Confirmed with a
   minimal repro. This fires during preview generation (`_validateOrderRows`), before the user
   even sees a policy choice — almost certainly the exact bug caught on-device.
2. **CRITICAL — `if` without braces makes `break` run unconditionally.**
   ```js
   for (var l = 0; l < existingById[grp.key].products.length; ++l) {
       if (existingById[grp.key].products[l].productId === pid)
           existingProduct = existingById[grp.key].products[l]
           break   // not inside the if — always fires after l=0
   }
   ```
   The loop always exits after checking index 0. For any order line whose product isn't the
   *first* line item on the existing order, `existingProduct` never gets set, so the diff-qty
   stock check silently falls through to the wrong branch. Confirmed with a repro.
3. **Pre-existing, not introduced here:** the replaced one-liner (`idToProduct[pid].stock - qty`)
   also assumed `idToProduct[pid]` exists — same crash risk for blank continuation rows or
   unresolved Product IDs, and this new block still runs *before* the existing `!pid`/`!inv`
   guard clauses further down, so it inherits the same ordering problem. Not new, but not fixed
   either — worth closing while this code is already being touched.
4. **Important — inconsistent status gating.** The "existing product" branch only checks stock
   when `status === "completed"`; the "new product" `else if` branch checks stock unconditionally
   regardless of status. A pending-status import of a genuinely new order-product would get
   incorrectly flagged, while the same case on an existing order wouldn't.

## Adjacent findings from tracing the surrounding code (not in the 2 commits, found while verifying them)
1. **CRITICAL — `OrderDetailDialog.qml:487`** still matches by name, not productId, when adding
   a product to an order being edited:
   ```js
   if (products.get(i).name === p.name) { products.setProperty(i, "quantity", ...) ... }
   ```
   Since names can legitimately duplicate (ground rule), adding Product B (different id, same
   name as Product A already on the order) will silently bump Product A's quantity instead of
   adding Product B as its own line — wrong product gets the price/tax/stock deduction. This is
   the exact bug class `efd2bfd` fixed everywhere else in this same file, missed here.
2. **CRITICAL / architecture — `DataModel.qml` `_tryAdjustOrder`'s "added units" path (~line
   577) has no stock-sufficiency check at all.** It consumes FIFO, and if short, calls
   `topUpOldest` (manufactures batch history) and deducts stock unconditionally — no guard, no
   report. This is the actual write path for "overwrite" import of an existing completed order,
   so even a perfectly-fixed `_validateOrderRows` preview check wouldn't fully guarantee "imports
   never oversell" — the enforcement point needs to also exist at the mutation layer, not only
   at preview time (defense in depth — root-cause note, not just a preview bug).
3. **Important — `OrdersStore.upsertMany()`** silently no-ops (no `counts.skipped` increment, no
   issue) when "overwrite" policy targets an order that isn't `status === "completed"`. Doesn't
   corrupt data, but under-reports what happened vs. the "show issue and skip it" ground rule.
4. **Needs Taher's call, not mine to silently resolve:** `completeImportedOrder()`'s existing,
   documented design ("owner decision 'complete + report shortfall'") deliberately allows a
   brand-new *imported* order marked "completed" to oversell inventory (reports `understocked`
   but doesn't block). This predates today's ground rule #3. Worth confirming whether rule #3
   should override this documented decision, or whether it's meant to apply only to the
   pending/processing import path.
5. **Minor:** `SalesPage.qml:2132` `_supplierIdForName()` does a case-sensitive `===` match for
   a supplier-name filter chip, while `SupplierStore.findByName()` (used for the actual
   supplier-resolution-on-import path) is case-insensitive. Low stakes (UI filter only), but
   worth aligning.
6. **Not a bug — confirmed reasonable design:** `SupplierStore`/`InventoryStore._resolveSupplierId`
   still resolves suppliers by name, but only as a find-or-create-canonical-ID step for free-text
   import fields (with an `SUP-` id-prefix escape hatch checked first, and case-insensitive/
   trimmed dedup on create). This is a different pattern from the OrderDetailDialog bug — it's
   not selecting among ambiguous existing records for a financial mutation, it's minting a
   stable ID from free text. Flagging only so it's clear I checked it, not asking for a change.

## Round 2 — Taher chose "continue holistic review into remaining modules"

Reviewed: StaffStore.qml (full), TransactionStore.qml (full, spot-checked recordSaleFromOrder/
recordReturn/recordPriceAdjust/totalsForOrder), StockBatchStore.qml (full), SupplierStore.qml
(full), OrdersStore.qml (full — upsertMany already covered round 1, this pass did the rest:
_mergeOrder, computeOrderTotals, applyAdjustment, approveAllPending, addOrder, deleteOrder,
openOrdersForProduct, updateOrder, the pendingOrderCount default), DataModel.qml's full
Connections{target:logic} block (RBAC gating across every handler + the completed→non-completed
revert path at onUpdateOrder:110-139), XlsxService.cpp (headers, writeProductsSheet,
writeOrdersSheet, writeReadmeSheet, readSheet — export/import round-trip), confirmed OrderMath.js
`allocate()` is deliberately parity-maintained with OrdersStore.computeOrderTotals (comment says
so explicitly) and covered by `tst_RealisedMathParityFixtures.qml`/`tst_BreakdownMathParityFixtures.qml`
— no fresh finding there.

### New findings this round
1. **Dormant-but-critical-if-shipped — `OrdersStore.deleteOrder()` has zero guard against
   deleting a `completed` order.** No reversal of stock deduction, no cleanup of the
   TransactionStore sale events tied to that orderId — they'd become permanently orphaned and
   inventory would stay silently deducted forever. Contrast with `onDeleteProduct`, which
   explicitly blocks when `openOrdersForProduct()` is non-empty. **However**: traced the full UI
   chain (`OrdersPage.qml`'s `deleteOrderClicked` signal and `canDeleteOrders` prop are declared
   but never emitted/consulted anywhere) — this is currently unreachable dead code, so no live
   risk today. Flagging so it's fixed *before* someone finishes wiring the button, not after.
2. **Important — RBAC gap on the order-revert path.** `onUpdateOrder`'s completed→non-completed
   branch (which calls `_reverseCompletedOrder`, undoing stock + financial ledger effects — same
   or larger blast radius than `onAdjustOrder`) has **no `_hasAnyRole` check at all**, while
   `onAdjustOrder`/`onDeleteOrder` require `owner/admin/manager`. Any authenticated staff can
   revert a completed sale today — this one **is** live/reachable (any order-detail status
   change routes through `onUpdateOrder`).
3. **Minor/consistency — repeated "read `array[length-1]`" pattern.** `onAddOrder`,
   `onAddProduct` both do `Store.items[Store.items.length - 1].id` to get the just-added id for
   their `orderAdded`/`productAdded` signals — the exact anti-pattern `StaffStore.lastAddedId`
   was built to avoid (its own comment explains why). Confirmed both signals currently have zero
   listeners (dormant, so no live bug), and confirmed the specific current call sites are
   synchronous (no async gap), so not exploitable as written today — but it's the same landmine
   class as `lastAddedId` was created to prevent, twice more, and `InventoryStore` has no
   equivalent `lastAddedId` to reach for if ever needed.
4. **Minor — `OrdersStore.pendingOrderCount: 2`** hardcoded initial default (siblings
   `completedOrderCount`/`outOfStockCount` correctly default to `0`). Self-corrects the instant
   `_refreshCounts()` runs, but the code's own comments confirm the Dashboard KPI can render
   before tenant context resolves — a real (if narrow, cosmetic) window to show "2 Pending
   Orders" on a cold start with zero real orders.
5. **Doc/code mismatch — the in-app Orders import README sheet** (`writeReadmeSheet` in
   XlsxService.cpp) says "SKU ... Resolves the line to a product," but `_validateOrderRows` only
   ever resolves by Product ID — SKU is read but unused for resolution. The code is actually
   correct per your ground rule (SKU can duplicate); the **doc overclaims**. Recommend fixing the
   doc text, not adding SKU-based resolution.
6. **Minor/Important — `SupplierStore.updateSupplier()` doesn't re-run the case-insensitive
   name-uniqueness check that `addSupplier()` does on create.** Renaming supplier A to match
   supplier B's existing name silently produces two ID-distinct suppliers with an identical
   display name — undermines the free-text import matching (`_resolveSupplierId`) which picks
   whichever one `findByName` hits first.

### Confirmed clean this round
StaffStore CRUD (ID-based throughout), TransactionStore event recording (ID-based, well-commented,
bug-number references suggest prior hardening), StockBatchStore FIFO/topUp/restore (ID-based,
solid), SupplierStore CRUD aside from #6, RBAC pattern for the rest of the CRUD surface (sales ops
open to all authenticated staff, admin-level ops gated — a reasonable, consistent design, not a
gap), export header/writer round-trip for products and orders (Taxable/Tax% already present,
matches the now-implemented `2026-07-10-product-tax-export-size-field.md` plan).

## Round 3 — Taher chose "finish Category/OrderChannel/ActivityLog"

Reviewed all three in full (120 + 137 + 235 lines).

### New findings
1. **Important — `ActivityLog`'s Firestore collection grows unbounded.** `record()` caps the
   LOCAL `entries` array at 50 (`arr.slice(0,50)`) but only ever `PUT`s the one new entry — it
   never deletes the docs that fall off the 50-cap. `_fetchFromFirebase()` uses
   `FirebaseService.get("activity_log", ...)`, which internally paginates to fetch the **entire**
   collection (unlike every other store, which uses the paginated `.query()` with an explicit
   `limit`) — then trims to 50 client-side. No cleanup Cloud Function exists either (checked
   `functions/index.js`). Net effect: every `record()` call (product add/update, staff add,
   order-derived activity, import) adds a permanent doc that's never removed; every app cold
   start re-fetches the whole, ever-growing collection just to show the newest 50. Not broken
   today at low volume, but it's a genuine unbounded-growth bug that will slow every cold start
   and increase Firestore read costs the longer the app is used. Needs either a TTL/cleanup
   function or a bounded query with a delete-the-overflow step in `record()`.
2. Confirmed (not new — matches the already-tracked memory item) — `CategoryStore` and
   `OrderChannelStore`'s `Component.onCompleted` fetch unconditionally, with no
   `AuthStore.tenantId.length > 0` guard, unlike Staff/Orders/Supplier/StockBatch/Inventory.
   `ActivityLog` has the same gap. This was already flagged in memory as an "optional follow-up,
   not broken today" from a prior session — now directly confirmed by reading all three files
   myself rather than by inference.

### Confirmed clean
Category/Channel add/remove/setDefault — simple string-keyed config lists by design (not
entities needing IDs, so the product/order/staff/supplier ID rule doesn't apply here), dedup is
case-insensitive and consistent between the two. `ActivityLog`'s dismiss/dismissAll/markAllRead/
record — well-structured immutable-update pattern, notifications/unreadCount filtering (dismissed
+ own-action suppression) is logically sound.

## Round 4 — Taher chose "finish StockReconcile.js, dialogs, Gateway/OutboxStore"

### New findings
1. **CRITICAL / systemic — all four entity ID generators reuse IDs after the highest-numbered
   record is deleted.** `InventoryStore.nextProductId()`, `OrdersStore.nextOrderId()`,
   `StaffStore.nextStaffId()`, `SupplierStore.nextSupplierId()` are all `max(existing numeric
   suffix) + 1`. Confirmed `InventoryStore.deleteProduct()` does **not** clean up
   `TransactionStore`/`StockBatchStore` records for that id — they're left in place, keyed by a
   now-free id. If PRD-042 (the current max) is deleted, the very next `addProduct()` calculates
   `max+1` from the remaining records and generates **PRD-042 again** — a brand-new, unrelated
   product now shares an id with a deleted product's entire transaction/batch history. Applies
   identically to staff and suppliers: delete the highest-numbered staff member, hire someone new,
   and they can inherit the departed employee's `STF-0xx` id — every historical order/transaction
   that recorded the old employee's `staffId` for attribution now silently points at the new hire.
   This is the same failure class every ground rule in this session was written to prevent, except
   it's in the id-minting step itself rather than a lookup. Also a **concurrent-add race**: two
   staff adding a product/order at nearly the same moment can compute the same `max+1` id from
   stale local state; nothing in `Gateway.recordMutation(..., "create", ...)` checks the doc
   doesn't already exist before writing, so the second write silently clobbers the first (full
   record loss, not just a display glitch). Fix needs a collision-safe id scheme (UUID, Firestore
   auto-id, or a atomically-incremented counter document) — `max(existing)+1` off a locally-synced
   array can't guarantee either uniqueness-under-deletion or uniqueness-under-concurrency.
2. **Minor/consistency — `RestockDialog.qml` calls `InventoryStore.restock()` directly**,
   bypassing `logic.restockProduct` → `DataModel.onRestockProduct`'s `_hasAnyRole(["owner",
   "admin"])` check entirely — a different code path than every other write, which routes through
   `logic.*` signals into gated `DataModel.qml` handlers. Currently mitigated: the Restock button
   itself (`ProductCard.restockBtn`) is `visible: card.canManage`, itself driven by
   `AuthStore.canManageInventory`, so an unauthorized role never sees the trigger in normal UI use.
   Still worth routing through the same gated path as everything else for consistency/defense in
   depth, same reasoning as the `onUpdateOrder` revert gap in round 2.
3. **Confirmed unchanged (not new) — `Gateway.qml`/`OutboxStore.qml` on this branch match what's
   already tracked in memory:** `mode: "direct"` (dormant), `drainNow()` still fires all due items
   concurrently with no sequencing, `OutboxStore.enqueue()` still unconditionally `push`es with no
   same-`entity+entityId` coalescing. Nothing regressed, nothing fixed — as expected, since this
   branch isn't the one scoped to do that work.

### Confirmed clean this round
`StockReconcile.js` (`delta()` — trivial, correct, well-documented pure function; its caller
`_reconcileBatchesForStockEdit` correctly reconciles FIFO batches on a manual stock edit).
`InventoryStore.restock()` itself correctly calls `StockBatchStore.addBatch()` — no FIFO-ledger
drift there. `AddProductDialog.trySubmit()` — thorough numeric validation (cost ≥ 0, price > 0,
price ≥ cost, stock ≥ 0, tax 0–100), all required fields checked.

## Review phase complete
This closes out the full scope discussed with Taher across all 4 rounds: the 2 requested commits,
Orders/Inventory/Import/Export, Staff/Transaction/StockBatch/Supplier, Category/Channel/
ActivityLog config stores + RBAC, and finally StockReconcile/dialog-validation/Gateway-Outbox.
13 findings total (4 in the 2 reviewed commits + 9 from the holistic pass). Full list posted to
Taher in chat with a recommendation to stop reviewing and start fixing — awaiting his decision.
