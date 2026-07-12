# Analysis page — by-product-name chart on every view, reordered to name → supplier → category

## Problem

All six Analysis reports (Value, Purchased, Current, Revenue, Sold, Profit) already show
always-visible by-category and by-supplier bar charts. A third chart card exists on every view
too, but it's overloaded — its content and meaning silently change per view (top-N-by-name for
Value/Profit→Potential, a period-bucketed trend for Sold/Purchased/Revenue/Profit→Realised, a
3-bar stock-health count for Current). There is no dedicated, consistently-labelled "by product
name" chart on every view, and no fixed chart ordering.

## Goals

- Every one of the six reports mandatorily shows a "by product name" bar chart.
- Fixed card order on every view: **by name → by supplier → by category**.
- Reuse `_topByName` (and its existing per-mode computation) wherever it's already correct;
  add new aggregation only where genuinely missing.
- Keep the existing third card (trend / stock-health) wherever it isn't a duplicate of the new
  by-name card.
- Keep the Cloud Functions `breakdownMath.js` mirror in parity with any `BreakdownMath.js` change.

## Non-goals

- No changes to xlsx export sections (`buildAnalysisExport`) — by-name export is a separate
  future decision, not requested this session.
- No changes to "Recent purchases", "Recent sales", "Top items" — left exactly as-is.
- No Cloud Functions deployment — the mirror stays in parity but remains undeployed.
- No renaming of the existing `_topByName` property, despite the naming inconsistency with its
  siblings `_breakdownByCategory` / `_breakdownBySupplier` (see Edge cases) — flagged, not fixed,
  per the smallest-diff preference for anything not explicitly requested.

## Current state (verified in source, `qml/pages/SalesPage.qml`, 2318 lines)

Only 3 `BreakdownBarCard` instances exist today (lines 663, 676, 696):

1. By-category — always visible, all 6 modes. Title from `_breakdownTitles().category`.
2. By-supplier — always visible (gated by `canViewSuppliers`), all 6 modes. Title from
   `_breakdownTitles().supplier`.
3. "Breakdown" / "Stock health" (`_MODE_CURRENT` only) — bound to `_breakdown`, whose meaning
   flips per mode:

   | Mode | What `_breakdown` currently holds | Is it already "by name"? |
   |---|---|---|
   | Value | top-8 products by value (`topRows`) | Yes |
   | Profit → Potential | top-8 products by profit (`topRowsP`) | Yes |
   | Profit → Realised | period-bucketed profit trend (`bins`) | No |
   | Current | 3-bar stock health (in stock / low / out) | No |
   | Sold | period-bucketed trend | No |
   | Purchased | period-bucketed trend (`bought`) | No |
   | Revenue | period-bucketed trend (`arr`) | No |

`_topByName` (a separate property, declared line 84) is **already populated** for Value (line 900),
Profit→Potential (line 995), Profit→Realised (line 1036), and Current (line 1152) — reusing each
mode's existing aggregation — but it is never rendered as its own chart. It is **never computed**
for Sold, Purchased, or Revenue.

`_breakdownByDimension(metric, dim, ignorePeriod)` (line ~1257) is the shared aggregator behind
cards 1 and 2. For `metric ∈ {sold, purchased}` it delegates to `BreakdownMath.breakdown()`
(`qml/helper/BreakdownMath.js`), which only understands `dim ∈ {"category", "supplier"}` today.
For `metric ∈ {revenue, tax, discount}` it instead calls
`InventoryStore.realisedProfitByDimension(field, scope)` directly — `BreakdownMath.js` is not
involved for Revenue at all. This method already supports `field: "productId"` (proven in
production use by Profit→Realised, line 1036).

`qml/helper/BreakdownMath.js` has a byte-for-byte Node.js mirror at `functions/lib/breakdownMath.js`
(confirmed via diff — identical logic, module boilerplate aside), covered by
`functions/test/breakdownMath.test.js` against `functions/test/fixtures/breakdownMathFixtures.js`.
Nothing enforces this parity automatically; it's been maintained by convention.

## Architecture

### Card reordering (`SalesPage.qml`)

Move the existing by-category and by-supplier `BreakdownBarCard` blocks so the source order
becomes: new by-name card → existing by-supplier card → existing by-category card. No changes
to the supplier/category cards' bindings — position only.

### New by-name card

```qml
// ── By-name breakdown (all views) ──
BreakdownBarCard {
    Layout.fillWidth: true
    Layout.leftMargin: dp(Constants.space4)
    Layout.rightMargin: dp(Constants.space4)
    visible: (root._topByName || []).length > 0
    title: root._breakdownTitles().name
    model: root._topByName
    currency: root._isCurrency
    barTop: Constants.brand1
    barBottom: Constants.brand2
}
```

