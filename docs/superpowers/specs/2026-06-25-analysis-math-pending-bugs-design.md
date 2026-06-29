# Analysis Math Pending Bugs — Fix Design

**Date:** 2026-06-25
**Branch:** `master` (work branch to be cut)
**Source doc:** `docs/superpowers/specs/2026-06-24-analysis-math-pending-bugs.md`
**Status:** Approved — implement in this pass.

Fix every pending finding (A–E, SITE 4–7) from the pending-bugs audit, with zero
regressions to current behaviour, real headless tests for the now-testable math,
and per-scenario manual test steps for the page-level surfaces that cannot load
under `qmltestrunner`.

---

## 1. Root cause & strategy

Five of the nine findings (A, C, D, SITE 4, SITE 5) share one root cause: **realised
money is aggregated from two different sources** —

- *live orders* via `OrderMath.allocate(o)` → Revenue hero, Revenue period bins,
  `_exportTotalsBlock`, `_breakdownByDimension("revenue", …)`, and
- the *immutable event log* via `eventProfit` / `realisedProfitByDimension` → Profit hero,
  by-dimension realised sections —

and the by-dimension realised sections ignore the active filter scope entirely.

The strategy is to **consolidate all realised-money aggregation onto the filtered event
log inside one new pure `.pragma library`** (`RealisedMath.js`), mirroring the existing
`BreakdownMath.js` / `OrderMath.js` pattern. This simultaneously:

