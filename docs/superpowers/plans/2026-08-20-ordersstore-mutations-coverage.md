# OrdersStore Mutations Coverage — Implementation Plan (Slice 3 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full test coverage for `OrdersStore.qml`'s write-path functions: `clear`, `_refreshCounts`,
`_commit`, `_mergeOrder`, `nextOrderId` (smoke), `upsertMany` (real coverage for its synchronous
empty-input path, smoke for the async path), `updateOrder`, `deleteOrder`, `_normalizeOrder`,
`_normalizeOrders`, and `addOrder` (smoke). The largest slice — these functions interact (`_clone`
calls `_normalizeOrder`, `updateOrder`/`deleteOrder` call `_commit`, `_commit` calls
`Gateway.recordMutation`), so this plan is written in dependency order: pure helpers first, then
the functions that call them.

**Architecture:** One new file, `tests/tst_OrdersStore_mutations.qml`, five commits. Every function
here that reaches `Gateway.recordMutation` does so safely under this suite's established pattern —
`Gateway.mode = "gateway"` + `AuthStore.idToken = ""` + the disk-level `AuthStore._settings.sessionJson`
reset from this session's AuthService-contamination fix — so nothing here makes a real network call;
`OutboxStore.dueItems().length` growing by one is how a test confirms a mutation was actually
recorded, not just that the function returned without throwing.

