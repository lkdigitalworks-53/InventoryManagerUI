# Analysis report revenue / profit / tax / discount reconciliation

**Date:** 2026-06-18
**Status:** Approved design — ready for implementation planning
**Area:** new `qml/helper/OrderMath.js`, `qml/model/OrdersStore.qml`,
`qml/model/InventoryStore.qml`, `qml/model/TransactionStore.qml`,
`qml/helper/BreakdownMath.js`, `qml/pages/SalesPage.qml`,
`qml/pages/ConfirmReturnSheet.qml`, `qml/pages/OrderDetailDialog.qml`,
`qml/model/DataModel.qml`. No C++ change required (`src/XlsxService.cpp`
`writeAnalysis` already renders arbitrary sections/columns).

## Problem

Tax and discount are stored **only at the order level** (`o.tax`, `o.discount`,
`o.total`), while every analytics surface aggregates at the line / FIFO-consumption
level using gross `qty × price`. Two families of "revenue" exist and never
reconcile:

- **`o.total`-based** (subtotal − discount + tax): Dashboard KPIs,
  `SalesStore.totalRevenue`, and the **Revenue export period tables**.
- **Gross `qty × price`-based** (ignores discount and tax): the on-screen
  **Revenue hero**, the **Profit report revenue column**, and **every
  by-category / by-supplier breakdown**.

Whenever an order carries tax or discount, the two disagree by exactly
`(tax − discount)`. This is the user-reported "revenue numbers don't match the
profit report" and "tax and discount are not captured in the reports."

### Confirmed defects (this spec fixes all High items + returns/tax)

| # | Severity | Defect |
|---|----------|--------|
| 1 | High | On-screen Revenue (`revenueOf`, gross) ≠ exported Revenue (`_binsFor`, `o.total`) for the same view/period. |
| 2 | High | A single exported Revenue workbook is self-inconsistent: period tables use `o.total`; "By category"/"By supplier" use gross `qty × price` (`BreakdownMath._revenue`). The totals don't add up. |
| 3 | High | An order's **original** discount is dropped from all line-level analytics — only discount *edits during an adjustment* emit a delta. Orders placed with a discount overstate revenue and profit by the full discount. |
| 4 | High | Original order tax inflates the `o.total`-based export period revenue only; it is excluded from profit-report revenue and breakdowns. Collected tax (a pass-through liability) is being counted as income in one place and ignored elsewhere. |
| 5 | High | The supplier filter silently switches the revenue definition: unfiltered → `o.total` (net+tax); supplier-filtered → gross `qty × price`. Filtered vs unfiltered totals are incomparable. |
| 6 | Medium | The discount-adjustment `price_adjust` (productId `""`) is added to the category and period axes but **skipped on the supplier axis**, so after a discount edit the by-supplier total ≠ by-category total ≠ period total. |
| 7 | Medium | Adding units to a completed order after enabling product tax leaves the added units untaxed: re-opening seeds existing lines from stored tax flags, and the qty increase merges into that stale line. |
| 8 | Medium | Customer refund on returns excludes tax: `recordReturn` and the ConfirmReturnSheet preview use pre-tax `qty × price`, so a customer who paid price + tax is under-refunded. |

(Finding #9 — hardcoded "▲ from yesterday/last week" trend labels — is cosmetic
and out of scope for this spec.)

## Decisions (locked with the user)

1. **Revenue = net sales, tax excluded.** Revenue = `subtotal − discount`. Tax is
   tracked as a **separate** pass-through line, never counted as revenue.
   **Profit = net revenue − COGS.**
