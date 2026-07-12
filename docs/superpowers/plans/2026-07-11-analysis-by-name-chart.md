# By-name Analysis Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a mandatory "by product name" bar chart to all six Analysis reports, with fixed
card order name → supplier → category, reusing existing per-mode data wherever already correct.

**Architecture:** `BreakdownMath.js` (and its Node mirror) gains a third `dim: "name"` alongside
the existing `"category"`/`"supplier"`, used only by Sold/Purchased. Revenue's by-name path
reuses the existing `InventoryStore.realisedProfitByDimension("productId", ...)` call already
proven by Profit→Realised. `SalesPage.qml` wires `_topByName` for the three modes that lack it,
adds a title, reorders the three `BreakdownBarCard` instances, and suppresses the old 4th card
only where it would otherwise duplicate the new one (Value, Profit→Potential).

**Tech Stack:** Felgo/Qt Quick QML, `.pragma library` JS helpers, Qt Quick Test (`qmltestrunner`,
Windows/Felgo-only — not runnable in this Cloud sandbox), Node.js `node:test` (runnable here via
`cd functions && npm test`).

## Global Constraints

- Every dimension (name/supplier/category), every mode: capped to top 8 by value, via
  `_topNFromMap(obj, 8)` / `_profitTopN(rows, 8, ...)` — verified in the spec, do not remove.
- `qml/helper/BreakdownMath.js` and `functions/lib/breakdownMath.js` must stay byte-identical in
  logic (module boilerplate aside) — any change to one is mirrored in the other, same commit.
- Unresolved product name falls back to `"(unnamed)"`, matching Current's existing convention.
- No xlsx export changes, no changes to Recent purchases/sales/Top items, no CF deployment.
- Git identity for all commits: `Taher <taher@lkdigitalworks.com>`.
- Full spec: `docs/superpowers/specs/2026-07-11-analysis-by-name-chart-design.md`.

---

### Task 1: `BreakdownMath.js` — add `dim: "name"` to `_sold()`/`_purchased()`

**Files:**
- Modify: `qml/helper/BreakdownMath.js:46-59` (add `_productNameKey`), `:134-167` (`_sold`),
  `:169-186` (`_purchased`), `:61-74` (doc comment)
- Test: `tests/tst_BreakdownMath.qml`

**Interfaces:**
- Produces: `_productNameKey(productName, productId)` (private helper, not exported — matches
  `_categoryKey`/`_supplierKey`). `breakdown()` now accepts `dim: "name"` and an optional
  `productName: { productId -> displayName }` map in `opts` (required whenever `dim === "name"`).

- [ ] **Step 1: Write the failing tests**

Add a shared fixture helper right after the existing `_supplierName()` helper (around line 52):

```qml
    function _productName()     { return { "P1": "Cola", "P2": "Chips", "P3": "Cola" } }
```

Extend `test_purchased_by_category_and_supplier_sum_equal` (existing function) to also assert
the name dimension — add `productName:_productName()` to `opts`, then after the existing
`bySup` assertions add:

```qml
        var byName = BM.breakdown(Object.assign({}, opts, { dim:"name" }))
        compare(byName["Cola"], 13)  // P1(10) + P3(3), both resolve to "Cola"
        compare(byName["Chips"], 5)
        compare(_sum(byName), _sum(byCat)) // reconciliation invariant: 18 == 18
```

Add three new test functions after `test_sold_nets_returns_by_category`:

