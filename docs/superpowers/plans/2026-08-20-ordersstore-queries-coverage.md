# OrdersStore Queries Coverage — Implementation Plan (Slice 2 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full test coverage for `OrdersStore.qml`'s eight read-only query/lookup functions: `get`,
`getById`, `findIndexById`, `openOrdersForProduct`, `pendingCount`, `completedThisMonth`,
`totalRevenue`, `processingCount`.

**Architecture:** One new file, `tests/tst_OrdersStore_queries.qml`, built across three commits.
All eight functions are pure reads over `OrdersStore.orders` (or, for the two trivial getters,
over `pendingOrderCount`/`completedOrderCount` directly) — no network, no mutation. Tests set
`OrdersStore.orders` (or the two count properties) directly to a known fixture rather than going
through `addOrder`/`_commit`, since those paths are Slice 3's concern and pulling them in here
would make this file depend on a slice that doesn't exist yet.

**Tech Stack:** QML/Qt Quick Test (`qmltestrunner`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-20-ordersstore-full-coverage-design.md` — implements that
  spec's Group A table rows for these eight functions, and the §5 happy/edge/negative taxonomy for
  each.
- **This sandbox cannot run `qmltestrunner`** — same standing constraint as every prior file. Every
  function here is a straightforward loop/conditional with no floating-point rounding involved (the
  one place that mattered, `computeOrderTotals`, was Slice 1's concern and was verified via Node
  there), so expected values below were checked by direct trace against the source
  (`qml/model/OrdersStore.qml:545-571,750-763`), not by execution — flagged as such, not implied to
  be machine-verified the way Slice 1's rounding case was.
- One commit per task, each independently reviewable.

## File Structure

- `tests/tst_OrdersStore_queries.qml` — new. Created in Task 1, extended in Tasks 2–3.

---

## Task 1: `get`, `getById`, `findIndexById`

**Files:**
- Create: `tests/tst_OrdersStore_queries.qml`

**Interfaces:**
- Consumes: `OrdersStore.get(idx)` (bounds-checked array access, returns `null` out of range),
  `OrdersStore.getById(orderId)` (returns the order or `null`), `OrdersStore.findIndexById(orderId)`
  (returns the index or `-1`) — all read `OrdersStore.orders` directly
  (`qml/model/OrdersStore.qml:545-552`).
- Produces: nothing consumed by later tasks in this file — each function group here is independent.

- [ ] **Step 1: Create the test file with the three lookup functions**

```qml
import QtQuick
import QtTest
import "../qml/model"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Expected values checked by direct trace against
// qml/model/OrdersStore.qml:545-571,750-763, not by execution (unlike
// Slice 1's computeOrderTotals tests, nothing here involves floating-
// point rounding). Needs a real qmltestrunner pass before merge.
TestCase {
    name: "OrdersStore_queries"

    function init() {
        OrdersStore.orders = [] // isolate each test from whatever the previous one left behind
    }

    function test_get_returns_the_order_at_a_valid_index() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "completed" }
        ]
        compare(OrdersStore.get(1).orderId, "ORD-002")
    }

    function test_get_returns_null_for_a_negative_index() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        compare(OrdersStore.get(-1), null)
    }

    function test_get_returns_null_for_an_index_past_the_end() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        compare(OrdersStore.get(1), null)
    }

    function test_get_returns_null_when_orders_is_empty() {
        compare(OrdersStore.get(0), null)
    }

    function test_getById_returns_the_matching_order() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "completed" }
        ]
        compare(OrdersStore.getById("ORD-002").status, "completed")
    }

    function test_getById_returns_null_when_no_order_matches() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        compare(OrdersStore.getById("ORD-999"), null)
    }

    function test_getById_returns_null_when_orders_is_empty() {
        compare(OrdersStore.getById("ORD-001"), null)
    }

    function test_findIndexById_returns_the_matching_index() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-002", status: "completed" }
        ]
        compare(OrdersStore.findIndexById("ORD-002"), 1)
    }

    function test_findIndexById_returns_negative_one_when_not_found() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        compare(OrdersStore.findIndexById("ORD-999"), -1)
    }

    function test_findIndexById_returns_the_first_match_when_ids_somehow_repeat() {
        // orderId should always be unique in practice, but the function
        // itself just does a forward linear scan and returns on first
        // match -- documenting that actual behavior, not assuming it.
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending" },
            { orderId: "ORD-001", status: "completed" }
        ]
        compare(OrdersStore.findIndexById("ORD-001"), 0)
    }
}
```

- [ ] **Step 2: Run locally (Taher) and confirm all 10 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 10 `OrdersStore_queries::test_get_*`/`test_getById_*`/`test_findIndexById_*` lines
show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_queries.qml
git commit -m "test(OrdersStore): full coverage for get/getById/findIndexById

10 tests: valid-index/matching-id happy paths, negative index,
past-the-end index, empty-orders, no-match, and the documented
first-match-wins behavior if orderId ever repeats (a data-integrity
assumption this function relies on but doesn't itself enforce)."
```

