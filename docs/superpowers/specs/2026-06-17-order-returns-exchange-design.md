# Order returns / exchange / cancellation after completion

**Date:** 2026-06-17
**Status:** Approved design — ready for implementation planning
**Area:** `qml/pages/OrderDetailDialog.qml`, `qml/Main.qml`, `qml/logic/Logic.qml`,
`qml/model/DataModel.qml`, `qml/model/OrdersStore.qml`, `qml/model/StockBatchStore.qml`,
`qml/model/TransactionStore.qml`, `qml/model/InventoryStore.qml`, new `qml/helper/OrderAdjust.js`

## Problem

Editing a **completed** order's line items currently rewrites `order.products` but never reverses
the FIFO stock consumption, never restores `product.stock`, and never amends the sale ledger. As a
result:

- Inventory is not restored when items are removed/reduced.
- The Analysis reports (Revenue / Sold / Profit), which read the sale + batch ledgers, stay stale.
- Reopening the order detail can show the previous values (the displayed order drifts from reality).

There is also a redundant double-dispatch: after the dialog saves via `logic.updateOrder(...)`, it
emits `orderUpdated`, which `Main.qml:665` handles by calling `logic.updateOrder(oid, {})` again — a
no-op-on-fields second write.

This is the practical retail returns/exchange/cancellation scenario. The fix is a proper feature:
capture *why* the order changed and write the correct, immutable ledger events so stock and reports
stay correct.

## Goals

- On a **completed** order, support partial per-line returns, exchanges, modifications, and
  cancellations, each writing the correct ledger events.
- Restore returned stock **cost-accurately** (to the original batches at the captured cost).
- Reflect every adjustment in the Analysis reports (Revenue / Sold / Profit) via immutable events.
- Capture a **reason** (Return / Exchange / Modify / Other+text) and a **condition**
  (Restock / Damaged) at save time, with a preview of the stock/revenue impact.
- Keep the order record matching reality (update lines/totals + an `adjustments[]` audit log) — which
  also fixes the "reopen shows previous values" symptom.
- Remove the redundant `Main.qml:665` double-dispatch.

## Non-goals

- No change to the pending/processing edit flow (no stock is booked until completion, so editing
  those orders needs no reversal — unchanged).
- No server-side enforcement / Firestore rules (client-side, consistent with the app's current model;
  the immutable-ledger *shape* here aligns with the P0 roadmap but P0 itself is separate).
- No refund-payment integration (the app excludes billing); "refund" here means the revenue-ledger
  reversal, not a payment gateway action.
- No customer-facing return receipts/RMA documents.

## Decisions captured during brainstorming

