# Completed-order detail must show tax on added units (mixed-vintage tax)

**Date:** 2026-06-26
**Status:** Approved
**Author:** debugging session (brainstorming)

## Problem

After a product's tax rate changes, increasing the quantity of that product on a
**completed** order books the added unit at the current rate in the immutable
sale ledger (correct — reports/hero/export show it), but the **order-detail
total shows no tax for it**. Order total (e.g. 40) disagrees with the ledger and
with what was actually collected (42).

### Root cause

An order line is a single `{quantity, taxable, taxPercent}` record — ONE tax
rate. After a mid-life tax change, a line's units span TWO vintages:
- **original units** — supplied at completion, booked at the **booked rate**
  (time-of-supply; immutable);
- **added units** — supplied at edit time, booked at the **current rate**
  (`DataModel._tryAdjustOrder:597-604`, their own sale event).

`OrdersStore.computeOrderTotals:237` taxes the whole line at its single stored
rate, so it cannot represent the split and drops one vintage's tax. The ledger
has no such problem — each unit batch is its own stamped event.

This is the mirror of the prior fix (commit 10b7e61): that stopped the total
OVER-taxing originals; this stops it UNDER-taxing added units. Same root: the
line is a lossy single-rate snapshot; the ledger is the truth.

## Solution (Approach A — order total follows the ledger; preview forecasts it)

Principle: **for a completed order, the order's tax/total is the immutable
ledger** (Σ stamped sale/return event tax). The live in-dialog preview, which
runs BEFORE the adjustment is booked, FORECASTS that ledger by splitting each
line into booked-original + current-added vintages. Both follow one rule, so
preview == saved total == ledger == reports.

### 1. New pure helper — `OrderMath.lineTax(line, opts)`

Vintage-split tax for one line. `opts` (optional): `{ originalQty, bookedRate }`.
- No opts → single-rate: `net(line) * (line.taxPercent/100)` when taxable
  (byte-identical to today; pending orders + all existing callers unaffected).
- With opts (completed-order line) → split the line's net pro-rata by quantity:
  `originalUnits` (min(originalQty, qty)) taxed at `bookedRate`; the remaining
  `addedUnits` taxed at the line's CURRENT `taxPercent`. Discount is distributed
  across the line's units first (per-unit net), so each vintage taxes its own net
  share — discount handled per vintage. Returns the summed line tax.

Pure, unit-tested. This is the single definition of the booked-vs-added rule.

### 2. New ledger aggregator — `TransactionStore.totalsForOrder(orderId)`

Returns `{ net, tax, total }` summed from STAMPED events for the order, matching
the report convention exactly:
- **tax** = Σ `e.tax` over `sale` + `return` (returns carry negative tax →
  netted). `price_adjust` has NO `tax` field → contributes 0 to tax (it is a
  revenue-only correction; verified in `recordPriceAdjust`).
- **net** = Σ `e.net` over `sale` + `return`  **+**  Σ `e.total` over
  `price_adjust` (the signed revenue delta of a price/discount edit MUST fold
  into net, else the order total drops a discount/price change).
- **total** = `net + tax`, rounded once.

Reuses the existing event-walk pattern (cf. `firstSaleEvent`). This is the
authoritative booked total for a completed order — the same fields reports sum,
so order == reports by construction.

### 3. Persisted total — `OrdersStore.applyAdjustment` (completed orders)

By the time `applyAdjustment` runs, `_tryAdjustOrder` has already booked the
added unit's sale event and any price/discount `price_adjust`s. So for a
**completed** order, source `o.tax`/`o.net`/`o.total` from
`TransactionStore.totalsForOrder(orderId)` instead of
`computeOrderTotals(newLines)`. Keep `subtotal`/`discount`/`taxBreakdown`/`items`
from `computeOrderTotals` (line-structure fields). Pending orders and `addOrder`
are unchanged — they still use `computeOrderTotals` end to end.

Rationale: do NOT re-derive the vintage split a second time inside the store —
that would be a third copy of tax logic that can drift from the ledger (the exact
bug class fixed repeatedly this session). One source of truth = the ledger.

### 4. Live preview — `OrderDetailDialog.recomputeSubtotal`

For a completed order, compute the previewed `_tax`/`_total` by summing
`OrderMath.lineTax(line, { originalQty, bookedRate })` per line, where
`originalQty`/`bookedRate` come from `_originalLines` (booked snapshot). Lines
with no booked original (genuinely new products) and pending orders pass no opts
→ current single rate. This forecasts exactly what `totalsForOrder` will report
after Save.

## Edge cases handled

- **Returns / qty down**: addedUnits = max(0, qty − originalQty) = 0 → whole line
  at booked rate. Correct (no new supply).
- **Genuinely new product on completed order**: no `_originalLines` entry →
  single current rate (it IS new supply).
- **Price modify on surviving units**: booked as a `price_adjust` (revenue-only,
  no tax field); the ledger total already reflects net deltas. Preview uses the
  line's current price for both vintages — minor preview-only nuance, reconciles
  to ledger on Save.
- **Pending orders**: untouched — single-rate throughout.

## Testing

`tst_CompletedOrderTaxTimeOfSupply` (extend) + `OrderMath` suite:
- `lineTax` no-opts == old single-rate formula (regression guard).
- `lineTax` split: original 1 @ 0% + added 1 @ 10% on a 20-each line → tax 2.
- with a line discount → each vintage taxes its discounted per-unit net.
- `totalsForOrder` sums stamped sale + return tax for an order (returns net it
  down); reconciles with the per-vintage preview for the same scenario.
- qty-down / new-product / pending → behave per edge cases above.
- Full order + analytics suites stay green.

## Out of scope

- No retroactive re-taxing of original units (time-of-supply preserved).
- `OrderAdjust.diffLines` tax-blindness (flagged earlier) — still not needed:
  the added unit IS detected (addedQty>0 books its event); this fix is about
  DISPLAYING the resulting ledger tax on the order. diffLines refactor remains a
  separate, deferred follow-up.
- No change to reports (already correct).