---

## Task 2: `openOrdersForProduct`, `pendingCount`, `completedThisMonth`

**Files:**
- Modify: `tests/tst_OrdersStore_queries.qml`

**Interfaces:**
- Consumes: `OrdersStore.openOrdersForProduct(productId)` (`qml/model/OrdersStore.qml:556-571`) —
  filters `orders` to status `pending`/`processing`/`out of stock`, returns the `orderId`s (not the
  order objects) of ones whose `products[]` reference `productId`. `OrdersStore.pendingCount()` /
  `completedThisMonth()` (`:513-514`) — trivial getters over `pendingOrderCount`/
  `completedOrderCount`, settable `property int`s tested directly here; the logic that actually
  *computes* those two properties (`_refreshCounts`) is Slice 3's concern, not duplicated here.

- [ ] **Step 1: Append the next set of tests**

Add these functions inside the same `TestCase { ... }` block, after
`test_findIndexById_returns_the_first_match_when_ids_somehow_repeat`:

```qml

    function test_openOrdersForProduct_includes_pending_orders_referencing_the_product() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending", products: [{ productId: "P1" }] }
        ]
        compare(OrdersStore.openOrdersForProduct("P1"), ["ORD-001"])
    }

    function test_openOrdersForProduct_includes_processing_and_out_of_stock_orders_too() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "processing", products: [{ productId: "P1" }] },
            { orderId: "ORD-002", status: "out of stock", products: [{ productId: "P1" }] }
        ]
        var refs = OrdersStore.openOrdersForProduct("P1")
        compare(refs.length, 2)
        verify(refs.indexOf("ORD-001") !== -1)
        verify(refs.indexOf("ORD-002") !== -1)
    }

    function test_openOrdersForProduct_excludes_completed_orders() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "completed", products: [{ productId: "P1" }] }
        ]
        compare(OrdersStore.openOrdersForProduct("P1"), [])
    }

    function test_openOrdersForProduct_excludes_orders_that_dont_reference_the_product() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending", products: [{ productId: "P2" }] }
        ]
        compare(OrdersStore.openOrdersForProduct("P1"), [])
    }

    function test_openOrdersForProduct_returns_empty_array_when_no_orders_exist() {
        compare(OrdersStore.openOrdersForProduct("P1"), [])
    }

    function test_openOrdersForProduct_returns_each_matching_orderId_once_even_with_multiple_matching_lines() {
        // Same product referenced twice in one order's line items -- the
        // source `break`s after the first match per order, so the orderId
        // must appear exactly once in the result, not twice.
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "pending",
              products: [{ productId: "P1" }, { productId: "P1" }] }
        ]
        compare(OrdersStore.openOrdersForProduct("P1"), ["ORD-001"])
    }

    function test_pendingCount_returns_the_pendingOrderCount_property() {
        OrdersStore.pendingOrderCount = 7
        compare(OrdersStore.pendingCount(), 7)
    }

    function test_pendingCount_zero() {
        OrdersStore.pendingOrderCount = 0
        compare(OrdersStore.pendingCount(), 0)
    }

    function test_completedThisMonth_returns_the_completedOrderCount_property() {
        // Despite the name, this does NOT filter by month -- it's a
        // direct passthrough of completedOrderCount (see
        // qml/model/OrdersStore.qml:514). Documenting actual behavior,
        // not the behavior the name implies. The property's own
        // computation (_refreshCounts) is covered in Slice 3.
        OrdersStore.completedOrderCount = 3
        compare(OrdersStore.completedThisMonth(), 3)
    }

    function test_completedThisMonth_zero() {
        OrdersStore.completedOrderCount = 0
        compare(OrdersStore.completedThisMonth(), 0)
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 10 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 10 new lines show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_queries.qml
git commit -m "test(OrdersStore): full coverage for openOrdersForProduct/pendingCount/completedThisMonth

10 tests: each of the three open statuses (pending/processing/out of
stock), completed-exclusion, non-matching product, empty orders, the
dedup-per-order edge case when one order references the same product
twice, and both trivial getters -- including documenting that
completedThisMonth doesn't actually filter by month despite its name,
it's a direct passthrough of completedOrderCount."
```

