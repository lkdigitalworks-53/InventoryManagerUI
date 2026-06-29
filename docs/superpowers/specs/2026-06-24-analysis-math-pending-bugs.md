# Analysis / Reporting — Pending Math Bugs & Test-Coverage Audit

**Date:** 2026-06-24
**Branch:** `fix/import-export-analytics-discount`
**Status:** ✅ **ALL RESOLVED 2026-06-25** — A–E and SITE 4–7 fixed. See
`docs/superpowers/specs/2026-06-25-analysis-math-pending-bugs-design.md` for the fix design.
Realised money aggregation was consolidated onto the immutable event log in a new pure
`qml/helper/RealisedMath.js` (the doc's Recommendation #3 extraction), unlocking real headless
tests (`tests/tst_RealisedMath.qml`). Suite: **140 passing, 0 failing across 14 suites.** The
per-finding status below is annotated inline.

This document lists every KNOWN-but-UNFIXED calculation bug found during the analysis-export
debugging sessions, plus a test/regression-coverage audit of every finding (fixed and pending).

The findings come from two audit families:

- **A–E** — the broad "audit every calculation" pass (2026-06-23): genuine current-code bugs in the
  value/profit aggregators and import.
- **SITE 1–7** — the "live-state derivation" architectural audit (2026-06-24): sites that re-derive a
  historical event's values from the **mutable live order** instead of from immutable stamped event
  fields. SITES 2 & 3 are FIXED (commit `6ae0e7c`); SITE 1 was investigated and is NOT a bug.

---

## Part 1 — Pending bugs (NOT yet fixed)

Severity legend: **Critical** = wrong money in a headline figure · **High** = wrong/contradictory
numbers users will notice · **Medium** = wrong only under a specific filter/edge · **Low** = cosmetic
or non-money / latent.

### A. Realised-profit by-dimension sections ignore active filters
- **Status:** ✅ FIXED — `realisedProfitByDimension(field, opts)` now takes a filter scope;
  `SalesPage._realisedScope()` passes the active filters from both the on-screen rebuild and the
  export builder. Test: `tst_RealisedMath::test_scope_filter_applies_to_bydimension`.
- **Severity:** High
- **Where:** `qml/model/InventoryStore.qml:175` (`realisedProfitByDimension(field)` — takes no filter
  args; iterates ALL `TransactionStore.entries`). Consumed filter-blind at
  `qml/pages/SalesPage.qml:1003, 1015–1022` (on-screen Realised view) and `:1500–1509` (export sections).
- **Symptom:** Under any active filter (date / channel / staff / category / supplier), the Realised
  hero + Totals + "By period" honour the filter, but the **By-product / supplier / category / channel /
  staff** sections do NOT → hero ≠ Σ(by-category), and the hero's own Markup% mixes a filtered profit
  with unfiltered revenue/COGS. Same defect on screen and in export.
- **Root cause:** `realisedProfitByDimension` has no notion of the active filter scope; it always sums
  the whole ledger.
- **Fix direction:** give `realisedProfitByDimension` an options arg (window / channel / staffId /
  category / supplierId) mirroring `_passesCrossFilters`, and pass the active scope from both the
  on-screen rebuild and the export builder. OR build the per-dimension maps from the same filtered
  event walk `_profitBucketWalk` already uses.

### B. Realised "By period" export can't represent a custom date window
- **Status:** ✅ FIXED — the By-period section is now omitted from the export when a custom date
  filter is active (the Totals + by-dimension sections carry the filtered breakdown). Manual-only.
- **Severity:** Medium
- **Where:** `qml/pages/SalesPage.qml:1487` (`_profitBucketWalk(root._period, "")` in the export builder).
- **Symptom:** The Realised export emits a single period table keyed to the on-screen `_period`, with
  buckets anchored to *now* (today / this week / this month / this year). Under a custom/back-dated date
  filter, the "By period" Total sums only events in the current calendar period ∩ the filter window
  (often near-zero), disagreeing with the date-filtered Totals block.
- **Fix direction:** when a date filter is active, compute buckets relative to the filter window, or
  omit the By-period section under custom date ranges.

### C. Multi-batch FIFO rounding in `realisedProfitByDimension`
- **Status:** ✅ FIXED — `RealisedMath.byDimension` assigns the rounding remainder to the largest
  consumption row (remainder-to-largest, like `OrderMath.allocate`). Test:
  `tst_RealisedMath::test_multibatch_rounding_reconciles`.
- **Severity:** Low (≤ ₹0.01; does NOT fire on single-batch lines — the common case)
- **Where:** `qml/model/InventoryStore.qml` consumption-scaling loop (the `frac = qty/lineQty;
  revenue = evNet * frac` block, ~line 285).
- **Symptom:** When ONE sale line is filled from ≥2 FIFO batches and its net doesn't divide evenly, the
  stamped net is split by raw `frac` with **no remainder-to-largest-row reconciliation** (unlike
  `OrderMath.allocate`, which assigns the rounding remainder to the largest consumption row). The
  supplier axis can drift ±0.01 from the category/hero total.
- **Fix direction:** reuse `OrderMath.allocate(parent).perLine[i].perConsumption[j].net` (already
  remainder-reconciled) instead of re-deriving `evNet*frac`; or replicate the remainder-to-largest logic.

### D. Supplier-slice Gross reconstructed as `net + discountShare`
- **Status:** ✅ FIXED — `_exportTotalsBlock` now sources from `RealisedMath.totals`, which computes
  `gross = round2(net + discount)` once. Test: `tst_RealisedMath::test_supplier_filtered_gross`.
- **Severity:** Low (≤ ₹0.01, Gross column only)
- **Where:** `qml/pages/SalesPage.qml:2039` (`_exportTotalsBlock` supplier-filter branch:
  `gross += (pc[ci].net + pc[ci].discountShare)`).
- **Symptom:** `perConsumption.net` and `.discountShare` are independently `_round2`'d in
  `OrderMath.allocate`; reconstructing gross as their sum can land ±0.01 off the true per-row gross.
  Affects only the Gross column under an active supplier filter (net/tax/cogs/profit are taken from
  stamped fields and are self-consistent).
- **Fix direction:** carry an explicit rounded `gross` on each `perConsumption` row in `allocate` and
  sum that.

### E. SKU rename suffix is string-concatenated (operator precedence)
- **Status:** ✅ FIXED — extracted to `ImportMath.renameSku(sku, addedCount)` =
  `sku + "-" + (addedCount + 1)`; `InventoryStore.upsertMany` calls it. Test: `tst_ImportMath`.
- **Severity:** Low (not money — wrong generated identifier)
- **Where:** `qml/model/InventoryStore.qml:534` — `r.sku = r.sku + "-" + counts.added + 1`.
- **Symptom:** `+` is left-associative, so this is `(sku + "-" + counts.added) + 1` → e.g. `counts.added=0`
  yields `"ABC-" + 0 + 1` = `"ABC-01"`, not the intended `"ABC-1"`. Every renamed SKU on import gets a
  trailing `1` glued to the counter.
- **Fix direction:** `r.sku = r.sku + "-" + (counts.added + 1)`.

### SITE 4. `realisedProfitByDimension` net fallback re-allocates the live order
- **Status:** ✅ FIXED — `RealisedMath.byDimension` reads stamped `e.net/tax/discount` only; a missing
  `net` contributes 0 (fail-closed) and never re-allocates the live order. Test:
  `tst_RealisedMath::test_no_net_fails_closed`.
- **Severity:** High (but LATENT — dormant under the MVP fresh-data invariant where every event carries
  a stamped `net`)
- **Where:** `qml/model/InventoryStore.qml:286` (`var a = OrderMath.allocate(parent)` inside the
  `evNet === null` fallback).
- **Symptom:** For any sale/return event missing a stamped `net` (legacy / un-migrated), it re-derives
  net/tax/discount by allocating the CURRENT order — which may be post-return-mutation → wrong. Today
  all events stamp `net`, so this branch doesn't execute; it's a latent instance of the prohibited
  "derive history from mutable live state" pattern.
- **Fix direction:** read stamped `e.net/e.tax/e.discountShare` only; make the fallback fail-closed
  (0) rather than re-deriving from the live order. Safe given the fresh-data invariant.

### SITE 5. Revenue hero / Totals block / by-dimension sections aggregate LIVE orders, not events
- **Status:** ✅ FIXED — the Revenue hero, period bins (`realisedBucketWalk`), `_exportTotalsBlock`
  (`realisedTotals`), and `_breakdownByDimension`'s revenue/tax/discount metrics now all aggregate the
  immutable event log via `RealisedMath`. Revenue-view and Profit-view reconcile; export Totals ==
  Σ(by-dimension). Tests: `tst_RealisedMath::test_revenue_and_profit_reconcile_one_source`,
  `test_sale_plus_return_nets_down`.
- **Severity:** High (the most architecturally significant remaining item)
- **Where:** `qml/pages/SalesPage.qml` — `_exportTotalsBlock` (`:2003`, allocate at `:2020`),
  `revenueOf`/Revenue hero (allocate at `:1229`), `_binsFor` revenue (allocate at `:1732`),
  `_breakdownByDimension` (`:1372`, passes `OrderMath.allocate` into BreakdownMath).
- **Symptom:** The Revenue view + export Totals compute by **allocating live completed orders**, while
  the Profit view sums **immutable sale/return/price_adjust events**. On any ADJUSTED/returned order the
  two sources diverge: a returned unit vanishes from `o.products` (so Revenue/Totals act as if it was
  never sold), but the event ledger still has the sale + return rows. → Revenue-view vs Profit-view
  disagree, and export-Totals vs event-based sections disagree, on every adjusted order.
- **Root cause:** two different aggregation SOURCES for the same money (live orders vs event log).
- **Fix direction (bounded refactor):** migrate the Revenue hero, `_exportTotalsBlock`, and
  `_breakdownByDimension` to aggregate the immutable event log (the `realisedProfitByDimension` /
  `eventProfit` path) so every surface reconciles to one source of truth. Larger than A–E; touches
  SalesPage's Revenue/export builders and possibly BreakdownMath.

### SITE 6. `_tryAdjustOrder` refund per-unit from live allocation
- **Status:** ✅ FIXED — refund now uses `OrderMath.refundPerUnit(TransactionStore.firstSaleEvent(...))`
  — the original sale event's stamped `(net+tax)/qty` — so a 2nd adjustment refunds at the
  original-sale rate, not adjustment #1's discounted rate. Falls back to the live allocation only for
  pre-event legacy orders. Test: `tst_OrderMath::test_refund_per_unit_from_original_sale_event`.
- **Severity:** Medium (customer-facing refund figure, not a ledger field)
- **Where:** `qml/model/DataModel.qml:567` (`perUnit = (pl2.net + pl2.tax) / pl2.qty` from
  `OrderMath.allocate(o)`).
- **Symptom:** Correct for a FIRST adjustment (allocate runs pre-mutation), but on a SECOND adjustment
  the live order reflects adjustment #1's discount, so the refund per-unit uses the wrong (current,
  not original-sale) discount rate.
