# Import/Export Fidelity, Post-Import Analytics & Per-Item Discount — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 17 device-reported defects so imported data populates every analysis report and history view, exports carry SKU/staff/supplier with correct README contracts, discount is modelled per line item, and chart labels sit at the bar bottom — with zero regressions to the locked net-revenue/profit math.

**Architecture:** The import path (`InventoryStore.upsertMany` / `OrdersStore.upsertMany`) is taught to write the same side-effect stores in-app creation already writes — `StockBatchStore` (opening batches), `TransactionStore` (`created`/`sale` events), and `ActivityLog` (import summary) — which is what every starved report reads. The order discount model moves from a single order-level field to a per-line `discountType`/`discountValue` on each line item, recomputed in `OrderMath.allocate()`. Export/README changes live in `src/XlsxService.cpp` with QML attaching resolved names before the call.

**Tech Stack:** Felgo QML (Qt 6.8), QtQuick, C++ (QXlsx via `XlsxService`), Firestore REST via `Gateway`/`FirebaseService`, Qt Quick Test (`qmltestrunner`) for headless JS-library tests.

## Global Constraints

- **Revenue convention (locked):** `net = gross − discount`; **tax is a separate pass-through, never part of revenue**; `total = net + tax`. Do not redefine revenue (item 16 = "keep net, add tax line").
- **MVP fresh-data phase:** no legacy/back-compat or migration code. Implement the clean new schema directly. Firestore is wiped and re-tested fresh.
- **Per-line discount only:** the order-level `discountValue`/`discountType` fields are removed entirely; discount lives on each line item.
- **Singleton store rule:** never use `Connections{}`/`Timer{}`/visual items inside a `pragma Singleton QtObject` (SKILLS Skill 20) — use property-watcher bindings.
- **Pages never import AuthStore / call stores directly for RBAC**; bind from Main.qml (AGENTS §6). Logic flows through `logic` signals → `DataModel`.
- **Batch the import writes:** the per-product/per-order side-effects must not trigger N Firebase round-trips beyond what `addBatch`/`recordCreated`/`recordSaleFromOrder` already do per row; assign the store array once.
- **Currency formatters** use `maximumFractionDigits: 1` (already in place) — do not change.
- **Run headless tests** with: `QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_<Name>.qml`
- **Build (C++ changes)** with: `cmake --build build` after `cmake -S . -B build -G "Ninja"`.

Spec: `docs/superpowers/specs/2026-06-21-import-export-analytics-discount-design.md`.

---

## Task ordering & dependency map

```
Task 1 (OrderMath per-line)  ──┬─> Task 2 (OrdersStore schema)
                               │       └─> Task 3 (NewOrderDialog UI)
                               │       └─> Task 4 (OrderDetailDialog UI)
                               │       └─> Task 5 (DataModel adjust event + completeImportedOrder)
Task 6 (InventoryStore.upsertMany side-effects) ─> Task 7 (ImportPreviewDialog)
Task 8 (ActivityLog import kind) ─> Task 7
Task 5 + Task 6 ───────────────────────────────> Task 7 (completion loop)
Task 9 (XlsxService export+README) ─> Task 10 (Main.qml export wiring)
Task 11 (OrderDetailDialog history SKU+notes) — independent
Task 12 (BreakdownBarCard label) — independent
```

Recommended execution order: **1 → 2 → 3 → 4 → 5 → 6 → 8 → 7 → 9 → 10 → 11 → 12**. Tasks 11 and 12 are independent and can be done any time.

---

### Task 1: Per-line discount in `OrderMath.allocate()`

**Files:**
- Modify: `qml/helper/OrderMath.js:13-118` (`allocate`)
- Test: `tests/tst_OrderMath.qml` (**already exists with ~20 tests built around the OLD order-level discount model**). Per owner decision: **delete the obsolete order-level-discount test cases and add the new per-line cases below.** KEEP the still-valid tests that do NOT assert order-level discount behaviour — `test_spread_order_delta_*`, `test_spread_line_delta_*`, `test_eventProfit_*`, `test_return_reverses_profit`, `test_sales_kpis_*`, `test_consumption_*`, `test_event_profit_reconciles` — but if any of their fixtures pass a non-zero order-level `discountValue` via the `_order(lines, dType, dVal)` helper, re-express that discount per-line so the case still reconciles. The file MUST end green.

**Interfaces:**
- Consumes: an order object whose line items now carry `discountType` ("flat"|"percent") and `discountValue` (number) **per line**; the order no longer carries order-level `discountType`/`discountValue`.
- Produces: `allocate(order)` returns the SAME shape as today — `{ perLine:[{productId,name,qty,price,gross,discountShare,net,taxable,taxPercent,tax,cogs,perConsumption}], totals:{gross,discount,net,tax,cogs,total,profit,itemCount} }`. `totals.discount` is now the **sum of per-line discounts**; `perLine[i].discountShare` is that line's own discount.

- [ ] **Step 1: Update the test file — remove obsolete order-level cases, add per-line cases**