**Tech Stack:** QML/Qt Quick Test (`qmltestrunner`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-20-ordersstore-full-coverage-design.md` — implements that
  spec's Group A rows for these functions, plus `_normalizeOrder`/`_normalizeOrders` (added to this
  file's scope after a gap found during Slice 2 prep — see the spec's §6, corrected entry).
- **This sandbox cannot run `qmltestrunner`.** Expected values checked by direct trace against
  `qml/model/OrdersStore.qml` (line numbers cited per function below), same standing constraint as
  every prior file in this suite.
- **Two real, non-obvious behaviors traced from the source, tested exactly as they actually work,
  not as they might be assumed to work:**
  1. `updateOrder`'s local state (`OrdersStore.orders` after the call) is normalized once, via
     `_clone()`'s internal `_normalizeOrder` call, *before* field mutations are applied — the
     second `_normalizeOrder(o)` call inside `_commit(...)` (`:601`) only builds the Gateway
     payload, it does **not** re-normalize what ends up in local `orders`. Both are correct;
     they're just not the same object.
  2. `deleteOrder` (`:733-748`) sets `orders = arr; revision++; _refreshCounts()`
     **unconditionally**, even when the `orderId` doesn't match anything (`arr` is just an
     unchanged clone in that case) — only the final `Gateway.recordMutation` call is skipped when
     nothing was found. `revision` genuinely increments on a no-op delete. Tested as real behavior
     below, not treated as a bug to route around.
- One commit per task, each independently reviewable.

## File Structure

- `tests/tst_OrdersStore_mutations.qml` — new. Created in Task 1, extended in Tasks 2–5.

---

## Task 1: `clear`, `_refreshCounts`, `_commit`

**Files:**
- Create: `tests/tst_OrdersStore_mutations.qml`

**Interfaces:**
- Consumes: `OrdersStore.clear()` (`:155-159`), `OrdersStore._refreshCounts()` (`:487-497`),
  `OrdersStore._commit(arr, changedOrder, action, before)` (`:499-505`).
- Produces: the `Gateway.mode="gateway"` + `AuthStore` reset pattern established in `init()` here is
  reused by every later task in this file that touches `Gateway`/`OutboxStore`.

- [ ] **Step 1: Create the test file with `clear`/`_refreshCounts`/`_commit` coverage**

```qml
import QtQuick
import QtTest
import "../qml/model"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Expected values checked by direct trace against qml/model/OrdersStore.qml
// (line numbers cited per function in this plan's Global Constraints).
// Needs a real qmltestrunner pass before merge.
TestCase {
    name: "OrdersStore_mutations"

    function init() {
        OrdersStore.orders = []
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = "" // see tst_Gateway.qml header / CHECKPOINT.md 2026-08-18
    }

    function test_clear_empties_orders_and_resets_counts() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "completed" }
        ]
        OrdersStore._refreshCounts()
        verify(OrdersStore.pendingOrderCount > 0)

        OrdersStore.clear()

        compare(OrdersStore.orders.length, 0)
        compare(OrdersStore.pendingOrderCount, 0)
        compare(OrdersStore.completedOrderCount, 0)
        compare(OrdersStore.outOfStockCount, 0)
    }

    function test_clear_increments_revision() {
        var before = OrdersStore.revision
        OrdersStore.clear()
        compare(OrdersStore.revision, before + 1)
    }

    function test_refreshCounts_counts_pending_completed_and_out_of_stock() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "pending" },
            { orderId: "ORD-003", status: "completed" },
            { orderId: "ORD-004", status: "out of stock" }
        ]
        OrdersStore._refreshCounts()
        compare(OrdersStore.pendingOrderCount, 2)
        compare(OrdersStore.completedOrderCount, 1)
        compare(OrdersStore.outOfStockCount, 1)
    }

    function test_refreshCounts_does_not_count_processing_status() {
        // "processing" is a real order status but _refreshCounts only
        // tracks pending/completed/"out of stock" -- processingCount() is
        // a separate, on-demand loop (Slice 2), not backed by this.
        OrdersStore.orders = [{ orderId: "ORD-001", status: "processing" }]
        OrdersStore._refreshCounts()
        compare(OrdersStore.pendingOrderCount, 0)
        compare(OrdersStore.completedOrderCount, 0)
        compare(OrdersStore.outOfStockCount, 0)
    }

    function test_refreshCounts_all_zero_when_orders_is_empty() {
        OrdersStore._refreshCounts()
        compare(OrdersStore.pendingOrderCount, 0)
        compare(OrdersStore.completedOrderCount, 0)
        compare(OrdersStore.outOfStockCount, 0)
    }

    function test_commit_replaces_orders_and_increments_revision() {
        var before = OrdersStore.revision
        var newArr = [{ orderId: "ORD-001", status: "pending" }]
        OrdersStore._commit(newArr, null, "update", null)
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].orderId, "ORD-001")
        compare(OrdersStore.revision, before + 1)
    }

    function test_commit_refreshes_counts() {
        OrdersStore._commit([{ orderId: "ORD-001", status: "completed" }], null, "update", null)
        compare(OrdersStore.completedOrderCount, 1)
    }

    function test_commit_records_a_mutation_when_changedOrder_is_given() {
        var before = OutboxStore.dueItems().length
        OrdersStore._commit(
            [{ orderId: "ORD-001", status: "pending" }],
            { orderId: "ORD-001", status: "pending" },
            "update", null
        )
        compare(OutboxStore.dueItems().length, before + 1)
    }

    function test_commit_does_not_record_a_mutation_when_changedOrder_is_null() {
        var before = OutboxStore.dueItems().length
        OrdersStore._commit([{ orderId: "ORD-001", status: "pending" }], null, "update", null)
        compare(OutboxStore.dueItems().length, before)
    }
}
```

- [ ] **Step 2: Run locally (Taher) and confirm all 9 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 9 `OrdersStore_mutations::test_clear_*`/`test_refreshCounts_*`/`test_commit_*` lines
show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_mutations.qml
git commit -m "test(OrdersStore): full coverage for clear/_refreshCounts/_commit

9 tests: clear's state+count reset and revision bump; _refreshCounts'
three tracked statuses plus the negative case that 'processing' is
deliberately not one of them; _commit's array-replace/revision/counts-
refresh, and both branches of its changedOrder guard -- records a
mutation when given one, stays silent when null."
```

---

## Task 2: `_mergeOrder`, `nextOrderId` (smoke), `upsertMany`

**Files:**
- Modify: `tests/tst_OrdersStore_mutations.qml`

**Interfaces:**
- Consumes: `OrdersStore._mergeOrder(existing, incoming)` (`:463-478`) — for a fixed key list, uses
  `incoming[key]` unless it's `undefined`/`null`/an empty string/an empty array, in which case it
  falls back to `existing[key]`; result passed through `_normalizeOrder`.
  `OrdersStore.nextOrderId(callback)` (`:518-527`) — async, calls
  `FirebaseService.mintCounterValue`, smoke-tested only per the spec's Group B routing.
  `OrdersStore.upsertMany(records, callback)` (`:174-301`) — the `!records || records.length === 0`
  branch (`:179-185`) is fully synchronous and independently testable; the real-records path calls
  `FirebaseService.mintCounterBatch`, smoke-tested only.

- [ ] **Step 1: Append `_mergeOrder`, `nextOrderId`, `upsertMany` tests**

Add these functions inside the same `TestCase { ... }` block, after
`test_commit_does_not_record_a_mutation_when_changedOrder_is_null`:

