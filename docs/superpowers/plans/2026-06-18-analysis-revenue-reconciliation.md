# Analysis Revenue / Profit / Tax / Discount Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every analysis surface (Dashboard, Analysis hero, Profit report, all exports) compute one canonical **net revenue** (subtotal − discount, tax excluded) so revenue, profit, tax, and discount reconcile across every dimension and between screen and export.

**Architecture:** Introduce one pure, unit-tested helper `qml/helper/OrderMath.js` that splits an order into per-line and per-FIFO-consumption `{ net, tax, discountShare, cogs, profit }` mirroring `OrdersStore.computeOrderTotals`'s pro-rata rounding. Every aggregator (`BreakdownMath._revenue`, `SalesPage.revenueOf`/`_binsFor`/`_profitBucketWalk`, `InventoryStore.realisedProfitByDimension`) and the export builder (`SalesPage.buildAnalysisExport`) is rewired to read those fields. Sale/return events stamp the allocated fields at write time. No C++ change; no data migration (MVP wipes Firestore each test cycle).

**Tech Stack:** Qt 6 / QML, `.pragma library` JavaScript helpers, Qt Quick Test (`qmltestrunner`), QXlsx (unchanged).

## Global Constraints

- **Revenue definition (verbatim from spec):** Revenue = `subtotal − discount`. Tax is a separate pass-through line, **never** counted as revenue. Profit = net revenue − COGS.
- **No migration / no back-compat:** events written before this change need not be readable; do not add shims for un-stamped historical events beyond the read-time `allocate()` fallback the order-level breakdowns already use.
- **Pure-library testing rule:** only `.pragma library` JS (`OrderMath.js`) is unit-testable under `qmltestrunner`. Page/store QML needing the Felgo `App` context (`dp()`/`sp()`/`Theme`) cannot load under the runner — keep all testable math in `OrderMath.js` and test it there.
- **Test run command (this box; `qmltestrunner` is silent without the two `QT_*` vars):**
  ```bash
  QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
    PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
    "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_<Name>.qml
  ```
- **`tests/` stays OUTSIDE `qml/`** so test files are not globbed into the app package. There is no CMake test target — the runner executes the `.qml` directly.
- **Branch:** `spec/analysis-revenue-reconciliation`. Commit after every task.
- **Rounding:** mirror `computeOrderTotals` — round discount, tax, subtotal to 2 dp (`Math.round(x*100)/100`) and `total = round(subtotal) − round(discount) + round(tax)`. Proportional child splits assign the sub-paisa remainder to the largest child so children re-sum to the parent.

## File Structure

