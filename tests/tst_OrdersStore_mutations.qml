import QtQuick
import QtTest
import "../qml/model"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Expected values checked by direct trace against qml/model/OrdersStore.qml
// (line numbers cited per function in the plan doc). Needs a real
// qmltestrunner pass before merge.
TestCase {
    name: "OrdersStore_mutations"

    function init() {
        OrdersStore.orders = []
        InventoryStore.products = []
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
}
