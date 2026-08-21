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
}
