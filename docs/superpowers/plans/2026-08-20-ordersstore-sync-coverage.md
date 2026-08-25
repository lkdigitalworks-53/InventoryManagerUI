# OrdersStore Sync Coverage — Implementation Plan (Slice 4 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full test coverage for `_onMutationConflicted` (real, complete coverage — it's pure/local
despite being triggered by a network event), and both real and smoke coverage for `_load`,
`_resetAndFetch`, `_fetchFromFirebase`, `syncFromFirebase` — the re-entrancy guards on the latter
three are pure and synchronously testable even though the fetch itself isn't.

**Architecture:** One new file, `tests/tst_OrdersStore_sync.qml`, two commits.

**Tech Stack:** QML/Qt Quick Test (`qmltestrunner`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-20-ordersstore-full-coverage-design.md` — implements that
  spec's Group A row for `_onMutationConflicted` and Group B rows for `_load`/`_resetAndFetch`/
  `_fetchFromFirebase`/`syncFromFirebase`, upgraded from pure smoke tests to real guard-logic
  coverage where the spec itself flagged that possibility (§3's Group B table, `_load`/
  `_resetAndFetch` row: "the `loadingMore` re-entrancy guard itself is pure and local").
- **This sandbox cannot run `qmltestrunner`.** Expected values checked by direct trace against
  `qml/model/OrdersStore.qml:63-152`, same standing constraint as every prior file.
- **One real behavior worth calling out explicitly**: `_onMutationConflicted`'s `revision++` and
  `_refreshCounts()` calls happen **unconditionally** after the `if(current)/else if` block —
  even in the case where entity matches "order" but neither branch actually changes `orders`
  (conflict reported on an order this client doesn't have locally, with `current` also falsy — an
  edge case, but the source doesn't special-case it out of the revision bump). Same pattern as
  `deleteOrder`'s unconditional revision bump found in Slice 3 — tested as real behavior, not
  routed around.
- One commit per task.

## File Structure

- `tests/tst_OrdersStore_sync.qml` — new. Created in Task 1, extended in Task 2.

---

## Task 1: `_onMutationConflicted` — full coverage

**Files:**
- Create: `tests/tst_OrdersStore_sync.qml`

**Interfaces:**
- Consumes: `OrdersStore._onMutationConflicted(entity, entityId, current)` (`:63-81`) — connected to
  `Gateway.mutationConflicted` in production (`Component.onCompleted`, `:53`), called directly here
  since the signal-connection wiring itself isn't this function's concern.

- [ ] **Step 1: Create the test file with `_onMutationConflicted` coverage**

```qml
import QtQuick
import QtTest
import "../qml/model"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Expected values checked by direct trace against
// qml/model/OrdersStore.qml:63-152. Needs a real qmltestrunner pass
// before merge.
TestCase {
    name: "OrdersStore_sync"

    function init() {
        OrdersStore.orders = []
        OrdersStore.loadingMore = false
        OrdersStore.hasMore = true
    }

    function test_onMutationConflicted_ignores_a_non_order_entity() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OrdersStore.revision
        OrdersStore._onMutationConflicted("product", "ORD-001", { orderId: "ORD-001", status: "completed" })
        compare(OrdersStore.revision, before) // early return, before revision++
        compare(OrdersStore.orders[0].status, "pending") // untouched
    }

    function test_onMutationConflicted_replaces_the_local_order_with_the_servers_current_version() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        OrdersStore._onMutationConflicted("order", "ORD-001", { orderId: "ORD-001", status: "completed" })
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].status, "completed")
    }

    function test_onMutationConflicted_pushes_current_when_the_order_is_not_locally_known() {
        // "rare: conflict on what we thought was a create" (source comment,
        // qml/model/OrdersStore.qml:73) -- the local client doesn't have
        // this orderId at all, but the server reports a conflicted current
        // version. Pushed, not silently dropped.
        OrdersStore.orders = []
        OrdersStore._onMutationConflicted("order", "ORD-999", { orderId: "ORD-999", status: "completed" })
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].orderId, "ORD-999")
    }

    function test_onMutationConflicted_removes_the_local_order_when_current_is_falsy_and_it_was_found() {
        // current === null means "deleted elsewhere".
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        OrdersStore._onMutationConflicted("order", "ORD-001", null)
        compare(OrdersStore.orders.length, 0)
    }

    function test_onMutationConflicted_is_a_no_op_on_orders_array_when_current_is_falsy_and_not_found() {
        // Neither branch of the if/else-if applies -- orders array itself
        // doesn't change -- but revision/refreshCounts still run
        // unconditionally (see this plan's Global Constraints).
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OrdersStore.revision
        OrdersStore._onMutationConflicted("order", "ORD-999", null)
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].orderId, "ORD-001")
        compare(OrdersStore.revision, before + 1) // still bumped, per the real traced behavior
    }

    function test_onMutationConflicted_increments_revision_and_refreshes_counts() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        var before = OrdersStore.revision
        OrdersStore._onMutationConflicted("order", "ORD-001", { orderId: "ORD-001", status: "completed" })
        compare(OrdersStore.revision, before + 1)
        compare(OrdersStore.completedOrderCount, 1)
    }
}
```

- [ ] **Step 2: Run locally (Taher) and confirm all 6 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 6 `OrdersStore_sync::test_onMutationConflicted_*` lines show `PASS`.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_sync.qml
git commit -m "test(OrdersStore): full coverage for _onMutationConflicted

6 tests: non-order-entity early return (before revision bumps), the
normal replace-with-server-version case, the rare push-when-not-
locally-known case the source comments as such, removal when deleted
elsewhere (current === null), and the edge case where neither branch
applies but revision/refreshCounts still run unconditionally -- same
pattern as deleteOrder's unconditional revision bump found in Slice 3,
tested as real behavior rather than assumed away."
```