- **Create** `qml/helper/OrderMath.js` — pure allocation helper (the testable core). One responsibility: turn one order into per-line / per-consumption net/tax/discount/cogs/profit + totals.
- **Create** `tests/tst_OrderMath.qml` — Qt Quick Test suite for `OrderMath.js`.
- **Modify** `qml/model/OrdersStore.qml` — no formula change; expose nothing new (kept as the rounding oracle the tests compare against).
- **Modify** `qml/helper/BreakdownMath.js` — `_revenue` reads net allocation; add `metric: "tax"` / `"discount"`; tests extended in existing `tests/tst_BreakdownMath.qml`.
- **Modify** `qml/model/InventoryStore.qml` — `realisedProfitByDimension` revenue=net, adds `tax`/`discount` accumulators, applies discount `price_adjust` to supplier axis.
- **Modify** `qml/model/TransactionStore.qml` — `recordSaleFromOrder` / `recordReturn` stamp allocated `net`/`tax`/`discountShare`/`cogs`; drop dead `unitCost = inv.price`.
- **Modify** `qml/pages/SalesPage.qml` — `revenueOf`, `_binsFor`, `_profitBucketWalk` use net allocation; hero gains `_periodTax`/`_periodDiscount`; `buildAnalysisExport` gains Totals block + per-section Discount/Tax/Net columns.
- **Modify** `qml/pages/DashboardPage.qml` + `qml/model/SalesStore.qml` — revenue helpers switch `o.total` → `OrderMath.allocate(o).totals.net`.
- **Modify** `qml/pages/ConfirmReturnSheet.qml` + `qml/model/DataModel.qml` — refund = net + tax for returned units (#8).
- **Modify** `qml/pages/OrderDetailDialog.qml` — re-tax a grown line from the current product (#7).

---

## Task 1: `OrderMath.allocate` core — totals + per-line, no consumption

**Files:**
- Create: `qml/helper/OrderMath.js`
- Test: `tests/tst_OrderMath.qml`

**Interfaces:**
- Consumes: nothing (pure library).
- Produces:
  - `allocate(order) → { perLine: [...], totals: {...} }` where
    `order = { products: [{ productId, name, price, quantity, taxable, taxPercent, consumption? }], discountType, discountValue }`.
  - `totals = { gross, discount, net, tax, cogs, total, itemCount }` (all numbers; this task leaves `cogs=0`, `profit` deferred to Task 2).
  - `perLine[i] = { productId, name, qty, price, gross, discountShare, net, taxable, taxPercent, tax, perConsumption: [] }` (perConsumption filled in Task 2).
  - Invariants this task guarantees: `Σ perLine.gross = totals.gross`; `Σ perLine.net = totals.net = round(subtotal) − round(discount)`; `Σ perLine.tax = totals.tax`; `totals.total = round(subtotal) − round(discount) + round(tax)`.

- [ ] **Step 1: Write the failing test**

Create `tests/tst_OrderMath.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/OrderMath.js" as OM

TestCase {
    name: "OrderMath"

    function _order(lines, dType, dVal) {
        return { products: lines, discountType: dType || "flat", discountValue: dVal || 0 }
    }

    // No discount, no tax → net == gross, tax == 0.
    function test_plain_no_discount_no_tax() {
        var o = _order([{ productId: "P1", name: "A", price: 100, quantity: 2, taxable: false, taxPercent: 0 }])
        var a = OM.allocate(o)
        compare(a.totals.gross, 200)
        compare(a.totals.discount, 0)
        compare(a.totals.net, 200)
        compare(a.totals.tax, 0)
        compare(a.totals.total, 200)
        compare(a.perLine.length, 1)
        compare(a.perLine[0].net, 200)
        compare(a.perLine[0].tax, 0)
    }

    // Flat discount + one taxable line: tax taken on the discounted (net) line value.
    function test_flat_discount_with_tax() {
        var o = _order([{ productId: "P1", name: "A", price: 100, quantity: 2, taxable: true, taxPercent: 10 }], "flat", 40)
        var a = OM.allocate(o)
        compare(a.totals.gross, 200)
        compare(a.totals.discount, 40)
        compare(a.totals.net, 160)         // 200 - 40
        fuzzyCompare(a.totals.tax, 16, 0.001) // 160 * 10%
        fuzzyCompare(a.totals.total, 176, 0.001)
    }

    // Percent discount clamps above 100.
    function test_percent_discount_clamped() {
        var o = _order([{ productId: "P1", name: "A", price: 50, quantity: 2, taxable: false, taxPercent: 0 }], "percent", 150)
        var a = OM.allocate(o)
        compare(a.totals.discount, 100)    // clamped to 100% of subtotal
        compare(a.totals.net, 0)
    }

    // Flat discount clamps to subtotal.
    function test_flat_discount_clamped_to_subtotal() {
        var o = _order([{ productId: "P1", name: "A", price: 30, quantity: 1, taxable: false, taxPercent: 0 }], "flat", 999)
        var a = OM.allocate(o)
        compare(a.totals.discount, 30)
        compare(a.totals.net, 0)
    }

    // Mixed taxable/non-taxable lines: discount spreads pro-rata; only taxable line nets tax.
    function test_mixed_taxable_lines() {
        var o = _order([
            { productId: "P1", name: "A", price: 100, quantity: 1, taxable: true,  taxPercent: 10 },
            { productId: "P2", name: "B", price: 100, quantity: 1, taxable: false, taxPercent: 0 }
        ], "flat", 20)
        var a = OM.allocate(o)
        // subtotal 200, discount 20 → each line discountShare 10, net 90 each.
        compare(a.perLine[0].net, 90)
        compare(a.perLine[1].net, 90)
        fuzzyCompare(a.totals.tax, 9, 0.001)   // only P1: 90 * 10%
        compare(a.totals.net, 180)
    }

    // Per-line net sums to totals.net (invariant).
    function test_perline_net_sums_to_total() {
        var o = _order([
            { productId: "P1", name: "A", price: 33, quantity: 3, taxable: false, taxPercent: 0 },
            { productId: "P2", name: "B", price: 17, quantity: 5, taxable: false, taxPercent: 0 }
        ], "percent", 13)
        var a = OM.allocate(o)
        var s = 0
        for (var i = 0; i < a.perLine.length; ++i) s += a.perLine[i].net
        fuzzyCompare(s, a.totals.net, 0.001)
    }

    // allocate().totals equals computeOrderTotals for the same input (oracle check
    // is added in tst against OrdersStore is impossible headless; assert internal
    // consistency of total = net + tax instead).
    function test_total_equals_net_plus_tax() {
        var o = _order([{ productId: "P1", name: "A", price: 100, quantity: 2, taxable: true, taxPercent: 18 }], "flat", 50)
        var a = OM.allocate(o)
        fuzzyCompare(a.totals.total, a.totals.net + a.totals.tax, 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderMath.qml
```
Expected: FAIL — `OrderMath.js` does not exist / `allocate is not a function`.

- [ ] **Step 3: Write minimal implementation**

Create `qml/helper/OrderMath.js`:

```javascript
.pragma library

// Canonical per-order allocation. Splits an order into per-line (and, in a
// later step, per-FIFO-consumption) net / tax / discount / cogs, mirroring the
// pro-rata rounding in OrdersStore.computeOrderTotals so every analytics axis
// reconciles to the order. Pure — no QML/singleton deps, unit-testable.
//
// Revenue convention (locked): net = gross - discountShare; tax is a SEPARATE
// pass-through amount, never part of revenue. total = net + tax.

function _round2(x) { return Math.round(x * 100) / 100 }

function allocate(order) {
    order = order || {}
    var lines = order.products || []
    var subtotal = 0
    for (var i = 0; i < lines.length; ++i)
        subtotal += (lines[i].quantity || 0) * (lines[i].price || 0)

    var discountType = order.discountType === "percent" ? "percent" : "flat"
    var discount
    if (discountType === "percent") {
        var pct = parseFloat(order.discountValue) || 0
        if (pct < 0) pct = 0
        if (pct > 100) pct = 100
        discount = subtotal * (pct / 100)
    } else {
        discount = parseFloat(order.discountValue) || 0
        if (discount < 0) discount = 0
        if (discount > subtotal) discount = subtotal
    }

    var perLine = []
    var totalTax = 0
    var itemCount = 0
    for (var j = 0; j < lines.length; ++j) {
        var ln = lines[j]
        var qty = ln.quantity || 0
        var price = (typeof ln.price === "number") ? ln.price : 0
        var gross = qty * price
        var discShare = subtotal > 0 ? (discount * (gross / subtotal)) : 0
        var net = gross - discShare
        var taxable = !!ln.taxable
        var taxPercent = (typeof ln.taxPercent === "number") ? ln.taxPercent : 0
        var tax = (taxable && taxPercent > 0) ? net * (taxPercent / 100) : 0
        totalTax += tax
        itemCount += qty
        perLine.push({
            productId: ln.productId || "", name: ln.name || "",
            qty: qty, price: price,
            gross: gross, discountShare: discShare, net: net,
            taxable: taxable, taxPercent: taxPercent, tax: tax,
            perConsumption: []
        })
    }

    var roundedSubtotal = _round2(subtotal)
    var roundedDiscount = _round2(discount)
    var roundedTax = _round2(totalTax)
    var roundedNet = _round2(roundedSubtotal - roundedDiscount)
    var total = _round2(roundedNet + roundedTax)

    return {
        perLine: perLine,
        totals: {
            gross: roundedSubtotal,
            discount: roundedDiscount,
            net: roundedNet,
            tax: roundedTax,
            cogs: 0,
            total: total,
            itemCount: itemCount
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same command from Step 2.
Expected: PASS — all 7 cases pass (`Totals: 7 passed, 0 failed`).

- [ ] **Step 5: Commit**

```bash
git add qml/helper/OrderMath.js tests/tst_OrderMath.qml
git commit -m "feat(analysis): add OrderMath.allocate net/tax/discount core

Pure per-line allocation mirroring computeOrderTotals rounding. net =
subtotal - discount; tax separate. Foundation for reconciled reports.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Per-consumption split + COGS/profit in `allocate`

**Files:**
- Modify: `qml/helper/OrderMath.js`
- Test: `tests/tst_OrderMath.qml`

**Interfaces:**
- Consumes: Task 1 `allocate` shape.
- Produces: each `perLine[i].perConsumption[c] = { supplierId, batchId, qtyConsumed, unitCost, net, tax, discountShare, cogs, profit }`. `totals.cogs` now = `Σ perConsumption.cogs`; add `totals.profit = totals.net − totals.cogs`. New invariants: `Σ perConsumption.net == perLine.net` (±0.01), `Σ perConsumption.cogs == perLine cogs`. Remainder from proportional split is assigned to the largest-qty consumption row.

- [ ] **Step 1: Write the failing test**

Append to `tests/tst_OrderMath.qml` (inside the `TestCase`):

```qml
    // Multi-supplier consumption: per-consumption net sums to line net; cogs per batch.
    function test_consumption_split_multi_supplier() {
        var o = _order([{
            productId: "P1", name: "A", price: 100, quantity: 5, taxable: true, taxPercent: 10,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 },
                { batchId: "B2", supplierId: "S2", qtyConsumed: 3, unitCost: 50 }
            ]
        }], "flat", 50)
        var a = OM.allocate(o)
        var line = a.perLine[0]
        // line: gross 500, discount 50, net 450, tax 45.
        compare(line.net, 450)
        var sumNet = 0, sumCogs = 0
        for (var i = 0; i < line.perConsumption.length; ++i) {
            sumNet += line.perConsumption[i].net
            sumCogs += line.perConsumption[i].cogs
        }
        fuzzyCompare(sumNet, line.net, 0.011)         // children re-sum to parent
        compare(sumCogs, 2 * 40 + 3 * 50)             // 80 + 150 = 230
        compare(a.totals.cogs, 230)
        fuzzyCompare(a.totals.profit, 450 - 230, 0.011)
    }

    // Pre-FIFO line (no consumption): perConsumption empty, totals still balance, cogs 0.
    function test_consumption_pre_fifo_empty() {
        var o = _order([{ productId: "P1", name: "A", price: 100, quantity: 2, taxable: false, taxPercent: 0 }])
        var a = OM.allocate(o)
        compare(a.perLine[0].perConsumption.length, 0)
        compare(a.totals.cogs, 0)
        compare(a.totals.net, 200)
        compare(a.totals.profit, 200)  // no cogs known
    }

    // Odd 3-way split: remainder lands on the largest row; children re-sum exactly.
    function test_consumption_rounding_remainder() {
        var o = _order([{
            productId: "P1", name: "A", price: 10, quantity: 3, taxable: false, taxPercent: 0,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 1 },
                { batchId: "B2", supplierId: "S2", qtyConsumed: 1, unitCost: 1 },
                { batchId: "B3", supplierId: "S3", qtyConsumed: 1, unitCost: 1 }
            ]
        }], "flat", 1)  // net 29 over 3 units → 9.67/9.67/9.66 style split
        var a = OM.allocate(o)
        var line = a.perLine[0]
        var sumNet = 0
        for (var i = 0; i < line.perConsumption.length; ++i) sumNet += line.perConsumption[i].net
        fuzzyCompare(sumNet, line.net, 0.0001)  // exact re-sum after remainder assignment
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderMath.qml
```
Expected: FAIL — `perConsumption` is empty and `totals.profit` is undefined.

- [ ] **Step 3: Write minimal implementation**

In `qml/helper/OrderMath.js`, replace the per-line `push` block and the totals object. Inside the `for (var j …)` loop, after computing `tax`, build the consumption split before pushing:

```javascript
        var cons = Array.isArray(ln.consumption) ? ln.consumption : []
        var perConsumption = []
        var lineCogs = 0
        if (cons.length > 0 && qty > 0) {
            // Proportional split of net/tax/discountShare by qtyConsumed/qty.
            var assignedNet = 0, assignedTax = 0, assignedDisc = 0
            var largestIdx = 0, largestQty = -1
            for (var c = 0; c < cons.length; ++c) {
                var cq = cons[c].qtyConsumed || 0
                var frac = cq / qty
                var cNet = _round2(net * frac)
                var cTax = _round2(tax * frac)
                var cDisc = _round2(discShare * frac)
                var cCost = cq * (cons[c].unitCost || 0)
                lineCogs += cCost
                assignedNet += cNet; assignedTax += cTax; assignedDisc += cDisc
                if (cq > largestQty) { largestQty = cq; largestIdx = c }
                perConsumption.push({
                    supplierId: cons[c].supplierId || "", batchId: cons[c].batchId || "",
                    qtyConsumed: cq, unitCost: cons[c].unitCost || 0,
                    net: cNet, tax: cTax, discountShare: cDisc,
                    cogs: cCost, profit: cNet - cCost
                })
            }
            // Assign rounding remainder to the largest row so children re-sum.
            if (perConsumption.length > 0) {
                var rNet = _round2(net) - assignedNet
                var rTax = _round2(tax) - assignedTax
                var rDisc = _round2(discShare) - assignedDisc
                var L = perConsumption[largestIdx]
                L.net = _round2(L.net + rNet)
                L.tax = _round2(L.tax + rTax)
                L.discountShare = _round2(L.discountShare + rDisc)
                L.profit = L.net - L.cogs
            }
        }
        totalCogs += lineCogs
        perLine.push({
            productId: ln.productId || "", name: ln.name || "",
            qty: qty, price: price,
            gross: gross, discountShare: discShare, net: net,
            taxable: taxable, taxPercent: taxPercent, tax: tax,
            cogs: lineCogs,
            perConsumption: perConsumption
        })
```

Add `var totalCogs = 0` next to `var totalTax = 0`, and update the returned `totals`:

```javascript
            cogs: _round2(totalCogs),
            profit: _round2(roundedNet - _round2(totalCogs)),
```

(Replace the `cogs: 0,` line; add the `profit` line after `total`.)

- [ ] **Step 4: Run test to verify it passes**

Run the same command from Step 2.
Expected: PASS — all cases (Task 1 + 3 new) pass.

- [ ] **Step 5: Commit**

```bash
git add qml/helper/OrderMath.js tests/tst_OrderMath.qml
git commit -m "feat(analysis): per-consumption net/tax/cogs split in OrderMath

Splits each line proportionally to qtyConsumed, assigns rounding
remainder to the largest row, adds totals.cogs/profit. Enables
reconciled per-supplier revenue and profit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `BreakdownMath._revenue` reads net allocation

**Files:**
- Modify: `qml/helper/BreakdownMath.js:90-130` (`_revenue`)
- Modify: `qml/helper/BreakdownMath.js:74-79` (`breakdown` dispatch — add `tax`/`discount` metrics)
- Test: `tests/tst_BreakdownMath.qml`

**Interfaces:**
- Consumes: `OrderMath.allocate` (Task 2). BreakdownMath is `.pragma library`; import OrderMath at top: `Qt.include` is unavailable in `.pragma library`, so instead **pass an `allocate` function in via `opts.allocate`** (keeps BreakdownMath dependency-free and testable). Callers (`SalesPage._breakdownByDimension`) pass `OrderMath.allocate`.
- Produces: `_revenue(o)` returns `{ key → net }` (was `{ key → gross }`). New `metric` values `"tax"` and `"discount"` return `{ key → tax }` / `{ key → discountShare }` by the same dimension.

- [ ] **Step 1: Write the failing test**

Append to `tests/tst_BreakdownMath.qml`:

```qml
    // Revenue is now NET (subtotal - discount), not gross qty*price.
    function test_revenue_is_net_of_discount() {
        var orders = [{
            status: "completed", date: "2026-06-15T10:00:00", orderChannel: "", staffId: "",
            discountType: "flat", discountValue: 40,
            products: [{ productId: "P1", price: 100, quantity: 2, taxable: false, taxPercent: 0 }]
        }]
        var out = BM.breakdown({
            metric: "revenue", dim: "category",
            orders: orders, window: null,
            productCategory: { "P1": "Drinks" }, supplierName: {},
            allocate: _allocate
        })
        // gross 200, discount 40 → net 160 attributed to Drinks.
        fuzzyCompare(out["Drinks"], 160, 0.001)
    }

    // A tiny inline allocate mirroring OrderMath for the test (avoids cross-import).
    function _allocate(o) {
        var sub = 0, lines = o.products || []
        for (var i = 0; i < lines.length; ++i) sub += lines[i].quantity * lines[i].price
        var disc = o.discountType === "percent" ? sub * (o.discountValue/100) : Math.min(o.discountValue, sub)
        var per = []
        for (var j = 0; j < lines.length; ++j) {
            var g = lines[j].quantity * lines[j].price
            var ds = sub > 0 ? disc * (g/sub) : 0
            per.push({ productId: lines[j].productId, qty: lines[j].quantity, net: g - ds,
                       tax: 0, discountShare: ds,
                       perConsumption: (lines[j].consumption||[]).map(function(c){
                           var f = c.qtyConsumed/lines[j].quantity
                           return { supplierId: c.supplierId, qtyConsumed: c.qtyConsumed,
                                    net: (g-ds)*f, tax: 0, discountShare: ds*f }
                       }) })
        }
        return { perLine: per, totals: { net: sub - disc } }
    }
```

> Note for implementer: prefer importing the real `OrderMath.js` in the test (`import "../qml/helper/OrderMath.js" as OM`) and passing `OM.allocate`. The inline `_allocate` above is a fallback only if cross-import in the test proves flaky under the runner; the real-import form is preferred and equivalent.

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_BreakdownMath.qml
```
Expected: FAIL — current `_revenue` returns gross 200, not 160.

- [ ] **Step 3: Write minimal implementation**

In `qml/helper/BreakdownMath.js`, rewrite `_revenue` to use the passed `allocate`. Replace the whole `_revenue` function (lines ~90-130) with:

```javascript
function _revenue(o) {
    // metricField: which per-consumption / per-line number to sum.
    var field = (o.metric === "tax") ? "tax"
              : (o.metric === "discount") ? "discountShare"
              : "net"
    var out = {}
    var orders = o.orders || []
    var alloc = o.allocate
    for (var i = 0; i < orders.length; ++i) {
        var ord = orders[i]
        if (ord.status !== "completed") continue
        var d = new Date(ord.date)
        if (!_inWindow(o.window, d)) continue
        if (o.channel && (ord.orderChannel || "") !== o.channel) continue
        if (o.staffId && (ord.staffId || "") !== o.staffId) continue
        var a = alloc(ord)
        for (var li = 0; li < a.perLine.length; ++li) {
            var pl = a.perLine[li]
            var lineCat = _categoryKey(o.productCategory, pl.productId)
            if (o.category && lineCat !== o.category) continue
            if (o.dim === "supplier") {
                var pc = pl.perConsumption || []
                for (var ci = 0; ci < pc.length; ++ci) {
                    if (o.supplierId && pc[ci].supplierId !== o.supplierId) continue
                    _add(out, _supplierKey(o.supplierName, pc[ci].supplierId), pc[ci][field] || 0)
                }
            } else { // category
                if (o.supplierId) {
                    var matched = 0
                    var pc2 = pl.perConsumption || []
                    for (var cj = 0; cj < pc2.length; ++cj)
                        if (pc2[cj].supplierId === o.supplierId) matched += (pc2[cj][field] || 0)
                    _add(out, lineCat, matched)
                } else {
                    _add(out, lineCat, pl[field] || 0)
                }
            }
        }
    }
    return out
}
```

Update the `breakdown` dispatch (lines ~74-79) so `tax`/`discount` route to `_revenue`:

```javascript
function breakdown(opts) {
    if (opts.metric === "revenue" || opts.metric === "tax" || opts.metric === "discount")
        return _revenue(opts)
    if (opts.metric === "sold")      return _sold(opts)
    if (opts.metric === "purchased") return _purchased(opts)
    return {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same command from Step 2. Expected: PASS (new case + all existing BreakdownMath cases still pass — the existing sold/purchased tests don't touch `_revenue`).

> If a pre-existing `_revenue` test asserted gross values, update it to the net expectation and note it in the commit. Re-run until green.

- [ ] **Step 5: Commit**

```bash
git add qml/helper/BreakdownMath.js tests/tst_BreakdownMath.qml
git commit -m "feat(analysis): BreakdownMath revenue uses net allocation

_revenue now sums per-line/per-consumption net (subtotal-discount) via
an injected allocate(); adds tax/discount metrics. Fixes gross-vs-net
mismatch on the by-category/by-supplier cards.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `InventoryStore.realisedProfitByDimension` — net revenue + tax/discount + supplier-axis discount

**Files:**
- Modify: `qml/model/InventoryStore.qml:174-235` (`realisedProfitByDimension`)
- Modify: `qml/model/InventoryStore.qml:241-270` (`potentialProfitByDimension` — add `tax:0`/`discount:0` for schema parity)

**Interfaces:**
- Consumes: `TransactionStore.entries` with the fields stamped in Task 5 (`net`, `tax`, `discountShare` on sale/return events) **plus** read-time fallback via `OrderMath.allocate` when those fields are absent. Import at top of file: `import "../helper/OrderMath.js" as OrderMath`.
- Produces: `{ key → { revenue, cogs, profit, tax, discount, margin } }` where `revenue` is **net**. Discount `price_adjust` (productId "") now also attributes to the `supplierId` dimension by spreading across the order's consumption rows pro-rata.

- [ ] **Step 1: Write the failing test**

This function reads the `TransactionStore` singleton and can't load headlessly. Per the pure-library rule, **add the reconciliation assertion to `tst_OrderMath.qml`** instead, proving the data `realisedProfitByDimension` will consume reconciles. Append:

```qml
    // Realised-profit building blocks: a sale event's net/cogs/profit equal the
    // allocated per-consumption values the store will sum.
    function test_event_allocation_reconciles_for_profit() {
        var o = _order([{
            productId: "P1", name: "A", price: 100, quantity: 4, taxable: true, taxPercent: 5,
            consumption: [
                { batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 60 }
            ]
        }], "flat", 20)
        var a = OM.allocate(o)
        var pc = a.perLine[0].perConsumption[0]
        // net 80, cogs 240? no: gross 400, disc 20, net 380, cogs 240, profit 140.
        compare(a.perLine[0].net, 380)
        compare(pc.cogs, 240)
        fuzzyCompare(pc.profit, 140, 0.001)
        fuzzyCompare(pc.tax, 19, 0.001)   // 380 * 5%
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderMath.qml
```
Expected: PASS already if Task 2 is correct, OR FAIL if the per-consumption tax/profit math has a gap — either way this locks the contract the store relies on. If it fails, fix `OrderMath.js` until green before editing the store.

- [ ] **Step 3: Write minimal implementation**

In `qml/model/InventoryStore.qml`, rewrite the sale/return branch of `realisedProfitByDimension` to prefer stamped fields and fall back to `allocate`. Replace the body of the `for` loop's non-`price_adjust` path (lines ~201-225) with:

```javascript
            // Net revenue + COGS per consumption row. Prefer fields stamped on
            // the event at write time (Task 5); fall back to recomputing from
            // the parent order via OrderMath when absent (older events).
            var unitPrice = e.unitPrice || 0
            var c = e.consumption || []
            var rowCategory = null
            if (field === "category") {
                var pp = getById(e.productId)
                rowCategory = (pp && pp.category) ? pp.category : "(uncategorised)"
            }
            // Resolve a per-row net/tax/discount source: stamped on the event, or
            // recomputed. The event stamps total line-level values; per
            // consumption we scale by qtyConsumed / lineQty.
            var lineQty = 0
            for (var q = 0; q < c.length; ++q) lineQty += (c[q].qtyConsumed || 0)
            var evNet = (e.net !== undefined) ? e.net : null
            var evTax = (e.tax !== undefined) ? e.tax : null
            var evDisc = (e.discountShare !== undefined) ? e.discountShare : null
            if (evNet === null) {
                // Fallback: recompute from the order.
                var parent = (typeof OrdersStore !== "undefined" && e.orderId)
                        ? OrdersStore.getById(e.orderId) : null
                if (parent) {
                    var a = OrderMath.allocate(parent)
                    for (var pli = 0; pli < a.perLine.length; ++pli) {
                        if (a.perLine[pli].productId === e.productId) {
                            evNet = a.perLine[pli].net
                            evTax = a.perLine[pli].tax
                            evDisc = a.perLine[pli].discountShare
                            break
                        }
                    }
                }
                if (evNet === null) { evNet = lineQty * unitPrice; evTax = 0; evDisc = 0 }
            }
            for (var ci = 0; ci < c.length; ++ci) {
                var cc = c[ci]
                var qty = cc.qtyConsumed || 0
                if (qty === 0) continue
                var frac = lineQty > 0 ? (qty / lineQty) : 0
                var revenue = evNet * frac
                var cogs = qty * (cc.unitCost || 0)
                var taxAmt = (evTax || 0) * frac
                var discAmt = (evDisc || 0) * frac
                var key
                if (field === "productId")      key = e.productId || ""
                else if (field === "supplierId") key = cc.supplierId || ""
                else if (field === "channel")    key = e.orderChannel || ""
                else if (field === "staffId")    key = e.staffId || ""
                else                              key = rowCategory
                if (!out[key]) out[key] = { revenue: 0, cogs: 0, profit: 0, tax: 0, discount: 0, margin: 0 }
                out[key].revenue += revenue
                out[key].cogs    += cogs
                out[key].profit  += (revenue - cogs)
                out[key].tax     += taxAmt
                out[key].discount += discAmt
            }
```

Update the `price_adjust` branch so the **supplier** dimension is no longer skipped — instead spread the delta across the order's consumption rows pro-rata. Replace the `else if (field === "supplierId") { ... continue }` block (lines ~191-195) with:

```javascript
                } else if (field === "supplierId") {
                    // Spread the revenue-correction delta across the order's
                    // consumption rows pro-rata so the supplier axis reconciles.
                    var parentO = (typeof OrdersStore !== "undefined" && e.orderId)
                            ? OrdersStore.getById(e.orderId) : null
                    if (parentO) {
                        var aa = OrderMath.allocate(parentO)
                        var totQty = 0, rows = []
                        for (var x = 0; x < aa.perLine.length; ++x)
                            for (var y = 0; y < aa.perLine[x].perConsumption.length; ++y) {
                                rows.push(aa.perLine[x].perConsumption[y])
                                totQty += aa.perLine[x].perConsumption[y].qtyConsumed
                            }
                        for (var z = 0; z < rows.length; ++z) {
                            var sk = rows[z].supplierId || ""
                            var share = totQty > 0 ? (e.total || 0) * (rows[z].qtyConsumed / totQty) : 0
                            if (!out[sk]) out[sk] = { revenue: 0, cogs: 0, profit: 0, tax: 0, discount: 0, margin: 0 }
                            out[sk].revenue += share
                            out[sk].profit  += share
                        }
                    }
                    continue
                }
```

Also add `tax: 0, discount: 0` to the `price_adjust` `out[paKey]` initializer (line ~196) and to `potentialProfitByDimension`'s `out[key]` initializer (line ~259), so all rows share the schema.

- [ ] **Step 4: Verify (manual smoke — store can't load headlessly)**

Run the OrderMath suite once more to confirm the contract still holds:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderMath.qml
```
Expected: PASS. (Full store behavior is verified in the app smoke test, Task 9.)

- [ ] **Step 5: Commit**

```bash
git add qml/model/InventoryStore.qml tests/tst_OrderMath.qml
git commit -m "feat(analysis): realised profit uses net revenue + tax/discount

Revenue=net via stamped event fields with OrderMath fallback; adds
tax/discount accumulators; discount price_adjust now attributes to the
supplier axis pro-rata so all dimensions reconcile.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Stamp allocated fields on sale/return events

**Files:**
- Modify: `qml/model/TransactionStore.qml:230-261` (`recordSaleFromOrder`)
- Modify: `qml/model/TransactionStore.qml:268-291` (`recordReturn`)

**Interfaces:**
- Consumes: `OrderMath.allocate` — import at top: `import "../helper/OrderMath.js" as OrderMath`.
- Produces: each `sale` doc gains `net`, `tax`, `discountShare` (line-level, matching `quantity`); `unitCost = inv.price` removed. Each `return` doc gains negative `net`/`tax`/`discountShare` proportional to returned qty.

- [ ] **Step 1: Write the failing test**

Stamping happens in a store method that reads `OrdersStore`/`InventoryStore` (not headless-loadable). Lock the contract in `tst_OrderMath.qml` — assert the per-line values a sale event must carry. Append:

```qml
    // The line-level net/tax/discount a sale event stamps for a whole line.
    function test_sale_event_line_stamp() {
        var o = _order([
            { productId: "P1", name: "A", price: 100, quantity: 2, taxable: true, taxPercent: 10,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 50 }] }
        ], "percent", 10)
        var a = OM.allocate(o)
        // gross 200, disc 20, net 180, tax 18.
        compare(a.perLine[0].net, 180)
        fuzzyCompare(a.perLine[0].tax, 18, 0.001)
        compare(a.perLine[0].discountShare, 20)
    }
```

- [ ] **Step 2: Run test to verify it fails / passes**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderMath.qml
```
Expected: PASS (contract already satisfied by Task 2). This guards the values the store will stamp.

- [ ] **Step 3: Write minimal implementation**

In `recordSaleFromOrder`, compute allocation once and look up each line. Replace the loop body (lines ~233-260):

```javascript
        var alloc = OrderMath.allocate(order)
        // productId → allocated perLine (line-level net/tax/discount).
        var allocByProduct = {}
        for (var ai = 0; ai < alloc.perLine.length; ++ai)
            allocByProduct[alloc.perLine[ai].productId] = alloc.perLine[ai]
        for (var i = 0; i < order.products.length; ++i) {
            var p = order.products[i]
            var qty = p.quantity || p.qty || 0
            if (!qty) continue
            var inv = p.productId ? InventoryStore.getById(p.productId) : null
            var al = allocByProduct[p.productId || ""] || { net: qty * (p.price || 0), tax: 0, discountShare: 0 }
            var doc = {
                txId: _nextId("s"),
                kind: "sale",
                timestamp: iso,
                date: order.date || Qt.formatDate(new Date(), "yyyy-MM-dd"),
                productId: p.productId || "",
                productName: p.name || (inv ? inv.name : ""),
                quantity: qty,
                unitPrice: typeof p.price === "number" ? p.price : 0,
                net: al.net,
                tax: al.tax,
                discountShare: al.discountShare,
                total: qty * (typeof p.price === "number" ? p.price : 0),
                orderId: order.orderId || "",
                orderChannel: order.orderChannel || "",
                staffId: order.staffId || "",
                consumption: Array.isArray(p.consumption) ? p.consumption.slice() : []
            }
            _push(doc)
        }
```

(Note: `unitCost` field removed from the doc — COGS comes from `consumption[].unitCost`.)

In `recordReturn`, stamp the negative allocated portion for the returned qty. After computing `unitPrice` (line ~270), add:

```javascript
        // Allocate the parent order and scale the returned line's net/tax/discount
        // to the returned qty (negative, mirroring the negative quantity/total).
        var rNet = 0, rTax = 0, rDisc = 0
        var parent = (typeof OrdersStore !== "undefined" && order && order.orderId)
                ? OrdersStore.getById(order.orderId) : null
        var src = parent || order
        if (src) {
            var ra = OrderMath.allocate(src)
            for (var ri = 0; ri < ra.perLine.length; ++ri) {
                var rl = ra.perLine[ri]
                if (rl.productId === (line.productId || "") && rl.qty > 0) {
                    var f = returnedQty / rl.qty
                    rNet = -(rl.net * f); rTax = -(rl.tax * f); rDisc = -(rl.discountShare * f)
                    break
                }
            }
        }
```

and add `net: rNet, tax: rTax, discountShare: rDisc,` to the `doc` object (next to `total`).

- [ ] **Step 4: Run test to verify it passes**

Run the OrderMath suite (Step 2 command). Expected: PASS. Store-level effect verified in Task 9 smoke test.

- [ ] **Step 5: Commit**

```bash
git add qml/model/TransactionStore.qml tests/tst_OrderMath.qml
git commit -m "feat(analysis): stamp net/tax/discount on sale & return events

recordSaleFromOrder/recordReturn now carry allocated line net, tax, and
discountShare (returns negative) so profit/revenue reports read them
without a join; drop dead unitCost=inv.price stamp.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: SalesPage on-screen revenue + profit walk use net allocation

**Files:**
- Modify: `qml/pages/SalesPage.qml:1212-1240` (`revenueOf` in `_rebuildBreakdown`)
- Modify: `qml/pages/SalesPage.qml:1633-1647` (`revenueOf` in `_binsFor`)
- Modify: `qml/pages/SalesPage.qml:1903-1972` (`_profitBucketWalk`)
- Modify: `qml/pages/SalesPage.qml:8` (add `import "../helper/OrderMath.js" as OrderMath`)
- Modify: `qml/pages/SalesPage.qml` hero block (~442-474) + `_rebuildBreakdown` Revenue tail (~1324-1334) to set `_periodTax`/`_periodDiscount`.

**Interfaces:**
- Consumes: `OrderMath.allocate`, `BreakdownMath` (Task 3 net metrics).
- Produces: on-screen Revenue hero = net; `_binsFor` Revenue = net for BOTH filtered and unfiltered (removes the `o.total` branch); `_profitBucketWalk` profit uses allocated net − cogs. New `property real _periodTax: 0`, `property real _periodDiscount: 0`.

- [ ] **Step 1: Write the failing test**

Page-level — not headless-testable. The reconciliation contract is already covered by `tst_OrderMath.qml` and `tst_BreakdownMath.qml`. Add a focused BreakdownMath case asserting filtered (supplier) revenue is also net, so the `_binsFor` parity is locked:

Append to `tests/tst_BreakdownMath.qml`:

```qml
    function test_revenue_supplier_filtered_is_net() {
        var orders = [{
            status: "completed", date: "2026-06-15T10:00:00", orderChannel: "", staffId: "",
            discountType: "flat", discountValue: 100,
            products: [{ productId: "P1", price: 100, quantity: 4, taxable: false, taxPercent: 0,
                         consumption: [{ batchId:"B1", supplierId:"S1", qtyConsumed:4, unitCost:60 }] }]
        }]
        var out = BM.breakdown({
            metric: "revenue", dim: "supplier",
            orders: orders, window: null, supplierId: "S1",
            productCategory: { "P1": "Drinks" }, supplierName: { "S1": "Acme" },
            allocate: _allocate
        })
        // gross 400, disc 100 → net 300 attributed to Acme.
        fuzzyCompare(out["Acme"], 300, 0.5)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_BreakdownMath.qml
```
Expected: PASS if Task 3 done (this guards regression). If FAIL, fix Task 3.

- [ ] **Step 3: Write minimal implementation**

Add the import (line 8 area):
```javascript
import "../helper/OrderMath.js" as OrderMath
```

Add hero state properties near the other `property real _periodTotal: 0` declarations (~line 66):
```javascript
    property real _periodTax: 0
    property real _periodDiscount: 0
```

Replace `revenueOf` inside `_rebuildBreakdown` (lines ~1212-1240) so it uses allocation:
```javascript
        var revenueOf = function(o) {
            if (_channelFilter !== "All" && (o.orderChannel || "") !== _channelFilter) return 0
            if ((_staffFilter !== "All" || !canViewAllSales) && (o.staffId || "") !== staffFilterId) return 0
            var a = OrderMath.allocate(o)
            var sum = 0
            for (var li = 0; li < a.perLine.length; ++li) {
                var pl = a.perLine[li]
                if (_categoryFilter !== "All") {
                    var p = InventoryStore.getById(pl.productId)
                    if (!p || (p.category || "") !== _categoryFilter) continue
                }
                if (filterId) {
                    var pc = pl.perConsumption || []
                    for (var ci = 0; ci < pc.length; ++ci)
                        if (pc[ci].supplierId === filterId) sum += pc[ci].net
                } else {
                    sum += pl.net
                }
            }
            return sum
        }
```

After the Revenue bins loop where `_periodTotal = total` is set (~line 1331), add tax/discount accumulation across the same in-window completed orders:
```javascript
        // Hero sublines: tax collected + discount given over the same scope.
        var _ptax = 0, _pdisc = 0
        for (var ti = 0; ti < orders.length; ++ti) {
            var to = orders[ti]
            if (to.status !== "completed") continue
            var td = new Date(to.date)
            if (isNaN(td.getTime())) continue
            if (dateWin && (td < dateWin.from || td >= dateWin.to)) continue
            var ta = OrderMath.allocate(to)
            _ptax += ta.totals.tax
            _pdisc += ta.totals.discount
        }
        _periodTax = _ptax
        _periodDiscount = _pdisc
```

Replace `revenueOf` inside `_binsFor` (lines ~1633-1647) — remove the `o.total` short-circuit so filtered and unfiltered both use net:
```javascript
        var revenueOf = function(o) {
            var a = OrderMath.allocate(o)
            var sum = 0
            for (var li = 0; li < a.perLine.length; ++li) {
                var pl = a.perLine[li]
                if (!filterId) { sum += pl.net; continue }
                var c = pl.perConsumption || []
                for (var ci = 0; ci < c.length; ++ci)
                    if (c[ci].supplierId === filterId) sum += c[ci].net
            }
            return sum
        }
```

In `_profitBucketWalk` (lines ~1960-1967), replace the consumption profit calc so it uses allocated net rather than raw `unitPrice`:
```javascript
            var a = OrderMath.allocate(OrdersStore.getById(e.orderId) || { products: [{ productId: e.productId, name: e.productName, price: e.unitPrice || 0, quantity: (function(){ var q=0; var cc=e.consumption||[]; for (var z=0; z<cc.length; ++z) q+=cc[z].qtyConsumed||0; return q })(), taxable: false, taxPercent: 0, consumption: e.consumption || [] }], discountType: "flat", discountValue: 0 })
            // Match this event's line in the allocation and bin its per-consumption profit.
            for (var pli = 0; pli < a.perLine.length; ++pli) {
                if (a.perLine[pli].productId !== e.productId) continue
                var pcs = a.perLine[pli].perConsumption
                for (var ci = 0; ci < pcs.length; ++ci) {
                    if (supplierId && pcs[ci].supplierId !== supplierId) continue
                    bins[idx] += pcs[ci].profit
                }
            }
```

(Replace the existing `var unitPrice = e.unitPrice || 0; var c = e.consumption || []; for(...) bins[idx] += qty * (unitPrice - unitCost)` block. The `price_adjust` branch above it is unchanged.)

Add the hero subline in the hero `ColumnLayout` after the `_periodSecondary` Text (~line 467):
```javascript
                    Text {
                        visible: root._viewMode === root._MODE_REVENUE
                                 && (root._periodTax > 0 || root._periodDiscount > 0)
                        text: qsTr("incl. %1 tax · %2 discount")
                              .arg(SalesStore.formatCurrency(root._periodTax))
                              .arg(SalesStore.formatCurrency(root._periodDiscount))
                        color: Qt.rgba(1,1,1,0.92)
                        font.pixelSize: sp(Constants.fsSmall)
                    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run both suites:
```bash
for t in OrderMath BreakdownMath; do
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_$t.qml; done
```
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/SalesPage.qml tests/tst_BreakdownMath.qml
git commit -m "feat(analysis): on-screen revenue & profit walk use net allocation

revenueOf (hero + export bins) and _profitBucketWalk read OrderMath net;
removes the o.total vs qty*price split (fixes filtered/unfiltered and
screen/export mismatch). Hero shows tax/discount sublines.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Restructure exports — Totals block + per-section Discount/Tax/Net columns

**Files:**
- Modify: `qml/pages/SalesPage.qml:1414-1596` (`buildAnalysisExport`)
- Modify: `qml/pages/SalesPage.qml:1841-1882` (`_exportSectionFromMap`, `_exportProfitSection`) and add `_exportNetSection`

**Interfaces:**
- Consumes: `_breakdownByDimension(metric, dim, ignorePeriod)` (now net via Task 3), `OrderMath.allocate`, `InventoryStore.realisedProfitByDimension` (Task 4 shape with `tax`/`discount`).
- Produces: every Revenue/Profit workbook starts with a "Totals" section (`Metric`,`Amount (₹)` rows: Gross, Discount, Net Revenue, Tax Collected, COGS, Profit, Margin %); category/supplier/staff/channel sections gain `Discount (₹)`,`Tax (₹)`,`Net Revenue (₹)` columns.

- [ ] **Step 1: Write the failing test**

Export builders are page-level. Lock the **Totals block math** in `tst_OrderMath.qml` — assert that summing allocations across a fixture order set yields the totals the block prints. Append:

```qml
    function test_totals_block_aggregation() {
        var orders = [
            _order([{ productId:"P1", name:"A", price:100, quantity:2, taxable:true, taxPercent:10,
                      consumption:[{batchId:"B1",supplierId:"S1",qtyConsumed:2,unitCost:60}] }], "flat", 20),
            _order([{ productId:"P2", name:"B", price:50, quantity:4, taxable:false, taxPercent:0,
                      consumption:[{batchId:"B2",supplierId:"S2",qtyConsumed:4,unitCost:30}] }], "flat", 0)
        ]
        var gross=0, disc=0, net=0, tax=0, cogs=0, profit=0
        for (var i=0;i<orders.length;++i) {
            var a = OM.allocate(orders[i])
            gross+=a.totals.gross; disc+=a.totals.discount; net+=a.totals.net
            tax+=a.totals.tax; cogs+=a.totals.cogs; profit+=a.totals.profit
        }
        compare(gross, 200 + 200)          // 400
        compare(disc, 20)
        compare(net, 380)                  // 180 + 200
        fuzzyCompare(tax, 18, 0.001)       // first order: net 180 *10%
        compare(cogs, 120 + 120)           // 240
        fuzzyCompare(profit, 380 - 240, 0.001)
    }
```

- [ ] **Step 2: Run test to verify it fails / passes**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderMath.qml
```
Expected: PASS (locks the aggregation the Totals block uses).

- [ ] **Step 3: Write minimal implementation**

Add a helper near `_exportSectionFromMap` (~line 1841):

```javascript
    // Net-section builder: a {key → {revenue, tax, discount}} map → rows with
    // Net / Discount / Tax columns and a reconciling Total row.
    function _exportNetSection(heading, rows) {
        var keys = Object.keys(rows || {})
        keys.sort(function(a, b) { return (rows[b].revenue || 0) - (rows[a].revenue || 0) })
        var out = []
        var tNet = 0, tTax = 0, tDisc = 0
        for (var i = 0; i < keys.length; ++i) {
            var r = rows[keys[i]]
            out.push([keys[i] || qsTr("(unspecified)"), r.revenue || 0, r.discount || 0, r.tax || 0])
            tNet += r.revenue || 0; tTax += r.tax || 0; tDisc += r.discount || 0
        }
        out.push([qsTr("Total"), tNet, tDisc, tTax])
        return {
            heading: heading,
            headers: [qsTr("Key"), qsTr("Net Revenue (₹)"), qsTr("Discount (₹)"), qsTr("Tax (₹)")],
            rows: out
        }
    }

    // Aggregate net/discount/tax over completed orders in the active filter
    // scope for the export Totals block.
    function _exportTotalsBlock() {
        var orders = OrdersStore.orders || []
        var gross = 0, disc = 0, net = 0, tax = 0, cogs = 0, profit = 0
        var win = _dateWindow()
        for (var i = 0; i < orders.length; ++i) {
            var o = orders[i]
            if (o.status !== "completed") continue
            var d = new Date(o.date)
            if (isNaN(d.getTime())) continue
            if (win && (d < win.from || d >= win.to)) continue
            if (_channelFilter !== "All" && (o.orderChannel || "") !== _channelFilter) continue
            var a = OrderMath.allocate(o)
            gross += a.totals.gross; disc += a.totals.discount; net += a.totals.net
            tax += a.totals.tax; cogs += a.totals.cogs; profit += a.totals.profit
        }
        var margin = cogs > 0 ? ((profit / cogs) * 100).toFixed(1) + "%" : "0%"
        return {
            heading: qsTr("Totals"),
            headers: [qsTr("Metric"), qsTr("Amount (₹)")],
            rows: [
                [qsTr("Gross sales"), gross],
                [qsTr("Discount"), disc],
                [qsTr("Net Revenue"), net],
                [qsTr("Tax Collected"), tax],
                [qsTr("COGS"), cogs],
                [qsTr("Profit"), profit],
                [qsTr("Margin %"), margin]
            ]
        }
    }
```

In `buildAnalysisExport`, for the Revenue/Sold/Purchased branch, prepend the Totals block (only meaningful for Revenue; emit it when `_viewMode === _MODE_REVENUE`) and swap the category/supplier sections to `_exportNetSection` fed by net+tax+discount maps. Replace the category/supplier append block (lines ~1584-1590) with:

```javascript
        if (root._viewMode === root._MODE_REVENUE) {
            // Build net/tax/discount maps per dimension and emit reconciling sections.
            var catNet  = _breakdownByDimension("revenue", "category", true)
            var catTax  = _breakdownByDimension("tax", "category", true)
            var catDisc = _breakdownByDimension("discount", "category", true)
            sections.push(_exportNetSection(qsTr("By category"), _mergeNetMaps(catNet, catTax, catDisc)))
            if (root.canViewSuppliers) {
                var supNet  = _breakdownByDimension("revenue", "supplier", true)
                var supTax  = _breakdownByDimension("tax", "supplier", true)
                var supDisc = _breakdownByDimension("discount", "supplier", true)
                sections.push(_exportNetSection(qsTr("By supplier"), _mergeNetMaps(supNet, supTax, supDisc)))
            }
            sections.unshift(_exportTotalsBlock())
        } else {
            // Sold / Purchased stay unit-based (no tax/discount dimension).
            sections.push(_exportSectionFromMap(qsTr("By category"),
                    [qsTr("Category"), dimUnit],
                    _breakdownByDimension(metricKey, "category", true)))
            if (root.canViewSuppliers)
                sections.push(_exportSectionFromMap(qsTr("By supplier"),
                        [qsTr("Supplier"), dimUnit],
                        _breakdownByDimension(metricKey, "supplier", true)))
        }
```

Add the `_mergeNetMaps` helper next to `_exportNetSection`:

```javascript
    // Combine three {key → number} maps (net, tax, discount) into
    // {key → {revenue, tax, discount}} for _exportNetSection.
    function _mergeNetMaps(netMap, taxMap, discMap) {
        var out = {}
        function _acc(map, field) {
            var ks = Object.keys(map || {})
            for (var i = 0; i < ks.length; ++i) {
                if (!out[ks[i]]) out[ks[i]] = { revenue: 0, tax: 0, discount: 0 }
                out[ks[i]][field] += map[ks[i]] || 0
            }
        }
        _acc(netMap, "revenue"); _acc(taxMap, "tax"); _acc(discMap, "discount")
        return out
    }
```

For the **Profit** branch (`_MODE_PROFIT`, realised), prepend `_exportTotalsBlock()` too:
after `sectionsP.push(... "By period" ...)` add `sectionsP.unshift(_exportTotalsBlock())` (so Totals is first). The existing `_exportProfitSection` already prints Revenue/COGS/Profit/Margin; extend its header/rows to also include Tax and Discount columns — update `_exportProfitSection` (lines ~1856-1882):

```javascript
    function _exportProfitSection(heading, rows) {
        var keys = Object.keys(rows || {})
        keys.sort(function(a, b) { return (rows[b].profit || 0) - (rows[a].profit || 0) })
        var out = []
        var totRev = 0, totCogs = 0, totProfit = 0, totTax = 0, totDisc = 0
        for (var i = 0; i < keys.length; ++i) {
            var r = rows[keys[i]]
            out.push([
                keys[i] || qsTr("(unspecified)"),
                r.revenue || 0, r.discount || 0, r.tax || 0,
                r.cogs || 0, r.profit || 0,
                (r.margin || 0).toFixed(1) + "%"
            ])
            totRev += r.revenue || 0; totCogs += r.cogs || 0; totProfit += r.profit || 0
            totTax += r.tax || 0; totDisc += r.discount || 0
        }
        var totalMargin = totCogs > 0 ? ((totProfit / totCogs) * 100).toFixed(1) + "%" : "0%"
        out.push([qsTr("Total"), totRev, totDisc, totTax, totCogs, totProfit, totalMargin])
        return {
            heading: heading,
            headers: [qsTr("Key"), qsTr("Net Revenue (₹)"), qsTr("Discount (₹)"),
                      qsTr("Tax (₹)"), qsTr("COGS (₹)"), qsTr("Profit (₹)"), qsTr("Margin %")],
            rows: out
        }
    }
```

- [ ] **Step 4: Run tests + manual export check**

Run the OrderMath suite (Step 2 command) — Expected: PASS. Full export rendering is verified in Task 9 (the C++ `writeAnalysis` is unchanged and already handles variable columns).

- [ ] **Step 5: Commit**

```bash
git add qml/pages/SalesPage.qml tests/tst_OrderMath.qml
git commit -m "feat(analysis): export Totals block + per-section tax/discount columns

Revenue/Profit workbooks lead with Gross/Discount/Net/Tax/COGS/Profit
totals; by-category/supplier sections gain Net/Discount/Tax columns that
reconcile to the block.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Dashboard + SalesStore net revenue; returns refund incl. tax; tax-on-edit

**Files:**
- Modify: `qml/pages/DashboardPage.qml:55-71,135-152,169-183` (revenue helpers)
- Modify: `qml/pages/DashboardPage.qml` imports (add `OrderMath`)
- Modify: `qml/model/SalesStore.qml:103-138` (`_rebuildDerivedData`)
- Modify: `qml/pages/ConfirmReturnSheet.qml:42-55` (`_impact`)
- Modify: `qml/model/DataModel.qml:432-434,455,472` (`refundAmount` uses allocated net+tax)
- Modify: `qml/pages/OrderDetailDialog.qml:_save` / qty-increment (re-tax grown line)

**Interfaces:**
- Consumes: `OrderMath.allocate`.
- Produces: Dashboard `_todayRevenue`/`_last7DaysRevenue`/`_yesterdayRevenue` and `SalesStore.totalRevenue`/`topProducts.revenue` use `allocate(o).totals.net` (and per-line net for top products). Refund = returned units' allocated `net + tax`. A completed-order line whose qty grew re-seeds `taxable`/`taxPercent` from the current product.

- [ ] **Step 1: Write the failing test**

Refund math is the testable piece. Append to `tests/tst_OrderMath.qml`:

```qml
    // Refund for returned units = their net + tax (what the customer paid).
    function test_refund_includes_tax_and_discount() {
        var o = _order([{ productId:"P1", name:"A", price:100, quantity:4, taxable:true, taxPercent:10,
                          consumption:[{batchId:"B1",supplierId:"S1",qtyConsumed:4,unitCost:50}] }], "flat", 40)
        var a = OM.allocate(o)
        // line: gross 400, disc 40, net 360, tax 36. Per unit: net 90, tax 9.
        // Return 2 units → refund = 2*(90+9) = 198.
        var pl = a.perLine[0]
        var perUnitNet = pl.net / pl.qty
        var perUnitTax = pl.tax / pl.qty
        fuzzyCompare((perUnitNet + perUnitTax) * 2, 198, 0.001)
    }
```

- [ ] **Step 2: Run test to verify it fails / passes**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderMath.qml
```
Expected: PASS (locks the refund contract).

- [ ] **Step 3: Write minimal implementation**

**DashboardPage** — add `import "../helper/OrderMath.js" as OrderMath` near the existing imports. In `_todayRevenue`, `_yesterdayRevenue`, `_last7DaysRevenue`, replace each `sum += (o.total || 0)` / `bins[...] += (o.total || 0)` with `+= OrderMath.allocate(o).totals.net`.

**SalesStore** — add `import "../helper/OrderMath.js" as OrderMath`. In `_rebuildDerivedData`, replace `revenueByMonth[m] += (o.total || 0)` and `totalRev += (co.total || 0)` with `OrderMath.allocate(o).totals.net` / `OrderMath.allocate(co).totals.net`. For `topProducts`, replace `productMap[name].revenue += qty * price` with the line's allocated net: compute `var a = OrderMath.allocate(o)` once per order, map productId→perLine, and use `perLine.net` (scaled if name-keyed) — minimal: `productMap[name].revenue += (allocByPid[p.productId] ? allocByPid[p.productId].net : qty*price)`.

**ConfirmReturnSheet `_impact`** — add `import "../helper/OrderMath.js" as OrderMath` and an `orderRef` property the opener passes; replace `revenueDelta -= d.returnedQty * d.oldPrice` with the allocated per-unit net+tax for the returned line. Minimal approach without a full order ref: keep the preview as net+tax using the line's own price and tax flag:
```javascript
            if (d.returnedQty > 0) {
                if (condition !== "damaged") stockBack += d.returnedQty
                var unitTax = (d.taxable && d.taxPercent > 0) ? d.oldPrice * (d.taxPercent/100) : 0
                revenueDelta -= d.returnedQty * (d.oldPrice + unitTax)
            }
```
(Requires `diffLines` to carry `taxable`/`taxPercent` — extend `OrderAdjust.diffLines` to copy them from the old line; add a test in `tst_OrderAdjust.qml` asserting the fields survive. This keeps the preview tax-aware without an order join.)

**DataModel `_tryAdjustOrder`** — for the refund accumulation, replace `refundAmount += d.returnedQty * d.oldPrice` (line ~434) with allocated net+tax. Compute `var alloc = OrderMath.allocate(o)` once at the top of the function, map productId→perLine, and:
```javascript
                var pl = allocByPid[d.productId]
                var perUnit = pl && pl.qty > 0 ? (pl.net + pl.tax) / pl.qty : d.oldPrice
                refundAmount += d.returnedQty * perUnit
```
Add `import "../helper/OrderMath.js" as OrderMath` (DataModel already imports OrderAdjust/StockReconcile the same way).

**OrderDetailDialog #7** — in `_save`, before building `prods`, for any line whose qty increased beyond its original, refresh tax from the current product:
```javascript
            var origQtyForTax = (function(){ var ol=_findOriginalLine(p.productId,p.name); return ol?(ol.quantity||0):0 })()
            var taxable = !!p.taxable, taxPercent = p.taxPercent || 0
            if (p.quantity > origQtyForTax) {
                var invp = InventoryStore.getById(p.productId) || InventoryStore.findByName(p.name)
                if (invp) { taxable = !!invp.taxable; taxPercent = invp.taxPercent || 0 }
            }
            prods.push({ productId: p.productId || "", name: p.name, price: p.price,
                         quantity: p.quantity, taxable: taxable, taxPercent: taxPercent })
```
(Replace the existing `prods.push` at lines ~267-270.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
for t in OrderMath OrderAdjust BreakdownMath; do
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_$t.qml; done
```
Expected: all PASS (including the new `OrderAdjust` tax-passthrough case).

- [ ] **Step 5: Commit**

```bash
git add qml/pages/DashboardPage.qml qml/model/SalesStore.qml qml/pages/ConfirmReturnSheet.qml qml/model/DataModel.qml qml/pages/OrderDetailDialog.qml qml/helper/OrderAdjust.js tests/tst_OrderMath.qml tests/tst_OrderAdjust.qml
git commit -m "feat(analysis): net revenue on dashboard; tax-aware refunds & edits

Dashboard/SalesStore revenue = net; returns refund net+tax for returned
units; growing a completed-order line re-taxes from the current product
(fixes add-tax-then-modify).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Full-suite run + app smoke verification

**Files:**
- None (verification only).

**Interfaces:**
- Consumes: all prior tasks.

- [ ] **Step 1: Run the entire test suite**

```bash
for t in OrderMath BreakdownMath OrderAdjust StockReconcile StaffScope ActivityLog; do
echo "=== tst_$t ==="
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_$t.qml; done
```
Expected: every suite prints `Totals: N passed, 0 failed, 0 skipped`.

- [ ] **Step 2: Build the app**

Run the project's configured build (per `CMakePresets.json` / the felgo-mingw-debug preset already in `build/`). Expected: compiles with no QML errors referencing `OrderMath`.

- [ ] **Step 3: Manual reconciliation smoke (documented checklist)**

With a fresh dataset, create: one order with a percent discount + a taxable product, complete it; then a second order with a flat discount. On the Analysis page:
- Revenue hero shows **net** with the `incl. ₹X tax · ₹Y discount` subline.
- Switch Revenue → by-category and by-supplier: each card's bars sum to the hero.
- Export Revenue: the **Totals** block's Net Revenue equals the hero; By-category and By-supplier Net columns each re-sum to it; Tax and Discount columns are populated.
- Profit (Realised) export: Totals Profit = Net − COGS; per-dimension Profit columns reconcile.
- Return 1 unit of the taxable product: refund preview and ledger include tax.
- Confirm the on-screen Revenue equals the exported Revenue period total for the same view/period.

Record pass/fail for each bullet in the PR description.

- [ ] **Step 4: Commit (if any verification-only doc added)**

```bash
git commit --allow-empty -m "test(analysis): full-suite green + reconciliation smoke checklist

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage**

| Spec item | Task |
|-----------|------|
| §1 OrderMath.allocate core + invariants | Tasks 1, 2 |
| §2 wiring two ledgers, stamp-at-write, drop dead unitCost | Tasks 4, 5 |
| §3 report/export Totals block + per-section columns | Task 7 |
| §3 hero net + tax/discount subline | Task 6 |
| §3 Dashboard/SalesStore net | Task 8 |
| §4 #8 refund incl. tax | Task 8 (DataModel + ConfirmReturnSheet) |
| §4 #7 tax on added units | Task 8 (OrderDetailDialog) |
| Finding #1 screen vs export | Task 6 |
| Finding #2 self-inconsistent workbook | Tasks 3, 7 |
| Finding #3 original discount in analytics | Tasks 1–6 (net everywhere) |
| Finding #4 original tax not double-counted | Tasks 3–7 |
| Finding #5 supplier filter net/gross flip | Task 6 (`_binsFor`) |
| Finding #6 discount adjust on supplier axis | Task 4 |
| Testing plan | Tasks 1–9 |
| No migration | honored — read-time fallback only |

No gaps.

**2. Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". Every code step shows code; the one prose-only step (Task 9 smoke) is verification, not code.

**3. Type consistency:** `allocate(order) → { perLine:[{ productId,name,qty,price,gross,discountShare,net,taxable,taxPercent,tax,cogs,perConsumption:[{supplierId,batchId,qtyConsumed,unitCost,net,tax,discountShare,cogs,profit}] }], totals:{ gross,discount,net,tax,cogs,total,itemCount,profit } }` — used consistently across Tasks 2–8. Event stamped fields `net`/`tax`/`discountShare` (Task 5) match the reader in Task 4. `_exportNetSection` consumes `{revenue,tax,discount}` produced by `_mergeNetMaps` (Task 7). Profit-row schema `{revenue,cogs,profit,tax,discount,margin}` consistent between Task 4 producer and Task 7 `_exportProfitSection` consumer.

> One known cross-import caveat (Task 3): `.pragma library` JS cannot `import` another JS module, so `BreakdownMath._revenue` receives `allocate` via `opts.allocate` rather than importing OrderMath directly. Tasks 6/7 pass `OrderMath.allocate` through `_breakdownByDimension`'s opts bundle — implementer must add `allocate: OrderMath.allocate` to the `BreakdownMath.breakdown({...})` call in `SalesPage._breakdownByDimension` (lines ~1359-1371). Flagged here so it isn't missed.