```qml
    function test_sold_by_name_collapses_multi_sku_and_reconciles() {
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:5,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:5} ] },
            { kind:"sale", timestamp:"2026-06-15T11:00:00", productId:"P3", quantity:2,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:2} ] }
        ]
        var opts = {
            metric:"sold", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName(),
            productName:_productName()
        }
        var byName = BM.breakdown(Object.assign({}, opts, { dim:"name" }))
        var byCat  = BM.breakdown(Object.assign({}, opts, { dim:"category" }))
        compare(byName["Cola"], 7)          // P1(5) + P3(2), both resolve to "Cola"
        compare(_sum(byName), _sum(byCat))  // reconciliation invariant: 7 == 7
    }

    function test_sold_name_dim_with_supplier_filter() {
        var entries = [
            { kind:"sale", timestamp:"2026-06-15T10:00:00", productId:"P1", quantity:12,
              orderChannel:"", staffId:"",
              consumption:[ {supplierId:"S1", qtyConsumed:10}, {supplierId:"S2", qtyConsumed:2} ] }
        ]
        var byName = BM.breakdown({
            metric:"sold", dim:"name", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"S1",
            productCategory:_productCategory(), supplierName:_supplierName(),
            productName:_productName()
        })
        compare(byName["Cola"], 10) // only S1's 10 units, not the full 12
    }

    function test_purchased_by_name_unresolved_product_falls_back() {
        var entries = [
            { kind:"purchase", timestamp:"2026-06-15T10:00:00", productId:"P9", party:"S1", quantity:4 }
        ]
        var byName = BM.breakdown({
            metric:"purchased", dim:"name", entries:entries, orders:[],
            window:null, channel:"", staffId:"", category:"", supplierId:"",
            productCategory:_productCategory(), supplierName:_supplierName(),
            productName:_productName()
        })
        compare(byName["(unnamed)"], 4) // P9 isn't in the productName map
    }
```

- [ ] **Step 2: Confirm the tests fail for the right reason**

This repo's Cloud sessions don't have the Windows/Felgo toolchain `qmltestrunner.exe` needs (see
`AGENTS.md`), so these can't be executed here. Confirm by reading, not running: today `dim:"name"`
falls into the `else` (category) branch in both `_sold()`/`_purchased()`, and `_productNameKey`
doesn't exist yet — so `byName["Cola"]` would actually read a category-keyed map and every
assertion above would fail or read `undefined`. When you build, run:

```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_BreakdownMath.qml
```

- [ ] **Step 3: Implement**

Add the helper right after `_supplierKey` (line 54):

```js
function _productNameKey(productName, productId) {
    var n = productName[productId]
    return (n && n.length) ? n : "(unnamed)"
}
```

Update the `breakdown()` doc comment (lines 61-74) — change the `dim:` line and add `productName`:

```js
//   dim:    "category"|"supplier"|"name",
```
```js
//   productCategory: {},   // productId -> category string
//   supplierName: {},      // supplierId -> display name
//   productName: {}        // productId -> display name (only needed when dim === "name")
```

In `_sold()`, replace the `if (o.dim === "supplier") { ... } else { ... }` block with:

```js
        var cons = e.consumption || []
        if (o.dim === "supplier") {
            for (var ci = 0; ci < cons.length; ++ci) {
                var c = cons[ci]
                if (o.supplierId && c.supplierId !== o.supplierId) continue
                _add(out, _supplierKey(o.supplierName, c.supplierId), c.qtyConsumed || 0)
            }
        } else if (o.dim === "name") {
            var nameKey = _productNameKey(o.productName, e.productId)
            if (o.supplierId) {
                var matchedName = 0
                for (var cn = 0; cn < cons.length; ++cn)
                    if (cons[cn].supplierId === o.supplierId) matchedName += (cons[cn].qtyConsumed || 0)
                _add(out, nameKey, matchedName)
            } else {
                _add(out, nameKey, e.quantity || 0)
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
```

In `_purchased()`, replace:

```js
        var qty = e.quantity || 0
        if (o.dim === "supplier") _add(out, _supplierKey(o.supplierName, pid), qty)
        else                      _add(out, cat, qty)
```

with:

```js
        var qty = e.quantity || 0
        if (o.dim === "supplier")      _add(out, _supplierKey(o.supplierName, pid), qty)
        else if (o.dim === "name")     _add(out, _productNameKey(o.productName, e.productId), qty)
        else                           _add(out, cat, qty)
```

- [ ] **Step 4: Trace by hand to confirm the tests would pass**