| Question | Decision |
|---|---|
| Reverse-FIFO cost basis | Restore to **original batches** at captured cost (via the line's stored `consumption[]`) |
| Sale-ledger model | Immutable **negative `return` event**, netted into existing sales sums |
| Reason behaviors | **Distinct per reason** (Return / Exchange / Modify / Other) |
| Returned-item condition | **Ask Restock vs Damaged**; Damaged = write-off, not re-stocked |
| Granularity | **Partial, per-line, any quantity** |
| Order record after | **Update order to current state + keep `adjustments[]` log** |
| Reason-capture UX | **Confirm-on-save sheet** (delta preview + reason + condition) |
| Permissions | **Owner / admin / manager only** (reuse the delete-order RBAC gate) |
| Architecture | **`_tryAdjustOrder` orchestrator in DataModel** (sibling to `_tryCompleteOrder`) |

## Architecture

Approach **A** — a `_tryAdjustOrder` orchestrator in `DataModel`, mirroring the existing,
working `_tryCompleteOrder`. Stores never orchestrate other stores; DataModel does. The risky pure
math (line diffing, per-batch restore computation) lives in a new headless-testable
`qml/helper/OrderAdjust.js`.

### Flow

```
OrderDetailDialog (completed order, lines changed)
  → tap "Save changes"
  → confirm-on-save sheet: reason + condition + computed delta preview
  → logic.adjustOrder(orderId, newLines, reason, condition, note)
  → DataModel.onAdjustOrder  (RBAC: owner/admin/manager)
  → _tryAdjustOrder(orderId, newLines, reason, condition, note)
       1. diff current vs new lines              → OrderAdjust.diffLines()
       2. per returned unit: restore-FIFO         → StockBatchStore.restoreFifo() (Restock)
                              or write-off         → StockBatchStore / movement (Damaged)
       3. restore/deduct product.stock            → InventoryStore
       4. append immutable negative/positive event→ TransactionStore.recordReturn() / sale
       5. update order lines+totals + adjustments[]→ OrdersStore.applyAdjustment()
  → _updateOrderInModel(orderId); logic.orderUpdated(orderId)
```

### New / changed surface

- **New** `qml/helper/OrderAdjust.js` (`.pragma library`, pure):
  - `diffLines(oldLines, newLines)` → `[{ productId, name, oldQty, newQty, returnedQty, addedQty,
    oldPrice, newPrice }]`. Drives every downstream effect.
  - `restorePlan(consumption, returnedQty)` → `[{ batchId, qty, unitCost }]` — walks a line's
    `consumption[]` (most-recently-consumed first) to compute how many units credit back to each
    original batch, for a partial return of `returnedQty`.
- **New** `StockBatchStore.restoreFifo(batchId, qty)` — credit `qtyRemaining` back on a specific
  batch (the inverse of `consumeFifo`). Batches are never deleted (only zeroed), so the original
  batch is always found by `getById`. Auditable via `Gateway.recordMutation`.
- **New** `TransactionStore.recordReturn(orderId, line, returnedQty, reversedConsumption, reason,
  condition, note)` — appends an immutable `kind:"return"` doc with **negative** `quantity` and
  `total`, carrying the reversed `consumption[]` so per-supplier/profit analytics net correctly.
- **New** `OrdersStore.applyAdjustment(orderId, newLines, adjustmentRecord)` — sets the order's lines
  to the post-adjustment state, recomputes totals (reusing `computeOrderTotals`), and pushes one
  entry to a new `order.adjustments[]` array. (Distinct from `updateOrder` so the normal edit path
  is untouched.)
- **New** `logic.adjustOrder(orderId, newLines, reason, condition, note)` signal +
  `DataModel.onAdjustOrder` handler + `_tryAdjustOrder`.
- **Changed** `OrderDetailDialog`: confirm-on-save sheet for completed orders; emits `adjustOrder`
  instead of `updateOrder` when the order is completed and lines changed.
- **Removed** `Main.qml:665` `onOrderUpdated: logic.updateOrder(oid, {})` redundant re-dispatch.
- **New field** `order.adjustments[]`: `[{ date, reason, condition, lineDeltas, refundAmount, note,
  actorUid }]`. Add to `OrdersStore._clone()` and the Firebase normalizer (default `[]`).

## Per-reason ledger semantics

The line diff produces per-line deltas; the **reason** interprets them. All events immutable; all
cost from the original `consumption[]` (captured cost), never current cost.

| Reason | Stock effect | Sale-ledger effect | Analysis impact |
|---|---|---|---|
| **Return** | Returned qty → original batches (Restock) **or** write-off (Damaged) | `recordReturn`: negative qty + total, reversed `consumption[]` | Sold ↓, Revenue ↓, Profit ↓ by reversed margin |
| **Exchange** | Removed line restored/written-off **and** replacement line deducted via `consumeFifo` | One `recordReturn` (negative) + one sale event (positive) for the replacement | Net of both |
| **Modify** | Delta only: reduction restores, increase deducts via `consumeFifo` | `recordReturn` for reductions / sale event for increases; `note:"modify"` | Nets corrected figures |
| **Other** | Same mechanics as Modify, driven by actual deltas | Same as Modify; free-text reason stored on the adjustment + event | Nets per deltas |

**Invariants:**
- **Cost basis** is always the line's stored `consumption[].unitCost` (captured at sale), so reversed
  COGS exactly matches what was booked.
- **Price-only change (Modify)**: a line whose *price* changes (not qty) records a revenue-only
  adjustment (`recordReturn` of `(oldPrice − newPrice) × qty`), no stock movement.
- **Damaged** returns write a `write_off` stock-movement (P1 taxonomy) instead of crediting batches —
  Revenue still drops (customer refunded), units do NOT re-enter sellable stock.
- **Exchange replacement** passes the same stock-availability check as a normal sale; the confirm
  sheet surfaces an out-of-stock error before committing.
- **Cancellation** = a Return of every line (full reversal); the order status may be set to
  `cancelled` after the reversal. (Handled by the same per-line return machinery with all lines
  returned.)

**Edge case — pre-FIFO lines (no `consumption[]`):** restore can't map to a batch; fall back to
`StockBatchStore.topUpOldest` (existing drift-repair) at the line's price-derived cost, and log it.
Rare, but handled rather than silently dropping stock.

## UI — confirm-on-save sheet

Editing a completed order's lines stays inline (qty steppers, remove) as today. On **Save changes**,
when the order is `completed` AND lines changed, a confirm sheet appears showing:

- Computed deltas in plain language ("Returning 2 × Widget A", "Adding 1 × Widget B").
- **Reason** dropdown: Return / Exchange / Modify / Other (Other reveals a free-text field).
- **Condition** toggle: Restock / Damaged — shown only when there's a returned/removed quantity.
- Live impact preview: "↩ +2 to stock · −₹200 revenue".
- Confirm → `logic.adjustOrder(...)`; Cancel → back to editing.

Pending/processing orders save exactly as today (no sheet — they route through the existing
`logic.updateOrder`). The sheet is gated to `completed` orders with actual line changes.

## The two existing bugs (in scope)

- **Double-dispatch:** remove `Main.qml:665` `onOrderUpdated: logic.updateOrder(oid, {})`. The dialog
  already persists via its own call; the empty re-dispatch is redundant and triggers an extra
  Firebase write.
- **"Reopen shows previous values":** fixed structurally — `_updateOrderInModel` refreshes the table
  and `OrderDetailDialog.openFor` reads the live `OrdersStore.getById`, which now matches the ledger
  because the order is updated to current state + `adjustments[]`. Verification step must confirm no
  stale `products` snapshot is cached in the dialog between open/save cycles (the dialog rebuilds its
  `products` ListModel in `openFor`, so re-opening re-reads the store — confirm on device).

## Permissions

`DataModel.onAdjustOrder` gates on `_hasAnyRole(["owner","admin","manager"])` (same pattern as
`onDeleteOrder`). Staff never reach an adjust path — they see only their own orders and have no
edit-to-completed access. If a staff call somehow arrives, it's rejected with
`logic.errorOccurred("auth", ...)`.

## Data flow into Analysis (why reports now update)

The Analysis layer sums `e.quantity` per matching `kind` and computes profit from
`qtyConsumed × (unitPrice − unitCost)` over `consumption[]`. A `recordReturn` event with negative
`quantity`/`total` and a reversed `consumption[]` (negative `qtyConsumed`, original `unitCost`) flows
through the **existing** sums:
- **Sold** (sums `quantity` of sale-kind) — include `return` kind in the Sold/Revenue bucketing so
  the negative qty nets down. (Bucketing change: treat `return` alongside `sale`, summing signed
  quantity/total.)
- **Revenue** — negative `total` reduces the bucket.
- **Profit** (`realisedProfitByDimension`) — include `return` entries; the reversed `consumption[]`
  with negative `qtyConsumed` reduces both revenue and COGS, netting the original margin back out.

**This requires two concrete code changes in the analysis layer** (verified against current code —
both currently reject returns):

1. **`TransactionStore.bucketsForFiltered`** sums `e.quantity` for the matched `kind`. To net
   returns, the Sold/Revenue callers must include `kind:"return"` in the matched set so its negative
   `quantity` subtracts. (Signed quantity already works once the kind is included.)
2. **`InventoryStore.realisedProfitByDimension`** currently has `if (e.kind !== "sale") continue`
   (line ~180) AND `if (qty <= 0) continue` (line ~192) — so it would skip return events *and* skip
   negative `qtyConsumed` even if the kind were allowed. Both guards must change: accept
   `kind === "sale" || kind === "return"`, and replace the `qty <= 0` skip with a `qty === 0` skip
   (or invert handling) so negative `qtyConsumed` from a return correctly subtracts revenue and COGS,
   netting the original margin back out.

Captured in the plan as an explicit task with tests. This is the one place where "treat return as a
signed sale" is NOT a free pass — the existing positive-only guards must be deliberately loosened.

## Edge cases

- **Increase a completed order's line** (Modify up): deduct the added qty via `consumeFifo` (a fresh
  positive sale event), same stock-availability check as completion. If insufficient stock, the
  confirm sheet blocks with the error.