- **Fix direction:** compute the refund from the original sale event's stamped per-unit net+tax for the
  returned units.

### SITE 7. `_consumptionBucketWalk` revenue/margin use gross `unitPrice`, not stamped net
- **Status:** ✅ FIXED — the revenue/margin branches now distribute stamped `e.net` by
  `qtyConsumed/lineQty` (discounted net), not `qtyConsumed * unitPrice`. Still dormant (only `qty` is
  wired), but correct when surfaced. Net-distribution covered by
  `tst_RealisedMath::test_revenue_and_profit_reconcile_one_source`.
- **Severity:** Medium (LATENT — only `field === "qty"` is wired today; the revenue/margin branches are
  dormant)
- **Where:** `qml/pages/SalesPage.qml:2408, 2411` (`bins[idx] += qtyConsumed * e.unitPrice` and the
  margin branch using `e.unitPrice - unitCost`).
- **Symptom:** If the revenue/margin fields are ever used, they'd report revenue GROSS of line discount
  (uses `unitPrice`, not the discounted stamped `net`), diverging from the net-revenue convention used
  everywhere else.
- **Fix direction:** distribute stamped `e.net` by `qtyConsumed/lineQty` (as `eventProfit` does), not
  `qtyConsumed * unitPrice`.

### SITE 1 — investigated, NOT a bug (recorded so it isn't re-opened)
`TransactionStore.recordReturn` stamps the return's net/tax/discount by allocating the LIVE order at
return time. This was suspected but **proven correct**: the live net already incorporates prior edits,
so reversing it nets the ledger to zero exactly. Reversing the *original sale* instead would CREATE a
residue. Leave as-is.