`test_purchased_by_category_and_supplier_sum_equal`: P1→10 units→"Cola", P2→5→"Chips",
P3→3→"Cola" (P3 has no supplier so lands under `"Unknown"` for `bySup`, unaffected by name dim).
`byName = { Cola: 13, Chips: 5 }`, sum 18, matches. ✓

`test_sold_by_name_collapses_multi_sku_and_reconciles`: P1(5)+P3(2), no supplier filter, both
resolve to "Cola" via `_add`'s natural accumulation → 7. `byCat` sums to 7 regardless of category
split. ✓

`test_sold_name_dim_with_supplier_filter`: matches `test_sold_supplier_filter_partial_attribution`
exactly, just keyed by name instead of category — S1's 10 units only. ✓

`test_purchased_by_name_unresolved_product_falls_back`: P9 not in `_productName()` map →
`_productNameKey` returns `"(unnamed)"`. ✓

- [ ] **Step 5: Commit**

```bash
git add qml/helper/BreakdownMath.js tests/tst_BreakdownMath.qml
git commit -m "feat: add dim:name to BreakdownMath for Sold/Purchased breakdowns

- New _productNameKey helper, mirrors _categoryKey/_supplierKey
- _sold()/_purchased() gain a name branch alongside category/supplier
- Multi-SKU products collapse into one bucket via the existing _add()
  accumulator; unresolved product falls back to (unnamed)
- Not yet run under qmltestrunner (no Windows/Felgo toolchain in this
  session) -- traced by hand against the existing category/supplier
  test patterns; verify on your machine before merging"
```

---

### Task 2: Mirror into `functions/lib/breakdownMath.js` + Node tests

**Files:**
- Modify: `functions/lib/breakdownMath.js` (same shape as Task 1, semicolons + no top-level `var`
  style differences already established in that file)
- Test: `functions/test/breakdownMath.test.js`, `functions/test/fixtures/breakdownMathFixtures.js`

**Interfaces:**
- Consumes: identical logic to Task 1 — this task is a byte-for-byte-logic port, not a new design.
- Produces: `BreakdownMath.breakdown({..., dim: "name", productName: {...}})` available from
  `functions/lib/breakdownMath.js`, same contract as the QML version.

- [ ] **Step 1: Write the failing test + fixture**

In `functions/test/fixtures/breakdownMathFixtures.js`, add `productName` and `expected.byName` to
both existing fixture objects:

```js
    {
        name: "sold_by_category_nets_returns",
        entries: [
            { kind: "sale", productId: "P1", quantity: 5, date: "2026-06-20",
              consumption: [{ supplierId: "S1", qtyConsumed: 5 }] },
            { kind: "sale", productId: "P2", quantity: 3, date: "2026-06-20",
              consumption: [{ supplierId: "S2", qtyConsumed: 3 }] },
            { kind: "return", productId: "P1", quantity: -2, date: "2026-06-21",
              consumption: [{ supplierId: "S1", qtyConsumed: -2 }] }
        ],
        productCategory: { P1: "Drinks", P2: "Snacks" },
        supplierName: { S1: "Acme", S2: "Beta" },
        productName: { P1: "Cola", P2: "Chips" },
        expected: {
            byCategory: { Drinks: 3, Snacks: 3 },
            bySupplier: { Acme: 3, Beta: 3 },
            byName: { Cola: 3, Chips: 3 }
        }
    },
    {
        name: "purchased_by_supplier",
        entries: [
            { kind: "purchase", productId: "P1", quantity: 20, date: "2026-06-15", party: "S1" },
            { kind: "purchase", productId: "P2", quantity: 10, date: "2026-06-16", party: "S2" },
            { kind: "created", productId: "P1", quantity: 5, date: "2026-06-01",
              snapshot: { supplierId: "S1" } }
        ],
        productCategory: { P1: "Drinks", P2: "Snacks" },
        supplierName: { S1: "Acme", S2: "Beta" },
        productName: { P1: "Cola", P2: "Chips" },
        expected: {
            byCategory: { Drinks: 25, Snacks: 10 },
            bySupplier: { Acme: 25, Beta: 10 },
            byName: { Cola: 25, Chips: 10 }
        }
    }
```

