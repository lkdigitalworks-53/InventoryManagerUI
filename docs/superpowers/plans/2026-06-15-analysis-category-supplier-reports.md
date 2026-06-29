# Analysis Category/Supplier Reports — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a "by category" and a "by supplier" vertical-bar chart on every Analysis view (Value, Purchased, Current, Revenue, Sold, Profit), period/filter-consistent with the hero number, and mirror them in the xlsx export.

**Architecture:** Extract the triplicated bar-chart block into one `BreakdownBarCard.qml`. Extract the *new* revenue/sold/purchased grouping math into a pure, headless-testable `BreakdownMath.js` library. `SalesPage.qml` keeps a thin `_breakdownByDimension()` wrapper that gathers live filter state and delegates to the library, then feeds the result through the existing `_topNFromMap` to produce chart rows. Value/Profit/Current already compute these breakdowns — only their visibility and property names change.

**Tech Stack:** Qt 6 / QML, Felgo, QtQuick.Layouts, QXlsx (export), `qmltestrunner.exe` (QtTest) for the JS unit test.

---

## Background the implementer needs

This app is a Felgo/QML business-management app. The "Analysis" page is **`qml/pages/SalesPage.qml`** (2,393 lines — the title bar reads "Analysis"; the file is historically named SalesPage). It has a segmented pill with six view modes:

```
_MODE_VALUE=0  _MODE_PURCHASED=1  _MODE_CURRENT=2  _MODE_REVENUE=3  _MODE_SOLD=4  _MODE_PROFIT=5
```

A single function, `_rebuildBreakdown()`, recomputes everything when the period, view, filters, or any store revision changes. It sets these page properties (among others):

- `_breakdown` — the main time-series/health chart model.
- `_stockByCategory`, `_stockByParty` — **the two breakdown cards this plan generalizes.** Despite the "stock" names they ALREADY hold category/supplier data for Value and Profit too; the cards are just hidden outside Current via `visible: root._viewMode === root._MODE_CURRENT`.
- `_periodTotal` — the hero headline number.

**Key facts (verified in source):**
- CMake globs QML with `file(GLOB_RECURSE ... CONFIGURE_DEPENDS ... qml/*.qml)` (CMakeLists.txt:36). New `.qml`/`.js` files under `qml/` are auto-packaged — **no CMakeLists edit needed.** (This is the documented Android-packaging gotcha; CONFIGURE_DEPENDS is already in place.)
- Components are used via relative imports: `import "../components"`, `import "../helper"`, `import "../model"` (SalesPage.qml:5-7). The `qml/components/qmldir` only lists the `Toast` singleton — **plain components need no qmldir entry.**
- Model singletons (`InventoryStore`, `TransactionStore`, `SupplierStore`, `OrdersStore`, etc.) are declared in `qml/model/qmldir` and expose plain `property var` data with a `revision` int.
- There is **no existing test infrastructure** in this repo. The JS unit test in Task 1 is the first; it runs standalone via `qmltestrunner.exe` (confirmed at `C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe`) and needs no CMake test target.

**Data shapes (verified):**
- Sale tx (`TransactionStore.recordSaleFromOrder`): `{ kind:"sale", timestamp, date, productId, productName, quantity, unitCost, unitPrice, total, orderId, orderChannel, staffId, consumption:[ {supplierId, qtyConsumed, unitCost}, … ] }`.
- Purchase tx (`recordPurchase`) / created tx (`recordCreated`): `{ kind:"purchase"|"created", timestamp, date, productId, party, quantity, unitCost, … , snapshot? }` — supplier is `e.party` (fallback `e.snapshot.supplierId` / `e.snapshot.party`).
- Order (`OrdersStore.orders[i]`): `{ status, date, orderChannel, staffId, products:[ {productId, name, price, quantity|qty, consumption:[ {supplierId, qtyConsumed, unitCost} ]} ] }`. Revenue counts only `status === "completed"`.
- Product (`InventoryStore.products[i]`): `{ productId, name, category, stock, minStock, price (cost), sellingPrice, … }`.

**Existing helpers reused (do not rewrite):** `_topNFromMap(map, n)`, `_namedSupplierMap(rows)`, `_dateWindow()`, `_passesCrossFilters(e)`, `_supplierIdForName(name)`, `_formatAxisValue(v)`, `_exportSectionFromMap(heading, headers, map)`, `_maxBreakdown()`, `_maxValue(arr)`. `SupplierStore.nameOf(id)` → name or undefined.

**Build & run commands (Windows, Git Bash shell):**
- Build (debug): `cmake --build --preset felgo-mingw-debug` (the build dir `build/felgo-mingw-debug` already exists; CONFIGURE_DEPENDS re-globs automatically on build).
- The compiled binary is `build/felgo-mingw-debug/appBusinessManagement.exe`. Running it requires the Felgo runtime; launch from Qt Creator with the `felgo-mingw-debug` kit, or run the exe with `C:/Felgo/Felgo/mingw_64/bin` on PATH. Manual visual verification happens here.
- JS unit test: `PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_BreakdownMath.qml`

> Note on `/graphify`: the project's existing knowledge graph covers only the C++/`functions/` layer (263 nodes, zero QML files), so it could not inform this QML work — the plan was derived by reading the QML source directly.

---

## File Structure

