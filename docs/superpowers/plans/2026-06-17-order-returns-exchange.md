# Order Returns / Exchange / Cancellation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let owner/admin/manager process partial returns, exchanges, modifications, and cancellations on a *completed* order, writing cost-accurate reverse-FIFO stock restores and immutable negative sale-ledger events so inventory and every Analysis report stay correct.

**Architecture:** A `_tryAdjustOrder` orchestrator in `DataModel` (sibling to the existing `_tryCompleteOrder`) diffs the edited lines against the order's current lines, reverses FIFO consumption to the original batches, writes negative `kind:"return"` transaction events, and updates the order + an `adjustments[]` audit log. The risky pure math (line diff, per-batch restore plan) lives in a new headless-testable `qml/helper/OrderAdjust.js`. A confirm-on-save sheet (hoisted to the App root, per the nested-popup gotcha) captures reason + condition with an impact preview. The Analysis layer is taught to net `kind:"return"` events.

**Tech Stack:** Felgo / Qt 6 QML, `pragma Singleton` stores, `qmltestrunner.exe` (QtTest) for pure-logic tests.

---

## Background the implementer needs

This is a Felgo/QML business app. The order/stock/sale data flow:

- **Orders** (`OrdersStore.orders`) carry `products[]` line items. A completed order's lines each have a `consumption[]` array — `[{ batchId, supplierId, qtyConsumed, unitCost }]` — stamped at completion, recording which FIFO batches the sale drew from and at what captured cost.
- **Stock batches** (`StockBatchStore.batches`) are FIFO lots: `{ batchId, productId, supplierId, qtyReceived, qtyRemaining, unitCost, receivedDate, ... }`. `consumeFifo(productId, qty)` drains oldest-first and returns the consumption array; batches are **never deleted** (only `qtyRemaining` zeroed), so any `batchId` is always findable via `getById`.
- **Transactions** (`TransactionStore.entries`) are the append-only ledger. `recordSaleFromOrder(order)` writes one `kind:"sale"` doc per line with `{ quantity, unitPrice, unitCost, total, consumption[], orderChannel, staffId, ... }`. The Analysis reports read this ledger.
- **Cross-store orchestration lives in `DataModel`**, never in a store. `_tryCompleteOrder` (DataModel.qml:280) is the model: validate → `consumeFifo` + `deductStock` → `updateOrder` with consumption → `recordSaleFromOrder`. Our `_tryAdjustOrder` mirrors it in reverse.

**Critical project conventions (verified / from memory):**
- **Pure JS helpers** go in `qml/helper/*.js` as `.pragma library` (e.g. `StockReconcile.js`, `BreakdownMath.js`, `StaffScope.js`) and are unit-tested via `qmltestrunner`. Tests live in `tests/` (outside `qml/`, not packaged). New `.qml`/`.js` under `qml/` are auto-globbed (`CONFIGURE_DEPENDS`); a brand-new file may need a one-time `cmake --preset` reconfigure before the build picks it up.
- **Nested popups gotcha (memory `feedback_qml_nested_popup_hoist`):** a `Popup`/`Dialog`/`BottomSheet` declared *inside* another BottomSheet's body opens off-screen. The confirm-on-save sheet MUST be declared at the App root (`Main.qml`) and triggered via a signal from `OrderDetailDialog` — NOT nested inside it.
- **Button alignment (memory):** center icon+text in any tappable control.
- **RBAC pattern:** `DataModel` handlers gate with `_hasAnyRole([...])`; pages stay prop-driven.

**Build & test commands (Git Bash):**
- Build: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug` (reconfigure first for a brand-new file: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --preset felgo-mingw-debug`). Expected exit 0.
- Unit test: `QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_<Name>.qml` (the two `QT_*` vars are required or the runner is silent on this box).

**The two existing bugs folded into this feature:**
- `Main.qml:665` `onOrderUpdated: function(oid) { logic.updateOrder(oid, {}) }` — a redundant empty re-dispatch after the dialog already saved. Removed in Task 8.
- "Order detail reopens showing previous values" — fixed structurally because the order is updated to current state (Task 4) and `OrderDetailDialog.openFor` rebuilds its `products` ListModel from the live store on each open. Confirmed at manual verification (Task 9).

> Note on `/graphify`: the project's knowledge graph covers only the C++/`functions/` layer (zero QML files), so it could not inform this QML work — the plan was derived by reading the QML source directly.

---

## Analysis-layer netting strategy (read before Task 5)

Returns are recorded as `kind:"return"` transaction docs with **negative** `quantity`, negative `total`, and a `consumption[]` whose `qtyConsumed` values are **negative** (the reversed lineage at the original `unitCost`). Because the values are signed, every sale-summing site nets a return correctly **once it includes `return`-kind rows**. The sale-summing sites are (verified):

1. `TransactionStore.bucketsForFiltered("sale", …)` — Sold/Revenue qty buckets. Callers: SalesPage:1152, 1619.
2. `SalesPage._consumptionBucketWalk("sale", …)` — supplier-filtered Sold. Sites: 1146, 1615; the `kind` is the function arg, gate at 2170 (`e.kind !== kind`).
3. `SalesPage._profitBucketWalk` — realised-profit period bins. Gate at 1947 (`e.kind !== "sale"`).
4. `InventoryStore.realisedProfitByDimension` — profit by dimension. Gate at 180 (`e.kind !== "sale"`) AND a `qty <= 0` skip at 192.

Task 5 changes each to also accept `return` and to NOT skip negative `qtyConsumed`. The display helper at SalesPage:2261 (`d.kind === "sale"` → "Sold N") gets a `return` branch so the activity row reads "Returned N".

