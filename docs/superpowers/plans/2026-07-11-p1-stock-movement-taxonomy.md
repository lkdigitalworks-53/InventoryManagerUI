# Plan — P1 Stock-Movement Taxonomy (data model + wiring only)

**Spec:** `docs/superpowers/specs/2026-06-06-india-compliance-roadmap-design.md` §4.3 (CGST 56(2))
**Checkpoint:** `docs/superpowers/specs/2026-07-11-p1-stock-movement-taxonomy-CHECKPOINT.md`
**Branch:** `feature/p1-stock-movement-taxonomy` (off latest `main`, P0 already merged)

## Decisions this plan encodes (confirmed with sign-off, including a live design discussion)
1. Scope: data model + wiring only. The opening/closing-balance register report is a separate,
   future session.
2. Manual stock-decrease adjustments (Edit Product's stock field) require picking a `kind`.
   Increases via that same path default to `kind: "adjustment"`, no picker needed.
3. **`kind` enum extended beyond the spec's literal 8 values, with a `sales_return` addition** —
   a documented deviation, reasoned from CGST Rule 56(2)'s actual text (verified via web search):
   the rule has no "return" column at all; a sales return is GST-mechanically a reduction to
   *supply* (credit-note treatment), not an independent event. Modeling it as a distinct
   `sales_return` kind (rather than a sign-flipped `sale`) keeps the ledger self-documenting and
   lets a future register report compute `Supply = Σsale − Σsales_return` unambiguously.
   - Full enum: `receipt | sale | loss | theft | destroyed | write_off | free_sample | gift |
     adjustment | sales_return`
4. **Booking-error reversals get the same `sales_return` treatment as genuine customer returns**
   — not "no movement at all" (my first instinct, corrected during discussion): the ledger is
   immutable, so if a `sale` movement was already written when an order was mistakenly marked
   completed, the only correct fix is an equal-and-opposite entry. The `reason` field carries the
   real-world distinction ("booking correction" vs. "customer return"), not the `kind`.
5. **Damaged-on-return gets TWO movements, not one**: `sales_return` (reverses the original sale
   out of "supply") + `destroyed` (the units are physically gone). Net effect on `product.stock`
   is zero (matches today's behavior — damaged returns don't restock), but the ledger accurately
   shows the units passed through as returned-then-destroyed rather than still being "supply."
6. Confirmed: order completion happens before invoicing (a later, separate step) — doesn't change
   the above; the ledger still records the reversal regardless, since over-recording is harmless
   and under-recording is the actual audit risk.
7. New `stock_movement` writes route through `Gateway.recordMutation`, same pattern as every P0
   entity (already registered in `ENTITY_COLLECTIONS`/`Gateway._collections` from the original P0
   session — no change needed there).

## Design notes

- **`StockMovementStore.qml` is write-only this session** — no local synced list, no read-back.
  The register report (out of scope) is what will eventually read these back; building read
  capability now with nothing to consume it would be speculative.
- **Id generation**: can't use the "scan local array for max" pattern other stores use (no local
  array to scan, by design above). Uses `Gateway._nextRequestId()`'s pattern instead:
  `"MOV-" + Date.now() + "-" + random suffix`.
- **Timestamp field naming**: the spec's shape says `serverTimestamp`, but per the established P0
  convention, a field with that name should only ever be a value CF-derived via
  `admin.firestore.FieldValue.serverTimestamp()` — using it for a client-supplied value would be
  misleading. This session names the client-supplied field `clientTimestamp` on the working doc
  itself (mirroring `Gateway.recordMutation`'s own request-body field of the same name); the
  true, tamper-evident `serverTimestamp` lives on the parallel `audit_log` entry the gateway
  writes in the same transaction (once live) — exactly like every other P0 entity.
- **No new Cloud Function code this session.** `stock_movement` was already registered as an
  entity in the original P0 session; this is a pure client-side (QML) change. That also means
  **none of this session's work can be TDD-verified with `node --test`** — it's all QML, and this
  sandbox has no Qt toolchain (same limitation as P0's Gateway/Outbox tests). Written carefully,
  manually reviewed, flagged clearly — not run here.

## Tasks

- [ ] 1. `qml/model/StockMovementStore.qml` (new): `recordMovement(kind, productId, qty, reason,
      valueAtCost, batchRef)` — validates `kind` against the 10-value enum, builds the doc
      (`id`, `productId`, `kind`, `qty`, `reason`, `valueAtCost`, `batchRef` (nullable),
      `actorUid: AuthStore.uid`, `clientTimestamp`), calls
      `Gateway.recordMutation("stock_movement", id, "create", null, doc)`. Exposes
      `readonly property var manualAdjustmentKinds` (the 7 kinds relevant to the Edit Product
      picker: loss/theft/destroyed/write_off/free_sample/gift/adjustment — `receipt`/`sale`/
      `sales_return` are never user-picked, they're stamped by their own dedicated flows).
      Register in `qml/model/qmldir`. Commit.
- [ ] 2. `InventoryStore.restock()`: after the existing batch/product update, call
      `StockMovementStore.recordMovement("receipt", productId, addedQty, reasonText, batchCost,
      batchId)`. Commit.
- [ ] 3. Order completion (`DataModel.qml` — both `_tryCompleteOrder` and
      `completeImportedOrder`'s matching block): after `InventoryStore.deductStock`, loop over
      the `consumption[]` StockBatchStore already returned and call
      `StockMovementStore.recordMovement("sale", productId, -qtyConsumed, ..., unitCost *
      qtyConsumed, batchId)` per consumed batch portion — accurate `valueAtCost`/`batchRef` per
      portion, no new cost-tracking needed (it's already sitting right there in `consumption[]`).
      Commit.
- [ ] 4. Returns — `DataModel._reverseCompletedOrder` and `_tryAdjustOrder`'s `d.returnedQty > 0`
      block:
      - `restock === true` (undamaged): `StockMovementStore.recordMovement("sales_return", ...)`.
      - `restock === false` (`condition === "damaged"`): TWO calls — `"sales_return"` (reverses
        the original sale out of "supply") then `"destroyed"` (the units are gone). Net zero
        stock effect, matches today's behavior; the ledger gets the accurate two-step picture.
      Commit.
- [ ] 5. `InventoryStore.updateProduct()`'s stock-field edit path + its dialog (`EditProductDialog.qml`
      or wherever the stock field lives): add a required `kind` picker (the 7
      `manualAdjustmentKinds`) that only appears/is-required when the new value is LESS than the
      old value; defaults silently to `"adjustment"` for increases. `updateProduct` gains a `kind`
      parameter, calls `StockMovementStore.recordMovement(...)` alongside its existing
      `TransactionStore.recordStockAdjustment` call. Commit.
- [ ] 6. Manual review pass across all 5 wiring points (no Qt toolchain here to run anything) —
      re-read each call site once wired, confirm no double-booking, confirm sign conventions
      (qty negative for decreases) are consistent. Update checkpoint with final status. Commit.

## Explicitly out of scope this session
- The opening/closing-balance register report (P1's second deliverable per the spec).
- Any Cloud Function changes (none needed — `stock_movement` entity already registered).
- Deploying anything / flipping `Gateway.mode`.
