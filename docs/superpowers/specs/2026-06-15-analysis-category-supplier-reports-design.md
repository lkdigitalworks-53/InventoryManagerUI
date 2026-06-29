# Analysis page — category-wise & supplier-wise reports for every view

**Date:** 2026-06-15
**Status:** Approved design — ready for implementation planning
**Area:** `qml/pages/SalesPage.qml` (the "Analysis" page), `qml/components/`, `qml/model/InventoryStore.qml`, `qml/model/TransactionStore.qml`

## Problem

The Analysis page has six view modes — **Value, Purchased, Current, Revenue, Sold, Profit**. Two
vertical-bar breakdown charts (**by category** and **by supplier**) already exist on the page, but
they only render in the **Current** view. The user wants both breakdowns available in *every* view,
rendered with the **same vertical-bar charts already implemented**, and reflected in the xlsx export.

## Goals

- A **"by category"** and a **"by supplier"** vertical-bar chart on all six views.
- Charts reflect the **currently-selected period and active filters** (date / channel / staff /
  category / supplier), so they always agree with the hero headline number.
- The xlsx export for **Revenue / Sold / Purchased** gains matching "By category" and "By supplier"
  sections (Value and Profit already have them).
- Reuse the existing chart look exactly — no new chart visual language.
- Pay down the one piece of debt directly in the way: the bar-chart block is currently copy-pasted
  three times in a 2,393-line file. Extract it into one component.

## Non-goals

- No new chart types (no donut/pie, no horizontal bars).
- No change to the period pill, filter sheet, or existing aggregation semantics for Value / Profit /
  Current (those breakdowns are already correct — only their *visibility* changes).
- No refactor of unrelated parts of `SalesPage.qml`.

## Current state (verified in source)

`_rebuildBreakdown()` in `SalesPage.qml` fills two page properties used by the two breakdown cards:

- `_stockByCategory` and `_stockByParty` — **already populated** for Value, Profit (realised &
  potential) and Current; the cards are simply hidden (`visible: _viewMode === _MODE_CURRENT`) in
  every view except Current.
- **Revenue, Sold, Purchased** branches do **not** compute any category/supplier breakdown today.

Existing model aggregators that are reused as-is:

- `InventoryStore.valueByCategory()`, `valueBySupplier()`, `valueByProduct()` → `{key → number}`.
- `InventoryStore.realisedProfitByDimension(field)` and `potentialProfitByDimension(field)` →
  `{key → {revenue, cogs, profit, margin}}`, `field ∈ productId|supplierId|category|channel|staffId`.
- `TransactionStore.bucketsForFiltered(kind, periodIdx, predicate)` — period bucketing with a
  per-entry predicate.

Existing `SalesPage` helpers reused: `_topNFromMap`, `_namedSupplierMap`, `_profitTopN`,
`_dateWindow()`, `_passesCrossFilters(e)`, `_supplierIdForName(name)`, `_formatAxisValue`,
`_exportSectionFromMap`.

> Note on `/graphify`: the project's existing graph (`graphify-out/`) covers only the C++ /
> `functions/` layer (263 nodes, zero QML files), so it could not answer the QML data-layer
> question. This design was derived by reading the QML source directly.

## Architecture

### New component: `qml/components/BreakdownBarCard.qml`

Extract the triplicated vertical-bar block ("Stock by category", "Purchases by party", and the main
"Breakdown") into one reusable card. The card is presentation-only — it renders a model the page
computes; it holds no business logic.

Public API:

```qml
property string title: ""        // e.g. "Revenue by category"
property var    model: []        // [{ label, value, fullLabel }]
property bool   currency: false  // true → ₹ prefix on y-axis + value tips
property string emptyText: ""    // shown (centered) when model is empty
property var    barTop: Constants.brand3     // gradient start (top)
property var    barBottom: Constants.brand2  // gradient end (bottom)
property real   chartHeight: dp(180)
```

Responsibilities (carried over verbatim from the current inline blocks):

- Card chrome: `Constants.cardBg`, `Constants.radius`, 1px `Constants.borderColor`.
- Y-axis column with three labels — max / max÷2 / 0 — formatted with the same compact logic as
  `_formatAxisValue` (₹ prefix gated by `currency`).