---

## Part 2 — Test / regression coverage audit

Headless suite location: `tests/tst_*.qml` (run with `qmltestrunner -platform offscreen`).
**Current total: 110 passing, 0 failing across 10 suites.**

> Coverage limitation that applies to the whole suite: page-level QML (`SalesPage`, dialogs) and the
> C++ `XlsxService` CANNOT load under `qmltestrunner` (need the full Felgo `App` context / a Qt build).
> So all "tests" are at the **pure-JS-library / store-logic** level — they mirror the production formula
> faithfully but do NOT exercise the real `SalesPage` export builders or the real C++ writer. Page-level
> and export-column correctness is verified by **manual on-device export + decode**, not automated tests.

### 2a. FIXED findings — coverage status

| Fix | Commit | Regression test | Status |
|---|---|---|---|
| Per-line discount in `OrderMath.allocate` | `b7a843f` | `tst_OrderMath`: `test_flat_per_line_discount`, `test_percent_per_line_discount`, `test_tax_on_net_excluded_from_revenue`, `test_reconciliation`, `test_flat_discount_clamped_to_line_gross` | ✅ Covered |
| `computeOrderTotals` ↔ allocate rounding parity | `0e8ac4f` | `tst_OrderMath`: `test_total_equals_net_plus_tax`, `test_totals_block_aggregation` (allocate side). **`computeOrderTotals` itself is NOT headless-testable** (OrdersStore needs app context). | ⚠️ Partial — allocate side only; parity asserted by reasoning, not a direct cross-check test |
| X2: adjust loses discount on added units | `218e4b9` | `tst_AdjustDiscountRepro`: `test_added_units_plus_discount_loses_fraction` | ✅ Covered (formula mirror) |
| X1: `_namedXMap` helpers drop discount/tax | `218e4b9` | — | ❌ **No test** — the `_namedSupplierMap/_namedStaffMap/_namedProductMap` helpers live in `SalesPage.qml` (not headless-loadable). Verified only by manual export decode. |
| Realised discount column omits discount-edit deltas | `b920c10` | `tst_RealisedDiscountColumn`: `test_discount_edit_reflected_in_discount_column`, `test_price_modify_not_counted_as_discount` | ✅ Covered (formula mirror of the price_adjust branch) |
| Realised reconciliation (Rida 67 / 178) | (audit) | `tst_RealisedProfitRepro`: `test_all_paths_reconcile`, `test_rida_realised_reconciles_to_67` | ✅ Covered (formula mirror) |
| SITES 2/3: stamp supplier split on price_adjust | `6ae0e7c` | `tst_PriceAdjustSupplierStamp`: `test_without_stamp_dumps_to_unknown_after_return`, `test_with_stamp_attributes_to_real_supplier_after_return` | ✅ Covered (proves stamp survives a full return; uses real `OrderMath.spreadLineDeltaBySupplier`) |

