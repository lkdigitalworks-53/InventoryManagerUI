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
        // unconditionally.
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