In `functions/test/breakdownMath.test.js`, add a `byName` assertion block to both existing
`test(...)` calls, right after the existing `bySup` block:

```js
    const byName = BreakdownMath.breakdown({
        metric: "sold", dim: "name", entries: f.entries,
        window: null, channel: "", staffId: "", category: "", supplierId: "",
        productCategory: f.productCategory, supplierName: f.supplierName,
        productName: f.productName
    });
    assert.deepEqual(byName, f.expected.byName);
```

(swap `metric: "sold"` for `metric: "purchased"` in the second test).

- [ ] **Step 2: Run to confirm it fails**

```bash
cd functions && npm test
```
Expected: `sold_by_category_nets_returns` and `purchased_by_supplier` FAIL — `breakdown()` doesn't
understand `dim: "name"` yet, so `byName` comes back as `{}` or mis-keyed, not matching
`f.expected.byName`.

- [ ] **Step 3: Implement — port Task 1's change into the Node file**

Apply the exact same structural change as Task 1 to `functions/lib/breakdownMath.js`, using this
file's existing semicolon style. Add after the existing `_supplierKey` function:

```js
function _productNameKey(productName, productId) {
    var n = productName[productId];
    return (n && n.length) ? n : "(unnamed)";
}
```

In `_sold()`, replace the `if (o.dim === "supplier") {...} else {...}` block (mirrors Task 1
exactly, semicolons added):

```js
        var cons = e.consumption || [];
        if (o.dim === "supplier") {
            for (var ci = 0; ci < cons.length; ++ci) {
                var c = cons[ci];
                if (o.supplierId && c.supplierId !== o.supplierId) continue;
                _add(out, _supplierKey(o.supplierName, c.supplierId), c.qtyConsumed || 0);
            }
        } else if (o.dim === "name") {
            var nameKey = _productNameKey(o.productName, e.productId);
            if (o.supplierId) {
                var matchedName = 0;
                for (var cn = 0; cn < cons.length; ++cn)
                    if (cons[cn].supplierId === o.supplierId) matchedName += (cons[cn].qtyConsumed || 0);
                _add(out, nameKey, matchedName);
            } else {
                _add(out, nameKey, e.quantity || 0);
            }
        } else { // category
            if (o.supplierId) {
                var matched = 0;
                for (var cj = 0; cj < cons.length; ++cj)
                    if (cons[cj].supplierId === o.supplierId) matched += (cons[cj].qtyConsumed || 0);
                _add(out, cat, matched);
            } else {
                _add(out, cat, e.quantity || 0);
            }
        }
```

In `_purchased()`, replace:

```js
        var qty = e.quantity || 0;
        if (o.dim === "supplier") _add(out, _supplierKey(o.supplierName, pid), qty);
        else                      _add(out, cat, qty);
```

with:

```js
        var qty = e.quantity || 0;
        if (o.dim === "supplier")      _add(out, _supplierKey(o.supplierName, pid), qty);
        else if (o.dim === "name")     _add(out, _productNameKey(o.productName, e.productId), qty);
        else                           _add(out, cat, qty);
```

- [ ] **Step 4: Run to confirm it passes**

```bash
cd functions && npm test
```
Expected: both tests PASS, all assertions including the new `byName` ones.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/breakdownMath.js functions/test/breakdownMath.test.js functions/test/fixtures/breakdownMathFixtures.js
git commit -m "feat: mirror dim:name into functions/lib/breakdownMath.js