First read the existing `tests/tst_OrderMath.qml`. Delete the test functions that assert **order-level** discount behaviour (those that rely on the `_order(lines, dType, dVal)` helper's order-level `discountType`/`discountValue` producing a pro-rata split): `test_flat_discount_with_tax`, `test_percent_discount_clamped`, `test_flat_discount_clamped_to_subtotal`, `test_mixed_taxable_lines`, `test_perline_net_sums_to_total`, and `test_plain_no_discount_no_tax` (replace with the per-line equivalents below). For any KEPT test whose fixture passes a non-zero order-level discount, move that discount onto the line(s). Then ADD the per-line test cases below. The suite MUST end green.

Add these test functions:

```qml
    function _round2(x) { return Math.round(x * 100) / 100 }

    // Flat per-line discount: line A ₹100×2 −₹10; line B ₹50×1 −₹0.
    function test_flat_per_line_discount() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 2, price: 100,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 10 },
            { productId: "B", name: "B", quantity: 1, price: 50,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }
        ] }
        var a = OM.allocate(order)
        compare(a.totals.gross, 250, "gross = 200 + 50")
        compare(a.totals.discount, 10, "discount = sum of line discounts")
        compare(a.totals.net, 240, "net = gross - discount")
        compare(a.perLine[0].discountShare, 10, "line A keeps its own ₹10")
        compare(a.perLine[1].discountShare, 0, "line B has no discount")
    }

    // Percent per-line discount: line A ₹100×2 −10% = −₹20.
    function test_percent_per_line_discount() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 2, price: 100,
              taxable: false, taxPercent: 0, discountType: "percent", discountValue: 10 }
        ] }
        var a = OM.allocate(order)
        compare(a.totals.discount, 20, "10% of 200")
        compare(a.totals.net, 180, "net = 200 - 20")
    }

    // Tax is on the discounted net, and excluded from net/revenue.
    function test_tax_on_net_excluded_from_revenue() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 1, price: 100,
              taxable: true, taxPercent: 18, discountType: "flat", discountValue: 10 }
        ] }
        var a = OM.allocate(order)
        compare(a.totals.net, 90, "net excludes tax")
        compare(_round2(a.totals.tax), 16.2, "tax = 18% of 90")
        compare(_round2(a.totals.total), 106.2, "total = net + tax")
    }

    // Reconciliation invariant: sum of line nets + sum of line discounts == gross.
    function test_reconciliation() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 3, price: 33,
              taxable: true, taxPercent: 5, discountType: "percent", discountValue: 7 },
            { productId: "B", name: "B", quantity: 2, price: 49.5,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 4.5 }
        ] }
        var a = OM.allocate(order)
        var sumNet = 0, sumDisc = 0
        for (var i = 0; i < a.perLine.length; ++i) {
            sumNet += a.perLine[i].net
            sumDisc += a.perLine[i].discountShare
        }
        compare(_round2(sumNet + sumDisc), a.totals.gross, "nets + discounts reconcile to gross")
    }

    // A flat line discount never exceeds the line gross (clamp).
    function test_flat_discount_clamped_to_line_gross() {
        var order = { products: [
            { productId: "A", name: "A", quantity: 1, price: 30,
              taxable: false, taxPercent: 0, discountType: "flat", discountValue: 100 }
        ] }
        var a = OM.allocate(order)
        compare(a.totals.discount, 30, "clamped to line gross")
        compare(a.totals.net, 0, "net floored at 0")
    }
}
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderMath.qml
```
Expected: the NEW `test_*_per_line_discount` cases FAIL — current `allocate()` reads order-level discount, so a per-line `discountValue` produces `discount: 0`. (The kept consumption/return/spread tests should still pass.)

- [ ] **Step 3: Rewrite the discount computation in `allocate()`**

In `qml/helper/OrderMath.js`, **replace** the order-level discount block (lines 20–31) — delete it entirely — and **replace** the per-line `discShare` line (line 42). The new per-line loop computes each line's own discount:

```javascript
    var perLine = []
    var totalTax = 0
    var totalCogs = 0
    var totalDiscount = 0
    var itemCount = 0
    for (var j = 0; j < lines.length; ++j) {
        var ln = lines[j]
        var qty = ln.quantity || 0
        var price = (typeof ln.price === "number") ? ln.price : 0
        var gross = qty * price
        // Per-line discount (replaces the old order-level pro-rata split).
        var lnType = ln.discountType === "percent" ? "percent" : "flat"
        var discShare
        if (lnType === "percent") {
            var lnPct = parseFloat(ln.discountValue) || 0
            if (lnPct < 0) lnPct = 0
            if (lnPct > 100) lnPct = 100
            discShare = gross * (lnPct / 100)
        } else {
            discShare = parseFloat(ln.discountValue) || 0
            if (discShare < 0) discShare = 0
            if (discShare > gross) discShare = gross
        }
        totalDiscount += discShare
        var net = gross - discShare
        var taxable = !!ln.taxable
        var taxPercent = (typeof ln.taxPercent === "number") ? ln.taxPercent : 0
        var tax = (taxable && taxPercent > 0) ? net * (taxPercent / 100) : 0
        totalTax += tax
        itemCount += qty
        // ... (the existing consumption-split block stays UNCHANGED from here) ...
```

Keep the entire per-consumption split block (old lines 49–87) exactly as-is — it splits `net`/`tax`/`discShare` by `qtyConsumed/qty` and is independent of where `discShare` came from.

Then **replace** the totals block (old lines 99–103) to use the summed discount:

```javascript
    var roundedSubtotal = _round2(subtotal)
    var roundedDiscount = _round2(totalDiscount)
    var roundedTax = _round2(totalTax)
    var roundedNet = _round2(roundedSubtotal - roundedDiscount)
    var total = _round2(roundedNet + roundedTax)
```

Remove the now-unused `discountType`/`discount` order-level variables.

- [ ] **Step 4: Run the tests to verify they pass**

Run the same command as Step 2.
Expected: PASS — all 5 cases green ("OrderMath_PerLineDiscount … 5 passed, 0 failed").

- [ ] **Step 5: Commit**

```bash
git add qml/helper/OrderMath.js tests/tst_OrderMath.qml
git commit -m "feat(order): per-line discount allocation in OrderMath

Each line carries its own discountType/discountValue; order discount is
the sum of line discounts. Tax stays on the discounted net and excluded
from revenue. Adds tst_OrderMath.qml reconciliation tests."
```

---

### Task 2: `OrdersStore` — per-line discount schema

**Files:**
- Modify: `qml/model/OrdersStore.qml` — `_fetchFromFirebase` (49-50), `upsertMany`/`_normalizeOrder` (156-211), `computeOrderTotals` (217-266), `_mergeOrder` (268-283), `_clone` (311-361), `updateOrder` (419-453), `applyAdjustment` (461-484), `addOrder` (500-540)

**Interfaces:**
- Consumes: `OrderMath.allocate()` per-line discount (Task 1) — but note `computeOrderTotals` is a parallel implementation that must match.
- Produces:
  - Line item shape now `{ productId, name, price, quantity, taxable, taxPercent, discountType, discountValue, consumption }`.
  - Order shape drops `discountType`/`discountValue`; keeps computed `discount`, `subtotal`, `tax`, `taxBreakdown`, `total`.
  - `computeOrderTotals(prods)` — **signature changes** to take only `prods` (no `discountType`/`discountValue` args); returns `{ subtotal, discount, tax, taxBreakdown, total, itemCount }` where `discount` = Σ line discounts.
  - `addOrder(customer, items, total, status, date, email, phone, orderProducts, orderChannel, staffId)` — **drops** `discountType`/`discountValue` params; each entry in `orderProducts` carries `discountType`/`discountValue`.

- [ ] **Step 1: Rewrite `computeOrderTotals` for per-line discount**

Replace `computeOrderTotals` (lines 217-266) with a version that takes only `prods` and reads each line's own discount:

```javascript
    // Compute subtotal, summed per-line discount, per-rate tax breakdown, and
    // grand total. Each line carries its own discountType/discountValue; tax is
    // taken on the discounted line net and is a pass-through (excluded from net).
    function computeOrderTotals(prods) {
        if (!prods) prods = [];
        var subtotal = 0; var itemCount = 0; var totalDiscount = 0;
        var taxByRate = {}; var totalTax = 0;
        for (var i = 0; i < prods.length; ++i) {
            var p = prods[i];
            var lineGross = p.quantity * p.price;
            subtotal += lineGross;
            itemCount += p.quantity;
            var lnType = p.discountType === "percent" ? "percent" : "flat";
            var lineDisc;
            if (lnType === "percent") {
                var pct = parseFloat(p.discountValue) || 0;
                if (pct < 0) pct = 0;
                if (pct > 100) pct = 100;
                lineDisc = lineGross * (pct / 100);
            } else {
                lineDisc = parseFloat(p.discountValue) || 0;
                if (lineDisc < 0) lineDisc = 0;
                if (lineDisc > lineGross) lineDisc = lineGross;
            }
            totalDiscount += lineDisc;
            var lineNet = lineGross - lineDisc;
            if (p.taxable && p.taxPercent && p.taxPercent > 0) {
                var lineTax = lineNet * (p.taxPercent / 100);
                taxByRate[p.taxPercent] = (taxByRate[p.taxPercent] || 0) + lineTax;
                totalTax += lineTax;
            }
        }
        var taxBreakdown = [];
        var keys = Object.keys(taxByRate).sort(function(a, b) { return parseFloat(a) - parseFloat(b); });
        for (var k = 0; k < keys.length; ++k)
            taxBreakdown.push({ rate: parseFloat(keys[k]), amount: taxByRate[keys[k]] });

        var roundedDiscount = Math.round(totalDiscount * 100) / 100;
        var roundedTax = Math.round(totalTax * 100) / 100;
        var roundedSubtotal = Math.round(subtotal * 100) / 100;
        var total = Math.round((roundedSubtotal - roundedDiscount + roundedTax) * 100) / 100;

        return {
            subtotal: roundedSubtotal,
            discount: roundedDiscount,
            tax: roundedTax,
            taxBreakdown: taxBreakdown,
            total: total,
            itemCount: itemCount
        };
    }
```

- [ ] **Step 2: Update `_normalizeOrder` (line items + drop order discount)**

In `_normalizeOrder` (156-211): in the line-item push (167-179) add the per-line discount fields, and change the totals call + returned object. Replace the per-line push block and below:

```javascript
            var lnType = lp.discountType === "percent" ? "percent" : "flat";
            var lnVal = parseCurrency(lp.discountValue);
            prods.push({
                productId: lp.productId || "",
                name: lp.name || "",
                price: typeof lp.price === "number" ? lp.price : parseCurrency(lp.price),
                quantity: parseInt(lp.quantity) || parseInt(lp.qty) || 0,
                taxable: taxable,
                taxPercent: isNaN(taxPercent) ? 0 : taxPercent,
                discountType: lnType,
                discountValue: lnVal,
                consumption: Array.isArray(lp.consumption) ? lp.consumption.slice() : []
            });
        }

        var totals = computeOrderTotals(prods);

        return {
            orderId: r.orderId,
            customer: r.customer || "",
            email: r.email || "",
            phone: r.phone || "",
            items: prods.length > 0 ? totals.itemCount : (parseInt(r.items) || 0),
            subtotal: totals.subtotal,
            discount: totals.discount,
            tax: totals.tax,
            taxBreakdown: totals.taxBreakdown,
            total: prods.length > 0 ? totals.total : parseCurrency(r.total),
            status: r.status || "pending",
            date: r.date || Qt.formatDate(new Date(), "yyyy-MM-dd"),
            updatedAt: r.updatedAt || new Date().toISOString(),
            notes: r.notes || "",
            orderChannel: r.orderChannel || "",
            staffId: r.staffId || "",
            products: prods
        };
```

Delete the old `discountType`/`discountValue` local vars (182-183) and their keys in the returned object.

- [ ] **Step 3: Update `_fetchFromFirebase`, `_mergeOrder`, `_clone`**

`_fetchFromFirebase` (49-50): remove the two lines defaulting `o.discountType`/`o.discountValue` (order-level fields no longer exist). Add nothing — line items are normalized on use.

`_mergeOrder` keys array (270-273): remove `"discountType"`, `"discountValue"` from the keys list.

`_clone` (335-338): add per-line discount to the cloned line push:
```javascript
                    prods.push({ productId: p.productId || "", name: p.name, price: p.price, quantity: p.quantity,
                                 taxable: !!p.taxable,
                                 taxPercent: typeof p.taxPercent === "number" ? p.taxPercent : 0,
                                 discountType: p.discountType === "percent" ? "percent" : "flat",
                                 discountValue: typeof p.discountValue === "number" ? p.discountValue : (parseCurrency(p.discountValue) || 0),
                                 consumption: consClone });
```
In `_clone`'s order push (346-358): remove the order-level `discountType`/`discountValue` lines.

- [ ] **Step 4: Update `updateOrder`, `applyAdjustment`, `addOrder`**

`updateOrder` (419-453): remove the `fields.discountType`/`fields.discountValue` handling (431-432); change the recompute condition (439-441) and call to:
```javascript
        if (fields.products !== undefined) {
            var t = computeOrderTotals(o.products || []);
            o.subtotal = t.subtotal;
            o.discount = t.discount;
            o.tax = t.tax;
            o.taxBreakdown = t.taxBreakdown;
            o.total = t.total;
            o.items = t.itemCount;
        }
```

`applyAdjustment` (461-484): change signature to `applyAdjustment(orderId, newLines, adjustmentRecord)` (drop `discountType`/`discountValue` params); remove the discount-persist block (471-472); change the recompute (473) to `var t = computeOrderTotals(o.products);`.

`addOrder` (500-540): drop `discountType`/`discountValue` params from the signature → `addOrder(customer, items, total, status, date, email, phone, orderProducts, orderChannel, staffId)`. In the line push (513-520) add per-line discount from each `pp`:
```javascript
                prods.push({
                    productId: pp.productId || "",
                    name: pp.name,
                    price: pp.price,
                    quantity: pp.qty !== undefined ? pp.qty : (pp.quantity || 0),
                    taxable: taxable,
                    taxPercent: isNaN(taxPercent) ? 0 : taxPercent,
                    discountType: pp.discountType === "percent" ? "percent" : "flat",
                    discountValue: parseCurrency(pp.discountValue)
                });
```
Remove the `dt`/`dv` lines (523-524); change `computeOrderTotals(prods, dt, dv)` → `computeOrderTotals(prods)`; remove `discountType`/`discountValue` keys from the pushed order object (529).

- [ ] **Step 5: Verify it loads (no headless test — page-level deps)**

Run a syntax sanity check by launching the app build or, at minimum, confirm no `discountType`/`discountValue` order-level references remain:
```bash
grep -n "o.discountType\|o.discountValue\|order.discountType\|order.discountValue\|computeOrderTotals(.*," qml/model/OrdersStore.qml
```
Expected: no matches for order-level discount; `computeOrderTotals(` only ever called with a single argument.

- [ ] **Step 6: Commit**

```bash
git add qml/model/OrdersStore.qml
git commit -m "refactor(orders): drop order-level discount, store per-line discount

computeOrderTotals(prods) now sums per-line discounts; line items carry
discountType/discountValue; addOrder/applyAdjustment signatures drop the
order-level discount params. MVP: no back-compat for old order-level docs."
```

---

### Task 3: `NewOrderDialog` — per-line discount UI + picker reset on close

**Files:**
- Modify: `qml/pages/NewOrderDialog.qml` — line-item model/row (~242), discount block (304-371 to remove), totals helper (~411, `_totals`), submit payload (492-520), open/reset (89-99), add `onClosed`

**Interfaces:**
- Consumes: `OrdersStore.addOrder(...)` new signature (Task 2); `logic.addOrder` signal path.
- Produces: order line objects each with `discountType`/`discountValue`; resets all cart state on close.

- [ ] **Step 1: Read the current line-row delegate and submit code**

Run:
```bash
sed -n '230,300p;400,530p' qml/pages/NewOrderDialog.qml
```
Confirm: the `Repeater`/`ListView` over `dlg.selectedProducts` (~242), the `_addToCart`/qty-change functions (437-474), `_totals` (~411), and the submit handler (492-520) that emits the order.

- [ ] **Step 2: Add per-line discount to each cart line's data + a per-line discount input in the row delegate**

Each entry in `selectedProducts` gains `discountType` (default "flat") and `discountValue` (default 0). When a product is added to the cart (the `_addToCart` push around 449), include:
```javascript
        arr.push({ productId: p.productId, name: p.name, price: p.price, qty: 1,
                   discountType: "flat", discountValue: 0 })
```
In the line-row delegate (~242 `delegate:`), add a compact discount control bound to the line. Example controls inside the existing row layout (place after the qty stepper):
```qml
                // Per-line discount: type toggle + value field.
                SegmentedPill {
                    options: ["₹", "%"]
                    selected: modelData.discountType === "percent" ? 1 : 0
                    onSelectedChanged: dlg._setLineDiscount(index, selected === 1 ? "percent" : "flat", modelData.discountValue)
                }
                AppTextField {
                    text: String(modelData.discountValue || 0)
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    onEditingFinished: {
                        var v = parseFloat(text); if (isNaN(v)) v = 0
                        dlg._setLineDiscount(index, modelData.discountType, v)
                    }
                }
```
(Use the row's existing `index` from the Repeater/ListView delegate; match the surrounding component names — if the file uses `QQC.TextField` instead of `AppTextField`, follow that.)

- [ ] **Step 3: Add the `_setLineDiscount` helper**

Near `_addToCart` (~437), add:
```javascript
    function _setLineDiscount(idx, type, value) {
        if (idx < 0 || idx >= selectedProducts.length) return
        var arr = selectedProducts.slice()
        arr[idx] = Object.assign({}, arr[idx], {
            discountType: type === "percent" ? "percent" : "flat",
            discountValue: isNaN(value) ? 0 : value
        })
        selectedProducts = arr
    }
```

- [ ] **Step 4: Update `_totals` and remove the order-level discount block**

Change `_totals` (~411) so it computes per-line discount instead of an order-level one. Replace its body to delegate to the canonical math:
```javascript
    function _totals(items, _ignoredType, _ignoredValue) {
        // Build a transient order and reuse the canonical allocator so the
        // dialog preview matches what OrdersStore will persist.
        var prods = []
        for (var i = 0; i < (items || []).length; ++i) {
            var sp = items[i]
            var inv = sp.productId ? InventoryStore.getById(sp.productId) : null
            prods.push({ productId: sp.productId, name: sp.name, price: sp.price,
                         quantity: sp.qty,
                         taxable: inv ? !!inv.taxable : false,
                         taxPercent: inv ? Number(inv.taxPercent || 0) : 0,
                         discountType: sp.discountType, discountValue: sp.discountValue })
        }
        var t = OrdersStore.computeOrderTotals(prods)
        return { subtotal: t.subtotal, discount: t.discount, tax: t.tax, total: t.total, itemCount: t.itemCount }
    }
```
Delete the order-level discount UI block (the `Row`/`Column` at 312-371 containing `discountTypeToggle` and `discountField`). Keep the discount **summary** line (369-371) but bind it to `dlg._totalsCache.discount` (already does). Remove `_discountType`/`_discountValue` properties (24-25) and their resets.

- [ ] **Step 5: Update the submit payload + open/close reset**

In the submit handler (492-520), each pushed product must carry its discount, and the `logic.addOrder`/`OrdersStore.addOrder` call drops the order-level discount args:
```javascript
            prods.push({ productId: selectedProducts[i].productId, name: selectedProducts[i].name,
                         qty: selectedProducts[i].qty, price: selectedProducts[i].price,
                         discountType: selectedProducts[i].discountType,
                         discountValue: selectedProducts[i].discountValue })
```
Change the order-creation call (~520) to remove `discountType: _discountType, discountValue: _discountValue`.

In `onOpened` (89-99): remove the `_discountType`/`_discountValue`/`discountField`/`discountTypeToggle` resets (no longer exist). Add an explicit close reset — add an `onClosed` handler (or wire the BottomSheet close signal) that resets cart state so cancel→reopen is clean:
```qml
    onClosed: {
        selectedProducts = []
        customerField.text = ""
        emailField.text = ""
        phoneField.text = ""
        productCombo.currentIndex = 0
        _rebuildPickerNames()
    }
```
(If `NewOrderDialog` is a `BottomSheet` subtype without a direct `onClosed`, connect to its `closed`/`opened` signal per the BottomSheet API used elsewhere — grep `onClosed` in other dialogs for the established pattern.)

- [ ] **Step 6: Manual verification (build + on-device/desktop)**

Launch the app (desktop). Open New Order → add a product (avail count drops by qty). Set a per-line discount → totals reflect it. Cancel → reopen → cart empty, avail count back to full stock. Add two lines with different discounts → submit → order total = Σ line nets + tax. Document the result in the commit body.

- [ ] **Step 7: Commit**

```bash
git add qml/pages/NewOrderDialog.qml
git commit -m "feat(neworder): per-line discount input; full reset on close

Each cart line has its own ₹/% discount; removed order-level discount UI.
onClosed clears the cart so cancel→reopen starts clean (bug 15)."
```

---

### Task 4: `OrderDetailDialog` + `ConfirmReturnSheet` — per-line discount UI + per-line discount event on save

**Files:**
- Modify: `qml/pages/OrderDetailDialog.qml` — totals (107-109), line-row delegate (~480-491), discount block (673-722 to remove), `openFor` (185-190, 253-254), `_save` (262-340)
- Modify: `qml/pages/ConfirmReturnSheet.qml` — `confirmed(...)` signal (19), `openFor`/`open` params (62-63), the `confirmed(...)` emit (90), and any UI referencing `discountType`/`discountValue` (27-30). **Drop the order-level `discountType`/`discountValue` params** — discount now lives on each line in `newLines`. Update its signature to `confirmed(orderId, newLines, reason, condition, note)` and remove the `discountType`/`discountValue` properties + their pass-through.

**Interfaces:**
- Consumes: `OrdersStore.computeOrderTotals(prods)` (Task 2); `logic.adjustOrder(...)` → `DataModel` (Task 5).
- Produces: edited line items carry `discountType`/`discountValue`; a per-line discount change on a completed order routes through the adjust path so Task 5 can emit a per-line `price_adjust` discount event.

- [ ] **Step 1: Add per-line discount editing to the line rows**

In the line-item delegate (~480-491, where `sku + price × qty` is shown), add the same per-line discount controls as Task 3 Step 2, bound to the editable line model the dialog uses. Add a `_setLineDiscount(idx, type, value)` helper mirroring Task 3 Step 3 operating on the dialog's working line array.

- [ ] **Step 2: Recompute totals per-line; remove order-level discount block**

Change the totals call (107): `var t = OrdersStore.computeOrderTotals(lineArr)`. Remove `_discountType`/`_discountValue` (42-43) usage for order-level totals; keep `_discount` (68) as the displayed summed discount from `t.discount`. Delete the order-level discount UI (673-722 `discountTypeToggle`/`discountField`), keeping the discount summary text bound to `dlg._discount`.

- [ ] **Step 3: Capture per-line original discount in `openFor`; update `_save`**

In `openFor` (185-190): remove the order-level `_discountType`/`_discountValue`/`_origDiscount*` capture; instead snapshot each line's `discountValue`/`discountType` into the working model. In `_save` (262-340): detect **per-line** discount changes (compare each working line's discount to its original) and, for a completed order, route through `logic.adjustOrder(...)` so Task 5 emits the discount event. For a non-completed order, route through the normal `logic.updateOrder`/products update. Replace the order-level `discountChanged` detection (309-311) with a per-line scan:
```javascript
            var discountChanged = false
            for (var di = 0; di < dlg._lines.length; ++di) {
                if (dlg._lines[di].discountValue !== dlg._lines[di]._origDiscountValue
                    || dlg._lines[di].discountType !== dlg._lines[di]._origDiscountType) {
                    discountChanged = true; break
                }
            }
            if (linesChanged || discountChanged) {
                logic.adjustOrder(dlg.orderId, dlg._buildAdjustedLines(), dlg._adjustReason, dlg._adjustNote)
            }
```
(Match the dialog's actual line-array property name — grep the file for the property feeding the line Repeater; the example uses `dlg._lines`. Adjust the `adjustOrder` call to the existing signal signature — see Task 5 for the finalized signature.)

- [ ] **Step 4: Update `ConfirmReturnSheet` to drop order-level discount**

In `qml/pages/ConfirmReturnSheet.qml`:
- Change the `confirmed(...)` signal (line 19) to `signal confirmed(string orderId, var newLines, string reason, string condition, string note)` — remove `string discountType, var discountValue`.
- Remove the `discountType`/`discountValue` properties (29-30) and their assignment in `openFor`/`open` (62-63).
- Change the emit (90) to `confirmed(orderId, newLines, reason, condition, note)`.
- Update the OrderDetailDialog handler of `confirmed(...)` and the `logic.adjustOrder` call to match the new arg list (discount rides inside `newLines`).

- [ ] **Step 5: Manual verification**

Build + run. Open a completed order → change one line's discount → save → order history shows a "Discount changed · <product>" event; product history (Edit Product dialog) shows the same event on that product. Confirm a return via ConfirmReturnSheet still completes (no discount params).

- [ ] **Step 6: Commit**

```bash
git add qml/pages/OrderDetailDialog.qml qml/pages/ConfirmReturnSheet.qml
git commit -m "feat(orderdetail): per-line discount editing; ConfirmReturnSheet drops order-level discount"
```

---

### Task 5: `DataModel` — per-line discount adjust event + `completeImportedOrder`

**Files:**
- Modify: `qml/model/DataModel.qml` — discount-edit handling in `_tryAdjustOrder` (~601-625 per spec), add `completeImportedOrder(orderId)`; `qml/logic/Logic.qml` if the `adjustOrder` signature changes.

**Interfaces:**
- Consumes: `TransactionStore.recordPriceAdjust(order, line, survivingQty, perUnitDelta, reason, note)` (existing); `OrdersStore.applyAdjustment(orderId, newLines, adjustmentRecord)` (Task 2 new signature); `StockBatchStore.consumeFifo`/`topUpOldest`; `OrdersStore.computeOrderTotals`.
- Produces:
  - Per-line discount edit on a completed order → one `price_adjust` event per changed line, `productId` = that line, `reason: "discount"`, `note: "discount <old>→<new> on <product>"`, with the signed revenue delta.
  - `completeImportedOrder(orderId)` → runs FIFO consumption (with shortfall handling) + `recordSaleFromOrder`; returns `{ ok: bool, understocked: bool }`.

- [ ] **Step 1: Locate the discount-edit ledger code in `_tryAdjustOrder`**

Run:
```bash
grep -n "recordPriceAdjust\|oldDiscAmt\|applyAdjustment\|_tryAdjustOrder\|recordSaleFromOrder" qml/model/DataModel.qml
```
Read the surrounding 40 lines of the discount-delta block.

- [ ] **Step 2: Replace order-wide discount delta with per-line discount deltas**

Where the code currently computes a single order-wide discount delta and calls `recordPriceAdjust(o, {productId:"", name:"Discount"}, 1, delta, "discount", ...)`, replace with a per-line loop that emits one event per changed line. For each line whose discount changed between `before` and `after` order state:
```javascript
            // Per-line discount edit → one price_adjust per changed line so the
            // delta nets against the REAL product (and its supplier) in reports
            // and shows in that product's history.
            var beforeAlloc = OrderMath.allocate(beforeOrder)
            var afterAlloc = OrderMath.allocate(afterOrder)
            var beforeNetByPid = {}, afterNetByPid = {}
            for (var bi = 0; bi < beforeAlloc.perLine.length; ++bi)
                beforeNetByPid[beforeAlloc.perLine[bi].productId] = beforeAlloc.perLine[bi]
            for (var ai = 0; ai < afterAlloc.perLine.length; ++ai) {
                var al = afterAlloc.perLine[ai]
                var bl = beforeNetByPid[al.productId]
                if (!bl) continue
                var netDelta = al.net - bl.net           // discount up → net down → negative
                if (Math.abs(netDelta) < 0.005) continue
                var qty = al.qty || 1
                // recordPriceAdjust expects perUnitDelta = old - new price-equivalent;
                // here the revenue delta is netDelta, spread over surviving qty.
                var perUnitDelta = -(netDelta / qty)     // so revenueDelta = -(qty*perUnitDelta) = netDelta
                TransactionStore.recordPriceAdjust(
                    afterOrder,
                    { productId: al.productId, name: al.name },
                    qty, perUnitDelta, "discount",
                    "discount " + (bl.discountShare) + "->" + (al.discountShare) + " on " + al.name)
            }
```
Update the `OrdersStore.applyAdjustment(...)` call to the new 3-arg signature (drop the discountType/value args).

- [ ] **Step 3: Add `completeImportedOrder`**

Add a public method modelled on `_tryCompleteOrder` (336-409) but tolerant of shortfall (per the "complete + report shortfall" decision) and **without** the `out of stock` early-return:
```javascript
    // Complete an imported order that arrived with status "completed".
    // Mirrors _tryCompleteOrder's FIFO + sale-recording, but never fails on
    // insufficient stock: it consumes what's available, tops up the deficit so
    // the sale still books, and reports the shortfall to the caller.
    // Returns { ok, understocked }.
    function completeImportedOrder(orderId) {
        var o = OrdersStore.getById(orderId)
        if (!o) return { ok: false, understocked: false }
        var understocked = false
        var linesWithConsumption = []
        if (o.products && o.products.length > 0) {
            for (var j = 0; j < o.products.length; ++j) {
                var pp = o.products[j]
                var qqty = _lineQty(pp)
                var invP = _resolveInventory(pp)
                var consumption = []
                if (invP && qqty > 0) {
                    if ((invP.stock || 0) < qqty) understocked = true
                    consumption = StockBatchStore.consumeFifo(invP.productId, qqty)
                    var consumed = _sumConsumed(consumption)
                    if (consumed < qqty) {
                        StockBatchStore.topUpOldest(invP.productId, qqty - consumed)
                        var retry = StockBatchStore.consumeFifo(invP.productId, qqty - consumed)
                        for (var r = 0; r < retry.length; ++r) consumption.push(retry[r])
                    }
                    InventoryStore.deductStock(invP.productId, qqty)
                }
                var line = {}
                for (var k in pp) line[k] = pp[k]
                line.consumption = consumption
                linesWithConsumption.push(line)
            }
        }
        OrdersStore.updateOrder(orderId, {
            products: linesWithConsumption.length > 0 ? linesWithConsumption : undefined
        })
        SalesStore.recordSale(o.total, o.items)
        TransactionStore.recordSaleFromOrder(OrdersStore.getById(orderId))
        _updateOrderInModel(orderId)
        return { ok: true, understocked: understocked }
    }
```
(Confirm `_lineQty`, `_resolveInventory`, `_sumConsumed`, `_updateOrderInModel` exist in DataModel — they're used by `_tryCompleteOrder` above.)

- [ ] **Step 4: Update `Logic.qml` if `adjustOrder` signature changed**

If Task 4's `_save` calls `logic.adjustOrder` with a different arg list, update the signal in `qml/logic/Logic.qml` and the `onAdjustOrder` handler signature in DataModel to match. Otherwise no change.

- [ ] **Step 5: Manual verification**

Build + run. (a) Edit a completed order's line discount → exactly one discount `price_adjust` event per changed line appears in order + product history, and Revenue nets down by the right amount. (b) Defer import verification to Task 7.

- [ ] **Step 6: Commit**

```bash
git add qml/model/DataModel.qml qml/logic/Logic.qml
git commit -m "feat(datamodel): per-line discount events; completeImportedOrder with shortfall handling"
```

---

### Task 6: `InventoryStore.upsertMany` — opening batch + created txn + supplierId

**Files:**
- Modify: `qml/model/InventoryStore.qml` — `upsertMany` (473-536), `_normalizeRecord` (538-559), `_mergeRecord` (561-586)

**Interfaces:**
- Consumes: `_resolveSupplierId(party)` (439-451, existing); `TransactionStore.recordCreated(...)`; `StockBatchStore.addBatch(...)`; `ActivityLog` (Task 8 adds `import` kind, but per-product events use `recordCreated`).
- Produces: every imported **new** product (add or rename) gets a `created` transaction (tagged origin `imported`) and, when `stock > 0`, one opening `StockBatchStore` batch with the resolved `supplierId`. `_normalizeRecord`/`_mergeRecord` carry a `supplierId` field. Overwrite path does **not** create batches.

- [ ] **Step 1: Add `supplierId` to `_normalizeRecord` and `_mergeRecord`**

In `_normalizeRecord` (538-559) add (resolving a `supplier` name or `supplierId` to a stable id):
```javascript
            supplierId: r.supplierId || (r.supplier ? _resolveSupplierId(r.supplier) : ""),
```
In `_mergeRecord` (561-586) add `"supplierId"` to the `keys` array so an overwrite preserves/updates it.

- [ ] **Step 2: Factor the per-new-product side-effects into a helper**

Add a private helper near `addProduct` that books creation + opening batch for an imported doc (mirrors `addProduct` 414-430 but tagged imported):
```javascript
    // Book the ledger side-effects for an imported product so analytics
    // (Value / Purchased / Profit / by-supplier) populate exactly as if the
    // product had been created in-app. Opening batch only when stock > 0.
    function _bookImportedProduct(doc) {
        var supplierId = doc.supplierId || "";
        var batchCost = (typeof doc.price === "number" && !isNaN(doc.price)) ? doc.price : 0;
        TransactionStore.recordCreated(doc.productId, doc.name, doc.stock, batchCost, {
            sku: doc.sku || "", category: doc.category || "", unit: doc.unit || "",
            sellingPrice: doc.sellingPrice, taxable: doc.taxable, taxPercent: doc.taxPercent,
            minStock: doc.minStock || 0, description: doc.description || "",
            supplierId: supplierId, origin: "imported"
        }, supplierId);
        if (doc.stock > 0)
            StockBatchStore.addBatch(doc.productId, supplierId, doc.stock, batchCost, "Imported opening stock");
    }
```

- [ ] **Step 3: Call the helper on the two add paths in `upsertMany`**

In `upsertMany`, after `var renamedDoc = _normalizeRecord(r); arr.push(renamedDoc);` (rename branch, ~502-503) add `_bookImportedProduct(renamedDoc);`. After `var doc = _normalizeRecord(r); arr.push(doc);` (new-row branch, ~525-526) add `_bookImportedProduct(doc);`. Do **not** add it to the overwrite branch (511-516).

- [ ] **Step 4: Sanity-check no double Firebase storms**

`recordCreated` and `addBatch` each route one `Gateway.recordMutation` per call (per-product), which matches in-app `addProduct`. `products = arr` is still assigned once at the end (534). Confirm by reading the final `upsertMany`. No additional change needed.

- [ ] **Step 5: Manual verification (deferred to Task 7 end-to-end)**

No isolated test — verified via Task 7's import flow. Just build to confirm it compiles/loads:
```bash
grep -n "_bookImportedProduct\|supplierId" qml/model/InventoryStore.qml
```
Expected: helper defined once, called in both add branches; `supplierId` in normalize + merge keys.

- [ ] **Step 6: Commit**

```bash
git add qml/model/InventoryStore.qml
git commit -m "feat(inventory): import writes opening batch + created txn + supplierId

upsertMany now mirrors addProduct's ledger side-effects for new/renamed
imported products so Value/Purchased/Profit/by-supplier populate. Overwrite
stays a field merge (no duplicate opening batches)."
```

---

### Task 7: `ImportPreviewDialog` — supplier column, validation contract, completion loop, activity summary

**Files:**
- Modify: `qml/pages/ImportPreviewDialog.qml` — `_validateProductRows` (320-375), `_validateOrderRows` (377-492), `_apply` (529-541); add warnings state.

**Interfaces:**
- Consumes: `InventoryStore.upsertMany` (Task 6), `OrdersStore.upsertMany` (Task 2), `DataModel.completeImportedOrder` (Task 5), `ActivityLog.record("import", …)` (Task 8). `dataModel` is reachable via dynamic scoping (this dialog is hoisted at App root — confirm how it reaches DataModel; if not, route through a new `logic.completeImportedOrders(ids)` signal).
- Produces: hard-reject vs default+warn validation per the finalized contract; a per-line `discountType`/`discountValue` passed through; imported completed orders completed via DataModel; one import ActivityLog summary; an aggregated warnings list surfaced in the preview.

- [ ] **Step 1: Add warning aggregation state**

Add near `_issueRows`:
```qml
    property var _warnRows: []   // [{ row, message }] non-blocking, analysis-impacting defaults
```
Surface `_warnRows` in the preview UI under the existing issues section (a yellow "Imported with warnings — these affect report accuracy" list). Match the existing `_issueRows` rendering pattern.

- [ ] **Step 2: Product validation — identifier + Cost Price mandatory; Unit/SKU default+warn**

In `_validateProductRows` (320-375), after the Name and Selling Price checks add:
```javascript
            var pid = (r["Product ID"] || "").toString().trim()
            var skuRaw = (r["SKU"] || "").toString().trim()
            if (!pid && !skuRaw) {
                issues.push({ row: row, message: "Missing identifier: need SKU or Product ID" })
                continue
            }
            var costRawV = r["Cost Price"]
            if (costRawV === undefined || costRawV === null || String(costRawV).trim() === "" || isNaN(parseFloat(costRawV))) {
                issues.push({ row: row, message: "Missing Cost Price (required for value/profit reports)" })
                continue
            }
```
(Keep the existing `cost`/`sell` parse below; the `cost < 0 → 0` clamp stays.) Add the Supplier column + warnings to the `rec`:
```javascript
                supplier: (r["Supplier"] || "").toString().trim(),
```
After building `rec`, push warnings for defaulted fields:
```javascript
            if (!(r["Unit"] || "").toString().trim())
                _warnRows.push({ row: row, message: name + ": Unit defaulted to 'Units (pcs)'" })
            if (!skuRaw && pid)
                _warnRows.push({ row: row, message: name + ": SKU will be auto-generated" })
```
(Initialize `var warns = []` at the top alongside `ready`/`issues`, push to it, and assign `_warnRows = warns` at the end next to `_readyRows`/`_issueRows`.)

- [ ] **Step 3: Order validation — line identifier mandatory; missing Qty rejects line; price/date default+warn**

In `_validateOrderRows` line loop (432-462), change the empty-line skip and add the per-line rules:
```javascript
                var pid = (lineSrc["Product ID"] || "").toString().trim()
                var sku = (lineSrc["SKU"] || "").toString().trim()
                var qtyRaw = lineSrc["Quantity"]
                var hasQty = !(qtyRaw === undefined || qtyRaw === null || String(qtyRaw).trim() === "")
                var qty = parseInt(qtyRaw) || 0
                if (!pid && !sku && !hasQty) continue          // genuinely empty continuation line
                if (!pid && !sku) {                            // has data but no identifier → reject line
                    unresolved.push("row " + lineRow + ": missing Product ID/SKU"); continue
                }
                var inv = null
                if (pid && idToProduct[pid]) inv = idToProduct[pid]
                else if (sku && skuToProduct[sku.toLowerCase()]) inv = skuToProduct[sku.toLowerCase()]
                if (!inv) { unresolved.push("row " + lineRow + ": " + (pid || sku)); continue }
                if (!hasQty || qty <= 0) {                     // reject the LINE, keep the order
                    warns.push({ row: lineRow, message: inv.name + ": line skipped — missing Quantity" })
                    continue
                }
                var unitPriceRaw = lineSrc["Unit Price"]
                var unitPrice = parseFloat(unitPriceRaw)
                if (isNaN(unitPrice)) {
                    unitPrice = inv.sellingPrice || inv.price || 0
                    warns.push({ row: lineRow, message: inv.name + ": Unit Price defaulted to current selling price (may differ from sale price)" })
                }
```
Carry the per-line discount onto the pushed product:
```javascript
                var lnDt = (lineSrc["Discount Type"] || "flat").toString().trim().toLowerCase()
                if (lnDt !== "percent") lnDt = "flat"
                var lnDv = parseFloat(lineSrc["Discount Value"]); if (isNaN(lnDv)) lnDv = 0
                prods.push({
                    productId: inv.productId, name: inv.name, price: unitPrice,
                    quantity: qty, taxable: taxable, taxPercent: taxPct,
                    discountType: lnDt, discountValue: lnDv
                })
```
For the order Date (480), warn when defaulted:
```javascript
            var dateStr = (head["Date"] || "").toString().trim()
            if (!dateStr) warns.push({ row: grp.firstRow, message: customer + ": Date defaulted to import day (skews time-series)" })
```
Remove the order-level `dt`/`dv` block (468-471) and the `discountType`/`discountValue` keys from `rec` (482-483) — discount is per-line now.

- [ ] **Step 4: `_apply` — supplier passthrough, completion loop, activity summary**

Rewrite `_apply` (529-541):
```javascript
    function _apply() {
        var counts, understocked = 0
        if (mode === "products") {
            counts = InventoryStore.upsertMany(_readyRows)
        } else {
            // Snapshot which orders are new+completed BEFORE upsert so we can
            // run completion only on freshly-added completed orders.
            counts = OrdersStore.upsertMany(_readyRows)
            for (var i = 0; i < _readyRows.length; ++i) {
                var rec = _readyRows[i]
                if (rec._conflictWith && rec._conflictPolicy === "skip") continue
                if (rec.status !== "completed") continue
                var oid = rec.orderId
                if (!oid) continue   // anon orders got ids inside upsert; skip auto-id edge for now
                var res = dataModel.completeImportedOrder(oid)
                if (res && res.understocked) understocked++
            }
        }

        var n = counts.added + counts.updated
        var msg = "Imported " + n + " row" + (n === 1 ? "" : "s")
        if (counts.skipped > 0) msg += " · " + counts.skipped + " skipped"
        if (understocked > 0) msg += " · " + understocked + " completed with insufficient stock"
        if (_warnRows.length > 0) msg += " · " + _warnRows.length + " warning(s)"

        // One Recent-Activity entry so the import is visible (bug 7).
        ActivityLog.record("import",
            (mode === "products" ? "Imported products" : "Imported orders"),
            msg, "")

        importCompleted(msg)
        close()
    }
```
**Note on anon orders:** orders without an Order ID get an id assigned *inside* `OrdersStore.upsertMany`, which `_readyRows[i].orderId` won't see. To complete those too, have `upsertMany` return the list of added ids, OR (simpler) assign a synthetic `orderId` in `_validateOrderRows` for anon completed orders. Pick the return-ids approach: extend `upsertMany` to also return `addedIds: []` and iterate those for completion. Update Task 2's `upsertMany` accordingly if not already. **Implementer: confirm and wire this** — do not leave anon completed orders un-booked.

- [ ] **Step 5: Confirm `dataModel` reachability**

Run:
```bash
grep -n "dataModel\|ImportPreviewDialog" qml/Main.qml
```
If `ImportPreviewDialog` is instantiated under the App root with `dataModel` in scope, the direct call works. If not, add a `logic.completeImportedOrder(orderId)` signal + `DataModel` handler and call that instead.

- [ ] **Step 6: Manual end-to-end verification**

Build + run. Prepare a products xlsx (with Supplier column, stock>0) and an orders xlsx (status completed, valid SKUs). Import products → InventoryStore shows them; Analysis → Value/Purchased/Current-by-supplier/Potential profit all non-zero. Import orders → Sold/Realised profit/Revenue-by-supplier non-zero. Recent activity shows "Imported products/orders". Product & order detail show history (created/sale events). Try a sheet with a missing-qty line and a missing-date order → warnings listed; line skipped; order still imported. Document results in commit.

- [ ] **Step 7: Commit**

```bash
git add qml/pages/ImportPreviewDialog.qml qml/model/OrdersStore.qml
git commit -m "feat(import): supplier column, per-line discount, validation contract, completion + activity

Hard-reject missing identifier/Cost Price (products) and Customer/line-id
(orders); reject missing-qty lines; default+warn for unit price/date/unit/sku.
Imported completed orders run FIFO completion (shortfall reported); one
Recent-Activity summary per import."
```

---

### Task 8: `ActivityLog` `import` kind + Dashboard/ActivityPage icons

**Files:**
- Modify: `qml/model/ActivityLog.qml` (kind doc comment 4-24; `record` accepts any kind already), `qml/pages/DashboardPage.qml` (icon map ~457-466), `qml/pages/ActivityPage.qml` (icon map ~98-146)

**Interfaces:**
- Consumes: `ActivityLog.record("import", title, subtitle, "")` (Task 7).
- Produces: an icon + palette for `kind: "import"` in both activity surfaces.

- [ ] **Step 1: Document the new kind**

In `ActivityLog.qml` lines 4-24 comment, add `| "import"` to the `kind:` enum list. No functional change to `record()` (it accepts any string).

- [ ] **Step 2: Add icon mapping in DashboardPage**

In `DashboardPage.qml` icon/palette mapping (~457-466), add a branch for `"import"`:
```qml
                            : modelData.kind === "import" ? "import"   // use an existing Icon name; see helper/Icon set
```
with a gradient token consistent with the others (e.g. `grad2`). If the icon set has no `import` glyph, reuse an existing one (e.g. `"product-added"` or a download/upload glyph) — grep `qml/components/Icon.qml` / the icon assets for an available name first:
```bash
grep -rn "import\|upload\|download\|file" qml/components/Icon.qml
```

- [ ] **Step 3: Add icon mapping in ActivityPage**

Mirror Step 2 in `ActivityPage.qml` (~98-146).

- [ ] **Step 4: Manual verification**

Covered by Task 7 Step 6 (the import entry renders with an icon, not a blank/fallback).

- [ ] **Step 5: Commit**

```bash
git add qml/model/ActivityLog.qml qml/pages/DashboardPage.qml qml/pages/ActivityPage.qml
git commit -m "feat(activity): render 'import' kind in recent activity feeds (bug 7)"
```

---

### Task 9: `XlsxService` — order SKU/Staff, product Supplier, README contract

**Files:**
- Modify: `src/XlsxService.cpp` — `kProductHeaders` (18-21), `kOrderHeaders` (26-32), `writeProductsSheet` (64-96), `writeOrdersSheet` (98-194), `writeReadmeSheet` (196-283)

**Interfaces:**
- Consumes: product maps now optionally carry `supplier` (name string, attached by Main.qml Task 10); order line maps carry `sku` and order maps carry `staffName` (Task 10).
- Produces: Products sheet gains a **Supplier** column; Orders sheet writes **SKU** per line and gains a **Staff** column; README required-column lists updated.

- [ ] **Step 1: Update header constants**

`kProductHeaders` (18-21) — append `"Supplier"`:
```cpp
const QStringList kProductHeaders = {
    "Product ID", "Name", "SKU", "Category", "Unit", "Description",
    "Cost Price", "Selling Price", "Stock", "Min Stock", "Photo URL", "Supplier"
};
```
`kOrderHeaders` (26-32) — add `"Staff"` after `"Phone"`, and keep `"SKU"` (now populated). Add per-line `"Discount Type"`/`"Discount Value"` and drop the order-level discount columns (per-line model). New list:
```cpp
const QStringList kOrderHeaders = {
    "Order ID", "Customer", "Email", "Phone", "Staff", "Status", "Date", "Notes",
    "Order Subtotal", "Order Discount", "Order Tax", "Tax Collected", "Order Total",
    "Product ID", "SKU", "Product Name", "Quantity", "Unit Price",
    "Discount Type", "Discount Value", "Tax %", "Line Tax", "Line Total"
};
```
("Tax Collected" = order tax total, the explicit tax line for item 16. It equals Order Tax; included as the named column the owner asked for.)

- [ ] **Step 2: Write the Supplier column in `writeProductsSheet`**

After line 81 (`photoUrl` at col 11) add:
```cpp
        doc.write(row, 12, variantToString(p.value("supplier")));
```
Add a column width: `doc.setColumnWidth(12, 20);`.

- [ ] **Step 3: Rewrite `writeOrdersSheet` column layout**

Update the order-header lambda and line writes to the new column indices. Replace the header-col lambda (121-135) and line block (143-170). Header columns now:
```cpp
        const QString staffName = variantToString(o.value("staffName"));
        // ... existing locals ...
        auto writeOrderHeaderCols = [&](int r) {
            doc.write(r, 1,  orderId);
            doc.write(r, 2,  customer);
            doc.write(r, 3,  email);
            doc.write(r, 4,  phone);
            doc.write(r, 5,  staffName);
            doc.write(r, 6,  status);
            doc.write(r, 7,  date);
            doc.write(r, 8,  notes);
            doc.write(r, 9,  subtotal);
            doc.write(r, 10, discount);
            doc.write(r, 11, tax);
            doc.write(r, 12, tax);            // Tax Collected (same as Order Tax)
            doc.write(r, 13, total);
        };
```
Line columns (replace 143-170):
```cpp
        for (const QVariant &it : items) {
            const QVariantMap line = it.toMap();
            writeOrderHeaderCols(row);

            const QString lineProductId = variantToString(line.value("productId"));
            const QString sku = variantToString(line.value("sku"));   // now populated by QML
            const int qty = static_cast<int>(variantToNumber(line.value("quantity")));
            const double unitPrice = variantToNumber(line.value("price"));
            const QString lnDiscType = variantToString(line.value("discountType"));
            const double lnDiscVal = variantToNumber(line.value("discountValue"));
            const double taxPct = variantToNumber(line.value("taxPercent"));
            const bool taxable = line.value("taxable").toBool();
            const double lineGross = qty * unitPrice;
            double lineDisc = (lnDiscType == QLatin1String("percent"))
                ? lineGross * (lnDiscVal / 100.0)
                : qMin(lnDiscVal, lineGross);
            const double lineNet = lineGross - lineDisc;
            const double lineTax = (taxable && taxPct > 0) ? (lineNet * (taxPct / 100.0)) : 0.0;

            doc.write(row, 14, lineProductId);
            doc.write(row, 15, sku);
            doc.write(row, 16, variantToString(line.value("name")));
            doc.write(row, 17, qty);
            doc.write(row, 18, unitPrice);
            doc.write(row, 19, lnDiscType);
            doc.write(row, 20, lnDiscVal);
            doc.write(row, 21, taxable ? taxPct : 0.0);
            doc.write(row, 22, lineTax);
            doc.write(row, 23, lineGross);
            ++row;
        }
```
Update the column-width block (173-193) to cover columns 1–23 with sensible widths (extend the existing list; add Staff at 5, Discount Type/Value at 19/20).

- [ ] **Step 4: Update README required-column lists**

In `writeReadmeSheet`, products `rows[]` (225-237): mark mandatory per the contract — `SKU *`, `Unit *`, `Cost Price *`, `Min Stock *` become `"yes"` with updated notes; add a `Supplier` row. Keep `Name *`, `Selling Price *`. Example changed/added rows:
```cpp
            {"SKU *",         "yes", "text",   "Required unless Product ID is given. Used by the Orders sheet to reference products."},
            {"Unit *",        "yes", "text",   "e.g. Units (pcs), Kg, Litres. Defaults to 'Units (pcs)' if blank."},
            {"Cost Price *",  "yes", "number", "What you pay your supplier. Required — drives value & profit reports."},
            {"Min Stock *",   "yes", "integer","Reorder threshold."},
            {"Supplier",      "no",  "text",   "Supplier name. Creates an opening stock batch so by-supplier reports work."},
```
Update the intro note (213-214) to: "required fields are marked with an asterisk; some defaults degrade report accuracy when left blank."

Orders `rows[]` (247-269): mark `Staff` (new), `Status *`, `Date *`, `SKU *`, `Quantity *`, `Unit Price *` per the contract; replace order-level Discount rows with per-line Discount Type/Value; add Tax Collected. Example:
```cpp
            {"Staff",         "no",  "text",   "Salesperson name. Informational on export."},
            {"Status *",      "yes", "text",   "One of: pending, processing, completed, out of stock."},
            {"Date *",        "yes", "date",   "yyyy-MM-dd preferred. Blank defaults to import day (skews time-series)."},
            {"SKU *",         "yes", "text",   "Required unless Product ID is given. Resolves the line to a product."},
            {"Quantity *",    "yes", "integer","Per-line quantity. A line with no quantity is skipped on import."},
            {"Unit Price *",  "yes", "number", "Per-line price. Blank falls back to current selling price (may differ)."},
            {"Discount Type", "no",  "text",   "'flat' or 'percent' — per LINE."},
            {"Discount Value","no",  "number", "Per-line discount amount."},
            {"Tax Collected", "no",  "number", "Order tax total (pass-through; not part of revenue)."},
```

- [ ] **Step 5: Build**

Run:
```bash
cmake --build build
```
Expected: compiles clean (no missing-symbol / signature errors in XlsxService).

- [ ] **Step 6: Commit**

```bash
git add src/XlsxService.cpp
git commit -m "feat(export): order SKU+Staff, product Supplier, per-line discount cols, README contract

Orders export now writes SKU per line, a Staff column, per-line discount,
and an explicit Tax Collected column. Products export adds Supplier. README
marks the owner's mandatory columns with asterisks."
```

---

### Task 10: `Main.qml` export wiring — attach sku / staffName / supplier

**Files:**
- Modify: `qml/Main.qml` — `_exportProducts` (825-827), `_exportOrders` (829-831)

**Interfaces:**
- Consumes: `InventoryStore.products`, `OrdersStore.orders`, `SupplierStore.nameOf(id)`, `StaffStore` name lookup, `InventoryStore.getById(productId).sku`.
- Produces: enriched arrays passed to `XlsxService.writeProducts`/`writeOrders` so C++ (Task 9) can write supplier/sku/staffName.

- [ ] **Step 1: Enrich products with supplier name before export**

Replace `_exportProducts` (825-827):
```qml
    function _exportProducts() {
        var src = InventoryStore.products || []
        var out = []
        for (var i = 0; i < src.length; ++i) {
            var p = src[i]
            var clone = JSON.parse(JSON.stringify(p))
            // supplierId may live on the product or on its latest batch/txn.
            var sid = p.supplierId || TransactionStore.lastSupplierFor(p.productId)
            clone.supplier = sid ? (SupplierStore.nameOf(sid) || "") : ""
            out.push(clone)
        }
        _deliverExport(XlsxService.writeProducts(out, ""), qsTr("Products"))
    }
```
(Confirm `SupplierStore.nameOf` exists — Task 11/spec references it; otherwise use `SupplierStore.getById(sid).name`.)

- [ ] **Step 2: Enrich orders with per-line SKU and staff name before export**

Replace `_exportOrders` (829-831):
```qml
    function _exportOrders() {
        var src = OrdersStore.orders || []
        var out = []
        for (var i = 0; i < src.length; ++i) {
            var o = JSON.parse(JSON.stringify(src[i]))
            o.staffName = o.staffId ? (StaffStore.nameOf(o.staffId) || "") : ""
            var lines = o.products || []
            for (var j = 0; j < lines.length; ++j) {
                var inv = lines[j].productId ? InventoryStore.getById(lines[j].productId) : null
                lines[j].sku = inv && inv.sku ? inv.sku : ""
            }
            out.push(o)
        }
        _deliverExport(XlsxService.writeOrders(out, ""), qsTr("Orders"))
    }
```
(Confirm `StaffStore.nameOf` exists; if not, look up via `StaffStore.getById(id).name` — grep `StaffStore.qml` for the accessor.)

- [ ] **Step 3: Verify accessors exist**

Run:
```bash
grep -n "function nameOf\|function getById" qml/model/SupplierStore.qml qml/model/StaffStore.qml
```
Use whichever accessor exists; adjust Steps 1–2 to match.

- [ ] **Step 4: Manual verification**

Build + run. Export products → Supplier column populated for products that have a supplier. Export orders → SKU populated per line, Staff column shows the salesperson. Re-import the exported products file → supplier round-trips (by-supplier reports populate). Document in commit.

- [ ] **Step 5: Commit**

```bash
git add qml/Main.qml
git commit -m "feat(export): attach supplier name, per-line SKU, and staff name before xlsx write"
```

---

### Task 11: `OrderDetailDialog` history — show SKU + always show reason notes

**Files:**
- Modify: `qml/pages/OrderDetailDialog.qml` — `_detailFor` (804-812), history row delegate (814-866)

**Interfaces:**
- Consumes: `TransactionStore.forOrder(orderId)` events; `InventoryStore.getById(e.productId).sku`.
- Produces: each history row shows the line's SKU; the reason note text is shown for every reason category that carries a note (including `reopened`).

- [ ] **Step 1: Always show the note in `_detailFor`**

Replace `_detailFor` (804-812):
```qml
            function _detailFor(e) {
                var parts = []
                if ((e.kind === "price_adjust" || e.kind === "return") && e.reason) {
                    // Show the reason label for every category (including reopened).
                    parts.push(e.reason.charAt(0).toUpperCase() + e.reason.slice(1))
                }
                if (e.note && e.note.length > 0) parts.push(e.note)
                return parts.join(" · ")
            }
```
(The change: drop the `&& e.reason !== "reopened"` guard so reopened notes render; the note is always appended when present.)

- [ ] **Step 2: Add SKU to the history row**

In the history row delegate (827-864), where the title renders (~843), add a SKU caption resolved from inventory. Add a `Text` (or extend the detail line) bound to:
```qml
                            // SKU for the line product (blank for order-wide discount rows).
                            property string _sku: {
                                if (!modelData.productId) return ""
                                var inv = InventoryStore.getById(modelData.productId)
                                return inv && inv.sku ? inv.sku : ""
                            }
```
and show `_sku` next to the product name (e.g. as a secondary caption). Hide when empty (`visible: _sku.length > 0`).

- [ ] **Step 3: Manual verification**

Build + run. Open an order with sale + a discount edit + a reopen → each row shows the product SKU; the reopen event shows its note text; discount/return reasons show with their notes.

- [ ] **Step 4: Commit**

```bash
git add qml/pages/OrderDetailDialog.qml
git commit -m "feat(orderhistory): show SKU per line and always render reason notes (bug 14)"
```

---

### Task 12: `BreakdownBarCard` — value label at the bar bottom

**Files:**
- Modify: `qml/components/BreakdownBarCard.qml:141-154`

**Interfaces:**
- Consumes: `barCell._barH`, `barCell._labelInside`, `modelData.value`.
- Produces: the per-bar value caption sits just above the x-axis baseline (bottom of the bar) for tall bars; short bars still float their label above the bar so it stays readable.

- [ ] **Step 1: Re-anchor the label to the bottom for tall bars**

Replace the `Text` block (141-154):
```qml
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            // Tall bars: sit just inside the bar's BOTTOM edge
                            // (above the x-axis). Short bars: float above the bar.
                            anchors.bottomMargin: barCell._labelInside
                                    ? dp(4)
                                    : barCell._barH + dp(2)
                            visible: root.showValueTips && modelData.value > 0
                            text: root._formatAxis(modelData.value)
                            color: barCell._labelInside ? Constants.textOnBrand : Constants.textSecondary
                            font.pixelSize: sp(Constants.fsCaption)
                            font.bold: true
                        }
```
(Only the `bottomMargin` for the `_labelInside` branch changes: from `Math.max(dp(2), _barH - dp(16))` (near top) to `dp(4)` (near bottom).)

- [ ] **Step 2: Manual verification**

Build + run. Open Analysis → any view with `showValueTips` → numbers render at the bottom of each tall bar, just above the axis; short-bar labels still float above. Document in commit.

- [ ] **Step 3: Commit**

```bash
git add qml/components/BreakdownBarCard.qml
git commit -m "fix(chart): render bar value labels at the bottom of bars (bug 13)"
```

---

## Self-Review

**Spec coverage:**
- Items 1,2,5,6 (Value/Purchased/Sold/Profit = 0) → Task 6 (opening batch + created txn) + Task 5/7 (imported order completion). ✓
- Item 3 (Current-by-supplier; supplier export/import) → Task 6 (supplierId + batch), Task 7 (supplier column read), Task 9/10 (supplier export). Batch sheet intentionally excluded per decision. ✓
- Item 4 (Revenue by supplier) → Task 5/7 (consumption lineage on imported completed orders). ✓
- Item 7 (no import activity) → Task 7 + Task 8. ✓
- Item 8 (no history in product/order) → Task 6 (created event), Task 5/7 (sale events). ✓
- Item 9 (staff in order export) → Task 9 (Staff col) + Task 10 (staffName). ✓
- Item 10 (SKU in order export) → Task 9 (populate col 15) + Task 10 (attach sku). ✓
- Items 11,12 (README mandatory) → Task 9 Step 4 + Task 7 validation. ✓
- Item 13 (bar labels at bottom) → Task 12. ✓
- Item 14 (SKU + notes in order history) → Task 11. ✓
- Item 15 (picker reset) → Task 3 Step 5. ✓
- Item 16 (tax line, keep net) → Task 9 (Tax Collected column); no revenue redefinition. ✓
- Item 17 (per-item discount + history) → Tasks 1,2,3,4,5. ✓

**Type consistency:** `computeOrderTotals(prods)` single-arg used consistently (Tasks 2,3); `discountType`/`discountValue` per line everywhere (Tasks 1,2,3,4,7,9,10); `completeImportedOrder` returns `{ok,understocked}` (Tasks 5,7); `_bookImportedProduct(doc)` (Task 6); `applyAdjustment(orderId,newLines,adjustmentRecord)` 3-arg (Tasks 2,5). 

**Open items flagged for implementer:**
- Task 7 Step 4: anon (no-id) completed orders — extend `OrdersStore.upsertMany` to return `addedIds` and complete those; do not leave un-booked.
- Task 3/4: confirm exact component names (`AppTextField`/`SegmentedPill`/line-array property) against the files before writing the UI rows.
- Task 8/10/11: confirm `Icon` glyph name, `SupplierStore.nameOf`/`StaffStore.nameOf` accessors exist; fall back to `getById().name`.

**Placeholder scan:** no TBD/TODO; every code step shows real code. Manual-verification steps are explicit (page-level QML can't run headless — only Task 1 has automated tests, per the project's testing posture).