- Bar `Repeater` over `model`: gradient bars (`barTop`→`barBottom`), `Math.max(dp(6), …)` min
  height, `Behavior on height { NumberAnimation { duration: Constants.durMed } }`, elided
  bottom labels.
- Optional per-bar value tip when the bar is tall enough (mirrors the existing Breakdown card).
- Centered `emptyText` when `model` is empty.

The card must follow the project button/tappable-alignment convention only where relevant; it has no
tappable controls, so this is not a concern here.

### `SalesPage.qml` changes

1. **Rename properties** so they stop implying stock-only data (they already carry category/supplier
   data for Value & Profit):
   - `_stockByCategory` → `_breakdownByCategory`
   - `_stockByParty`    → `_breakdownBySupplier`
   - Update every read/write site (the two chart cards and all `_rebuildBreakdown()` branches).
2. **Replace** the two inline chart cards (and, for consistency, the main "Breakdown" card if it
   maps cleanly) with `BreakdownBarCard` instances.
3. **Make both breakdown cards visible in all six views** (remove the
   `visible: _viewMode === _MODE_CURRENT` gate), each bound to:
   - `title:` a view-aware string from a new `_breakdownTitles()` helper.
   - `currency:` `root._isCurrency`.
   - `model:` `_breakdownByCategory` / `_breakdownBySupplier`.
   - `emptyText:` a view-appropriate message (esp. the supplier card for pre-FIFO sales).
4. **Populate the two properties in the Revenue / Sold / Purchased branches** of
   `_rebuildBreakdown()` via the new aggregator (below).

## Data flow & new aggregators

Every view ends `_rebuildBreakdown()` with `_breakdownByCategory` and `_breakdownBySupplier` set.
Value / Profit / Current already do this. Revenue / Sold / Purchased need new aggregation that —
per the approved decision — **honors the selected period and all active filters**, reusing the
page's existing `_dateWindow()` and `_passesCrossFilters(e)` predicates so the breakdown sums match
the hero `_periodTotal`.

### New helper: `_breakdownByDimension(metric, dim, ignorePeriod)`

- `metric ∈ "revenue" | "sold" | "purchased"`, `dim ∈ "category" | "supplier"`.
- `ignorePeriod` (optional, default `false`): when `false`, the walk applies the current period
  window in addition to the cross-filters (used by the on-screen charts, which track the period
  pill). When `true`, the period window is skipped and only the cross-filters (date/channel/staff/
  category/supplier) apply — used by the export, whose category/supplier sections are filter-scoped
  totals, not single-period (matching the existing Value/Profit export sections). This mirrors how
  `_binsFor` already produces period-specific results independent of the live `_period`.
- Returns a `{key → number}` map, then the caller runs it through `_topNFromMap` (and, for supplier
  IDs, `_namedSupplierMap`-style name resolution) to produce top-8 chart rows.

Per-metric logic (mirrors the period/total math already proven on the page):

- **Revenue** — iterate completed orders; gate each order by channel/staff (order-level) and
  date window; walk each line; category via `InventoryStore.getById(productId).category`; supplier
  via `line.consumption[].supplierId`; value = qty × unit price (FIFO-correct, same as the existing
  `revenueOf(o)`). When a supplier filter is active, only matching consumption rows contribute.
- **Sold** — walk `consumption[]` on `sale` entries that pass `_passesCrossFilters(e)`; accumulate
  `qtyConsumed` per category (product lookup) / per supplier (`consumption[].supplierId`). Mirrors
  `_consumptionBucketWalk`.