Keeps the Node port in parity with qml/helper/BreakdownMath.js (Task 1).
Verified: cd functions && npm test -- both suites pass with the new
byName assertions."
```

---

### Task 3: Extend the QML parity-fixtures file to match

**Files:**
- Modify: `tests/tst_BreakdownMathParityFixtures.qml`

**Interfaces:**
- Consumes: `BreakdownMath.breakdown()` from Task 1 (already committed by this point).
- Produces: nothing new consumed by later tasks — this closes out the parity-fixture pairing so
  the QML and Node fixture files hold the exact same literal scenario data (per the file's own
  header comment: "If you change a scenario in one file of a pair, change it in the other too").

- [ ] **Step 1: Write the extension (same fixture data as Task 2's Node file, by design)**

Add a `productName` map to both existing test functions' fixture blocks, and a `byName`
assertion block after each existing `bySup`/`byCat` pair:

In `test_sold_by_category_nets_returns`, after `var supplierName = { S1: "Acme", S2: "Beta" }`:

```qml
        var productName = { P1: "Cola", P2: "Chips" }
```

Then add `productName: productName` to both `BM.breakdown({...})` call objects in that function,
and after the existing `compare(bySup["Beta"], 3)` line add:

```qml
        var byName = BM.breakdown({
            metric: "sold", dim: "name", entries: entries,
            window: null, channel: "", staffId: "", category: "", supplierId: "",
            productCategory: productCategory, supplierName: supplierName, productName: productName
        })
        compare(byName["Cola"], 3)
        compare(byName["Chips"], 3)
```

In `test_purchased_by_supplier`, same pattern: add `productName = { P1: "Cola", P2: "Chips" }`,
add `productName: productName` to both existing `BM.breakdown({...})` calls, and after
`compare(bySup["Beta"], 10)` add:

```qml
        var byName = BM.breakdown({
            metric: "purchased", dim: "name", entries: entries,
            window: null, channel: "", staffId: "", category: "", supplierId: "",
            productCategory: productCategory, supplierName: supplierName, productName: productName
        })
        compare(byName["Cola"], 25)
        compare(byName["Chips"], 10)
```

- [ ] **Step 2: Trace by hand (can't run qmltestrunner in this session)**

These numbers are identical to Task 2's Node fixtures by construction (P1→Cola, P2→Chips, same
entries) — since Task 2's Node run already confirmed `Cola: 3, Chips: 3` and `Cola: 25, Chips:
10` pass against the same `BreakdownMath.breakdown()` logic (Task 1's port), and this file calls
the QML original of that exact same logic, these will pass once run under a real
`qmltestrunner`. Flagged for verification on your machine, same as Task 1.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_BreakdownMathParityFixtures.qml
git commit -m "test: extend BreakdownMath parity fixtures with dim:name cases

Mirrors the byName fixture data added to functions/test/fixtures/
breakdownMathFixtures.js in the prior commit -- same literal scenarios,
proving the QML original and Node port agree."
```

---

### Task 4: `_breakdownByDimension()` — build and pass through `productName`

**Files:**
- Modify: `qml/pages/SalesPage.qml:1292-1316`

**Interfaces:**
- Consumes: `BreakdownMath.breakdown()` with `dim: "name"` support (Task 1, already on this
  branch).