```qml

    function test_mergeOrder_incoming_values_override_existing() {
        var existing = { orderId: "ORD-001", customer: "Old Name", status: "pending", products: [] }
        var incoming = { orderId: "ORD-001", customer: "New Name", status: "completed", products: [] }
        var merged = OrdersStore._mergeOrder(existing, incoming)
        compare(merged.customer, "New Name")
        compare(merged.status, "completed")
    }

    function test_mergeOrder_falls_back_to_existing_when_incoming_field_is_undefined() {
        var existing = { orderId: "ORD-001", customer: "Existing Name", status: "pending", products: [] }
        var incoming = { orderId: "ORD-001", status: "completed", products: [] } // customer omitted
        var merged = OrdersStore._mergeOrder(existing, incoming)
        compare(merged.customer, "Existing Name")
    }

    function test_mergeOrder_falls_back_to_existing_when_incoming_field_is_empty_string() {
        var existing = { orderId: "ORD-001", customer: "Existing Name", status: "pending", products: [] }
        var incoming = { orderId: "ORD-001", customer: "", status: "completed", products: [] }
        var merged = OrdersStore._mergeOrder(existing, incoming)
        compare(merged.customer, "Existing Name")
    }

    function test_mergeOrder_falls_back_to_existing_when_incoming_array_field_is_empty() {
        var existingProducts = [{ productId: "P1", name: "Widget", quantity: 1, price: 10 }]
        var existing = { orderId: "ORD-001", customer: "X", status: "pending", products: existingProducts }
        var incoming = { orderId: "ORD-001", customer: "X", status: "pending", products: [] }
        var merged = OrdersStore._mergeOrder(existing, incoming)
        compare(merged.products.length, 1)
        compare(merged.products[0].productId, "P1")
    }

    function test_nextOrderId_dispatches_without_throwing() {
        OrdersStore.nextOrderId(function(id) {})
        verify(true)
    }

    function test_upsertMany_empty_records_array_returns_zeroed_counts_synchronously() {
        var received = null
        OrdersStore.upsertMany([], function(counts) { received = counts })
        // No FirebaseService call happens on this path (:179-185) -- the
        // callback fires synchronously, so `received` is already set here,
        // not just eventually.
        verify(received !== null, "callback must fire synchronously for an empty records array")
        compare(received.added, 0)
        compare(received.updated, 0)
        compare(received.skipped, 0)
        compare(received.addedIds.length, 0)
    }

    function test_upsertMany_null_records_returns_zeroed_counts_synchronously() {
        var received = null
        OrdersStore.upsertMany(null, function(counts) { received = counts })
        verify(received !== null, "callback must fire synchronously for null records")
        compare(received.added, 0)
    }

    function test_upsertMany_with_records_dispatches_without_throwing() {
        // Non-empty input reaches FirebaseService.mintCounterBatch -- real
        // outcome needs the emulator (E2E slice), this only confirms the
        // synchronous portion before that call doesn't throw.
        OrdersStore.upsertMany(
            [{ orderId: "", customer: "New Customer", products: [], _conflictPolicy: "skip" }],
            function(counts) {}
        )
        verify(true)
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 7 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 7 new lines show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_mutations.qml
git commit -m "test(OrdersStore): full coverage for _mergeOrder, smoke tests for nextOrderId/upsertMany

7 tests: _mergeOrder's override-vs-fallback behavior for scalar and
array fields (undefined, empty string, empty array all count as
'empty' and fall back to existing); upsertMany's empty/null-records
path gets REAL synchronous coverage (asserts the actual zeroed counts
object, not just 'didn't throw') since that path never reaches
FirebaseService at all; the real-records path and nextOrderId stay
smoke-tested per the spec's Group B routing -- both need the emulator
for genuine coverage, planned for the E2E slice."
```

---

## Task 3: `updateOrder`

**Files:**
- Modify: `tests/tst_OrdersStore_mutations.qml`

**Interfaces:**
- Consumes: `OrdersStore.updateOrder(orderId, fields)` (`:573-602`).

- [ ] **Step 1: Append `updateOrder` tests**

Add these functions inside the same `TestCase { ... }` block, after
`test_upsertMany_with_records_dispatches_without_throwing`:

```qml

    function test_updateOrder_updates_the_specified_fields() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "Old Name", email: "old@x.com", phone: "111",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }]
        OrdersStore.updateOrder("ORD-001", { status: "completed", notes: "Handled" })
        var updated = OrdersStore.getById("ORD-001")
        compare(updated.status, "completed")
        compare(updated.notes, "Handled")
    }

    function test_updateOrder_leaves_unspecified_fields_unchanged() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "Keep This Name", email: "keep@x.com", phone: "111",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }]
        OrdersStore.updateOrder("ORD-001", { status: "completed" }) // customer/email not mentioned
        var updated = OrdersStore.getById("ORD-001")
        compare(updated.customer, "Keep This Name")
        compare(updated.email, "keep@x.com")
    }

    function test_updateOrder_recomputes_totals_when_products_change() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "X", email: "", phone: "",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }]
        // Reuses the verified computeOrderTotals case from Slice 1:
        // gross 200, no discount/tax -> subtotal=total=200, itemCount=2.
        OrdersStore.updateOrder("ORD-001", {
            products: [{ productId: "", name: "Widget", price: 100, quantity: 2,
                         taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }]
        })
        var updated = OrdersStore.getById("ORD-001")
        compare(updated.subtotal, 200)
        compare(updated.total, 200)
        compare(updated.items, 2)
    }

    function test_updateOrder_uses_fields_total_directly_when_products_not_given() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "X", email: "", phone: "",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 50, discount: 0, tax: 0,
            taxBreakdown: [], total: 50, items: 1, adjustments: []
        }]
        OrdersStore.updateOrder("ORD-001", { total: "\u20B975.00" }) // string, goes through parseCurrency
        var updated = OrdersStore.getById("ORD-001")
        compare(updated.total, 75)
        compare(updated.subtotal, 50) // untouched -- only products-driven updates recompute subtotal
    }

    function test_updateOrder_is_a_no_op_for_an_unknown_orderId() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OrdersStore.revision
        OrdersStore.updateOrder("ORD-999", { status: "completed" })
        compare(OrdersStore.revision, before) // findIndexById returns -1, function returns before _commit
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].status, "pending")
    }

    function test_updateOrder_records_a_mutation() {
        OrdersStore.orders = [{
            orderId: "ORD-001", customer: "X", email: "", phone: "",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }]
        var before = OutboxStore.dueItems().length
        OrdersStore.updateOrder("ORD-001", { status: "completed" })
        compare(OutboxStore.dueItems().length, before + 1)
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 6 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 6 new lines show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_mutations.qml
git commit -m "test(OrdersStore): full coverage for updateOrder

6 tests: specified-fields update, unspecified-fields-untouched
(guards against a field getting silently clobbered), totals
recomputed when products change (reuses a Slice 1-verified
computeOrderTotals case), fields.total taken directly via
parseCurrency when products isn't given, no-op for an unknown
orderId, and mutation recording."
```

---

## Task 4: `deleteOrder`

**Files:**
- Modify: `tests/tst_OrdersStore_mutations.qml`

**Interfaces:**
- Consumes: `OrdersStore.deleteOrder(orderId)` (`:733-748`).

- [ ] **Step 1: Append `deleteOrder` tests**

Add these functions inside the same `TestCase { ... }` block, after `test_updateOrder_records_a_mutation`:

```qml

    function test_deleteOrder_removes_the_matching_order() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "pending" }
        ]
        OrdersStore.deleteOrder("ORD-001")
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].orderId, "ORD-002")
    }

    function test_deleteOrder_records_a_mutation() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OutboxStore.dueItems().length
        OrdersStore.deleteOrder("ORD-001")
        compare(OutboxStore.dueItems().length, before + 1)
    }

    function test_deleteOrder_is_a_no_op_for_an_unknown_orderId_but_still_increments_revision() {
        // Real, traced behavior (see this plan's Global Constraints): orders/
        // revision/_refreshCounts run unconditionally, BEFORE the found-check.
        // Documenting what the code actually does, not routing around it.
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var beforeRevision = OrdersStore.revision
        OrdersStore.deleteOrder("ORD-999")
        compare(OrdersStore.orders.length, 1) // nothing actually removed
        compare(OrdersStore.revision, beforeRevision + 1) // but revision still bumped
    }

    function test_deleteOrder_does_not_record_a_mutation_for_an_unknown_orderId() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OutboxStore.dueItems().length
        OrdersStore.deleteOrder("ORD-999")
        compare(OutboxStore.dueItems().length, before) // the one guard that DOES check `found`
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 4 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 4 new lines show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_mutations.qml
git commit -m "test(OrdersStore): full coverage for deleteOrder

4 tests: removal, mutation recording, and the two-part real behavior
for an unknown orderId -- orders/revision/_refreshCounts run
unconditionally (revision genuinely increments on a no-op delete) while
only Gateway.recordMutation is actually guarded by whether anything was
found. Tested as real traced behavior, not assumed or routed around."
```

