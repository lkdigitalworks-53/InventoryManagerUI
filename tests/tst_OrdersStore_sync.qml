import QtQuick
import QtTest
import "../qml/model"
import "../qml/components"

// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Expected values checked by direct trace against
// qml/model/OrdersStore.qml:63-152. Needs a real qmltestrunner pass
// before merge.
TestCase {
    name: "OrdersStore_sync"

    SignalSpy { id: toastSpy; target: Toast; signalName: "showRequested" }

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

    // ── action-based toast wording (2026-08-30) ─────────────────────────────
    // Gateway.mutationConflicted grew a 4th `action` param so this handler
    // can tell a rejected delete-attempt apart from a rejected edit — see
    // docs/superpowers/specs/2026-08-30-product-order-delete-ui.md. Uses
    // SignalSpy on Toast.showRequested, new to this file (existing tests
    // above never asserted on toast text) but a standard QtTest type.

    function test_update_conflict_shows_the_update_worded_toast() {
        toastSpy.clear()
        OrdersStore.orders = [{ orderId: "ORD-001", status: "pending" }]
        OrdersStore._onMutationConflicted("order", "ORD-001", { orderId: "ORD-001", status: "completed" }, "update")
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0],
                "This order was updated elsewhere — your change didn't save. \nRefreshed to the latest version.")
    }

    function test_delete_conflict_restores_the_order_and_shows_delete_worded_toast() {
        toastSpy.clear()
        // The order was optimistically removed locally by deleteOrder()'s
        // optimistic apply before the mutation was sent; the server
        // rejected the delete because someone else's edit landed first.
        OrdersStore.orders = []
        OrdersStore._onMutationConflicted("order", "ORD-001", { orderId: "ORD-001", status: "processing" }, "delete")
        compare(OrdersStore.orders.length, 1, "order must be restored, not stay deleted")
        compare(OrdersStore.orders[0].orderId, "ORD-001")
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0],
                "Couldn't delete — this order was updated elsewhere. It's been restored with the latest version.")
    }

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
        // _fetchFromFirebase has its OWN independent loadingMore guard --
        // a separate line from _resetAndFetch's -- tested separately
        // since it's separate code, even though both check the same flag.
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
}