- **Create `qml/helper/BreakdownMath.js`** — pure, stateless `.pragma library`. Period-window math + the revenue/sold/purchased grouping. No QML imports, no singletons, no `dp()`/`sp()`. The only new business logic; fully unit-testable.
- **Create `tests/tst_BreakdownMath.qml`** — QtTest `TestCase` exercising `BreakdownMath.js`. Runs headless via `qmltestrunner`.
- **Create `qml/components/BreakdownBarCard.qml`** — reusable vertical-bar chart card (title + axis + gradient bars + optional value tips + empty state). Pure presentation; renders a model.
- **Modify `qml/pages/SalesPage.qml`** — rename two properties; replace three inline chart blocks with `BreakdownBarCard`; unhide both breakdown cards for all views; add `_breakdownTitles()` and the `_breakdownByDimension()` wrapper; populate the two properties in the Revenue/Sold/Purchased branches; extend `buildAnalysisExport()`.

No other files change. CMakeLists.txt needs no edit (CONFIGURE_DEPENDS).

---

## Task 1: Pure breakdown math library (`BreakdownMath.js`) — TDD

**Files:**
- Create: `qml/helper/BreakdownMath.js`
- Test: `tests/tst_BreakdownMath.qml`

This is the riskiest new logic (the Revenue/Sold/Purchased grouping that must sum to the hero total), so it is built test-first in isolation.

- [ ] **Step 1: Write the failing test**

Create `tests/tst_BreakdownMath.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/BreakdownMath.js" as BM

TestCase {
    name: "BreakdownMath"

    // ── periodWindow ────────────────────────────────────────────────
    function test_periodWindow_day() {
        var now = new Date(2026, 5, 15, 13, 0, 0) // 15 Jun 2026, 1pm
        var w = BM.periodWindow(0, now)
        compare(w.from.getTime(), new Date(2026, 5, 15, 0, 0, 0).getTime())
        compare(w.to.getTime(),   new Date(2026, 5, 16, 0, 0, 0).getTime())
    }
    function test_periodWindow_year() {
        var now = new Date(2026, 5, 15)
        var w = BM.periodWindow(3, now)
        compare(w.from.getTime(), new Date(2026, 0, 1).getTime())
        compare(w.to.getTime(),   new Date(2027, 0, 1).getTime())
    }

    // ── intersect ───────────────────────────────────────────────────
    function test_intersect_nulls() {
        var a = { from: new Date(2026,0,1), to: new Date(2026,1,1) }
        compare(BM.intersect(null, null), null)
        compare(BM.intersect(a, null), a)
        compare(BM.intersect(null, a), a)
    }
    function test_intersect_overlap() {
        var a = { from: new Date(2026,0,1), to: new Date(2026,5,1) }
        var b = { from: new Date(2026,3,1), to: new Date(2026,8,1) }
        var r = BM.intersect(a, b)
        compare(r.from.getTime(), new Date(2026,3,1).getTime())
        compare(r.to.getTime(),   new Date(2026,5,1).getTime())
    }

    // Shared fixtures ----------------------------------------------------
    function _productCategory() { return { "P1": "Drinks", "P2": "Snacks", "P3": "" } }
    function _supplierName()    { return { "S1": "Acme", "S2": "Beta" } }

    // ── PURCHASED ───────────────────────────────────────────────────
    function test_purchased_by_category_and_supplier_sum_equal() {
        var entries = [
            { kind:"purchase", timestamp:"2026-06-15T10:00:00", productId:"P1", party:"S1", quantity:10 },
            { kind:"created",  timestamp:"2026-06-15T11:00:00", productId:"P2", party:"S2", quantity:5 },
            { kind:"purchase", timestamp:"2026-06-15T12:00:00", productId:"P3", party:"",   quantity:3 },
            { kind:"sale",     timestamp:"2026-06-15T12:30:00", productId:"P1", quantity:99 } // ignored
        ]
        var opts = {
            metric:"purchased", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName()
        }
        var byCat = BM.breakdown(Object.assign({}, opts, { dim:"category" }))
        var bySup = BM.breakdown(Object.assign({}, opts, { dim:"supplier" }))
        compare(byCat["Drinks"], 10)
        compare(byCat["Snacks"], 5)
        compare(byCat["(uncategorised)"], 3)
        compare(bySup["Acme"], 10)
        compare(bySup["Beta"], 5)
        compare(bySup["Unknown"], 3)   // empty supplierId rolls up to "Unknown"
        compare(_sum(byCat), _sum(bySup)) // 18 == 18
    }

    // ── SOLD (FIFO consumption) ─────────────────────────────────────
    function test_sold_supplier_split_and_category_total() {
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:12,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:10}, {supplierId:"S2", qtyConsumed:2} ] }
        ]
        var opts = {
            metric:"sold", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName()
        }
        var byCat = BM.breakdown(Object.assign({}, opts, { dim:"category" }))
        var bySup = BM.breakdown(Object.assign({}, opts, { dim:"supplier" }))
        compare(byCat["Drinks"], 12)
        compare(bySup["Acme"], 10)
        compare(bySup["Beta"], 2)
        compare(_sum(byCat), _sum(bySup)) // 12 == 12
    }
    function test_sold_supplier_filter_partial_attribution() {
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:12,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:10}, {supplierId:"S2", qtyConsumed:2} ] }
        ]
        var bySup = BM.breakdown({
            metric:"sold", dim:"supplier", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"S1",
            productCategory:_productCategory(), supplierName:_supplierName()
        })
        compare(bySup["Acme"], 10) // only Acme's 10 units, not 12
        verify(bySup["Beta"] === undefined)
    }

    // ── REVENUE ─────────────────────────────────────────────────────
    function test_revenue_category_total_equals_lines() {
        var orders = [
            { status:"completed", date:"2026-06-15", orderChannel:"", staffId:"",
              products:[
                { productId:"P1", price:100, quantity:2,
                  consumption:[ {supplierId:"S1", qtyConsumed:2} ] },
                { productId:"P2", price:50, quantity:3,
                  consumption:[ {supplierId:"S2", qtyConsumed:3} ] }
              ] },
            { status:"pending", date:"2026-06-15", products:[ { productId:"P1", price:100, quantity:9 } ] } // ignored
        ]
        var opts = {
            metric:"revenue", entries:[], orders:orders,
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName()
        }
        var byCat = BM.breakdown(Object.assign({}, opts, { dim:"category" }))
        var bySup = BM.breakdown(Object.assign({}, opts, { dim:"supplier" }))
        compare(byCat["Drinks"], 200) // 2 * 100
        compare(byCat["Snacks"], 150) // 3 * 50
        compare(bySup["Acme"], 200)
        compare(bySup["Beta"], 150)
        compare(_sum(byCat), 350)
        compare(_sum(byCat), _sum(bySup))
    }

    function _sum(map) {
        var t = 0, ks = Object.keys(map)
        for (var i = 0; i < ks.length; ++i) t += map[ks[i]]
        return t
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_BreakdownMath.qml
```
Expected: FAIL — `BreakdownMath.js` does not exist / `periodWindow is not a function`.

