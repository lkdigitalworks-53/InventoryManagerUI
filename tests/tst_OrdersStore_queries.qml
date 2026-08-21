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