- fixes SITE 5 (one source of truth → Revenue-view and Profit-view reconcile),
- gives A a filter-scope parameter,
- folds C/D/SITE 4 into the single canonical aggregator, and
- makes the math **headless-testable** (the doc's Recommendation #3), so the new tests
  are real, not formula mirrors that can drift from the call sites.

Two findings are isolated and get small, local, separately-tested fixes: **E** (import SKU
suffix) and **SITE 6** (refund per-unit). **B** is a product decision (omit the section).
**SITE 7** is a one-site formula correction in the (currently dormant) revenue/margin
branches of `_consumptionBucketWalk`.

---

## 2. New / changed units

### 2.1 `qml/helper/RealisedMath.js` — NEW (pure library)

`.pragma library` + `.import "OrderMath.js" as OrderMath`. No QML/singleton deps — all
inputs passed in. This is the single home for realised event-log aggregation.

A **scope** object mirrors `_passesCrossFilters` + supplier filter:

```js
// scope = { window:{from,to}|null, channel:"", staffId:"", category:"", supplierId:"",
//           productCategory:{productId->category} }   // "" / null = "all"
```

**Exports:**

- `byDimension(field, entries, scope, lookups)` → `{ key -> {gross,net,discount,tax,cogs,profit,margin} }`
  - `field ∈ "productId"|"supplierId"|"category"|"channel"|"staffId"`.
  - Walks `entries`, skipping any row that fails `scope`. Supplier filter matches at the
    `consumption[]` row level (partial-row inclusion, as today).
  - Reads **stamped** `e.net/e.tax/e.discountShare` only. When `e.net` is absent the row
    contributes **0** (fail-closed) — never re-allocates the live order. **(SITE 4)**
  - Per-consumption split uses **remainder-to-largest** reconciliation so the supplier axis
    is cent-exact vs the line net. **(C)**
  - `price_adjust` handling (order-wide spread, per-line supplier slices, discount column)
    is carried over verbatim from the current `realisedProfitByDimension`, now also
    gated by `scope`.
  - `margin` computed in the second pass: `cogs>0 ? profit/cogs*100 : 0`.
- `totals(entries, scope)` → one `{gross,discount,net,tax,cogs,profit}` block over the
  filtered event log. Replaces the live-order summation in `_exportTotalsBlock` and the
  Revenue/Profit hero totals. Per-row `gross` is a single `_round2(rowNet + rowDisc)`
  value (no independent double-round). **(D, SITE 5)**
- `bucketWalk(metric, periodIdx, entries, scope, now)` → period bins `[{label,value}]` for
  `metric ∈ "net"|"profit"`. Both Revenue bins and Profit bins walk events. **(SITE 5)**
  - `now` is passed in (tests inject a fixed date; production passes `new Date()`).
- `nameMerge(rows, nameLookup, fallback)` → `{id->row}` → `{name->row}` merge with margin
  recompute, extracted from the three `_namedXMap` helpers. **(closes X1 coverage gap)**

**Reconciliation invariant (the headline guarantee):** for any scope,
`Σ byDimension(any field) == totals == Σ bucketWalk(metric)` to the cent.

### 2.2 `qml/helper/OrderMath.js` — small add

```js
function refundPerUnit(saleEvent) { /* (net+tax)/qty from stamped fields; 0 if qty<=0 */ }
```
Pure; used by SITE 6. Reads stamped `net`/`tax` off the original **sale** event, never
re-allocates. **(SITE 6)**

### 2.3 `qml/helper/ImportMath.js` — NEW (tiny pure library)

```js
function renameSku(sku, addedCount) { return sku + "-" + (addedCount + 1) }
```
Extracted only so the operator-precedence fix carries a test. **(E)**

### 2.4 `qml/model/InventoryStore.qml` — thin wrappers

- `realisedProfitByDimension(field, opts)` becomes a thin adapter: assemble `entries`,
  `productCategory`, and call `RealisedMath.byDimension`. **`opts` is optional** — when
  omitted the scope is "all", so every existing caller is byte-for-byte equivalent
  (no regression). Bug-A callers pass the active scope.
- `upsertMany` line 534: `r.sku = ImportMath.renameSku(r.sku, counts.added)`. **(E)**

### 2.5 `qml/pages/SalesPage.qml` — call-site rewiring

- Realised on-screen rebuild (:1003–1022) and export sections (:1500–1509): build a `scope`
  from the active filters and pass it into the realised calls; use `RealisedMath.nameMerge`
  in place of `_namedSupplierMap/_namedStaffMap/_namedProductMap` (those wrappers become
  thin shims over `nameMerge`, or are removed if no other caller). **(A, X1)**
- Realised export By-period (:1485–1499): **omit** the By-period section when a custom date
  filter is active. **(B)**
- Revenue view (:1226–1364): hero total, period bins, and tax/discount sublines source from
  `RealisedMath.totals` / `bucketWalk("net", …)` instead of `revenueOf`/`OrderMath.allocate`.
  `_breakdownByDimension("revenue", …)` routes revenue through the event log too. **(SITE 5)**
- `_exportTotalsBlock` (:2003): replace the live-order loop with `RealisedMath.totals(scope)`.
  **(SITE 5, D)**
- `_consumptionBucketWalk` revenue/margin branches (:2408, :2411): distribute stamped `e.net`
  by `qtyConsumed/lineQty` (as `eventProfit` does); margin uses net, not `unitPrice`. The
  `qty` branch is unchanged. **(SITE 7)**

### 2.6 `qml/model/DataModel.qml` — SITE 6

`_tryAdjustOrder` :566–568: compute the returned-unit refund from the **original sale
event's** stamped per-unit (`OrderMath.refundPerUnit(originalSaleEvent)`), not from a live
`OrderMath.allocate(o)` that may already reflect adjustment #1's discount. Needs a lookup
for the order's original sale event for the returned product:
`TransactionStore.firstSaleEvent(orderId, productId)` (new, read-only: first `kind:"sale"`
row matching orderId+productId). Fallback to the existing `(pl2.net+pl2.tax)/pl2.qty` when
no sale event exists (pre-event legacy), preserving today's behaviour. **(SITE 6)**

---

## 3. Test plan (real, headless)

Because the math now lives in pure libraries, these are **real** tests, not formula
mirrors.

- **`tests/tst_RealisedMath.qml`** (new):
  - `byDimension` reconciles to `totals` for every field, no filter.
  - **A:** under each active scope (date / channel / staff / category / supplier),
    `Σ byDimension == totals == Σ bucketWalk` to the cent.
  - **SITE 4:** an event with `net` undefined contributes 0 (fail-closed), not a
    re-derived value.
  - **C:** one line consumed 2+1 across two suppliers with a net that doesn't divide
    evenly → `Σ per-supplier net == line net` exactly (remainder-to-largest).
  - **D:** supplier-filtered `totals.gross == Σ rounded(net+disc)` to the cent.
  - **SITE 5:** sale → adjust (discount) → partial return order: Revenue (`bucketWalk("net")`),
    `totals.net`, and `Σ byDimension(...).net` all equal `Σ event nets`.
  - `nameMerge`: id→name merge sums duplicates, applies fallback, recomputes margin.
- **`tests/tst_OrderMath.qml`** (extend):
  - **SITE 6:** sale (disc) → adjust#1 (discount edit) → adjust#2 (return) → `refundPerUnit`
    of the original sale event is unchanged by adjust#1.
- **`tests/tst_ImportMath.qml`** (new):
  - **E:** `renameSku("ABC", 0) === "ABC-1"`, `renameSku("ABC", 4) === "ABC-5"` (not `"ABC-01"`).
- **SITE 7:** in `tst_RealisedMath`, `bucketWalk("net")` distributes stamped net (a
  discounted line reports net, not gross `qty*unitPrice`).

**No-regression gate:** the full existing suite (110 cases / 10 suites) plus the new
suites must pass via the AGENTS.md runner command.

### Coverage ceiling (explicit, unchanged by this work)

`qmltestrunner` cannot load `SalesPage.qml` (needs Felgo `App` context) or the C++
`XlsxService` (needs a Qt build). So **"100% coverage" is achieved for the extracted pure
libraries** (`RealisedMath.js`, `OrderMath.js`, `ImportMath.js`, `BreakdownMath.js`), not
for page-level QML wiring or the xlsx column-writer. Those remain verified by the manual
**export → unzip → decode → reconcile** procedure (Part 4). This matches the source doc's
coverage limitation note and Recommendation #4.

---

## 4. Manual test steps (per scenario)

Page-level surfaces that the headless suite can't reach are verified on-device. For each:

- **A — filter-blind realised sections:** Open Analysis → Profit (Realised). Apply a date
  (or channel/staff/category/supplier) filter. Verify the Realised hero total equals the
  sum of the By-category bars, and By-product/supplier/category/channel/staff all move with
  the filter. Export → decode → confirm Σ(each by-dimension section) == Totals block.
- **B — By-period custom range:** Apply a custom back-dated date range. Export Realised
  profit. Confirm the **By-period section is absent** and Totals + by-dimension sections
  reconcile.
- **C — multi-batch rounding:** Create a product stocked from two suppliers; sell a qty that
  draws from both batches with a price that doesn't divide evenly (e.g. 3 units @ ₹10 with a
  ₹1 flat discount). Export → decode → confirm supplier net sums to the category/line net to
  the cent.