---

## File Structure

- **New `qml/helper/OrderAdjust.js`** — pure: `diffLines(oldLines, newLines)`, `restorePlan(consumption, returnedQty)`. The only new business math; fully testable.
- **New `tests/tst_OrderAdjust.qml`** — QtTest for the above.
- **Modify `qml/model/StockBatchStore.qml`** — `restoreFifo(batchId, qty)` (inverse of consumeFifo).
- **Modify `qml/model/TransactionStore.qml`** — `recordReturn(...)` (negative `kind:"return"` event).
- **Modify `qml/model/OrdersStore.qml`** — `applyAdjustment(orderId, newLines, adjustmentRecord)`; add `adjustments[]` to `_clone()` + the Firebase normalizer.
- **Modify `qml/model/DataModel.qml`** — `onAdjustOrder` handler + `_tryAdjustOrder` orchestrator.
- **Modify `qml/logic/Logic.qml`** — `signal adjustOrder(...)`.
- **Modify `qml/pages/SalesPage.qml` + `qml/model/InventoryStore.qml`** — net `kind:"return"` in the analysis sums.
- **Modify `qml/pages/OrderDetailDialog.qml`** — emit `adjustRequested(...)` for completed-order edits (instead of saving directly).
- **Modify `qml/Main.qml`** — hoisted confirm-on-save sheet; wire `adjustOrder`; remove the `:665` double-dispatch.

---

## Task 1: Pure adjustment math — `OrderAdjust.js` (TDD)

**Files:**
- Create: `qml/helper/OrderAdjust.js`
- Test: `tests/tst_OrderAdjust.qml`

- [ ] **Step 1: Write the failing test**

Create `tests/tst_OrderAdjust.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/OrderAdjust.js" as OA

TestCase {
    name: "OrderAdjust"

    // ── diffLines: per-line deltas of new vs current order lines ──────────
    function test_diff_partial_reduction() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 3 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var d = OA.diffLines(oldL, newL)
        compare(d.length, 1)
        compare(d[0].productId, "P1")
        compare(d[0].returnedQty, 2)
        compare(d[0].addedQty, 0)
        compare(d[0].oldPrice, 100)
        compare(d[0].newPrice, 100)
    }
    function test_diff_full_removal() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 3 }]
        var newL = []
        var d = OA.diffLines(oldL, newL)
        compare(d.length, 1)
        compare(d[0].returnedQty, 3)
        compare(d[0].newQty, 0)
    }
    function test_diff_addition() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 4 }]
        var d = OA.diffLines(oldL, newL)
        compare(d[0].addedQty, 3)
        compare(d[0].returnedQty, 0)
    }
    function test_diff_new_line_added() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 },
                    { productId: "P2", name: "Gadget", price: 50, quantity: 2 }]
        var d = OA.diffLines(oldL, newL)
        // P1 unchanged (no delta row), P2 added qty 2
        var p2 = null
        for (var i = 0; i < d.length; ++i) if (d[i].productId === "P2") p2 = d[i]
        verify(p2 !== null)
        compare(p2.addedQty, 2)
        compare(p2.oldQty, 0)
    }
    function test_diff_price_change_only() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 2 }]
        var newL = [{ productId: "P1", name: "Widget", price: 80, quantity: 2 }]
        var d = OA.diffLines(oldL, newL)
        compare(d[0].returnedQty, 0)
        compare(d[0].addedQty, 0)
        compare(d[0].oldPrice, 100)
        compare(d[0].newPrice, 80)
    }
    function test_diff_no_change_empty() {
        var oldL = [{ productId: "P1", name: "Widget", price: 100, quantity: 2 }]
        var newL = [{ productId: "P1", name: "Widget", price: 100, quantity: 2 }]
        compare(OA.diffLines(oldL, newL).length, 0)
    }

    // ── restorePlan: how a returned qty credits back to original batches ──
    function test_restore_partial_across_batches() {
        // line was satisfied 2 from batch B1, 3 from batch B2 (5 total).
        var consumption = [
            { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 },
            { batchId: "B2", supplierId: "S2", qtyConsumed: 3, unitCost: 12 }
        ]
        // return 4 → unwind most-recently-consumed first: 3 from B2, then 1 from B1
        var plan = OA.restorePlan(consumption, 4)
        compare(plan.length, 2)
        compare(plan[0].batchId, "B2")
        compare(plan[0].qty, 3)
        compare(plan[0].unitCost, 12)
        compare(plan[1].batchId, "B1")
        compare(plan[1].qty, 1)
        compare(plan[1].unitCost, 10)
    }
    function test_restore_full() {
        var consumption = [
            { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 },
            { batchId: "B2", supplierId: "S2", qtyConsumed: 3, unitCost: 12 }
        ]
        var plan = OA.restorePlan(consumption, 5)
        var total = 0
        for (var i = 0; i < plan.length; ++i) total += plan[i].qty
        compare(total, 5)
    }
    function test_restore_empty_consumption_is_empty() {
        // pre-FIFO line (no consumption) → empty plan signals the topUpOldest fallback
        compare(OA.restorePlan([], 3).length, 0)
        compare(OA.restorePlan(null, 3).length, 0)
    }
    function test_restore_zero_qty_empty() {
        var consumption = [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 }]
        compare(OA.restorePlan(consumption, 0).length, 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it FAILS**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_OrderAdjust.qml
```
Expected: FAIL — `OrderAdjust.js` does not exist.

- [ ] **Step 3: Implement `qml/helper/OrderAdjust.js`**