- Produces: `_breakdownByDimension(metric, "name", ignorePeriod)` now returns a valid
  `{ productName -> number }` map for `metric ∈ {sold, purchased}` (Revenue is out of scope here
  — see Task 5's guardrail note).

- [ ] **Step 1: Implement**

In `_breakdownByDimension()`, right after the existing `productCategory`/`supplierName` map
construction (after the `for (var sj ...)` loop, before the `return BreakdownMath.breakdown({...})`
call), add:

```qml
        var productName = {}
        for (var pk = 0; pk < inv.length; ++pk)
            productName[inv[pk].productId] = inv[pk].name || inv[pk].productId
```

Add `productName: productName` to the `BreakdownMath.breakdown({...})` call object (alongside
the existing `productCategory: productCategory, supplierName: supplierName,` line):

```qml
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
            supplierName: supplierName,
            productName: productName,
            allocate: OrderMath.allocate
        })
```

- [ ] **Step 2: Verify no regression by hand**

This function is unchanged for `dim ∈ {"category","supplier"}` — `productName` is simply an extra
key in the passed object that `BreakdownMath.breakdown()` ignores unless `dim === "name"` (Task
1's `_sold`/`_purchased` only read `o.productName` inside the `dim === "name"` branch). No
existing call site is affected.

- [ ] **Step 3: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat: build productName map in _breakdownByDimension

Enables dim:name for Sold/Purchased. No behavior change for existing
category/supplier callers -- productName is an additive, ignored key
unless dim === name."
```

---

### Task 5: `_profitTopN()` field parameter + Revenue's `_topByName`

**Files:**
- Modify: `qml/pages/SalesPage.qml:1718-1737` (`_profitTopN`), `:1243-1244` (Revenue branch)

**Interfaces:**
- Consumes: `InventoryStore.realisedProfitByDimension("productId", periodScope)` — already
  proven in production by Profit→Realised's `_topByName` (line 1036); `_namedProductMap()` —
  already exists (line 1761).
- Produces: `_profitTopN(rows, n, filterKey, field)` — 4th param optional, defaults `"profit"`.
  Revenue mode's `_topByName` populated for the first time.

- [ ] **Step 1: Implement — extend `_profitTopN`**

Replace the function signature and body:

```js
    function _profitTopN(rows, n, filterKey, field) {
        field = field || "profit"
        var keys = Object.keys(rows || {})
        if (filterKey) keys = keys.filter(function(k) { return k === filterKey })
        keys.sort(function(a, b) { return (rows[b][field] || 0) - (rows[a][field] || 0) })
        if (n && keys.length > n) keys = keys.slice(0, n)
        var out = []
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i]
            var lbl = k.length > 6 ? k.substring(0, 5) + "…" : k
            out.push({
                label: lbl,
                value: rows[k][field],
                fullLabel: k,
                revenue: rows[k].revenue,
                cogs: rows[k].cogs,
                margin: rows[k].margin
            })
        }
        return out
    }
```

(Only the added `field = field || "profit"` line and the two `[field]` substitutions for
`sort`/`value` differ from today — every existing call site passes 3 args, so `field` defaults to
`"profit"` and behavior is unchanged for them.)

- [ ] **Step 2: Wire Revenue's `_topByName`**

**Do not** add a `dim: "name"` case to `_breakdownByDimension()`'s revenue branch — its
`field = dim === "supplier" ? "supplierId" : "category"` ternary silently falls through to
`"category"` for any other `dim` (see the spec's guardrail note). Instead, in the Revenue branch
of `_rebuildBreakdown()`, right after the existing line:

```qml
        _breakdownBySupplier = _topNFromMap(_breakdownByDimension("revenue", "supplier", false), 8)
```

add:

```qml
        _topByName = _profitTopN(_namedProductMap(InventoryStore.realisedProfitByDimension("productId", periodScope)), 8, "", "revenue")
```

(`periodScope` is already in scope here — declared earlier in this same branch at
`var periodScope = _realisedScope(true)`.)

- [ ] **Step 3: Verify by hand**

Profit→Realised's existing line 1036 call — `_profitTopN(_namedProductMap(InventoryStore.
realisedProfitByDimension("productId", realisedScope)), 8, "")` — is the exact same shape with a
different scope variable name and the new 4th arg. Since `InventoryStore.
realisedProfitByDimension("productId", ...)` already returns `{ productId -> {revenue, cogs,
profit, margin} }` rows (proven by that existing call), and `_namedProductMap` merges them to
`{ productName -> row }` (proven the same way), the only new surface is `_profitTopN` reading
`rows[k]["revenue"]` instead of `rows[k]["profit"]` — a direct property lookup, no edge case.

- [ ] **Step 4: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat: wire Revenue's _topByName via existing realisedProfitByDimension path

_profitTopN gains an optional 4th 'field' param (default 'profit', so
every existing call site is unaffected) so Revenue's by-name chart can
sort/extract revenue instead of profit -- reusing the exact pattern
Profit->Realised already proved out, not a new aggregation path."
```

---

### Task 6: Sold/Purchased `_topByName` wiring

**Files:**
- Modify: `qml/pages/SalesPage.qml:1185-1186` (Sold), `:1202-1203` (Purchased)