---

## Task 5: `_normalizeOrder`, `_normalizeOrders` — complete this slice

**Files:**
- Modify: `tests/tst_OrdersStore_mutations.qml`

**Interfaces:**
- Consumes: `OrdersStore._normalizeOrder(r)` (`:343-408`), `OrdersStore._normalizeOrders(arr)`
  (`:100-126`, batch wrapper — different field set, backend-shape normalization rather than
  full-order defaulting; both need coverage).
- `_normalizeOrder` resolves per-line `taxable`/`taxPercent` from `InventoryStore.getById(productId)`
  when a line doesn't specify them itself — tests that exercise this path set `InventoryStore.products`
  directly and restore it to `[]` afterward via `init()`.

- [ ] **Step 1: Append `_normalizeOrder`/`_normalizeOrders` tests**

Add these functions inside the same `TestCase { ... }` block, after
`test_deleteOrder_does_not_record_a_mutation_for_an_unknown_orderId`. Also add
`InventoryStore.products = []` to `init()` at the top of the file so these tests start from a known
state:

```qml
```

First, modify `init()`:

```qml
    function init() {
        OrdersStore.orders = []
        InventoryStore.products = []
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = "" // see tst_Gateway.qml header / CHECKPOINT.md 2026-08-18
    }
```

Then append:

```qml

    function test_normalizeOrder_fills_in_missing_optional_fields_with_defaults() {
        var result = OrdersStore._normalizeOrder({ orderId: "ORD-001" })
        compare(result.customer, "")
        compare(result.email, "")
        compare(result.phone, "")
        compare(result.notes, "")
        compare(result.orderChannel, "")
        compare(result.staffId, "")
        compare(result.status, "pending")
        compare(result.adjustments.length, 0)
        compare(result.products.length, 0)
    }

    function test_normalizeOrder_computes_items_and_totals_from_products_when_present() {
        var result = OrdersStore._normalizeOrder({
            orderId: "ORD-001",
            products: [{ productId: "", name: "Widget", price: 100, quantity: 2,
                         taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }]
        })
        // Same verified case as Slice 1: gross 200, no discount/tax.
        compare(result.subtotal, 200)
        compare(result.total, 200)
        compare(result.items, 2)
    }

    function test_normalizeOrder_falls_back_to_r_items_and_r_total_when_no_products() {
        var result = OrdersStore._normalizeOrder({ orderId: "ORD-001", items: 5, total: "\u20B9250.00" })
        compare(result.items, 5)
        compare(result.total, 250) // parseCurrency("₹250.00")
    }

    function test_normalizeOrder_resolves_tax_from_inventory_when_line_does_not_specify_it() {
        InventoryStore.products = [
            { id: "P1", name: "Taxed Widget", taxable: true, taxPercent: 18 }
        ]
        var result = OrdersStore._normalizeOrder({
            orderId: "ORD-001",
            products: [{ productId: "P1", name: "Taxed Widget", price: 100, quantity: 1 }] // no taxable/taxPercent on the line itself
        })
        compare(result.products[0].taxable, true)
        compare(result.products[0].taxPercent, 18)
    }

    function test_normalizeOrder_line_level_taxable_and_taxPercent_override_inventory() {
        InventoryStore.products = [
            { id: "P1", name: "Taxed Widget", taxable: true, taxPercent: 18 }
        ]
        var result = OrdersStore._normalizeOrder({
            orderId: "ORD-001",
            products: [{ productId: "P1", name: "Taxed Widget", price: 100, quantity: 1,
                         taxable: false, taxPercent: 0 }] // line explicitly overrides
        })
        compare(result.products[0].taxable, false)
        compare(result.products[0].taxPercent, 0)
    }

    function test_normalizeOrder_deep_copies_consumption_so_mutating_the_result_does_not_affect_the_source() {
        var sourceConsumption = [{ batchId: "B1", supplierId: "S1", qtyConsumed: 5, unitCost: 10 }]
        var result = OrdersStore._normalizeOrder({
            orderId: "ORD-001",
            products: [{ productId: "P1", name: "Widget", price: 10, quantity: 1, consumption: sourceConsumption }]
        })
        result.products[0].consumption[0].qtyConsumed = 999
        compare(sourceConsumption[0].qtyConsumed, 5) // source untouched -- proves it's a real copy, not a shared reference
    }

    function test_normalizeOrder_adjustments_defaults_to_empty_array_when_missing_or_not_an_array() {
        var result1 = OrdersStore._normalizeOrder({ orderId: "ORD-001" }) // adjustments omitted
        compare(result1.adjustments.length, 0)
        var result2 = OrdersStore._normalizeOrder({ orderId: "ORD-001", adjustments: "not an array" })
        compare(result2.adjustments.length, 0)
    }

    function test_normalizeOrders_normalizes_every_order_in_the_array() {
        var arr = [
            { order_id: "ORD-001" }, // backend field name, no local orderId yet
            { orderId: "ORD-002", customer: "Already Has Customer" }
        ]
        var result = OrdersStore._normalizeOrders(arr)
        compare(result.length, 2)
        compare(result[0].orderId, "ORD-001") // order_id -> orderId
        compare(result[0].customer, "") // defaulted
        compare(result[1].customer, "Already Has Customer") // left alone
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 8 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 8 new lines show `PASS`. Slice 3 complete: 34 tests total in this file.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_mutations.qml
git commit -m "test(OrdersStore): full coverage for _normalizeOrder/_normalizeOrders

8 tests: default-filling for a bare-minimum order, totals computed from
products vs. falling back to r.items/r.total when there are none,
inventory-resolved tax on a line that doesn't specify it and the line-
level override that beats inventory, the consumption[] deep-copy (proves
it's a real copy, not a shared reference, per the 2026-07-30 bug this
function's own comment documents), adjustments defaulting to [] for both
missing and non-array input, and _normalizeOrders' backend-field-name
translation across a batch. Slice 3 of 5 complete --
tst_OrdersStore_mutations.qml done, 34 tests total."
```