```javascript
.pragma library

// Pure order-adjustment math for returns/exchanges/modify on a completed order.
// No QML/singleton deps so it's unit-testable. The orchestration (stock + ledger
// writes) lives in DataModel._tryAdjustOrder; this just computes deltas/plans.

// Per-line delta of the edited lines vs the order's current lines. Matches lines
// by productId. Emits one row per line that changed (qty up/down, removed, added,
// or price changed). Lines with no change are omitted.
//   → [{ productId, name, oldQty, newQty, returnedQty, addedQty, oldPrice, newPrice }]
function diffLines(oldLines, newLines) {
    oldLines = oldLines || []
    newLines = newLines || []
    var byIdOld = {}
    for (var i = 0; i < oldLines.length; ++i) {
        var o = oldLines[i]
        byIdOld[o.productId || o.name] = o
    }
    var byIdNew = {}
    for (var j = 0; j < newLines.length; ++j) {
        var n = newLines[j]
        byIdNew[n.productId || n.name] = n
    }
    var out = []
    // Lines present in old (changed or removed)
    for (var k = 0; k < oldLines.length; ++k) {
        var ol = oldLines[k]
        var key = ol.productId || ol.name
        var nl = byIdNew[key]
        var oldQty = ol.quantity || 0
        var newQty = nl ? (nl.quantity || 0) : 0
        var oldPrice = ol.price || 0
        var newPrice = nl ? (nl.price || 0) : oldPrice
        var changed = (oldQty !== newQty) || (oldPrice !== newPrice)
        if (!changed) continue
        out.push({
            productId: ol.productId || "", name: ol.name,
            oldQty: oldQty, newQty: newQty,
            returnedQty: Math.max(0, oldQty - newQty),
            addedQty: Math.max(0, newQty - oldQty),
            oldPrice: oldPrice, newPrice: newPrice
        })
    }
    // Lines only in new (brand-new lines added during the edit)
    for (var m = 0; m < newLines.length; ++m) {
        var n2 = newLines[m]
        var key2 = n2.productId || n2.name
        if (byIdOld[key2]) continue
        out.push({
            productId: n2.productId || "", name: n2.name,
            oldQty: 0, newQty: n2.quantity || 0,
            returnedQty: 0, addedQty: n2.quantity || 0,
            oldPrice: 0, newPrice: n2.price || 0
        })
    }
    return out
}

// Compute which original batches a returned qty credits back to, unwinding the
// line's consumption[] most-recently-consumed first (reverse-FIFO). Returns
// [{ batchId, qty, unitCost, supplierId }]. Empty when there's no consumption
// lineage (pre-FIFO line) — caller falls back to topUpOldest.
function restorePlan(consumption, returnedQty) {
    if (!consumption || returnedQty <= 0) return []
    var plan = []
    var remaining = returnedQty
    // Unwind newest-consumed first: iterate consumption in reverse.
    for (var i = consumption.length - 1; i >= 0 && remaining > 0; --i) {
        var c = consumption[i]
        var avail = c.qtyConsumed || 0
        if (avail <= 0) continue
        var take = Math.min(avail, remaining)
        plan.push({
            batchId: c.batchId,
            qty: take,
            unitCost: c.unitCost || 0,
            supplierId: c.supplierId || ""
        })
        remaining -= take
    }
    return plan
}
```

- [ ] **Step 4: Run the test to verify it PASSES**

Run the Step 2 command. Expected: all `test_*` PASS (10 + init/cleanup).

- [ ] **Step 5: Commit**

```bash
git add qml/helper/OrderAdjust.js tests/tst_OrderAdjust.qml
git commit -m "feat(returns): pure order-adjustment math (diffLines + restorePlan) with tests"
```

---

## Task 2: Ledger primitives — `restoreFifo` + `recordReturn`

**Files:**
- Modify: `qml/model/StockBatchStore.qml`
- Modify: `qml/model/TransactionStore.qml`

- [ ] **Step 1: Add `restoreFifo` to StockBatchStore**

`consumeFifo` is at StockBatchStore.qml:156; `getById` at :89; `addBatch` at :124. Add this function right after `topUpOldest` (which ends at :238, the closing `}` before the file's final `}`):

```qml
    // Inverse of consumeFifo: credit `qty` back onto a specific batch (used when
    // a completed-order line is returned and the units go back to sellable
    // stock). The batch is found by id — batches are never deleted, only zeroed,
    // so a fully-consumed batch is still present and gets its qtyRemaining
    // restored. If the batch id can't be found (rare: ledger drift), fall back to
    // topUpOldest so stock isn't silently lost.
    function restoreFifo(batchId, productId, qty) {
        if (!qty || qty <= 0) return
        var b = getById(batchId)
        if (!b) {
            if (productId) topUpOldest(productId, qty)
            return
        }
        var before = Object.assign({}, b)
        var updated = Object.assign({}, b, {
            qtyRemaining: (b.qtyRemaining || 0) + qty,
            updatedAt: new Date().toISOString()
        })
        var next = []
        for (var i = 0; i < batches.length; ++i)
            next.push(batches[i].batchId === batchId ? updated : batches[i])
        batches = next
        Gateway.recordMutation("stock_batch", batchId, "update", before, updated)
    }
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`. Expected exit 0.

- [ ] **Step 3: Add `recordReturn` to TransactionStore**

`recordSaleFromOrder` is at TransactionStore.qml:230; `_push` at :52; `_nextId` at :48. Add this function right after `recordSaleFromOrder` (ends at :261):

```qml
    // Append an immutable return event for one returned line. Negative quantity
    // and total so the existing sale-summing analytics net it down. Carries the
    // REVERSED consumption[] (negative qtyConsumed at the original unitCost) so
    // per-supplier/profit queries unwind the exact margin originally booked.
    //   reversedConsumption: [{ batchId, supplierId, qtyConsumed (negative), unitCost }]
    function recordReturn(order, line, returnedQty, reversedConsumption, reason, condition, note) {
        if (!returnedQty || returnedQty <= 0) return
        var unitPrice = typeof line.price === "number" ? line.price : 0
        var doc = {
            txId: _nextId("r"),
            kind: "return",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: line.productId || "",
            productName: line.name || "",
            quantity: -returnedQty,                 // negative → nets down Sold
            unitCost: 0,
            unitPrice: unitPrice,
            total: -(returnedQty * unitPrice),      // negative → nets down Revenue
            orderId: order.orderId || "",
            orderChannel: order.orderChannel || "",
            staffId: order.staffId || "",
            consumption: Array.isArray(reversedConsumption) ? reversedConsumption.slice() : [],
            reason: reason || "",                   // "return"|"exchange"|"modify"|"other"
            condition: condition || "",             // "restock"|"damaged"
            note: note || ""
        }
        _push(doc)
    }
```

- [ ] **Step 4: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`. Expected exit 0.

- [ ] **Step 5: Commit**

```bash
git add qml/model/StockBatchStore.qml qml/model/TransactionStore.qml
git commit -m "feat(returns): restoreFifo batch credit + recordReturn negative ledger event"
```

---

## Task 3: `OrdersStore.applyAdjustment` + `adjustments[]` field

**Files:**
- Modify: `qml/model/OrdersStore.qml`

- [ ] **Step 1: Carry `adjustments[]` through `_clone()`**

`_clone()` is at OrdersStore.qml:310; the per-order object literal it pushes is at :345-356 (`a.push({ orderId: ..., products: prods })`). Add `adjustments` to that literal — change the closing of the pushed object from:
```qml
                      staffId: o.staffId || "",
                      products: prods });