Placed first, ahead of supplier/category. Colors reuse existing palette tokens already used
elsewhere on the page (no new tokens needed).

### Duplicate suppression on the old third card

For Value and Profit→Potential, `_breakdown` and `_topByName` are the same data — showing both
the new by-name card and the old third card would render the identical chart twice. The old
card's `visible` binding gets one added condition:

```qml
visible: !(root._viewMode === root._MODE_VALUE)
         && !(root._viewMode === root._MODE_PROFIT && root._profitMode === "Potential")
```

(Current's version of this card has no explicit `visible` today — it relies on always being
reached since Current isn't Value or Profit, so it needs no change beyond the shared condition
above evaluating true for it.) Result: 4 visible chart cards on Current, Sold, Purchased, and
Profit→Realised; 3 visible chart cards on Value and Profit→Potential.

### `BreakdownMath.js` — new `dim: "name"` (Sold, Purchased only)

Add a `"name"` branch to `_sold()` and `_purchased()`, structurally identical to the existing
`"category"` branch (product id is already available at the line/event level for both metrics —
no per-consumption FIFO walk needed, same as category, unlike supplier). Resolution uses a new
`productName` map (`{ productId → display name }`), passed in alongside the existing
`productCategory` / `supplierName` maps. Same-name entries sum naturally through the existing
`_add(out, key, value)` accumulator — no separate merge step needed, since two productIds
resolving to the same name simply add into the same output key. Unresolved product id falls back
to `"(unnamed)"`, matching Current's existing convention for the same situation.