---

## Task 3: `totalRevenue`, `processingCount` — complete this slice

**Files:**
- Modify: `tests/tst_OrdersStore_queries.qml`

**Interfaces:**
- Consumes: `OrdersStore.totalRevenue()` (`:750-756`) — sums `total` across orders with
  `status === "completed"` only. `OrdersStore.processingCount()` (`:758-763`) — counts orders with
  `status === "processing"`, computed on demand each call (unlike `pendingCount`, this is **not**
  backed by a reactive property).

- [ ] **Step 1: Append the final tests**

Add these functions inside the same `TestCase { ... }` block, after `test_completedThisMonth_zero`:

```qml

    function test_totalRevenue_sums_total_of_completed_orders_only() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "completed", total: 500 },
            { orderId: "ORD-002", status: "pending", total: 300 },
            { orderId: "ORD-003", status: "completed", total: 250 }
        ]
        compare(OrdersStore.totalRevenue(), 750)
    }

    function test_totalRevenue_returns_zero_when_none_are_completed() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending", total: 500 }]
        compare(OrdersStore.totalRevenue(), 0)
    }

    function test_totalRevenue_returns_zero_when_orders_is_empty() {
        compare(OrdersStore.totalRevenue(), 0)
    }

    function test_processingCount_counts_processing_status_orders() {
        OrdersStore.orders = [
            { orderId: "ORD-001", status: "processing" },
            { orderId: "ORD-002", status: "pending" },
            { orderId: "ORD-003", status: "processing" }
        ]
        compare(OrdersStore.processingCount(), 2)
    }

    function test_processingCount_returns_zero_when_none_are_processing() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "completed" }]
        compare(OrdersStore.processingCount(), 0)
    }

    function test_processingCount_returns_zero_when_orders_is_empty() {
        compare(OrdersStore.processingCount(), 0)
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 6 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 6 new lines show `PASS`. Slice 2 complete: 26 tests total in this file.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_queries.qml
git commit -m "test(OrdersStore): full coverage for totalRevenue/processingCount

6 tests: revenue summing across only completed orders (mixed statuses,
none completed, empty), and processing-status counting (mixed, none,
empty). Slice 2 of 5 complete -- tst_OrdersStore_queries.qml done."
```

---

## Self-review (per writing-plans skill)

**Spec coverage:** Spec's Group A rows for `get`, `getById`, `findIndexById`,
`openOrdersForProduct`, `pendingCount`, `completedThisMonth`, `totalRevenue`, `processingCount` —
all eight now have a task.

**Placeholder scan:** No "TBD"/"similar to Task N" — every step has complete, runnable code and a
concrete expected result.

**Type consistency:** Function names match `OrdersStore.qml`'s actual exposed names exactly
(re-checked against the source at `qml/model/OrdersStore.qml:545-571,750-763` while writing this
plan, not assumed from the spec's table).

**What this slice does not cover:** `addOrder`, `updateOrder`, `deleteOrder`, `clear`, `upsertMany`,
`_mergeOrder`, `_commit`, `_refreshCounts`, `nextOrderId`, `_normalizeOrder`, `_normalizeOrders` —
Slice 3 (`tst_OrdersStore_mutations.qml`), a separate plan.