- **Purchased** — `purchase` + `created` events passing the date/category gate; supplier from
  `e.party` (or `e.snapshot`); category via product lookup. Mirrors the existing
  `purchasePredicate`. (Channel/staff don't exist on purchase events, so they pass through.)

### View-aware titles: `_breakdownTitles()`

Returns `{ category, supplier }` strings keyed off `_viewMode` (and `_profitMode`):

| View | Category title | Supplier title | Units |
|------|----------------|----------------|-------|
| Value | Value by category | Value by supplier | ₹ |
| Purchased | Purchased units by category | Purchased units by supplier | qty |
| Current | Stock by category | Purchases by party | qty |
| Revenue | Revenue by category | Revenue by supplier | ₹ |
| Sold | Units sold by category | Units sold by supplier | qty |
| Profit | Profit by category | Profit by supplier | ₹ |

### Reactivity

Unchanged. The existing `_ordersWatcher` / `_txWatcher` / `_invWatcher` / `_batchWatcher` /
`_supWatcher` and the period/view/filter `onChanged` handlers already retrigger
`_rebuildBreakdown()`; it will now additionally fill the two breakdown properties for the three new
views.

## Export

In `buildAnalysisExport()`, the Revenue / Sold / Purchased branch currently emits only four
period tables (Day/Week/Month/Year). Add two sections per export — **"By category"** and **"By
supplier"** — built from `_breakdownByDimension(metric, dim, /*ignorePeriod*/ true)` via the existing
`_exportSectionFromMap(heading, headers, map)`:

- Revenue → headers `[Category|Supplier, "Amount (₹)"]`.
- Sold / Purchased → headers `[Category|Supplier, "Units"]`.

Value and Profit exports already include these sections — leave them unchanged.

**Period scope of the export sections (explicit):** the on-screen charts show one selected period at
a time, but the Revenue/Sold/Purchased export already emits all four period tables (Day/Week/Month/
Year) in one workbook. The new "By category" / "By supplier" export sections are therefore **not**
single-period — they aggregate across the export's full scope (all-time, narrowed only by the active
date/channel/staff/category/supplier filters captured in `partyTag`), exactly the way the Value and
Profit export sections already aggregate. So: on-screen breakdowns track the period pill; the export
breakdowns are filter-scoped totals. This is intentional and consistent with the current export.

## Edge cases

- Uncategorised products → `"(uncategorised)"`.
- Missing supplier → `"Unknown"`; removed supplier → `"(removed)"` (existing conventions).
- Empty map → card shows `emptyText` instead of an empty axis.
- Pre-FIFO sales (no `consumption[]`) contribute to category (product lookup) but not to supplier;
  the supplier card shows `emptyText` ("No supplier data for this period") when the supplier map is
  empty — same friendly-placeholder pattern already on "Purchases by party".

## Testing

The charts are presentation-only; the logic worth testing is the aggregators.

- Add a Qt Quick Test (via the `qt-qml-test` skill) that loads small fixed fixtures into
  OrdersStore / TransactionStore / StockBatchStore / InventoryStore and asserts, for each metric
  (Revenue, Sold, Purchased) and each period, that the sum of `_breakdownByDimension(metric,
  "category")` equals the sum of `_breakdownByDimension(metric, "supplier")` equals the hero
  `_periodTotal` under the same period and filters.
- Spot-check a supplier-filtered Sold case where one sale draws partially from two suppliers (the
  attributed qty must land only under the matching supplier).

## Files touched

- **New:** `qml/components/BreakdownBarCard.qml`
- **Modified:** `qml/pages/SalesPage.qml` (rename two properties; replace inline chart blocks with
  the component; unhide both cards for all views; add `_breakdownByDimension` + `_breakdownTitles`;
  populate the two properties in the Revenue/Sold/Purchased branches; extend `buildAnalysisExport`).
- **Possibly modified:** `CMakeLists.txt` / qrc / qmldir if QML components are explicitly listed for
  packaging (verify the new file is picked up — recall the GLOB/CONFIGURE_DEPENDS Android packaging
  gotcha; confirm the components dir is globbed with `CONFIGURE_DEPENDS` or add the file explicitly).

## Build sequence

1. Create `BreakdownBarCard.qml`; swap the existing Current-view cards to use it (no behavior
   change — pure extraction). Verify Current view looks identical.
2. Rename `_stockByCategory`/`_stockByParty` → `_breakdownByCategory`/`_breakdownBySupplier`
   across all sites.
3. Add `_breakdownTitles()`; bind card titles; unhide both cards for all views. Verify Value /
   Profit / Current still correct (data already computed).
4. Add `_breakdownByDimension(metric, dim)`; populate the two properties in the Revenue / Sold /
   Purchased branches. Verify breakdown sums equal the hero total under each period/filter.
5. Extend `buildAnalysisExport()` with the two new sections for Revenue / Sold / Purchased.
6. Add the Qt Quick Test for the aggregators; confirm packaging picks up the new QML file.