- [ ] **Step 3: Write the implementation**

Create `qml/helper/BreakdownMath.js`:

```javascript
.pragma library

// Pure breakdown math for the Analysis page. No QML imports, no singletons,
// no dp()/sp() — everything needed is passed in. Keeps the heavy grouping
// logic out of SalesPage.qml and makes it unit-testable via qmltestrunner.

// [from, to) window for a period index relative to `now`.
//   0=Day(today)  1=Week(Mon–Sun)  2=Month  3=Year
function periodWindow(periodIdx, now) {
    if (periodIdx === 0) {
        var d0 = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        return { from: d0, to: new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1) }
    } else if (periodIdx === 1) {
        var monday = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        var dow = (monday.getDay() + 6) % 7 // 0=Mon..6=Sun
        monday.setDate(monday.getDate() - dow)
        var next = new Date(monday); next.setDate(monday.getDate() + 7)
        return { from: monday, to: next }
    } else if (periodIdx === 2) {
        return { from: new Date(now.getFullYear(), now.getMonth(), 1),
                 to:   new Date(now.getFullYear(), now.getMonth() + 1, 1) }
    }
    return { from: new Date(now.getFullYear(), 0, 1),
             to:   new Date(now.getFullYear() + 1, 0, 1) }
}

// Intersect two [from,to) windows. null = unbounded. Returns null only when
// both are null. An empty result (from >= to) filters everything out.
function intersect(a, b) {
    if (!a && !b) return null
    if (!a) return b
    if (!b) return a
    var from = a.from.getTime() >= b.from.getTime() ? a.from : b.from
    var to   = a.to.getTime()   <= b.to.getTime()   ? a.to   : b.to
    return { from: from, to: to }
}

function _inWindow(win, dateObj) {
    if (!win) return true
    var t = dateObj.getTime()
    if (isNaN(t)) return false
    return t >= win.from.getTime() && t < win.to.getTime()
}

function _categoryKey(productCategory, productId) {
    var c = productCategory[productId]
    return (c && c.length) ? c : "(uncategorised)"
}

function _supplierKey(supplierName, supplierId) {
    if (!supplierId) return "Unknown"
    return supplierName[supplierId] || "(removed)"
}

function _add(out, key, value) {
    if (value === 0) return
    out[key] = (out[key] || 0) + value
}

// Group + sum a metric by a dimension. Returns { key -> number }.
// opts = {
//   metric: "revenue"|"sold"|"purchased",
//   dim:    "category"|"supplier",
//   orders: [],            // revenue
//   entries: [],           // sold / purchased
//   window: {from,to}|null,// period ∩ date-filter (already intersected)
//   channel: "",           // "" = all (order/sale level)
//   staffId: "",           // "" = all (resolved id, not name)
//   category: "",          // "" = all (cross-filter, product category)
//   supplierId: "",        // "" = all (supplier filter, resolved id)
//   productCategory: {},   // productId -> category string
//   supplierName: {}       // supplierId -> display name
// }
function breakdown(opts) {
    if (opts.metric === "revenue")   return _revenue(opts)
    if (opts.metric === "sold")      return _sold(opts)
    if (opts.metric === "purchased") return _purchased(opts)
    return {}
}

function _revenue(o) {
    var out = {}
    var orders = o.orders || []
    for (var i = 0; i < orders.length; ++i) {
        var ord = orders[i]
        if (ord.status !== "completed") continue
        var d = new Date(ord.date)
        if (!_inWindow(o.window, d)) continue
        if (o.channel && (ord.orderChannel || "") !== o.channel) continue
        if (o.staffId && (ord.staffId || "") !== o.staffId) continue
        var lines = ord.products || []
        for (var li = 0; li < lines.length; ++li) {
            var ln = lines[li]
            var lineCat = _categoryKey(o.productCategory, ln.productId)
            if (o.category && lineCat !== o.category) continue
            var price = (typeof ln.price === "number") ? ln.price : 0
            var cons = ln.consumption || []
            if (o.dim === "supplier") {
                // Attribute each consumption row's qty*price to its supplier.
                for (var ci = 0; ci < cons.length; ++ci) {
                    var c = cons[ci]
                    if (o.supplierId && c.supplierId !== o.supplierId) continue
                    _add(out, _supplierKey(o.supplierName, c.supplierId),
                         (c.qtyConsumed || 0) * price)
                }
            } else { // category
                if (o.supplierId) {
                    // Supplier filter: only the matched consumption qty counts.
                    var matched = 0
                    for (var cj = 0; cj < cons.length; ++cj)
                        if (cons[cj].supplierId === o.supplierId) matched += (cons[cj].qtyConsumed || 0)
                    _add(out, lineCat, matched * price)
                } else {
                    var qty = ln.quantity || ln.qty || 0
                    _add(out, lineCat, qty * price)
                }
            }
        }
    }
    return out
}

function _sold(o) {
    var out = {}
    var entries = o.entries || []
    for (var i = 0; i < entries.length; ++i) {
        var e = entries[i]
        if (e.kind !== "sale") continue
        var d = new Date(e.timestamp || e.date)
        if (!_inWindow(o.window, d)) continue
        if (o.channel && (e.orderChannel || "") !== o.channel) continue
        if (o.staffId && (e.staffId || "") !== o.staffId) continue
        var cat = _categoryKey(o.productCategory, e.productId)
        if (o.category && cat !== o.category) continue
        var cons = e.consumption || []
        if (o.dim === "supplier") {
            for (var ci = 0; ci < cons.length; ++ci) {
                var c = cons[ci]
                if (o.supplierId && c.supplierId !== o.supplierId) continue
                _add(out, _supplierKey(o.supplierName, c.supplierId), c.qtyConsumed || 0)
            }
        } else { // category
            if (o.supplierId) {
                var matched = 0
                for (var cj = 0; cj < cons.length; ++cj)
                    if (cons[cj].supplierId === o.supplierId) matched += (cons[cj].qtyConsumed || 0)
                _add(out, cat, matched)
            } else {
                _add(out, cat, e.quantity || 0)
            }
        }
    }
    return out
}

function _purchased(o) {
    var out = {}
    var entries = o.entries || []
    for (var i = 0; i < entries.length; ++i) {
        var e = entries[i]
        if (e.kind !== "purchase" && e.kind !== "created") continue
        var d = new Date(e.timestamp || e.date)
        if (!_inWindow(o.window, d)) continue
        var pid = e.party || (e.snapshot ? (e.snapshot.supplierId || e.snapshot.party || "") : "")
        if (o.supplierId && pid !== o.supplierId) continue
        var cat = _categoryKey(o.productCategory, e.productId)
        if (o.category && cat !== o.category) continue
        var qty = e.quantity || 0
        if (o.dim === "supplier") _add(out, _supplierKey(o.supplierName, pid), qty)
        else                      _add(out, cat, qty)
    }
    return out
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_BreakdownMath.qml
```
Expected: PASS — all `test_*` cases green (`Totals: 8 passed, 0 failed` or similar).