---

## Self-review (per writing-plans skill)

**Spec coverage:** Spec's Group A rows for `clear`, `_mergeOrder`, `_refreshCounts`, `_commit`,
`updateOrder`, `deleteOrder`, `_normalizeOrder` — all covered with real tests. Group B rows for
`nextOrderId`, `upsertMany` — smoke-tested per the spec's routing, except `upsertMany`'s empty/null
path which turned out to be fully synchronous and got real coverage instead (a genuine improvement
over the spec's original "smoke-test half" framing for that one path, not a deviation from it —
worth a note back to the spec, see below). `addOrder` — smoke test still needed; not yet added in
this plan, see gap below.

**Gap found in this self-review**: `addOrder`'s own smoke test was planned in the spec's file
layout ("addOrder (smoke-test half)") but no task above actually adds it. Fixing now rather than
letting it slide to Slice 4 by accident — added as a final addendum task.

**Placeholder scan:** No "TBD"/"similar to Task N" — every step has complete, runnable code.

**Type consistency:** Function names and line numbers re-checked against
`qml/model/OrdersStore.qml` directly while writing this plan (not from the spec's table, which
doesn't carry line numbers), including the two non-obvious behaviors called out in Global
Constraints.

## Addendum: `addOrder` smoke test (closing the gap found above)

**Files:**
- Modify: `tests/tst_OrdersStore_mutations.qml`

- [ ] **Step 1: Append the `addOrder` smoke test**

Add this function inside the same `TestCase { ... }` block, after
`test_normalizeOrders_normalizes_every_order_in_the_array`:

```qml

    function test_addOrder_dispatches_without_throwing() {
        // addOrder is fully async (nextOrderId -> FirebaseService.mintCounterValue
        // is its first step) -- real outcome needs the emulator (E2E slice),
        // this only confirms the synchronous portion before that call doesn't throw.
        OrdersStore.addOrder(
            "New Customer", 0, 0, "pending", new Date(), "", "", [], "", "",
            function(ok, id) {}
        )
        verify(true)
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm the new test passes**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: `OrdersStore_mutations::test_addOrder_dispatches_without_throwing` shows `PASS`. Slice 3
now genuinely complete: 35 tests total.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_mutations.qml
git commit -m "test(OrdersStore): add the addOrder smoke test missed in this slice's first self-review

Closes a gap this plan's own self-review caught: addOrder was in the
spec's file layout for this slice but no task actually added it.
Smoke-test only, per the spec's Group B routing -- addOrder is fully
async (nextOrderId -> FirebaseService.mintCounterValue is its first
step), real coverage is the E2E slice's job."
```