- **Return more than was sold**: clamp returnedQty to the original line qty; the diff can never
  produce a return exceeding what the line held.
- **Order with no `consumption[]` (legacy/pre-FIFO)**: restore via `topUpOldest` fallback (above).
- **Damaged + Exchange combination**: the removed line is written off (not restocked) while the
  replacement deducts normally — both events recorded.
- **Reopen during a pending Firebase write**: the local in-memory order is authoritative for display;
  no re-fetch fires on dialog open (verified during debugging).

## Testing

- **Pure unit tests** (`qmltestrunner`, established pattern): new `tests/tst_OrderAdjust.qml` covering
  `OrderAdjust.diffLines` (partial reduction, full removal, addition, price change, no-op,
  multi-line) and `OrderAdjust.restorePlan` (partial return across a multi-batch `consumption[]`,
  full return, single-batch, pre-FIFO empty consumption → empty plan signalling fallback).
- **Manual device verification** for cross-store effects + the confirm-sheet UX: return 2 of 3 →
  Restock → confirm stock +2, Value/Sold/Revenue/Profit reports drop correctly, order detail reopens
  showing 1 (not 3), adjustments log shows the entry; repeat for Damaged (stock unchanged, revenue
  drops), Exchange (net), Modify price change (revenue only), full cancellation.