**Interfaces:**
- Consumes: `_breakdownByDimension(metric, "name", false)` (Task 4), `_topNFromMap(obj, 8)`
  (existing).
- Produces: `_topByName` populated for Sold and Purchased — the last two of the three genuinely
  missing modes (Revenue done in Task 5).

- [ ] **Step 1: Implement — Sold**

After the existing line:

```qml
            _breakdownBySupplier = _topNFromMap(_breakdownByDimension("sold", "supplier", false), 8)
```

add:

```qml
            _topByName = _topNFromMap(_breakdownByDimension("sold", "name", false), 8)
```

- [ ] **Step 2: Implement — Purchased**

After the existing line:

```qml
            _breakdownBySupplier = _topNFromMap(_breakdownByDimension("purchased", "supplier", false), 8)
```

add:

```qml
            _topByName = _topNFromMap(_breakdownByDimension("purchased", "name", false), 8)
```

- [ ] **Step 3: Verify by hand**

Identical pattern to the existing category/supplier lines directly above each addition — same
function, same `_topNFromMap(..., 8)` wrapper, only `"name"` swapped in for the dim argument.
Every mode now populates `_topByName`: Value/Current/Profit (already did), Revenue (Task 5),
Sold/Purchased (this task).

- [ ] **Step 4: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat: populate _topByName for Sold and Purchased

Closes the last two of the three modes that never computed by-name
data (Revenue done in the prior commit). All six modes now populate
_topByName."
```

---

### Task 7: `_breakdownTitles()` — add the `name` key

**Files:**
- Modify: `qml/pages/SalesPage.qml:1327-1337`

**Interfaces:**
- Consumes: nothing new.
- Produces: `_breakdownTitles().name` — used by Task 8's new card.

- [ ] **Step 1: Implement**

Replace the function body:

```qml
    function _breakdownTitles() {
        switch (_viewMode) {
        case _MODE_VALUE:     return { name: qsTr("Value by product"),          category: qsTr("Value by category"),          supplier: qsTr("Value by supplier") }
        case _MODE_PURCHASED: return { name: qsTr("Purchased units by product"), category: qsTr("Purchased units by category"), supplier: qsTr("Purchased units by supplier") }
        case _MODE_CURRENT:   return { name: qsTr("Stock by product"),          category: qsTr("Stock by category"),           supplier: qsTr("Purchases by party") }
        case _MODE_REVENUE:   return { name: qsTr("Revenue by product"),        category: qsTr("Revenue by category"),         supplier: qsTr("Revenue by supplier") }
        case _MODE_SOLD:      return { name: qsTr("Units sold by product"),     category: qsTr("Units sold by category"),      supplier: qsTr("Units sold by supplier") }
        case _MODE_PROFIT:    return { name: qsTr("Profit by product"),         category: qsTr("Profit by category"),          supplier: qsTr("Profit by supplier") }
        }
        return { name: qsTr("By product"), category: qsTr("By category"), supplier: qsTr("By supplier") }
    }
```

- [ ] **Step 2: Verify by hand**

Every existing `.category`/`.supplier` string is untouched (same `qsTr` text, same key) — only a
new `.name` key is added per branch. Nothing reads a title map key that isn't present, since
Task 8 is the only consumer of `.name` and is added after this task.

- [ ] **Step 3: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat: add by-product title strings to _breakdownTitles

Follows the existing '<Metric> by <dimension>' convention already used
for category/supplier."
```

---

### Task 8: New by-name card, reordering, duplicate suppression

**Files:**
- Modify: `qml/pages/SalesPage.qml:663-707`

