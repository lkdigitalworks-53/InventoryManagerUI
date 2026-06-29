# Profit hero: delete the duplicate walker, route through the canonical path

**Date:** 2026-06-26
**Status:** Approved
**Author:** debugging session (audit → brainstorming)

## Problem

The realised-profit hero + chart use `SalesPage._profitBucketWalk`, a
hand-duplicated twin of `RealisedMath.bucketWalk("profit")`. It has drifted,
producing TWO confirmed reconciliation bugs (hero ≠ Σ by-dimension):

- **D-1** (`SalesPage.qml:1936`): under a supplier filter, `_profitBucketWalk`
  SKIPS every `price_adjust` (`if (!supplierId) ...; continue`) instead of
  attributing via stamped `supplierSlices`. Profit hero shows 0 where the
  by-dimension cards (already fixed in RealisedMath) show -7. This is the
  user-reported bug.
- **D-2** (`SalesPage.qml:972` vs `:979`): the hero sums `_profitBucketWalk`
  bins, which gate dates via `_passesCrossFilters` → `_dateWindow()` (raw date
  filter, NO period intersection). The by-dimension cards + `realisedTotals` use
  `_realisedScope(true)` = `intersect(period, date)`. Under a custom date filter
  the two windows differ, so hero ≠ Σ by-dimension, and the hero's own
  totalProfit (un-intersected) disagrees with its totalRevenue/COGS/markup
  (intersected).

Root cause of both: the duplicate walker. A contained one-line fix would patch
D-1 but leave D-2 and leave the duplicate free to drift again.

## Solution (Approach C — eliminate the duplicate)

Delete `_profitBucketWalk` and route both its callers through the canonical
`InventoryStore.realisedBucketWalk("profit", periodIdx, scope)` — the SAME
already-fixed RealisedMath path the Revenue hero uses. Revenue is the proven
reference (`realisedBucketWalk("net", _period, _realisedScope(true))`); Profit
becomes structurally identical with `metric="profit"`.

### Change 1 — on-screen hero (SalesPage `_rebuildBreakdown`, ~line 972)

Reorder so `realisedScope` is computed first, then:
```js
var realisedScope = _realisedScope(true)
bins = InventoryStore.realisedBucketWalk("profit", _period, realisedScope)
```
`realisedScope` already carries supplierId/channel/staff/category + the
period∩date window, so the bins now (a) attribute supplier-filtered price_adjust
via stamped slices (fixes D-1) and (b) use the same window as the by-dimension
cards and `realisedTotals(realisedScope)` (fixes D-2). `filterId` is no longer
used in this sub-branch (still used by the Potential sub-branch).

### Change 2 — profit export "By period" (buildAnalysisExport, ~line 1367)

```js
var periodBins = InventoryStore.realisedBucketWalk("profit", root._period, exportScope)
```
where `exportScope = _realisedScope(false)` (whole date window, period-bucketed).
Fixes D-1 in the export too and keeps the By-period section reconciling with the
Totals block. (Section still omitted under a custom date filter, unchanged.)

### Change 3 — delete `_profitBucketWalk` (SalesPage ~lines 1877-1949).

### Why this is safe / no regressions

- `RealisedMath.bucketWalk` emits IDENTICAL bucket labels (`"0h"`, `Mon..Sun`,
  `W1..W4`, single-letter months) — the on-screen chart and the export By-period
  labels are unchanged.
- `bucketWalk` supports `metric="profit"` (uses `OrderMath.eventProfit`, the same
  formula `_profitBucketWalk` used for sale/return).
- Replicates the exact Revenue-hero pattern, which the user confirmed works.

## Testing

Add a `RealisedMath.bucketWalk("profit", …)` reconciliation case (extend
`tst_PriceAdjustSupplierStamp` or `tst_RealisedMath`):
- supplier filter + the two SUP-001 adjusts → profit bins sum to -7
  (== `totals.profit`), proving hero == Σ bucketWalk under the filter (D-1).
- a period ∩ custom-date window → bucketWalk sum == `totals` over the same
  intersected scope (D-2).
- different supplier → 0.

Full math suite must stay green.

## Out of scope

- I-1 (deleted-product category filter excludes events in RealisedMath but maps
  to "(uncategorised)" in BreakdownMath) — pre-existing, low severity, fresh-data
  MVP; flagged separately, not fixed here.
- No change to the no-filter path or to write-time stamping.