## Files touched

- **New:** `qml/helper/OrderAdjust.js`, `tests/tst_OrderAdjust.qml`
- **Modified:** `qml/model/StockBatchStore.qml` (`restoreFifo`),
  `qml/model/TransactionStore.qml` (`recordReturn`),
  `qml/model/OrdersStore.qml` (`applyAdjustment`, `adjustments[]` in `_clone` + normalizer),
  `qml/model/DataModel.qml` (`onAdjustOrder`, `_tryAdjustOrder`),
  `qml/logic/Logic.qml` (`adjustOrder` signal),
  `qml/pages/OrderDetailDialog.qml` (confirm-on-save sheet, emit `adjustOrder`),
  `qml/Main.qml` (wire `adjustOrder`; remove the `:665` double-dispatch),
  the Analysis layer (`TransactionStore.bucketsForFiltered` + `InventoryStore.realisedProfitByDimension`)
  to treat `kind:"return"` as a signed sale.

## Build sequence (for the plan)

1. `OrderAdjust.js` (`diffLines`, `restorePlan`) + `tst_OrderAdjust.qml` — pure, test-first.
2. `StockBatchStore.restoreFifo` + `TransactionStore.recordReturn` (the ledger primitives).
3. `OrdersStore.applyAdjustment` + `adjustments[]` field (clone + normalizer).
4. `DataModel._tryAdjustOrder` + `onAdjustOrder` + `Logic.adjustOrder` signal; RBAC gate.
5. Analysis layer: include `kind:"return"` as a signed sale in bucketing + profit walkers (+ tests).
6. `OrderDetailDialog` confirm-on-save sheet; emit `adjustOrder` for completed orders.
7. `Main.qml` wiring + remove the `:665` double-dispatch.
8. Full manual acceptance pass across all reasons/conditions + the reopen-detail check.