- [ ] **Step 5: Commit**

```bash
git add qml/helper/BreakdownMath.js tests/tst_BreakdownMath.qml
git commit -m "feat(analysis): pure category/supplier breakdown math + unit tests"
```

---

## Task 2: Reusable `BreakdownBarCard.qml` (pure extraction)

**Files:**
- Create: `qml/components/BreakdownBarCard.qml`

Extract the vertical-bar chart visual that is currently copy-pasted three times in SalesPage.qml (Stock-by-category ~L527-619, Purchases-by-party ~L622-725, main Breakdown ~L731-856). The component reproduces the existing look exactly: card chrome, a `dp(28)`-wide y-axis with max / max÷2 / 0, gradient bars with animated height, elided labels, optional per-bar value tips, and a centered empty message.

- [ ] **Step 1: Create the component**

Create `qml/components/BreakdownBarCard.qml`:

```qml
import QtQuick
import QtQuick.Layouts

import "../helper"

// Vertical-bar breakdown chart used across every Analysis view. Pure
// presentation — it renders `model` ([{ label, value, fullLabel }]) and
// computes its own max. The page supplies the title, colours, and units.
ColumnLayout {
    id: root

    property string title: ""
    property var    model: []
    property bool   currency: false   // ₹ prefix on axis + value tips
    property string emptyText: ""
    property var    barTop: Constants.brand3      // gradient start (top)
    property var    barBottom: Constants.brand2   // gradient end (bottom)
    property real   chartHeight: dp(180)
    property bool   showValueTips: false          // per-bar value caption

    spacing: dp(Constants.space2)
    Layout.fillWidth: true

    function _maxValue() {
        var m = 0
        var src = root.model || []
        for (var i = 0; i < src.length; ++i)
            if (src[i].value > m) m = src[i].value
        return m
    }

    // Compact axis label — mirrors SalesPage._formatAxisValue.
    function _formatAxis(v) {
        if (v === undefined || v === null || isNaN(v)) v = 0
        var n = Math.round(v)
        var compact
        if (Math.abs(n) >= 1e6) compact = (n / 1e6).toFixed(1) + "M"
        else if (Math.abs(n) >= 1e3) compact = (n / 1e3).toFixed(1) + "k"
        else compact = String(n)
        return root.currency ? "₹" + compact : compact
    }

    Text {
        text: root.title
        color: Constants.textPrimary
        font.pixelSize: sp(Constants.fsBodyLg)
        font.bold: true
        visible: root.title.length > 0
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: root.chartHeight
        radius: dp(Constants.radius)
        color: Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1

        // Centered placeholder when there's nothing to chart.
        Text {
            anchors.centerIn: parent
            width: parent.width - dp(Constants.space4 * 2)
            visible: (root.model || []).length === 0 && root.emptyText.length > 0
            text: root.emptyText
            color: Constants.textMuted
            font.pixelSize: sp(Constants.fsCaption)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }

        Item {
            id: yAxis
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: dp(Constants.space3)
            anchors.topMargin: dp(Constants.space3)
            anchors.bottomMargin: dp(Constants.space3) + dp(20)
            width: dp(28)
            visible: (root.model || []).length > 0
            Text {
                anchors.right: parent.right; anchors.top: parent.top
                text: root._formatAxis(root._maxValue())
                color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
            }
            Text {
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                text: root._formatAxis(root._maxValue() / 2)
                color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
            }
            Text {
                anchors.right: parent.right; anchors.bottom: parent.bottom
                text: "0"; color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
            }
        }

        RowLayout {
            anchors.left: yAxis.right
            anchors.leftMargin: dp(Constants.space2)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.rightMargin: dp(Constants.space3)
            anchors.topMargin: dp(Constants.space3)
            anchors.bottomMargin: dp(Constants.space3)
            spacing: dp(6)
            visible: (root.model || []).length > 0

            Repeater {
                model: root.model
                delegate: ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: dp(4)
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            radius: dp(Constants.radiusSm)
                            height: Math.max(dp(6), parent.height *
                                    Math.min(1, modelData.value /
                                        Math.max(1, root._maxValue())))
                            gradient: Gradient {
                                orientation: Gradient.Vertical
                                GradientStop { position: 0.0; color: root.barTop }
                                GradientStop { position: 1.0; color: root.barBottom }
                            }
                            Behavior on height { NumberAnimation { duration: Constants.durMed } }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: dp(2)
                            visible: root.showValueTips && modelData.value > 0
                                     && parent.height > dp(40)
                                     && (modelData.value / Math.max(1, root._maxValue())) > 0.18
                            text: root._formatAxis(modelData.value)
                            color: Constants.textOnBrand
                            font.pixelSize: sp(Constants.fsCaption)
                            font.bold: true
                        }
                    }
                    Text {
                        text: modelData.label
                        color: Constants.textSecondary
                        font.pixelSize: sp(Constants.fsCaption)
                        Layout.alignment: Qt.AlignHCenter
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cmake --build --preset felgo-mingw-debug`
Expected: build succeeds, no QML compile errors mentioning `BreakdownBarCard.qml`. (The component isn't used yet — this just confirms it parses and the new file is globbed in.)

- [ ] **Step 3: Commit**

```bash
git add qml/components/BreakdownBarCard.qml
git commit -m "feat(analysis): add reusable BreakdownBarCard chart component"
```

---

## Task 3: Rename properties + route the three existing charts through `BreakdownBarCard`

**Files:**
- Modify: `qml/pages/SalesPage.qml`

Pure refactor — no behavioral change. Rename `_stockByCategory` → `_breakdownByCategory` and `_stockByParty` → `_breakdownBySupplier` at all sites, then replace the three inline chart blocks with `BreakdownBarCard`. After this task the Current view must look identical to before.

- [ ] **Step 1: Rename the two property declarations**

In `qml/pages/SalesPage.qml` (around L64-65):

```qml
    // Current-view-only datasets, populated alongside _breakdown.
    property var _breakdownByCategory: []
    property var _breakdownBySupplier: []
```

- [ ] **Step 2: Rename all remaining read/write sites**

Replace every other occurrence of `_stockByCategory` with `_breakdownByCategory` and `_stockByParty` with `_breakdownBySupplier`. The sites (verified) are:
- `_stockByCategory`: L559, L564, L584, L599, L1076, L1174, L1213, L1329
- `_stockByParty`: L656, L661, L681, L696, L717, L1078, L1175, L1214, L1330

Use a find-replace across the file for the two identifiers. Verify zero remain:

```bash
grep -n "_stockByCategory\|_stockByParty" qml/pages/SalesPage.qml
```
Expected: no output.

- [ ] **Step 3: Replace the "Stock by category" chart block with the component**

Replace the entire `ColumnLayout { … }` for the category chart (the block beginning with the comment `// ── Current-view: Stock by category chart ──`, ~L526-619) with:

```qml
            // ── By-category breakdown (all views) ──
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root._viewMode === root._MODE_CURRENT
                title: qsTr("Stock by category")
                model: root._breakdownByCategory
                currency: root._isCurrency
                barTop: Constants.brand3
                barBottom: Constants.brand2
            }
```

(The `visible`/`title` become view-aware in Task 4; this keeps Current-only behavior for now so this task stays a no-op refactor.)

- [ ] **Step 4: Replace the "Purchases by party" chart block with the component**

Replace the entire `ColumnLayout { … }` for the party chart (begins with `// ── Current-view: Stock by party chart ──`, ~L621-725, including the trailing empty-state `Text`) with:

```qml
            // ── By-supplier breakdown (all views) ──
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root._viewMode === root._MODE_CURRENT
                title: qsTr("Purchases by party")
                model: root._breakdownBySupplier
                currency: root._isCurrency
                barTop: Constants.brand4
                barBottom: Constants.brand5
                emptyText: qsTr("No supplier purchases recorded yet — capture a supplier on your next restock.")
            }
```

- [ ] **Step 5: Replace the main "Breakdown" chart block with the component**

Replace the main breakdown `ColumnLayout { … }` (begins with the comment `// Breakdown bars — title flips per view.`, ~L727-856) with:

```qml
            // Main breakdown — time series for Revenue/Sold/Purchased, top-N
            // for Value/Profit, stock-health for Current. Title flips per view.
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                title: root._viewMode === root._MODE_CURRENT ? qsTr("Stock health") : qsTr("Breakdown")
                model: root._breakdown
                currency: root._isCurrency
                chartHeight: dp(200)
                showValueTips: true
                barTop: Constants.brand2
                barBottom: Constants.brand1
            }
```

- [ ] **Step 6: Build**

Run: `cmake --build --preset felgo-mingw-debug`
Expected: build succeeds, no QML errors.

- [ ] **Step 7: Run and visually verify (no regression)**

Launch the app (Qt Creator, `felgo-mingw-debug` kit, or run `build/felgo-mingw-debug/appBusinessManagement.exe` with `C:/Felgo/Felgo/mingw_64/bin` on PATH). Go to the Analysis tab. Verify in **Current** view: "Stock by category", "Purchases by party", and "Stock health" charts render exactly as before (gradient bars, axis labels, value tips on the health chart). Switch to Value/Profit and confirm the main Breakdown still renders. No category/supplier cards yet appear outside Current — that's expected.

- [ ] **Step 8: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "refactor(analysis): route the three bar charts through BreakdownBarCard, rename breakdown props"
```

---

## Task 4: View-aware titles + show both breakdown cards on every view

**Files:**
- Modify: `qml/pages/SalesPage.qml`

Value, Profit, and Current already populate `_breakdownByCategory`/`_breakdownBySupplier` — so simply unhiding the two cards and giving them view-aware titles immediately lights up category/supplier charts for those three views. Revenue/Sold/Purchased will show empty until Task 5 fills the data.

- [ ] **Step 1: Add the `_breakdownTitles()` helper**

Add this function next to the other helpers in `SalesPage.qml` (e.g. just after `_maxBreakdown()`, ~L1547):

```qml
    // Per-view titles for the two breakdown cards. Wording lives in one place
    // so the cards stay declarative.
    function _breakdownTitles() {
        switch (_viewMode) {
        case _MODE_VALUE:     return { category: qsTr("Value by category"),         supplier: qsTr("Value by supplier") }
        case _MODE_PURCHASED: return { category: qsTr("Purchased units by category"),supplier: qsTr("Purchased units by supplier") }
        case _MODE_CURRENT:   return { category: qsTr("Stock by category"),          supplier: qsTr("Purchases by party") }
        case _MODE_REVENUE:   return { category: qsTr("Revenue by category"),        supplier: qsTr("Revenue by supplier") }
        case _MODE_SOLD:      return { category: qsTr("Units sold by category"),     supplier: qsTr("Units sold by supplier") }
        case _MODE_PROFIT:    return { category: qsTr("Profit by category"),         supplier: qsTr("Profit by supplier") }
        }
        return { category: qsTr("By category"), supplier: qsTr("By supplier") }
    }
```

- [ ] **Step 2: Make the by-category card visible on all views with a view-aware title**

In the by-category `BreakdownBarCard` (from Task 3 Step 3), change `visible` and `title`:

```qml
                visible: (root._breakdownByCategory || []).length > 0
                title: root._breakdownTitles().category
```

> Intentional asymmetry: the **category** card simply hides when its model is empty
> (every product has a category — "(uncategorised)" at worst — so an empty category
> breakdown means there's genuinely no data for the period, and hiding is cleaner than a
> message). The **supplier** card instead shows an empty-state message (Step 3), because
> missing supplier lineage (e.g. pre-FIFO sales) is a meaningful state the user should see
> explained rather than have the card vanish. This matches the existing "Purchases by party"
> empty-state behavior.

- [ ] **Step 3: Make the by-supplier card visible on all views with a view-aware title + empty text**

In the by-supplier `BreakdownBarCard` (Task 3 Step 4), change `visible`, `title`, and `emptyText`:

```qml
                visible: root._viewMode === root._MODE_CURRENT
                         || (root._breakdownBySupplier || []).length > 0
                         || root._supplierBreakdownApplies()
                title: root._breakdownTitles().supplier
                emptyText: root._viewMode === root._MODE_CURRENT
                           ? qsTr("No supplier purchases recorded yet — capture a supplier on your next restock.")
                           : qsTr("No supplier data for this period.")
```

- [ ] **Step 4: Add the `_supplierBreakdownApplies()` helper**

So the supplier card shows its friendly empty-state (instead of vanishing) on views where supplier data is meaningful but currently empty. Add near `_breakdownTitles()`:

```qml
    // True for views where a supplier breakdown is meaningful — so the card
    // shows its empty-state message rather than disappearing when there's no
    // supplier lineage yet (e.g. pre-FIFO sales).
    function _supplierBreakdownApplies() {
        return _viewMode === _MODE_VALUE
            || _viewMode === _MODE_REVENUE
            || _viewMode === _MODE_SOLD
            || _viewMode === _MODE_PURCHASED
            || _viewMode === _MODE_PROFIT
    }
```

- [ ] **Step 5: Build**

Run: `cmake --build --preset felgo-mingw-debug`
Expected: build succeeds.

- [ ] **Step 6: Run and verify Value / Profit / Current**

Launch the app → Analysis. Verify:
- **Value:** "Value by category" and "Value by supplier" bar charts now appear (₹ axis), populated from existing `valueByCategory()`/`valueBySupplier()`.
- **Profit** (both Realised and Potential): "Profit by category"/"Profit by supplier" appear.
- **Current:** unchanged ("Stock by category"/"Purchases by party").
- **Revenue/Sold/Purchased:** category card hidden (empty), supplier card shows "No supplier data for this period." (data arrives in Task 5).

- [ ] **Step 7: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat(analysis): show category/supplier breakdown cards on all views with view-aware titles"
```

---

## Task 5: Populate category/supplier breakdowns for Revenue, Sold, Purchased

**Files:**
- Modify: `qml/pages/SalesPage.qml`

Add the `_breakdownByDimension()` wrapper that gathers live filter state and delegates to `BreakdownMath.breakdown`, then fill the two properties in the three time-based branches of `_rebuildBreakdown()`.

- [ ] **Step 1: Add the import for the math library**

At the top of `qml/pages/SalesPage.qml`, after the existing imports (L1-7), add:

```qml
import "../helper/BreakdownMath.js" as BreakdownMath
```

- [ ] **Step 2: Add the `_breakdownByDimension()` wrapper**

Add near `_breakdownTitles()` in `SalesPage.qml`:

```qml
    // Build the live opts bundle and delegate the grouping to BreakdownMath.
    // metric ∈ "revenue"|"sold"|"purchased"; dim ∈ "category"|"supplier".
    // ignorePeriod=true skips the period window (used by the export, whose
    // category/supplier sections are filter-scoped totals, not single-period).
    // Returns a { key -> number } map; callers wrap it with _topNFromMap.
    function _breakdownByDimension(metric, dim, ignorePeriod) {
        // Window = period ∩ date-filter (or just date-filter when ignoring period).
        var periodWin = ignorePeriod ? null : BreakdownMath.periodWindow(_period, new Date())
        var win = BreakdownMath.intersect(periodWin, _dateWindow())

        // Resolve staff name → id once (mirrors _passesCrossFilters).
        var staffId = ""
        if (_staffFilter !== "All") {
            var roster = StaffStore.staff || []
            for (var si = 0; si < roster.length; ++si)
                if (roster[si].name === _staffFilter) { staffId = roster[si].staffId || ""; break }
        }

        // productId → category, supplierId → name lookup maps.
        var productCategory = {}
        var inv = InventoryStore.products || []
        for (var pi = 0; pi < inv.length; ++pi)
            productCategory[inv[pi].productId] = inv[pi].category || ""
        var supplierName = {}
        var sup = SupplierStore.suppliers || []
        for (var sj = 0; sj < sup.length; ++sj)
            supplierName[sup[sj].supplierId] = sup[sj].name

        return BreakdownMath.breakdown({
            metric: metric,
            dim: dim,
            orders: OrdersStore.orders || [],
            entries: TransactionStore.entries || [],
            window: win,
            channel: _channelFilter === "All" ? "" : _channelFilter,
            staffId: staffId,
            category: _categoryFilter === "All" ? "" : _categoryFilter,
            supplierId: _partyFilter !== "All" ? _supplierIdForName(_partyFilter) : "",
            productCategory: productCategory,
            supplierName: supplierName
        })
    }
```

- [ ] **Step 3: Fill the two properties in the Sold branch**

In `_rebuildBreakdown()`, the Sold branch (`if (_viewMode === _MODE_SOLD)`) ends by setting `_periodTotal`/`_periodLabel`/`_periodCompare` then `return` (~L1359-1364). Immediately before that `return`, add:

```qml
            _breakdownByCategory = _topNFromMap(_breakdownByDimension("sold", "category", false), 8)
            _breakdownBySupplier = _topNFromMap(_breakdownByDimension("sold", "supplier", false), 8)
```

- [ ] **Step 4: Fill the two properties in the Purchased branch**

In the Purchased branch (`if (_viewMode === _MODE_PURCHASED)`), immediately before its `return` (~L1400), add:

```qml
            _breakdownByCategory = _topNFromMap(_breakdownByDimension("purchased", "category", false), 8)
            _breakdownBySupplier = _topNFromMap(_breakdownByDimension("purchased", "supplier", false), 8)
```

- [ ] **Step 5: Fill the two properties in the Revenue branch**

The Revenue branch is the function's fall-through tail; it ends with `_breakdown = arr` then `_periodTotal = total` (~L1538-1539) and the function closes. Immediately after `_periodTotal = total`, add:

```qml
        _breakdownByCategory = _topNFromMap(_breakdownByDimension("revenue", "category", false), 8)
        _breakdownBySupplier = _topNFromMap(_breakdownByDimension("revenue", "supplier", false), 8)
```

- [ ] **Step 6: Build**

Run: `cmake --build --preset felgo-mingw-debug`
Expected: build succeeds.

- [ ] **Step 7: Run and verify sums match the hero**

Launch → Analysis. With some completed orders and restocks present:
- **Revenue:** "Revenue by category"/"Revenue by supplier" bars appear. The sum of the category bars should equal the hero "Revenue this <period>" number for the same period/filters. Change the period pill (Day/Week/Month/Year) and confirm the breakdowns re-scale with the hero.
- **Sold:** "Units sold by category"/"by supplier" appear; category sum equals the hero units.
- **Purchased:** "Purchased units by category"/"by supplier" appear; both sum to the hero.
- Apply a supplier chip / category filter and confirm the breakdowns and hero move together.
- Supplier card shows the empty-state message only when there's genuinely no supplier lineage (e.g. all pre-FIFO sales).

- [ ] **Step 8: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat(analysis): period/filter-aware category & supplier breakdowns for revenue, sold, purchased"
```

---

## Task 6: Add category/supplier sections to the Revenue/Sold/Purchased export

**Files:**
- Modify: `qml/pages/SalesPage.qml`

`buildAnalysisExport()` already emits four period tables for Revenue/Sold/Purchased (the `sections` array built ~L1694-1715). Append two more sections — "By category" and "By supplier" — built from `_breakdownByDimension(metric, dim, /*ignorePeriod*/ true)` via the existing `_exportSectionFromMap`. These are filter-scoped totals (not single-period), consistent with how Value/Profit export sections already work.

- [ ] **Step 1: Append the two sections before the export return**

In `buildAnalysisExport()`, locate the Revenue/Sold/Purchased tail where `sections` has been filled by the `periodMeta` loop, just before:

```qml
        return {
            title: titleMap[root._viewMode] + partyTag,
            suggestedName: "analysis_" + (titleMap[root._viewMode] || "report").toLowerCase() + "_" + stamp + ".xlsx",
            sections: sections
        }
```

Insert immediately above that `return`:

```qml
        // Category + supplier breakdowns mirror the on-screen cards. Filter-
        // scoped totals (ignorePeriod) — the period tables above already cover
        // the time dimension, so these summarise across the active filters.
        var metricKey = root._viewMode === root._MODE_REVENUE ? "revenue"
                      : root._viewMode === root._MODE_SOLD ? "sold" : "purchased"
        var dimUnit = root._viewMode === root._MODE_REVENUE ? qsTr("Amount (₹)") : qsTr("Units")
        sections.push(_exportSectionFromMap(qsTr("By category"),
                [qsTr("Category"), dimUnit],
                _breakdownByDimension(metricKey, "category", true)))
        sections.push(_exportSectionFromMap(qsTr("By supplier"),
                [qsTr("Supplier"), dimUnit],
                _breakdownByDimension(metricKey, "supplier", true)))
```

- [ ] **Step 2: Build**

Run: `cmake --build --preset felgo-mingw-debug`
Expected: build succeeds.

- [ ] **Step 3: Run and verify the exported workbook**

Launch → Analysis → Revenue view → tap the export (share) icon → save the xlsx. Open it and confirm: the four period sheets/sections are present AND two new sections, "By category" and "By supplier", each ending in a Total row. Repeat for Sold and Purchased (units). Confirm Value and Profit exports are unchanged (they already had these sections).

- [ ] **Step 4: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat(analysis): add category & supplier sections to revenue/sold/purchased export"
```

---

## Task 7: Final verification sweep

**Files:** none (verification only)

- [ ] **Step 1: Re-run the unit test**

```bash
PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_BreakdownMath.qml
```
Expected: all green.

- [ ] **Step 2: Confirm no stale identifiers remain**

```bash
grep -n "_stockByCategory\|_stockByParty" qml/pages/SalesPage.qml
```
Expected: no output.

- [ ] **Step 3: Clean build**

Run: `cmake --build --preset felgo-mingw-debug`
Expected: build succeeds with no QML errors/warnings about the touched files.

- [ ] **Step 4: Full manual checklist (launch the app, Analysis tab)**

Verify for **every** view (Value, Purchased, Current, Revenue, Sold, Profit):
- Both a "by category" and a "by supplier" chart render with correct view-aware titles and correct units (₹ for Value/Revenue/Profit; counts otherwise).
- Breakdown bar sums track the hero number as the period pill and filters change.
- Supplier card shows the friendly empty-state (not a blank axis) where there's no lineage.
- Export for Revenue/Sold/Purchased contains the two new sections; Value/Profit unchanged.
- Switch views rapidly and toggle Realised/Potential in Profit — no binding errors in the console.

- [ ] **Step 5: Final commit (if any checklist fixes were needed)**

```bash
git add -A
git commit -m "fix(analysis): address verification findings for category/supplier reports"
```

---

## Self-review notes (for the implementer)

- **Spec coverage:** Task 2 → component extraction; Task 3 → property rename + dedup; Task 4 → all-views visibility + titles; Task 5 → new period/filter-aware aggregators; Task 6 → export. Task 1 covers the spec's testing requirement (made runnable by extracting pure math to `BreakdownMath.js`).
- **Refinement vs. spec:** the spec described `_breakdownByDimension` as a SalesPage method. To satisfy the spec's own "test that breakdowns sum to the hero" requirement in a repo with no test harness, the pure math lives in `BreakdownMath.js` (headless-testable) and the SalesPage method is a thin wrapper. Behavior is identical to the spec; only the seam moved. Flag this to the user if it matters.
- **Type/name consistency:** properties are `_breakdownByCategory` / `_breakdownBySupplier` everywhere; the library entry point is `BreakdownMath.breakdown(opts)`; the wrapper is `_breakdownByDimension(metric, dim, ignorePeriod)` returning a `{key→number}` map wrapped by `_topNFromMap`. Export uses `ignorePeriod=true`; on-screen uses `false`.
- **No CMake change:** new `.qml`/`.js` under `qml/` are auto-globbed (CONFIGURE_DEPENDS). `tests/` is outside `qml/` so it is NOT packaged into the app — correct, it's test-only.