```
to:
```qml
                      staffId: o.staffId || "",
                      adjustments: Array.isArray(o.adjustments) ? o.adjustments.slice() : [],
                      products: prods });
```

- [ ] **Step 2: Default `adjustments` in the Firebase normalizer**

`_fetchFromFirebase` normalizes incoming docs at :37-60. After the `if (!o.staffId) o.staffId = "";` line (:59), add:
```qml
                    if (!Array.isArray(o.adjustments)) o.adjustments = [];
```

- [ ] **Step 3: Add `applyAdjustment`**

`updateOrder` is at OrdersStore.qml:415, `computeOrderTotals` is referenced there too, `_commit` at :303. Add this function right after `updateOrder` (ends at :449):

```qml
    // Apply a return/exchange/modify adjustment: set the order's lines to the
    // post-adjustment state, recompute totals, and append one immutable entry to
    // the order's adjustments[] audit log. Used by DataModel._tryAdjustOrder
    // AFTER it has already written the stock + ledger reversals. Distinct from
    // updateOrder so the normal edit path is untouched.
    //   adjustmentRecord: { date, reason, condition, lineDeltas, refundAmount, note, actorUid }
    function applyAdjustment(orderId, newLines, adjustmentRecord) {
        var idx = findIndexById(orderId);
        if (idx < 0) return;
        var arr = _clone();
        var o = arr[idx];
        o.products = newLines || [];
        var t = computeOrderTotals(o.products, o.discountType, o.discountValue);
        o.subtotal = t.subtotal;
        o.discount = t.discount;
        o.tax = t.tax;
        o.taxBreakdown = t.taxBreakdown;
        o.total = t.total;
        o.items = t.itemCount;
        if (!Array.isArray(o.adjustments)) o.adjustments = [];
        o.adjustments.push(adjustmentRecord);
        o.updatedAt = new Date().toISOString();
        _commit(arr);
    }
```

- [ ] **Step 4: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`. Expected exit 0.

- [ ] **Step 5: Commit**

```bash
git add qml/model/OrdersStore.qml
git commit -m "feat(returns): OrdersStore.applyAdjustment + adjustments[] audit field"
```

---

## Task 4: `DataModel._tryAdjustOrder` orchestrator + `Logic.adjustOrder` signal

**Files:**
- Modify: `qml/logic/Logic.qml`
- Modify: `qml/model/DataModel.qml`

- [ ] **Step 1: Add the `adjustOrder` signal**

In `qml/logic/Logic.qml`, the order signals are near `signal updateOrder(string orderId, var fields)` (:41). Add after it:
```qml
    signal adjustOrder(string orderId, var newLines, string reason, string condition, string note)
```

- [ ] **Step 2: Import OrderAdjust + StaffScope-style helper in DataModel**

`qml/model/DataModel.qml` already has `import "../helper/StockReconcile.js" as StockReconcile` at the top (from the prior bug fix). Add after it:
```qml
import "../helper/OrderAdjust.js" as OrderAdjust
```

- [ ] **Step 3: Add the `onAdjustOrder` handler**

In the `Connections` block (the `onUpdateOrder` handler is at DataModel.qml:79). Add this handler right after `onDeleteOrder` (ends at :131):
```qml
        function onAdjustOrder(orderId, newLines, reason, condition, note) {
            if (!_hasAnyRole(["owner", "admin", "manager"])) {
                logic.errorOccurred("auth", "You do not have permission to adjust orders")
                return
            }
            var ok = _tryAdjustOrder(orderId, newLines, reason, condition, note)
            if (ok) {
                _updateOrderInModel(orderId)
                logic.orderUpdated(orderId)
            }
        }
```

- [ ] **Step 4: Add the `_tryAdjustOrder` orchestrator**

Add this private function right after `_tryCompleteOrder` (ends at DataModel.qml:353, before `_sumConsumed`):