**Coverage gaps among FIXED items:**
- **X1 (`_namedXMap` discount/tax drop): NOW COVERED.** The merge was extracted to
  `RealisedMath.nameMerge`; the three `_namedXMap` helpers are thin shims over it. Test:
  `tst_RealisedMath::test_name_merge`.
- **`computeOrderTotals` parity: only indirectly tested.** The allocate side is covered; the
  OrdersStore implementation that must match it is not headless-loadable. A divergence would slip
  through automated tests.
- The `tst_AdjustDiscountRepro` / `tst_RealisedProfitRepro` / `tst_RealisedDiscountColumn` /
  `tst_PriceAdjustSupplierStamp` suites are **formula MIRRORS** — they re-implement the production
  logic in the test and assert the math. They guard the *algorithm*, but would NOT catch a regression
  where the production call site stops invoking that algorithm (e.g. someone changes
  `realisedProfitByDimension` to not read `supplierSlices`). True integration coverage needs the app.

### 2b. Findings — coverage status (✅ ALL FIXED & COVERED 2026-06-25)

These are now **real** tests over the extracted pure libs (not formula mirrors): the production code
under test IS the library the test imports.

| Finding | Test | Status |
|---|---|---|
| A. Realised sections ignore filters | `tst_RealisedMath::test_scope_filter_applies_to_bydimension` + reconciliation cases | ✅ Covered |
| B. By-period export under custom date window | (omit-section behaviour) | ✅ Fixed — manual-only (page-level) |
| C. Multi-batch FIFO rounding | `tst_RealisedMath::test_multibatch_rounding_reconciles` | ✅ Covered |
| D. Supplier-slice gross ±0.01 | `tst_RealisedMath::test_supplier_filtered_gross` | ✅ Covered |
| E. SKU rename concat | `tst_ImportMath` (3 cases) | ✅ Covered (real — `ImportMath.renameSku` extracted) |
| SITE 4. Net fallback re-allocate | `tst_RealisedMath::test_no_net_fails_closed` | ✅ Covered |
| SITE 5. Revenue/Totals source vs events | `tst_RealisedMath::test_revenue_and_profit_reconcile_one_source`, `test_sale_plus_return_nets_down` | ✅ Covered |
| SITE 6. Refund per-unit on 2nd adjust | `tst_OrderMath::test_refund_per_unit_from_original_sale_event` | ✅ Covered |
| SITE 7. consumptionBucketWalk gross | `tst_RealisedMath` net-distribution (bucketWalk) | ✅ Fixed + net path covered (branch still dormant) |

---

## Part 3 — Recommendations

1. **Highest value next fix:** **A** (filter-blind realised sections) and **SITE 5** (Revenue/Totals
   source) — these are the two that make on-screen numbers visibly contradict each other under normal
   use (filters, adjusted orders). They share a theme: consolidate all money aggregation onto the
   immutable event log with a single filter-scope parameter.
2. **Quick wins:** **E** (one-line precedence fix) and **C/D** (±0.01 rounding) are small and isolated.
3. **Test-infrastructure improvement:** the biggest coverage gap is that `SalesPage`'s export/aggregation
   math isn't headless-testable. Extracting the pure aggregation math (the `_namedXMap` merges,
   `_exportTotalsBlock` summation, the realised filter walk) into a `.pragma library` JS helper (like
   `BreakdownMath.js` / `OrderMath.js`) would let real regression tests cover X1, A, D, and SITE 5 —
   instead of formula mirrors that can drift from the call sites.
4. **Integration-test caveat:** even with extraction, the C++ `XlsxService` column writing and the real
   `SalesPage` wiring remain manual-decode-only. Keep the "export → unzip → decode → reconcile" manual
   procedure (used throughout this debugging) as the acceptance check for any analysis change.
