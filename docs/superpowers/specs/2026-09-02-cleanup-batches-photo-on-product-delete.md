# Design: clean up stock batches (and the photo) on product delete

Status: design only, not implemented. Raised after merge of `feature/product-order-delete-ui`,
which shipped two symptom-level fixes (Potential profit, Inventory Value) for the same root
cause described here — see `docs/superpowers/KNOWN-ISSUES.md`.

## The issue

`InventoryStore.deleteProduct()` removes the product and routes the delete through
`Gateway.recordMutation("inventory", productId, "delete", before, null)`. It does not touch two
things that reference that product:

- **`StockBatchStore` entries.** Every batch received against that product (`{ batchId,
  productId, qtyRemaining, unitCost, supplierId, ... }`) stays in the store forever, pointing at
  a `productId` that no longer resolves to anything.
- **The product photo** in Firebase Storage (`StorageService.deleteProductPhoto`, already used
  elsewhere — see below).

This is the root cause behind two bugs already shipped in `feature/product-order-delete-ui`:
Sales Analysis's "Potential profit" going negative for orphaned stock (fixed by excluding a
batch once its product no longer resolves), and "Inventory Value" not moving at all after a
delete (same fix, different symptom, because that calculation never needed a live product to
begin with). Both fixes were deliberately symptom-level — excluding orphaned batches at the
*consuming* end (analysis calculations) rather than stopping them from being created. That was
the right scope for a UI ticket and a bug report; it is not a substitute for fixing the actual
source. Every future feature that reads `StockBatchStore.batches` inherits the same defect until
this is fixed once, at the source.

## Why this wasn't just fixed outright

Checked before proposing a design, not assumed:

- **There is currently no way for a user to reduce a batch's `qtyRemaining` to 0 except by
  selling it through a real order.** `StockBatchStore.qml` has `addBatch`/`addBatchMany` (receive
  stock) and `restoreFifo` (put quantity back on an order reversal) — nothing that manually
  reduces or writes off a batch. This rules out simply *blocking* delete while stock remains
  (mirroring the existing open-orders guard) as a standalone fix — it would permanently trap a
  user who wants to remove a discontinued or mis-entered product that still shows stock, with no
  way to zero it out first.
- **`consumption[]` on orders is a self-contained snapshot, not a pointer back to the batch.**
  Confirmed in `RealisedMath.js`: every consumption entry carries its own `unitCost`/`qty`
  stamped at the time of sale and is read directly (`cc.unitCost`) — it never re-queries
  `StockBatchStore` for the original batch. This means the batch's *working* record can be
  removed without touching any historical revenue/profit number; the audit trail (see below)
  is what actually matters for compliance, not the working doc.
- **Batches already route through the same audit pattern as everything else** —
  `Gateway.recordMutation("stock_batch", batchId, ...)` / `Gateway.recordDelta(...)` — so a
  cascade-delete can preserve the ledger/working two-tier model this app already relies on: hard-
  delete the working `StockBatchStore` doc, keep the `audit_log` entry, exactly like
  `deleteProduct` already does for the product itself.

## Options considered

**A — Block delete while stock remains** (mirror the open-orders guard). Ruled out standalone —
no write-off feature exists, so this traps users rather than solving anything. Would need a new
"zero out stock" feature shipped alongside it to not be a dead end — much bigger scope than this
ticket.

**B — Silently cascade-delete batches, no warning.** Destroys a real, financially meaningful
record (remaining stock quantity and its cost basis) as a side effect of a button the user
thinks only affects the product catalog entry. Conflicts with this app's own "confirm before
destructive/irreversible actions" principle, already applied to every other delete in this app.

**C — Soft-archive instead of hard delete when stock remains** (new `archived` product state,
hidden from active views, unarchivable). Probably the most correct long-term answer, but it's a
new product-lifecycle feature — new field, new filtering across every page that lists products
(inventory list, order product picker, every analysis view), a new "unarchive" affordance. Not a
delete-bug fix; a scope decision for Taher, not something to back into here.

**D — Warn, then cascade-delete with audit preserved (recommended).** Enhance the existing
delete-confirm dialog: when the product has any batch with `qtyRemaining > 0`, show the
quantity and its cost-basis value in the confirmation ("This product has 12 units in stock worth
$340 — deleting will remove that stock record too."); on confirm, `deleteProduct()` cascades to
every batch for that product (not just the open ones — an already-exhausted batch has no
ongoing value once its product is gone, and leaving some behind while removing others is a more
confusing half-measure than removing all of them), removing each from the local array and
routing it through `Gateway.recordMutation("stock_batch", batchId, "delete", before, null)` —
same fire-and-forget pattern already used for every other delete in this app, so it inherits the
same known, separately-tracked `_send` terminal-failure risk (see KNOWN-ISSUES.md) rather than a
new one.

Recommending D. It doesn't require a new feature (unlike A or C), doesn't destroy value
silently (unlike B), and it's a direct, bounded extension of the delete flow that already
exists.

## Proposed implementation shape (not yet written)

1. **`DataModel.onDeleteProduct`**: before the existing open-orders check (or after — order
   doesn't matter, both are refusal-free at this point), compute remaining stock via
   `StockBatchStore` for the productId. Pass it through to whatever opens the confirm dialog
   (`Main.qml`'s `confirmDlg.ask({...})`) so the dialog can show the enhanced warning when
   stock > 0, plain wording when it's 0 — matching the existing pattern where the dialog's copy
   already varies by context.
2. **`InventoryStore.deleteProduct()`**: after splicing the product and before (or after —
   doesn't matter for correctness) calling `Gateway.recordMutation` for the product itself, walk
   `StockBatchStore.batches` for this `productId`, remove each locally, and call
   `Gateway.recordMutation("stock_batch", batchId, "delete", before, null)` per batch — same
   shape as `StockBatchStore`'s own existing mutation calls.
3. **Photo cleanup**: call `StorageService.deleteProductPhoto(productId, function(ok, err) {...})`
   unconditionally in `deleteProduct()`, fire-and-forget, non-blocking — a failed photo delete
   (e.g. no photo existed) must not roll back or block the product/batch delete. Same function
   already used in `EditProductDialog.qml`'s "remove photo" action; no new Storage-side code
   needed.

## Open questions for Taher, not decided here

- **Exact warning copy and whether to show it as a distinct dialog vs. an enhanced version of
  the existing one.** Proposed wording above is a starting point, not final.
- **Backfill for already-orphaned batches.** This fix only stops *new* deletes from leaving
  orphans — any batch already orphaned by a delete that happened before this ships stays
  orphaned (though harmless, since the Potential-profit/Inventory-Value fixes already exclude
  orphaned batches from every calculation that matters). Worth a one-time cleanup script, or not
  worth the effort given the fixes already in place make it cosmetically invisible either way —
  Taher's call.
- **Whether the audit_log's "delete" reason for a cascade-deleted batch should say something
  more specific than the generic reason `deleteProduct` already uses** (e.g. distinguishing "this
  batch was removed because its product was deleted" from a hypothetical future direct batch-
  delete feature, which doesn't exist yet but might one day) — a nice-to-have for
  audit-trail readability, not required for correctness.
- **Whether "stock still exists" should also block delete for staff-role reasons** (i.e., does
  only owner/admin get to see/authorize a stock write-off, same as the existing
  `canManageInventory` gate) — likely yes by default since it's the same role gate already on
  the whole delete action, flagging in case there's a reason to split it.