```qml
    // Reverse/adjust a COMPLETED order's lines. Diffs the edited lines vs the
    // order's current lines and, per changed line: restores returned units to
    // their original batches (Restock) or writes them off (Damaged), deducts any
    // added units via fresh FIFO, writes a negative return ledger event, then
    // updates the order + appends an adjustments[] entry. Mirrors _tryCompleteOrder
    // in reverse. Returns true on success.
    function _tryAdjustOrder(orderId, newLines, reason, condition, note) {
        var o = OrdersStore.getById(orderId)
        if (!o) return false

        var deltas = OrderAdjust.diffLines(o.products || [], newLines || [])
        var refundAmount = 0
        var restock = (condition !== "damaged")  // default restock unless explicitly damaged

        for (var i = 0; i < deltas.length; ++i) {
            var d = deltas[i]

            // ── Returned / removed units ─────────────────────────────────
            if (d.returnedQty > 0) {
                // Find the matching current line to read its consumption[].
                var line = _findLine(o.products, d.productId, d.name)
                var consumption = line && Array.isArray(line.consumption) ? line.consumption : []
                var plan = OrderAdjust.restorePlan(consumption, d.returnedQty)
                var reversed = []
                if (restock) {
                    if (plan.length > 0) {
                        for (var p = 0; p < plan.length; ++p) {
                            StockBatchStore.restoreFifo(plan[p].batchId, d.productId, plan[p].qty)
                            reversed.push({ batchId: plan[p].batchId, supplierId: plan[p].supplierId,
                                            qtyConsumed: -plan[p].qty, unitCost: plan[p].unitCost })
                        }
                    } else {
                        // Pre-FIFO line: no lineage — repair via topUpOldest.
                        if (d.productId) StockBatchStore.topUpOldest(d.productId, d.returnedQty)
                    }
                    InventoryStore.restock2(d.productId, d.returnedQty)
                } else {
                    // Damaged: build the reversed consumption for accurate revenue/
                    // profit netting, but do NOT return units to sellable stock.
                    for (var pd = 0; pd < plan.length; ++pd)
                        reversed.push({ batchId: plan[pd].batchId, supplierId: plan[pd].supplierId,
                                        qtyConsumed: -plan[pd].qty, unitCost: plan[pd].unitCost })
                    // Stock stays deducted (units are gone); product.stock already
                    // reflects the sale, so nothing to add back.
                }
                TransactionStore.recordReturn(o, { productId: d.productId, name: d.name, price: d.oldPrice },
                                              d.returnedQty, reversed, reason, condition, note)
                refundAmount += d.returnedQty * d.oldPrice
            }

            // ── Added units (exchange replacement / modify-up) ───────────
            if (d.addedQty > 0) {
                var invA = InventoryStore.getById(d.productId)
                if (invA) {
                    var cons = StockBatchStore.consumeFifo(d.productId, d.addedQty)
                    var consumed = _sumConsumed(cons)
                    if (consumed < d.addedQty) {
                        StockBatchStore.topUpOldest(d.productId, d.addedQty - consumed)
                        var retry = StockBatchStore.consumeFifo(d.productId, d.addedQty - consumed)
                        for (var r = 0; r < retry.length; ++r) cons.push(retry[r])
                    }
                    InventoryStore.deductStock(d.productId, d.addedQty)
                    // Record the added units as a positive sale event.
                    TransactionStore.recordSaleFromOrder({
                        orderId: o.orderId, date: o.date, orderChannel: o.orderChannel,
                        staffId: o.staffId,
                        products: [{ productId: d.productId, name: d.name, price: d.newPrice,
                                     quantity: d.addedQty, consumption: cons }]
                    })
                    refundAmount -= d.addedQty * d.newPrice
                }
            }

            // ── Price-only change (modify): revenue adjustment, no stock ──
            if (d.returnedQty === 0 && d.addedQty === 0 && d.oldPrice !== d.newPrice) {
                var priceDeltaQty = d.newQty
                // Negative event for the price difference × qty (no consumption,
                // no stock movement — pure revenue correction).
                TransactionStore.recordReturn(o, { productId: d.productId, name: d.name,
                                                   price: (d.oldPrice - d.newPrice) },
                                              priceDeltaQty, [], reason, condition,
                                              (note ? note + " · " : "") + "price " + d.oldPrice + "→" + d.newPrice)
                refundAmount += priceDeltaQty * (d.oldPrice - d.newPrice)
            }
        }

        // Persist the order to its post-adjustment state + audit log entry.
        OrdersStore.applyAdjustment(orderId, newLines, {
            date: new Date().toISOString(),
            reason: reason || "", condition: condition || "",
            lineDeltas: deltas, refundAmount: refundAmount,
            note: note || "", actorUid: AuthStore.uid || ""
        })
        return true
    }

    // Find an order line by productId (preferred) or name.
    function _findLine(lines, productId, name) {
        if (!lines) return null
        for (var i = 0; i < lines.length; ++i) {
            if (productId && lines[i].productId === productId) return lines[i]
            if (!productId && name && lines[i].name === name) return lines[i]
        }
        return null
    }
```

NOTE: this references `InventoryStore.restock2(productId, qty)` — a stock-INCREASE-without-batch helper does NOT exist yet (`restock` creates a batch + purchase event, which we do NOT want here since restoreFifo already credited the batch). Add a minimal stock-only increment to InventoryStore in Step 5.

- [ ] **Step 5: Add `restock2` (stock-only increment) to InventoryStore**