- **D — supplier-slice gross:** With the same order, filter by one supplier and export.
  Confirm the Totals Gross column equals net+discount for that supplier to the cent.
- **E — SKU rename:** Import a CSV whose SKU collides with an existing product, choose
  "rename". Confirm the new SKU is `<sku>-1` (not `<sku>-01`). (Also covered by unit test.)
- **SITE 4 — net fallback:** (Latent under fresh-data.) No manual step needed beyond the
  unit test; if a no-`net` event is ever produced, the supplier/profit sections must show 0
  for that row, not a re-derived figure.
- **SITE 5 — Revenue vs Profit reconcile:** Complete an order, then adjust it (return one
  unit). Open Analysis → Revenue and note the hero. Switch to Profit (Realised) → the
  revenue implied by the profit view (and the by-dimension nets) must match. Export both →
  decode → Revenue Totals net == Profit Totals net == Σ event nets.
- **SITE 6 — 2nd-adjust refund:** Complete an order with a discount. Adjust #1: edit the
  discount. Adjust #2: return a unit. Confirm the refund uses the **original sale** per-unit
  (net+tax)/qty, not adjustment #1's discounted rate.
- **SITE 7 — consumption revenue/margin:** Dormant today (only the `qty` field is wired). If
  the revenue/margin branch is ever surfaced, confirm it reports discounted net, not gross.

---

## 5. Post-development updates

- **AGENTS.md:** Shared Components Agent — add `RealisedMath.js`, `ImportMath.js`, and the
  `OrderMath.refundPerUnit` addition to the pure-library list and key files. Testing & QA
  Agent — add the new suites.
- **SKILLS.md:** add a skill entry documenting the event-sourced realised aggregation
  (one source of truth: `RealisedMath`), the scope object, and the reconciliation invariant.
- **`2026-06-24-analysis-math-pending-bugs.md`:** mark A–E and SITE 4–7 fixed (with this
  spec + the fixing commit), and update Part 2 coverage rows from ❌ to ✅ for the items now
  covered by `tst_RealisedMath` / `tst_OrderMath` / `tst_ImportMath`.

---

## 6. Non-goals (YAGNI)

- No change to the C++ `XlsxService` writer or its (manual-only) verification.
- No back-compat / migration code for legacy un-stamped events beyond the fail-closed-to-0
  fallback (MVP fresh-data invariant).
- No new now-relative bucketing for B (omit instead — approved).
- No refactor of `BreakdownMath.js`'s sold/purchased paths (out of scope).