**Interfaces:**
- Consumes: `_topByName` (Tasks 5/6, plus Value/Current/Profit's pre-existing computation),
  `_breakdownTitles().name` (Task 7).
- Produces: final on-screen card order and visibility — the last task in this plan.

- [ ] **Step 1: Reorder — move by-supplier above by-category, add the new by-name card first**

Replace the three-card block (lines 663-707) with:

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

            // ── By-supplier breakdown (all views) ──
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root.canViewSuppliers
                         && (root._viewMode === root._MODE_CURRENT
                             || (root._breakdownBySupplier || []).length > 0
                             || root._supplierBreakdownApplies())
                title: root._breakdownTitles().supplier
                model: root._breakdownBySupplier
                currency: root._isCurrency
                barTop: Constants.brand4
                barBottom: Constants.brand5
                emptyText: root._viewMode === root._MODE_CURRENT
                           ? qsTr("No supplier purchases recorded yet — capture a supplier on your next restock.")
                           : qsTr("No supplier data for this period.")
            }

            // ── By-category breakdown (all views) ──
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: (root._breakdownByCategory || []).length > 0
                title: root._breakdownTitles().category
                model: root._breakdownByCategory
                currency: root._isCurrency
                barTop: Constants.brand3
                barBottom: Constants.brand2
            }

            // Main breakdown — time series for Revenue/Sold/Purchased, stock-health for
            // Current. Hidden for Value and Profit→Potential, where this would otherwise
            // duplicate the by-name card above (both show the same top-8-by-name data).
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: !(root._viewMode === root._MODE_VALUE)
                         && !(root._viewMode === root._MODE_PROFIT && root._profitMode === "Potential")
                title: root._viewMode === root._MODE_CURRENT ? qsTr("Stock health") : qsTr("Breakdown")
                model: root._breakdown
                currency: root._isCurrency
                chartHeight: dp(200)
                showValueTips: true
                barTop: Constants.brand2
                barBottom: Constants.brand1
            }
```

- [ ] **Step 2: Verify by hand against the manual QA checklist**

Trace each of the 6 modes against the spec's checklist:
- **Value**: by-name visible (topRows), by-supplier visible if applicable, by-category visible,
  4th card hidden (Value excluded) → 3 cards. ✓
- **Profit→Potential**: same shape as Value, 4th card hidden (`_profitMode === "Potential"`
  excluded) → 3 cards. ✓
- **Profit→Realised**: 4th card visible (neither exclusion applies) → 4 cards, 4th shows the
  period-bucketed profit trend, unchanged. ✓
- **Current**: 4th card visible → 4 cards, 4th shows stock health, unchanged. ✓
- **Sold, Purchased**: 4th card visible → 4 cards each, 4th shows the period trend, unchanged. ✓

- [ ] **Step 3: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat: reorder Analysis charts to name -> supplier -> category

- New by-name BreakdownBarCard, first in source order
- By-supplier and by-category cards reordered, bindings unchanged
- 4th (trend/stock-health) card now hidden for Value and Profit-
  Potential specifically, since it would otherwise duplicate the new
  by-name card there -- visible everywhere else, unchanged content"
```

---

### Task 9: Wrap-up — Node suite re-run, checkpoint, handoff for on-device verification

**Files:**
- Modify: `CHECKPOINT.md`

- [ ] **Step 1: Re-run the Node suite once more, now that all QML/JS changes are in**

```bash
cd functions && npm test
```
Expected: all suites pass, including the two `byName` assertions from Task 2.

- [ ] **Step 2: Update `CHECKPOINT.md`**

Mark all 9 tasks complete, and record explicitly what could and couldn't be verified in this
session (Node: run and passing; QML: written and hand-traced against existing passing patterns,
not run — needs a `qmltestrunner` pass on Taher's machine before merging), plus the manual QA
checklist from the spec for on-device verification once build/run is requested.

- [ ] **Step 3: Final commit**

```bash
git add CHECKPOINT.md
git commit -m "docs: mark by-name analysis chart feature complete, pending on-device QA

All 9 plan tasks done. Node parity suite passes (cd functions && npm
test). QML tests written and hand-traced but not run under a real
qmltestrunner in this session -- needs verification on the Felgo
toolchain before merge, per the manual QA checklist in the spec."
```

Do **not** push — push only happens with a PAT Taher provides in-session, and only after he's
reviewed the diffs.