In `qml/model/InventoryStore.qml`, `deductStock` is at :577. Add a sibling right after it (after :601, the `deductStock` closing brace — verify exact line):
```qml
    // Increment product.stock WITHOUT creating a batch or purchase event. Used by
    // the returns flow, where StockBatchStore.restoreFifo has ALREADY credited the
    // batch ledger — this just keeps product.stock in lockstep. (Distinct from
    // restock(), which is a supplier receipt that DOES create a batch.)
    function restock2(productId, qty) {
        if (!qty || qty <= 0) return
        var arr = _clone()
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId === productId) {
                arr[i].stock = (arr[i].stock || 0) + qty
                products = arr
                Gateway.recordMutation("inventory", productId, "update", null, arr[i])
                return
            }
        }
        console.warn("[InventoryStore] restock2: no product with id", productId)
    }
```

- [ ] **Step 6: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`. Expected exit 0. (`AuthStore` is already used in DataModel — `_hasAnyRole` reads `AuthStore.role` at :39-41 — so `AuthStore.uid` in `_tryAdjustOrder` resolves. `restock2` slots into InventoryStore right after `deductStock`'s closing brace, before `findIndexById`.)

- [ ] **Step 7: Commit**

```bash
git add qml/logic/Logic.qml qml/model/DataModel.qml qml/model/InventoryStore.qml
git commit -m "feat(returns): _tryAdjustOrder orchestrator + adjustOrder signal + restock2"
```

---

## Task 5: Net `kind:"return"` into the Analysis reports

**Files:**
- Modify: `qml/model/InventoryStore.qml`
- Modify: `qml/pages/SalesPage.qml`

Returns carry signed (negative) values, so each site just needs to INCLUDE return rows. Five summing sites + one display site.

- [ ] **Step 1: `realisedProfitByDimension` — accept return + allow negative qty**

In `qml/model/InventoryStore.qml`, `realisedProfitByDimension` is at :174. Change line 180 from:
```qml
            if (e.kind !== "sale") continue
```
to:
```qml
            if (e.kind !== "sale" && e.kind !== "return") continue
```
And change the per-consumption guard at :192 from:
```qml
                if (qty <= 0) continue
```
to:
```qml
                if (qty === 0) continue
```
(A return's negative `qtyConsumed` now flows through: `revenue` and `cogs` both go negative, netting the original margin back out.)

- [ ] **Step 2: `_profitBucketWalk` — accept return**

In `qml/pages/SalesPage.qml`, `_profitBucketWalk` is at :1905; its sale gate is at :1947. Change:
```qml
            if (e.kind !== "sale") continue
```
to:
```qml
            if (e.kind !== "sale" && e.kind !== "return") continue
```
AND the inner consumption loop has its OWN guard at :1958 (`if (qty <= 0) continue`) that would discard a return's negative `qtyConsumed`. Change :1958 from:
```qml
                if (qty <= 0) continue
```
to:
```qml
                if (qty === 0) continue
```
(Line :1959 multiplies `qty × (unitPrice − unitCost)`, so a negative `qtyConsumed` now correctly subtracts profit. Both the kind gate AND this guard must change.)

- [ ] **Step 3: `_consumptionBucketWalk` — accept return alongside the requested kind**

In `qml/pages/SalesPage.qml`, `_consumptionBucketWalk(kind, supplierId, field)` is at :2125; its gate is at :2170 (`if (e.kind !== kind) continue`). When the caller asks for `"sale"`, returns must also count. Change :2170 from:
```qml
            if (e.kind !== kind) continue
```
to:
```qml
            // Returns net against sales: include them whenever sales are requested.
            if (e.kind !== kind && !(kind === "sale" && e.kind === "return")) continue