2. **Scope:** all High items (#1–#5) + #6 + returns/tax (#7, #8).
3. **Reports:** a top **Totals block** (Gross, Discount, Net Revenue, Tax
   Collected, COGS, Profit, Margin%) plus per-section **Discount / Tax / Net
   Revenue** columns. Every section reconciles to the Totals block.
4. **Historical data / migration: not a concern.** The app is in MVP stage; the
   user wipes and recreates Firestore data on each test cycle. So there is **no
   migration, no back-compat shim, and no need to preserve old report totals.**
   The design is free to stamp the new allocation fields onto events at write
   time as the primary path and treat read-time recompute purely as a
   convenience for the order-level revenue breakdowns (which read OrdersStore,
   not events).

## Goals

- One canonical revenue/profit/tax/discount definition used by Dashboard, the
  Analysis hero, the Profit report, and every export.
- Every aggregation axis (period, category, supplier, staff, channel, product)
  sums to the same order totals and to each other — penny-for-penny.
- Tax and discount are explicitly surfaced in reports and exports.
- Returns refund the customer what they actually paid (price + tax − discount
  share). Units added to a completed order after a tax change are taxed
  correctly.
- No C++/migration changes; recompute from stored data.

## Non-goals

- Changing how `computeOrderTotals` itself rounds or distributes discount
  (the new helper deliberately mirrors it so the two agree).
- Multi-currency, rounding-policy configuration, or tax-inclusive pricing modes.
- Trend-label direction fix (#9), Order/Products/Staff export sheets (unchanged),
  and the import path.

## Design

### 1. Canonical allocation helper — `qml/helper/OrderMath.js`

A pure, `.pragma library`, unit-testable module (no QML/singleton deps) that is
the single source of truth for splitting an order into net / tax / discount /
COGS, down to the FIFO consumption row. It mirrors the pro-rata logic already in
`OrdersStore.computeOrderTotals` so the sums agree by construction.

```
allocate(order) → {
  perLine: [ {
    productId, name, qty, price,
    gross,                  // qty × price
    discountShare,          // discount × (gross / subtotal)
    net,                    // gross − discountShare   ← "revenue"
    taxPercent, taxable,
    tax,                    // taxable ? net × taxPercent/100 : 0
    perConsumption: [ {     // one per consumption[] row; empty for pre-FIFO
      supplierId, batchId, qtyConsumed, unitCost,
      net,                  // line.net × (qtyConsumed / qty)
      tax,                  // line.tax × (qtyConsumed / qty)
      discountShare,        // line.discountShare × (qtyConsumed / qty)
      cogs,                 // qtyConsumed × unitCost
      profit                // net − cogs
    } ]
  } ],
  totals: { gross, discount, net, tax, cogs, total, itemCount }
}
```

Allocation rules (identical to `computeOrderTotals`):

- `subtotal = Σ gross`
- `discount`: percent → `subtotal × pct/100` (clamped 0–100%); flat → clamped
  `0 … subtotal`.
- `lineDiscountShare = subtotal > 0 ? discount × (lineGross / subtotal) : 0`
- `lineNet = lineGross − lineDiscountShare`
- `lineTax = (taxable && taxPercent > 0) ? lineNet × taxPercent/100 : 0`
- Per-consumption split is proportional to `qtyConsumed / qty`. When a line has
  no `consumption[]` (pre-FIFO), `perConsumption` is empty and callers that need
  supplier attribution fall back exactly as today (counted in category/period,
  surfaced under the "no supplier data" empty-state).

**Invariants (asserted by unit tests):**

- `Σ perLine.net = totals.net = subtotal − discount`
- `Σ perLine.tax = totals.tax = o.tax`
- `Σ (perLine.net + perLine.tax) = totals.total = o.total`
- `Σ perConsumption.net = perLine.net` (within rounding tolerance ≤ 1 paisa/line)
- `Σ perConsumption.cogs = line COGS`

A `roundingReconcile` step assigns any sub-paisa remainder from proportional
splits to the largest consumption row so the children always re-sum to the parent.

### 2. Wiring into the two ledgers

Two parallel ledgers drift today: **OrdersStore** (revenue breakdowns read it)
and **TransactionStore** sale/return/price_adjust events (profit report reads
it). Both resolve allocation from the same `OrderMath.allocate()`:

- **Primary path — stamp at write time.** `recordSaleFromOrder` and
  `recordReturn` run `allocate()` and **stamp** the allocated `net`, `tax`,
  `discountShare`, `cogs` onto each event (returns stamp the negative of the
  allocated portion for the returned qty). The profit/revenue aggregators read
  these stamped fields directly — no join. Since migration is a non-concern
  (MVP, data wiped each test cycle), this is the canonical source for events.
- **Order-level breakdowns** (the Revenue by-category/by-supplier cards and the
  export period tables, which read `OrdersStore.orders` rather than events) call
  `allocate(o)` at read time and sum `perLine.net` / `perConsumption.net`. These
  are recomputed on each rebuild anyway, so a read-time call is fine.
- Remove the misleading `unitCost = inv.price` stamp in `recordSaleFromOrder`
  (COGS is derived from `consumption[].unitCost`, so the field is dead and
  confusing).

#### Functions rewritten to consume net allocation

| Function | Change |
|----------|--------|
| `BreakdownMath._revenue` | Sum `perConsumption.net` (supplier dim) / `perLine.net` (category dim) instead of `qty × price`. Add optional `metric: "tax"` / `"discount"` for report columns. |
| `SalesPage.revenueOf` (`_rebuildBreakdown`) | Net via `allocate(o)`; supplier filter sums `perConsumption.net` for matching supplier. |
| `SalesPage._binsFor` (export) | Net via `allocate(o)`; drop the `o.total` branch so filtered and unfiltered use the **same** definition (fixes #1, #5). |
| `InventoryStore.realisedProfitByDimension` | Revenue = `perConsumption.net`; profit = `perConsumption.profit`. Discount/price `price_adjust` events still net in, and are now applied to the **supplier axis too** by attributing the discount-edit delta across the order's consumption rows pro-rata (fixes #6). Add `tax` and `discount` accumulators to each row. |
| `SalesPage._profitBucketWalk` | Profit per consumption row = `net − cogs` using the allocated net (so original discount reduces profit, fixing #3); price/discount `price_adjust` deltas unchanged. |
| `potentialProfitByDimension` | Unchanged definition (open-stock snapshot at selling price), but gains `tax`/`discount = 0` columns so its export shares the section schema. |

Because every axis now reads the same per-consumption fields produced by one
`allocate()`, all dimensions reconcile to the order and to each other (fixes
#1, #2, #5, #6).

### 3. Report & export restructuring (`SalesPage.buildAnalysisExport`)

C++ `writeAnalysis` already renders arbitrary `{ heading, headers, rows }`
sections, so only the QML payload builder changes.

Every Revenue / Profit workbook gains:

- **Totals block** (first section): rows for `Gross`, `Discount`,
  `Net Revenue`, `Tax Collected`, `COGS`, `Profit`, `Margin %`.
- **By-category / by-supplier / by-staff / by-channel** sections gain
  `Discount (₹)`, `Tax (₹)`, `Net Revenue (₹)` columns (Profit sections keep
  `COGS`, `Profit`, `Margin %`). Each section's Total row reconciles to the
  Totals block.
- A shared `_exportNetSection(heading, map)` / extended `_exportProfitSection`
  produce these consistently.

On-screen (`SalesPage` hero): the headline shows **Net Revenue**, with a subline
`incl. ₹X tax · ₹Y discount` (driven by new `_periodTax` / `_periodDiscount`
properties accumulated during `_rebuildBreakdown`).

`Dashboard._todayRevenue` / `_last7DaysRevenue` / `_yesterdayRevenue` and
`SalesStore.totalRevenue` switch from `o.total` to `allocate(o).totals.net` so
the Dashboard agrees with Analysis.

### 4. Returns & tax-on-edit (#7, #8)

- **#8 — refund includes tax.** `ConfirmReturnSheet._impact` and
  `DataModel._tryAdjustOrder`'s `refundAmount` compute the refund for returned
  units as their allocated `net + tax` (i.e. price-share − discount-share + tax),
  via `allocate()` on the pre-adjustment order. `recordReturn` stamps the
  negative allocated `net`/`tax`/`discountShare` for the returned qty so the
  reports unwind exactly what was booked.
- **#7 — tax on added units.** When a completed-order edit increases a line's
  qty, re-seed that line's `taxable`/`taxPercent` from the **current** product
  record before recompute, so all units on the line (original + added) are taxed
  on the current setting. `OrderDetailDialog.openFor` keeps seeding existing
  lines from stored flags for display, but `_save`/`recomputeSubtotal` refresh
  tax fields from inventory for any line whose qty grew. (UX detail — re-tax the
  whole line vs. split into a sub-line — finalized in the implementation plan;
  default is re-tax the whole line for simplicity.)

## Data flow (after)

```
order (stored: lines + discountType/Value + line taxable/taxPercent)
        │
        ▼
OrderMath.allocate(order)  ──►  perLine[] + perConsumption[] + totals
        │                               │
        ├── Dashboard / SalesStore ◄─────┤ totals.net
        ├── SalesPage hero        ◄──────┤ net + tax + discount sublines
        ├── BreakdownMath (cat/sup)◄─────┤ perLine.net / perConsumption.net
        ├── realisedProfitByDimension◄───┤ perConsumption.net/cogs/profit/tax/discount
        └── buildAnalysisExport   ◄──────┘ Totals block + per-section columns
```

## Testing

New `tests/` Qt Quick Test specs (the repo already runs `qmltestrunner`):

- **OrderMath unit tests** (pure JS via a tiny TestCase harness):
  - No discount, no tax → `net = gross`, `tax = 0`.
  - Flat discount, mixed taxable/non-taxable lines → invariants hold.
  - Percent discount > 100 / flat discount > subtotal → clamped.
  - Multi-supplier `consumption[]` → `Σ perConsumption.net = perLine.net`,
    COGS attributed per batch.
  - Pre-FIFO line (empty `consumption[]`) → category/period counted, supplier
    axis empty, totals still balance.
  - Rounding: 3-way split of an odd discount re-sums to the parent.
- **Reconciliation tests:** for a fixture set of orders (incl. discount + tax +
  a return + a price modify), assert period total == Σ category == Σ supplier ==
  Σ staff, and net + tax == Σ `o.total`.
- **Regression:** returns refund = net + tax for returned units; adding a unit to
  a completed order after enabling tax produces a taxed line.

## Rollout / risk

- **No migration / no back-compat.** MVP stage; the user wipes and recreates
  Firestore data each test cycle, so events written before this change don't
  need to be readable. Reversible by reverting code.
- Risk: rounding drift between `OrderMath.allocate` and the legacy
  `computeOrderTotals`. Mitigation: `allocate` reuses the exact same rounding
  order, and a test asserts `allocate(o).totals` equals
  `computeOrderTotals(o.products, o.discountType, o.discountValue)` for the
  fixture set.

## Open items for the implementation plan

- Exact column order / header wording for the restructured sections.
- #7 UX: re-tax whole line vs. split sub-line (default: whole line).