`_revenue()` is **not** touched — Revenue's by-name path reuses `InventoryStore.
realisedProfitByDimension()` instead (see below).

### `_breakdownByDimension()` — build the `productName` map

Alongside the existing `productCategory`/`supplierName` map construction, build
`productName: { productId → InventoryStore.getById(productId)?.name || productId }` and pass it
through to `BreakdownMath.breakdown()` when `dim === "name"`.

### `_profitTopN()` — one new optional parameter

```js
function _profitTopN(rows, n, filterKey, field) {
    field = field || "profit"
    ...
    keys.sort(function(a, b) { return (rows[b][field] || 0) - (rows[a][field] || 0) })
    ...
    out.push({ label: lbl, value: rows[k][field], fullLabel: k, revenue: rows[k].revenue, cogs: rows[k].cogs, margin: rows[k].margin })
}
```

Default preserves every existing call site's behavior unchanged. Revenue's `_topByName` becomes:

```js
_topByName = _profitTopN(_namedProductMap(InventoryStore.realisedProfitByDimension("productId", periodScope)), 8, "", "revenue")
```

— the exact pattern Profit→Realised already uses at line 1036, with `"revenue"` swapped in for
`"profit"`.

### `_topByName` for Sold / Purchased

```js
_topByName = _topNFromMap(_breakdownByDimension("sold" /* or "purchased" */, "name", false), 8)
```

Mirrors the existing category/supplier calls for these modes exactly.

## View-aware titles: `_breakdownTitles()`

Add a `name` key to every branch, following the existing `"<Metric> by <dimension>"` convention:

| Mode | New `name` title |
|---|---|
| Value | "Value by product" |
| Purchased | "Purchased units by product" |
| Current | "Stock by product" |
| Revenue | "Revenue by product" |
| Sold | "Units sold by product" |
| Profit | "Profit by product" |
| default | "By product" |

## Edge cases

- **Duplicate suppression** (above) — the one place this design deliberately deviates from a
  literal "keep the old card everywhere" reading, because keeping it literally would show the
  same chart twice on 2 of 6 views. Called out explicitly for review.
- **Naming inconsistency, left alone**: `_topByName` doesn't match the `_breakdownByCategory` /
  `_breakdownBySupplier` naming pattern. Renaming it would touch 4+ existing call sites for a
  purely cosmetic reason. Left as-is per non-goals; flagging in case you'd rather rename it now
  while the file is already open.
- **Multi-SKU same-name products**: collapse into one bar by summing, consistent with how
  Value/Current/Profit already behave (via `RealisedMath.nameMerge` / manual collapsing) — the
  new Sold/Purchased path achieves the same result through `BreakdownMath`'s existing `_add()`
  accumulator, no new merge function needed.
- **Unresolved product id** (deleted product, bad data): falls back to `"(unnamed)"`, matching
  Current's existing convention.
- **Empty state**: new card's `visible` follows the same `.length > 0` pattern as the category
  card — no custom empty-state text, consistent with category's existing (lack of) messaging.
- **Bar count cap**: every dimension (name, supplier, category), in every one of the 6 modes, is
  already capped to the top 8 by value/profit/revenue via `_topNFromMap(obj, 8)` or
  `_profitTopN(rows, 8, ...)` — verified by direct inspection, not assumed. This matters because
  `BreakdownBarCard.qml`'s `Repeater` has no cap or scrolling of its own; it renders whatever
  array it's given. The aggregation-layer `8` is the only thing preventing an unbounded product/
  supplier/category count from overflowing the card. The new by-name wiring for Sold/Purchased/
  Revenue reuses these same capped helpers, so it inherits the limit automatically — no new
  capping logic needed. Long labels are separately truncated to 5 characters + `…` by
  `_topNFromMap`/`_profitTopN` and elided by the component, so long product names don't break the
  layout either.
- **Guardrail — don't extend `_breakdownByDimension()`'s revenue branch with `dim: "name"`**:
  its `field = dim === "supplier" ? "supplierId" : "category"` ternary silently falls through to
  `"category"` for any unrecognised `dim`, including `"name"`. Revenue's `_topByName` must call
  `InventoryStore.realisedProfitByDimension("productId", periodScope)` directly (bypassing
  `_breakdownByDimension()` entirely), exactly as Profit→Realised already does — not go through
  the shared dimension function. Verified insertion point: right after the existing
  `_breakdownBySupplier = _topNFromMap(_breakdownByDimension("revenue", "supplier", false), 8)`
  line, reusing the `periodScope` variable already in scope there.

## Testing

- `tests/tst_BreakdownMath.qml` — new cases: `dim: "name"` for both `sold` and `purchased`,
  including (a) a multi-SKU-same-name collapsing case, (b) an unresolved-product-id fallback
  case, (c) a case confirming `dim: "category"`/`"supplier"` behavior is unchanged (regression
  guard).
- `tests/tst_BreakdownMathParityFixtures.qml` — extend existing fixture scenarios with a
  `productName` map and `byName` assertions, same literal entries already used for the
  category/supplier assertions in that file.
- `functions/test/fixtures/breakdownMathFixtures.js` + `functions/test/breakdownMath.test.js` —
  identical scenario data and assertions, manually mirrored (matching the existing pairing
  convention noted in the QML file's header comment).
- No automated coverage for the `SalesPage.qml` card wiring/reordering/suppression itself — that's
  UI composition, not pure-JS. Manual QA checklist (for whenever you choose to build and run):
  1. Each of the 6 modes shows the by-name card first, then supplier, then category.
  2. Value and Profit→Potential show exactly 3 chart cards (no 4th/duplicate).
  3. Current, Sold, Purchased, Profit→Realised show exactly 4 chart cards, with the 4th being
     the original trend/stock-health content, unchanged.
  4. Sold/Purchased/Revenue by-name bars show correct multi-SKU collapsing against a product
     family with 2+ SKUs.
  5. Filter chips (category/supplier/staff/period) still correctly affect all three top cards,
     not just category/supplier.

## Files touched

- `qml/pages/SalesPage.qml` — card reordering, new by-name card, duplicate-suppression
  condition, `_breakdownTitles()` name key, `_breakdownByDimension()` productName map,
  `_profitTopN()` field parameter, `_topByName` wiring for Sold/Purchased/Revenue.
- `qml/helper/BreakdownMath.js` — new `dim: "name"` branch in `_sold()`/`_purchased()`.
- `functions/lib/breakdownMath.js` — mirrored `dim: "name"` branch (parity).
- `tests/tst_BreakdownMath.qml` — new cases.
- `tests/tst_BreakdownMathParityFixtures.qml` — extended fixtures.
- `functions/test/fixtures/breakdownMathFixtures.js` — mirrored fixtures.
- `functions/test/breakdownMath.test.js` — mirrored assertions.

## Build sequence

1. `BreakdownMath.js` `dim: "name"` branch + `tests/tst_BreakdownMath.qml` cases (TDD: red then
   green, pure-JS).
2. Mirror into `functions/lib/breakdownMath.js` + Node test/fixture updates.
3. `tests/tst_BreakdownMathParityFixtures.qml` + Node fixture mirror.
4. `_breakdownByDimension()` productName map wiring.
5. `_profitTopN()` field parameter + Revenue's `_topByName` wiring.
6. Sold/Purchased `_topByName` wiring.
7. `_breakdownTitles()` name key.
8. New by-name `BreakdownBarCard` + card reordering + duplicate-suppression condition.
9. Manual QA checklist written into this doc (done above) for whenever build/run is requested.
