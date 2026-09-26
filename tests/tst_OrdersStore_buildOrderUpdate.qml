import QtQuick
import QtTest
import "../qml/model"

// OrdersStore.buildOrderUpdate / applyRemoteOrder / completionEpoch —
// added for the atomic order-completion operation (C-3, 2026-09-20 plan
// Task 9). buildOrderUpdate is the pure half of updateOrder (computes the
// before/after pair without touching `orders` or the Gateway — the
// CompletionPlan needs this to plan an operation BEFORE anything is sent).
// applyRemoteOrder reflects a server-confirmed order doc into local state
// without sending anything.
//
// completionEpoch is a NEW order field this task adds: it must round-trip
// through _normalizeOrder (used by _clone(), buildOrderUpdate AND
// applyRemoteOrder) or a re-plan after a rejection would silently reuse
// epoch 1 forever — this was found and fixed while implementing this task
// (the plan document's draft code assumed _normalizeOrder already carried
// unknown fields through; the live function does not, it only returns a
// fixed field list — see qml/model/OrdersStore.qml's _normalizeOrder).
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Written
// against the live qml/model/OrdersStore.qml (re-read fresh on current
// main) using the same order fixture shape as tst_OrdersStore_mutations.qml;
// needs a real qmltestrunner pass (CI) before merge.
TestCase {
    name: "OrdersStore_buildOrderUpdate"

    function init() {
        OrdersStore.orders = []
        InventoryStore.products = []
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = "" // see tst_Gateway.qml header / CHECKPOINT.md 2026-08-18
    }

    function _order(overrides) {
        var base = {
            orderId: "ORD-001", customer: "X", email: "", phone: "",
            status: "pending", date: "2026-01-01", notes: "", products: [],
            orderChannel: "", staffId: "", subtotal: 0, discount: 0, tax: 0,
            taxBreakdown: [], total: 0, items: 0, adjustments: []
        }
        return Object.assign(base, overrides || {})
    }

    // -- buildOrderUpdate -----------------------------------------------------

    function test_unknown_order_returns_null() {
        OrdersStore.orders = [_order({ orderId: "ORD-001" })]
        var r = OrdersStore.buildOrderUpdate("ORD-999", { status: "completed" })
        compare(r, null)
    }

    function test_before_equals_the_untouched_stored_order() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending", customer: "Keep Me" })]
        var r = OrdersStore.buildOrderUpdate("ORD-001", { status: "completed" })
        compare(r.before.status, "pending")
        compare(r.before.customer, "Keep Me")
        compare(OrdersStore.getById("ORD-001").status, "pending", "the stored order is untouched")
    }

    function test_after_has_the_requested_fields_applied() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending" })]
        var r = OrdersStore.buildOrderUpdate("ORD-001", { status: "completed", notes: "Done" })
        compare(r.after.status, "completed")
        compare(r.after.notes, "Done")
    }

    function test_recomputes_totals_when_products_change() {
        OrdersStore.orders = [_order({ orderId: "ORD-001" })]
        var r = OrdersStore.buildOrderUpdate("ORD-001", {
            products: [{ productId: "", name: "Widget", price: 100, quantity: 2,
                         taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }]
        })
        compare(r.after.subtotal, 200)
        compare(r.after.total, 200)
        compare(r.after.items, 2)
    }

    function test_carries_completionEpoch_through_to_after() {
        OrdersStore.orders = [_order({ orderId: "ORD-001" })]
        var r = OrdersStore.buildOrderUpdate("ORD-001", { status: "completed", completionEpoch: 1 })
        compare(r.after.completionEpoch, 1)
    }

    function test_does_not_touch_the_stored_orders_array() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending" })]
        OrdersStore.buildOrderUpdate("ORD-001", { status: "completed" })
        compare(OrdersStore.orders[0].status, "pending")
    }

    function test_does_not_bump_revision_or_refresh_counts() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending" })]
        OrdersStore._refreshCounts() // establish a known baseline (counts don't auto-recompute)
        var beforeRevision = OrdersStore.revision
        var beforePending = OrdersStore.pendingOrderCount
        OrdersStore.buildOrderUpdate("ORD-001", { status: "completed" })
        compare(OrdersStore.revision, beforeRevision)
        compare(OrdersStore.pendingOrderCount, beforePending, "counts unchanged — nothing was committed")
    }

    function test_never_calls_the_gateway() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending" })]
        var before = OutboxStore.items.length
        OrdersStore.buildOrderUpdate("ORD-001", { status: "completed" })
        compare(OutboxStore.items.length, before)
    }

    // -- updateOrder still delegates correctly (thin regression check; full
    //    behavioural coverage already lives in tst_OrdersStore_mutations.qml,
    //    unchanged by this refactor and must stay green) -----------------------

    function test_updateOrder_still_commits_through_buildOrderUpdate() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending" })]
        OrdersStore.updateOrder("ORD-001", { status: "completed" })
        compare(OrdersStore.getById("ORD-001").status, "completed")
        compare(OutboxStore.dueItems().length, 1, "updateOrder must still record a mutation")
    }

    // -- completionEpoch round-trips through _normalizeOrder -------------------

    function test_completionEpoch_defaults_to_zero_when_absent() {
        // getById() returns the raw stored object (no normalization on a
        // plain property read) — route this fixture through the real
        // normalize path (buildOrderUpdate -> _clone() -> _normalizeOrder)
        // instead of asserting on the untouched raw fixture, or this test
        // would just be checking JS's `undefined`, not the store's default.
        // (Caught by CI: this exact mistake failed here first — see PR #87.)
        OrdersStore.orders = [_order({ orderId: "ORD-001" })]
        var r = OrdersStore.buildOrderUpdate("ORD-001", { notes: "touch" })
        compare(r.after.completionEpoch, 0)
    }

    function test_completionEpoch_survives_an_unrelated_updateOrder_call() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", completionEpoch: 1 })]
        OrdersStore.updateOrder("ORD-001", { notes: "unrelated edit" })
        compare(OrdersStore.getById("ORD-001").completionEpoch, 1,
                "a field this task adds must not be silently dropped by _normalizeOrder on every other edit")
    }

    // -- applyRemoteOrder -------------------------------------------------------

    function test_applyRemoteOrder_unknown_order_returns_null_and_changes_nothing() {
        OrdersStore.orders = [_order({ orderId: "ORD-001" })]
        var r = OrdersStore.applyRemoteOrder(_order({ orderId: "ORD-999", status: "completed" }))
        compare(r, null)
        compare(OrdersStore.orders.length, 1)
    }

    function test_applyRemoteOrder_replaces_the_local_order_and_returns_the_previous_one() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending" })]
        var incoming = _order({ orderId: "ORD-001", status: "completed", completionEpoch: 1 })
        var previous = OrdersStore.applyRemoteOrder(incoming)
        compare(previous.status, "pending")
        compare(OrdersStore.getById("ORD-001").status, "completed")
        compare(OrdersStore.getById("ORD-001").completionEpoch, 1)
    }

    function test_applyRemoteOrder_bumps_revision_and_refreshes_counts() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending" })]
        var before = OrdersStore.revision
        OrdersStore.applyRemoteOrder(_order({ orderId: "ORD-001", status: "completed" }))
        compare(OrdersStore.revision, before + 1)
        compare(OrdersStore.pendingOrderCount, 0)
        compare(OrdersStore.completedOrderCount, 1)
    }

    function test_applyRemoteOrder_never_calls_the_gateway() {
        OrdersStore.orders = [_order({ orderId: "ORD-001", status: "pending" })]
        var before = OutboxStore.items.length
        OrdersStore.applyRemoteOrder(_order({ orderId: "ORD-001", status: "completed" }))
        compare(OutboxStore.items.length, before)
    }
}
