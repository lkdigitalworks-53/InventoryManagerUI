# Completed-order detail: show the forecast tax row for added units

**Date:** 2026-06-26
**Status:** Approved
**Author:** debugging session (brainstorming)

## Problem

After a product's tax rate changes, increasing its qty on a completed order shows
**no tax** in the order-detail totals strip (screenshot: Subtotal 40, Discount 2,
Total 38 — no Tax row), even though the added unit will be booked at the current
rate and the reports show it. The prior mixed-vintage fix (commit 48af63c) made
the *persisted* total + ledger correct but left the *live preview* broken.

### Root cause (reproduced headlessly)

Two gaps in the PREVIEW path (`OrderDetailDialog`), both because a line stores a
single tax rate while a mixed-vintage line needs two:

1. **No current rate available to the split.** The prior "keep booked tax" fix
   seeds a re-added completed-order line with the BOOKED rate (0%). `recomputeSubtotal`
   then calls `OrderMath.lineTax(line, {originalQty, bookedRate})`, and `lineTax`
   reads the line's CURRENT `taxPercent` for the added units — which is also 0.
   So added units forecast 0 tax. The product's current rate is never consulted.

2. **No tax breakdown row.** The Tax row (`OrderDetailDialog.qml:777`) is a
   Repeater over `_taxBreakdown`, built by `computeOrderTotals` (single booked
   rate → empty). The prior fix set `_tax`/`_total` numbers but never populated
   `_taxBreakdown`, so no Tax row renders and `_total` collapsed to
   subtotal − discount = 38.

Persisted total + ledger (`TransactionStore.totalsForOrder`,
`OrdersStore.applyAdjustment`) are already correct — this is preview-only.

## Solution (preview-only; one combined Tax row)

### Change 1 — `OrderMath.lineTax` takes an explicit current rate

Add `currentRate` to `opts`: `{ originalQty, bookedRate, currentRate }`.
- Added units are taxed at `currentRate` (when provided) instead of reading
  `line.taxPercent`. Default when `currentRate` is undefined → `line.taxable ?
  line.taxPercent : 0` (so every existing caller and the no-opts single-rate path
  are byte-identical).
- Originals still taxed at `bookedRate`. Discount still distributed per-unit.

This lets the caller control BOTH vintages explicitly: the line keeps its booked
rate (persisted semantics unchanged) while the preview overlays the product's
current rate for added units.

### Change 2 — `OrderDetailDialog.recomputeSubtotal` builds the preview tax + row

For a COMPLETED order:
- Resolve each line's CURRENT rate from inventory:
  `inv = InventoryStore.getById(productId) || findByName(name)`;
  `currentRate = inv && inv.taxable ? (inv.taxPercent||0) : 0`.
- `bookedRate`/`originalQty` from `_findOriginalLine` (the booked snapshot); a
  line with no booked original (genuinely new product) → `originalQty 0`, so all
  its units use `currentRate`.
- Sum `OrderMath.lineTax(line, {originalQty, bookedRate, currentRate})` → forecast
  tax; round once.
- Set `_tax = forecastTax`, `_total = subtotal − discount + forecastTax`, and
  `_taxBreakdown = forecastTax > 0 ? [{ rate: <combined>, amount: forecastTax }] : []`.
  Per the chosen "one combined tax line", the row shows a single Tax figure. The
  `rate` label is cosmetic — use the dominant added-units `currentRate` (the rate
  the user just applied) so the row reads "Tax (10%)"; when forecastTax is 0 the
  row stays hidden.

Pending orders: unchanged — keep `computeOrderTotals`'s single-rate `_tax`/
`_taxBreakdown`/`_total`.

### Reconciliation

The preview forecast equals what `totalsForOrder` books on Save (both: originals
at booked rate, added at current rate, discount per-unit), so the on-screen total
before Save matches the persisted total and the reports after Save.

## Testing

- `tst_OrderMath`: `lineTax` with explicit `currentRate` — added units taxed at
  `currentRate` not `line.taxPercent`; `currentRate` undefined falls back to the
  line (regression guard for existing callers).
- `tst_CompletedOrderTaxTimeOfSupply`: preview scenario — booked 0% line, current
  10%, qty 1→2, flat discount 2 → forecast tax ≈ 1.9, total ≈ 39.9; breakdown has
  one row; reconciles with the `totalsForOrder` mirror for the same events.
- New product on completed order (no booked line) → all units at current rate.
- Full suite green.

## Out of scope

- Per-rate tax rows (user chose one combined line).
- Persisted/ledger path (already correct).
- `OrderAdjust.diffLines` tax-blindness (still a deferred follow-up; not needed —
  addedQty is detected on Save; this is purely the live display).