```
(Negative `qtyConsumed` nets qty/revenue/margin down.)

- [ ] **Step 4: `bucketsForFiltered` — include return when "sale" requested**

In `qml/model/TransactionStore.qml`, `bucketsForFiltered(kind, periodIdx, predicate)` is at :287; the single-kind match is at :338 (`else if (kind && e.kind !== kind)`, inside the `else` of the `kindSet` branch). The cleanest change: at the top of the per-entry loop, normalize so a `"sale"` request also matches `"return"`. Change the kind-matching block (lines ~336-348) — locate:
```qml
            if (kindSet) {
                if (!kindSet[e.kind]) continue
            } else if (kind && e.kind !== kind) {
```
to:
```qml
            if (kindSet) {
                // A "sale" request also nets "return" rows (signed quantity).
                if (!kindSet[e.kind] && !(kindSet["sale"] && e.kind === "return")) continue
            } else if (kind && e.kind !== kind && !(kind === "sale" && e.kind === "return")) {
```
(The bin sums `e.quantity` at :354; a return's negative quantity nets Sold/Revenue down. Purchased — `["purchase","created"]` — is unaffected since it never requests "sale".)

- [ ] **Step 5: Activity-row display — label returns**

In `qml/pages/SalesPage.qml`, the transaction subtitle helper has `else if (d.kind === "sale") head = qsTr("Sold %1")...` at :2261. Add a return branch right before it:
```qml
        else if (d.kind === "return")  head = qsTr("Returned %1").arg(Math.abs(d.quantity || 0))
```

- [ ] **Step 6: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`. Expected exit 0.

- [ ] **Step 7: Commit**

```bash
git add qml/model/InventoryStore.qml qml/pages/SalesPage.qml qml/model/TransactionStore.qml
git commit -m "feat(returns): net kind:return as signed sales across Analysis reports"
```

---

## Task 6: OrderDetailDialog — emit adjust for completed orders

**Files:**
- Modify: `qml/pages/OrderDetailDialog.qml`

The dialog must (a) remember the order's original lines on open, (b) on Save of a *completed* order with changed lines, emit an `adjustRequested` signal carrying the new lines + original (so Main.qml's hoisted confirm sheet can show the delta) instead of saving directly.

- [ ] **Step 1: Add a signal + capture original lines**

In `qml/pages/OrderDetailDialog.qml`, the dialog has `signal orderUpdated(string orderId)` at :21. Add after it:
```qml
    // Emitted when a COMPLETED order's lines changed — Main.qml shows the
    // confirm-on-save sheet (reason + condition) and routes to logic.adjustOrder.
    signal adjustRequested(string orderId, var newLines, var originalLines)
    property string _orderStatus: ""
    property var _originalLines: []
```

In `openFor(id)` (at :114), after the order `o` is resolved and `products` populated, record the status + a snapshot of the original lines. After the `recomputeSubtotal()` call near the end of `openFor` (:177), add:
```qml
        _orderStatus = String(o.status || "")
        _originalLines = (o.products || []).map(function(lp) {
            return { productId: lp.productId || "", name: lp.name, price: lp.price,
                     quantity: lp.quantity, consumption: lp.consumption || [] }
        })
```

- [ ] **Step 2: Branch `_save` for completed orders**

`_save()` is at :185; it currently builds `prods` then calls `logic.updateOrder(...)` at :214. Wrap the completed-order case: after `prods` is built and stock errors checked (after :204, `stockErrorLabel.text = ""`), insert:
```qml
        // A completed order's line edits are returns/exchanges/modifications —
        // route through the confirm-on-save sheet (Main.qml) instead of a plain
        // update, so stock + sale ledger get reversed correctly.
        if (_orderStatus === "completed") {
            var changed = JSON.stringify(_lineKeys(prods)) !== JSON.stringify(_lineKeys(_originalLines))
            if (changed) {
                dlg.adjustRequested(dlg.orderId, prods, dlg._originalLines)
                dlg.close()
                return
            }
        }
```
And add a small helper near `_lineItemArray` (:62):
```qml
    // Normalized {productId, quantity, price} per line for change detection.
    function _lineKeys(lines) {
        var out = []
        for (var i = 0; i < lines.length; ++i)
            out.push({ id: lines[i].productId || lines[i].name, q: lines[i].quantity, p: lines[i].price })
        return out
    }
```
(Non-completed orders fall through to the existing `logic.updateOrder` path unchanged.)

- [ ] **Step 3: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`. Expected exit 0.

- [ ] **Step 4: Commit**

```bash
git add qml/pages/OrderDetailDialog.qml
git commit -m "feat(returns): OrderDetailDialog emits adjustRequested for completed-order edits"
```

---

## Task 7: Hoisted confirm-on-save sheet in Main.qml

**Files:**
- Modify: `qml/Main.qml`

Per the nested-popup gotcha, the confirm sheet is declared at the App root and triggered by `OrderDetailDialog.adjustRequested`.

- [ ] **Step 1: Add a ConfirmReturnSheet component**

Create `qml/pages/ConfirmReturnSheet.qml` — a BottomSheet that shows the computed delta, a reason dropdown, a condition toggle, an impact preview, and emits `confirmed(orderId, newLines, reason, condition, note)`:

```qml
import QtQuick
import QtQuick.Layouts
import "../components"
import "../helper"
import "../helper/OrderAdjust.js" as OrderAdjust
import "../model"

// Confirm-on-save sheet for completed-order returns/exchanges. Declared at the
// App root (nested popups inside a BottomSheet open off-screen). Triggered via
// openFor() from Main.qml when OrderDetailDialog.adjustRequested fires.
BottomSheet {
    id: root
    sheetTitle: qsTr("Confirm changes")
    primaryAction: qsTr("Confirm & save")
    secondaryAction: qsTr("Cancel")

    signal confirmed(string orderId, var newLines, string reason, string condition, string note)

    property string orderId: ""
    property var newLines: []
    property var deltas: []
    property string reason: "return"
    property string condition: "restock"
    property string note: ""
    readonly property bool hasReturn: {
        for (var i = 0; i < deltas.length; ++i) if (deltas[i].returnedQty > 0) return true
        return false
    }

    function openFor(oid, newL, originalL) {
        orderId = oid
        newLines = newL
        deltas = OrderAdjust.diffLines(originalL || [], newL || [])
        reason = "return"; condition = "restock"; note = ""
        open()
    }

    onPrimaryClicked: {
        confirmed(orderId, newLines, reason, condition, note)
        close()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // Delta summary
        Repeater {
            model: root.deltas
            delegate: Text {
                Layout.fillWidth: true
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsBody)
                text: modelData.returnedQty > 0
                        ? qsTr("Returning %1 × %2").arg(modelData.returnedQty).arg(modelData.name)
                      : modelData.addedQty > 0
                        ? qsTr("Adding %1 × %2").arg(modelData.addedQty).arg(modelData.name)
                      : qsTr("Price change on %1").arg(modelData.name)
            }
        }

        Text { text: qsTr("Reason"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
        AppComboBox {
            Layout.fillWidth: true
            model: [qsTr("Return"), qsTr("Exchange"), qsTr("Modify"), qsTr("Other")]
            onCurrentIndexChanged: root.reason = ["return","exchange","modify","other"][currentIndex]
        }
        AuthTextField {
            Layout.fillWidth: true
            visible: root.reason === "other"
            label: qsTr("Reason note")
            onTextChanged: root.note = text
        }

        // Condition (only when something is returned)
        Text { visible: root.hasReturn; text: qsTr("Condition"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
        SegmentedPill {
            visible: root.hasReturn
            Layout.fillWidth: true
            model: [qsTr("Restock"), qsTr("Damaged")]
            selected: 0
            onSegmentSelected: function(idx, label) { root.condition = idx === 1 ? "damaged" : "restock" }
        }
    }
}
```

- [ ] **Step 2: Instantiate it at the App root + wire the dialog**

In `qml/Main.qml`, the `OrderDetailDialog { id: orderDetail }` is at :663-666. Replace the whole block (including the `:665` double-dispatch removal) with:
```qml
    OrderDetailDialog {
        id: orderDetail
        onAdjustRequested: function(oid, newLines, originalLines) {
            confirmReturnSheet.openFor(oid, newLines, originalLines)
        }
    }
    ConfirmReturnSheet {
        id: confirmReturnSheet
        onConfirmed: function(oid, newLines, reason, condition, note) {
            logic.adjustOrder(oid, newLines, reason, condition, note)
        }
    }
```
NOTE: this REMOVES the old `onOrderUpdated: function(oid) { logic.updateOrder(oid, {}) }` line — the redundant double-dispatch. The dialog's non-completed save path still calls `logic.updateOrder(...)` itself, so nothing is lost.

- [ ] **Step 3: Add ConfirmReturnSheet to the dialog imports list if needed**

`ConfirmReturnSheet.qml` lives in `qml/pages/`. Main.qml already imports `"pages"` (or references dialogs directly — verify with `grep -n "OrderDetailDialog\|import \"pages\"\|import \"./pages\"" qml/Main.qml`). If pages are referenced via a relative import that the new file falls under, no import change is needed (same directory as OrderDetailDialog). Confirm the new component resolves by building.

- [ ] **Step 4: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --preset felgo-mingw-debug` (reconfigure for the new ConfirmReturnSheet.qml), then `--build --preset felgo-mingw-debug`. Expected exit 0.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/ConfirmReturnSheet.qml qml/Main.qml
git commit -m "feat(returns): hoisted confirm-on-save sheet + wire adjustOrder; remove double-dispatch"
```

---

## Task 8: Full verification — tests + acceptance matrix

**Files:** none (verification only)

- [ ] **Step 1: Run all unit suites**

```bash
for t in tst_OrderAdjust tst_StockReconcile tst_StaffScope tst_BreakdownMath; do
  echo -n "$t: "
  QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/$t.qml 2>&1 | grep "Totals:"
done
```
Expected: all suites green (tst_OrderAdjust 10/10 + the three prior suites unchanged).

- [ ] **Step 2: Clean build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`. Expected exit 0, no warnings on touched files.

- [ ] **Step 3: Manual acceptance matrix (launch app, owner/admin/manager)**

Complete an order with a multi-unit line, then on the completed order:

| Action | Expected |
|---|---|
| Return 2 of 3 · Restock | Confirm sheet shows "Returning 2 × X"; on confirm: stock +2, Value/Sold/Revenue/Profit reports drop; order detail reopens showing qty 1 (not 3); adjustments log has an entry |
| Return 1 · Damaged | Revenue/Sold/Profit drop; stock UNCHANGED (write-off); detail reflects reduced qty |
| Exchange (remove A, add B) | A's stock returns, B's stock deducts; reports net both |
| Modify price (₹100→₹80) | Revenue drops by the difference × qty; stock unchanged |
| Full cancellation (remove all) | All stock restored; reports zero out the order; order shows 0 items |
| Reopen detail after any of the above | Shows the CURRENT (post-adjustment) lines — confirms the stale-detail bug is fixed |
| Edit a pending/processing order | Saves normally, NO confirm sheet (unchanged path) |
| Staff account | Cannot reach adjust (no completed-order edit access); owner/admin/manager can |

- [ ] **Step 4: Commit any verification fixes**

```bash
git add -A
git commit -m "fix(returns): address verification findings"
```

---

## Self-review notes (for the implementer)

- **Spec coverage:** Task 1 → OrderAdjust pure math; Task 2 → restoreFifo + recordReturn; Task 3 → applyAdjustment + adjustments[]; Task 4 → _tryAdjustOrder orchestrator + signal + restock2; Task 5 → analysis netting (all 5 summing sites + display); Task 6 → dialog emits adjust; Task 7 → hoisted confirm sheet + double-dispatch removal; Task 8 → verification. Every spec section maps to a task.
- **`kind:"return"` over negative-`kind:"sale"`:** the spec chose `kind:"return"` for audit clarity; Task 5 enumerates ALL six sale-summing/display sites that must include it. (A reviewer may note that writing returns as negative `kind:"sale"` would auto-net at most sites — but that loses the audit distinction the user explicitly wanted, so we keep `kind:"return"` and net it explicitly.)
- **Cost accuracy:** reversed consumption uses the line's stored `unitCost`, never current cost — verified the order line carries `consumption[]` with `unitCost`.
- **restock2 vs restock:** restock2 is stock-only (restoreFifo already credited the batch); restock() creates a batch + purchase event and must NOT be used here (would double-count). Flagged in Task 4/5.
- **Damaged path:** writes the reversed consumption for revenue/profit netting but does NOT restock — units are written off (product.stock stays reduced from the sale). If a P1 stock-movement write-off taxonomy lands later, hook it here.
- **Verification gaps flagged for implementer:** confirm `AuthStore` reachable in DataModel (Task 4 Step 6); confirm exact `deductStock` closing line for restock2 placement (Task 4 Step 5); confirm Main.qml pages import resolves ConfirmReturnSheet (Task 7 Step 3); confirm `_profitBucketWalk` inner loop has no `qty<=0` skip (Task 5 Step 2).
- **No CMake change:** new `OrderAdjust.js`, `ConfirmReturnSheet.qml`, `tst_OrderAdjust.qml` are auto-globbed; reconfigure once for the brand-new files.
```