---

## Task 2: `_load`, `_resetAndFetch`, `_fetchFromFirebase`, `syncFromFirebase` — complete this slice

**Files:**
- Modify: `tests/tst_OrdersStore_sync.qml`

**Interfaces:**
- Consumes: `OrdersStore._load()` (`:87-89`, one-line wrapper around `_resetAndFetch`),
  `OrdersStore._resetAndFetch()` (`:91-98`, its own `if (loadingMore) return` guard, `:92`),
  `OrdersStore._fetchFromFirebase()` (`:128-151`, its own independent `if (loadingMore) return`
  guard, `:129`, then sets `loadingMore = true` and calls `FirebaseService.query`),
  `OrdersStore.syncFromFirebase()` (`:153`, one-line wrapper around `_resetAndFetch`).

- [ ] **Step 1: Append the guard and smoke tests**

Add these functions inside the same `TestCase { ... }` block, after
`test_onMutationConflicted_increments_revision_and_refreshes_counts`:

```qml

    function test_resetAndFetch_is_a_no_op_while_a_fetch_is_already_in_flight() {
        // Same pattern this codebase already established for TransactionStore
        // (TransactionStore_resetGuard::test_resetAndFetch_is_a_no_op_while_a_fetch_is_already_in_flight).
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        OrdersStore.loadingMore = true
        OrdersStore._resetAndFetch()
        // Guard returns before the orders=[]/hasMore=true/_cursor=null reset:
        compare(OrdersStore.orders.length, 1)
    }

    function test_resetAndFetch_resets_local_state_and_begins_a_fetch_when_not_already_in_flight() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        OrdersStore.hasMore = false
        OrdersStore.loadingMore = false
        OrdersStore._resetAndFetch()
        // Synchronously observable before any network response arrives:
        // orders/hasMore reset, then _fetchFromFirebase's own entry sets
        // loadingMore = true.
        compare(OrdersStore.orders.length, 0)
        compare(OrdersStore.hasMore, true)
        compare(OrdersStore.loadingMore, true)
    }

    function test_load_delegates_to_resetAndFetch() {
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        OrdersStore.loadingMore = false
        OrdersStore._load()
        compare(OrdersStore.orders.length, 0) // same observable effect as _resetAndFetch directly
    }

    function test_fetchFromFirebase_is_a_no_op_while_already_in_flight() {
        // _fetchFromFirebase has its OWN independent loadingMore guard
        // (:129) -- a separate line from _resetAndFetch's (:92) -- tested
        // separately since it's separate code, even though both check the
        // same flag.
        OrdersStore.hasMore = false
        OrdersStore.loadingMore = true
        OrdersStore._fetchFromFirebase()
        compare(OrdersStore.hasMore, false) // guard returns before hasMore/_cursor could change
    }

    function test_fetchFromFirebase_dispatches_without_throwing_when_not_already_in_flight() {
        OrdersStore.loadingMore = false
        OrdersStore._fetchFromFirebase()
        verify(true)
        compare(OrdersStore.loadingMore, true) // its own entry sets this synchronously, before any network response
    }

    function test_syncFromFirebase_dispatches_without_throwing() {
        OrdersStore.syncFromFirebase()
        verify(true)
    }
```

- [ ] **Step 2: Run locally (Taher) and confirm all 6 new tests pass**

Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml -o -,txt`
Expected: all 6 new lines show `PASS`. Slice 4 complete: 12 tests total in this file.

- [ ] **Step 3: Commit**

```bash
git add tests/tst_OrdersStore_sync.qml
git commit -m "test(OrdersStore): guard-logic and smoke coverage for _load/_resetAndFetch/_fetchFromFirebase/syncFromFirebase

6 tests: _resetAndFetch's loadingMore guard gets REAL coverage both
ways (no-op while in flight; resets state and begins a fetch when not),
matching the TransactionStore_resetGuard precedent already established
in this suite. _fetchFromFirebase's own independent loadingMore guard
(separate line, same flag) tested separately. _load and syncFromFirebase
smoke-tested as thin wrappers. Real fetch outcomes (pagination assembly,
failure handling) remain the E2E slice's job per the spec's Group B
routing -- this file only covers what's synchronously observable before
any network response arrives. Slice 4 of 5 complete --
tst_OrdersStore_sync.qml done, 12 tests total."
```

---

## Self-review (per writing-plans skill)

**Spec coverage:** Spec's Group A row for `_onMutationConflicted` — full coverage, 6 tests. Group B
rows for `_load`/`_resetAndFetch`/`_fetchFromFirebase`/`syncFromFirebase` — upgraded from pure
smoke tests to real guard-logic coverage (matching what the spec itself flagged as possible), with
smoke coverage retained for the genuinely-can't-verify-without-emulator portions.

**Placeholder scan:** No "TBD"/"similar to Task N" — every step has complete, runnable code.

**Type consistency:** Function/property names (`loadingMore`, `hasMore`, `_cursor`, `orders`,
`revision`) re-checked against `qml/model/OrdersStore.qml:1-152` directly while writing this plan.

**What this slice does not cover, and where it goes instead:** Real pagination assembly (seed >50
orders, confirm multi-page fetch completes), a failed/rejected fetch's actual recovery, and the
genuine multi-user conflict scenario (two sessions racing an edit, `_onMutationConflicted` firing
for real through the emulator rather than called directly with a fake payload) — all Slice 5
(`test/e2e/tst_OrdersStoreE2E.qml`), the final plan in this series.
