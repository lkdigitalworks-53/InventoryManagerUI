import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// Coverage for DataModel.onDeleteProduct / onDeleteOrder — NOT new logic
// (this branch didn't touch DataModel.qml at all), but it had zero test
// coverage before this file and is exactly the "does a blocked delete
// notify the user" question this branch was asked to check. Traced by
// reading qml/model/DataModel.qml:257-276 (onDeleteProduct) and
// qml/model/DataModel.qml:172-191 (onDeleteOrder).
//
// DataModel takes its dispatcher as an injected property (see
// qml/Main.qml: `Logic { id: logic }` then `DataModel { dispatcher: logic }`)
// rather than a hardcoded singleton reference, so a fresh Logic+DataModel
// pair here is fully isolated from any other test file or the real app —
// same technique as tst_DataModel_adjustOrderSyncGuard.qml, extended to
// go through the real signal dispatch (logic.deleteProduct(...)/
// logic.deleteOrder(...)) rather than calling a private function directly,
// since onDeleteProduct/onDeleteOrder have no separate _tryDeleteX to call
// into the way onAdjustOrder does.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Uses SignalSpy, which no other file in this suite currently does; a
// completely standard QtTest type, but flagging since it's new to this
// specific test suite's established patterns.
TestCase {
    name: "DataModel_deleteGuards"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }

    SignalSpy { id: errorSpy;   target: testLogic; signalName: "errorOccurred" }
    SignalSpy { id: prodDelSpy; target: testLogic; signalName: "productDeleted" }
    SignalSpy { id: ordDelSpy;  target: testLogic; signalName: "orderDeleted" }

    function init() {
        InventoryStore.products = []
        OrdersStore.orders = []
        AuthStore.role = ""
        errorSpy.clear()
        prodDelSpy.clear()
        ordDelSpy.clear()
    }

    function _product() {
        return { productId: "SKU-1", name: "Widget", sku: "W1", category: "",
                 description: "", unit: "pc", price: 100, sellingPrice: 100,
                 taxable: false, taxPercent: 0, size: "", stock: 10, minStock: 0 }
    }

    function _order(status) {
        return { orderId: "ORD-1", customer: "Test Customer", status: status,
                 date: "2026-08-30", email: "", phone: "", notes: "",
                 orderChannel: "", staffId: "", adjustments: [],
                 products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: 1 }] }
    }

    // ── product delete: permission guard ────────────────────────────────────

    function test_deleteProduct_refused_for_role_without_permission() {
        AuthStore.role = "staff"
        InventoryStore.products = [_product()]

        testLogic.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 1, "product must still be present — delete refused")
        compare(errorSpy.count, 1)
        compare(errorSpy.signalArguments[0][0], "auth")
        compare(errorSpy.signalArguments[0][1], "Only owner/admin can delete products")
        compare(prodDelSpy.count, 0, "productDeleted must not fire on a refused delete")
    }

    // ── product delete: open-order guard ────────────────────────────────────

    function test_deleteProduct_refused_while_open_order_references_it() {
        AuthStore.role = "owner"
        InventoryStore.products = [_product()]
        OrdersStore.orders = [_order("pending")]

        testLogic.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 1, "product must still be present — delete refused")
        compare(errorSpy.count, 1)
        compare(errorSpy.signalArguments[0][0], "inventory")
        verify(errorSpy.signalArguments[0][1].indexOf("ORD-1") >= 0,
               "message must name the blocking order so the user knows what to resolve")
        compare(prodDelSpy.count, 0)
    }

    function test_deleteProduct_allowed_once_the_referencing_order_is_completed() {
        // openOrdersForProduct only counts pending/processing/"out of stock"
        // (OrdersStore.qml:566) — a completed order keeps its line-item
        // snapshot but no longer blocks the product it referenced.
        AuthStore.role = "owner"
        InventoryStore.products = [_product()]
        OrdersStore.orders = [_order("completed")]

        testLogic.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0, "delete must proceed")
        compare(prodDelSpy.count, 1)
        compare(prodDelSpy.signalArguments[0][0], "SKU-1")
    }

    // ── product delete: success path ────────────────────────────────────────

    function test_deleteProduct_succeeds_for_owner_with_no_open_orders() {
        AuthStore.role = "owner"
        InventoryStore.products = [_product()]

        testLogic.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0)
        compare(errorSpy.count, 0)
        compare(prodDelSpy.count, 1)
        compare(prodDelSpy.signalArguments[0][0], "SKU-1")
    }

    // ── order delete: permission guard ──────────────────────────────────────

    function test_deleteOrder_refused_for_role_without_permission() {
        AuthStore.role = "staff"
        OrdersStore.orders = [_order("pending")]

        testLogic.deleteOrder("ORD-1")

        compare(OrdersStore.orders.length, 1, "order must still be present — delete refused")
        compare(errorSpy.count, 1)
        compare(errorSpy.signalArguments[0][0], "auth")
        compare(errorSpy.signalArguments[0][1], "You do not have permission to delete orders")
        compare(ordDelSpy.count, 0)
    }

    function test_deleteOrder_allowed_for_manager_role() {
        // canDeleteOrders in AuthStore.qml is owner/admin/manager — manager
        // specifically is the narrowest role that should still succeed.
        AuthStore.role = "manager"
        OrdersStore.orders = [_order("pending")]

        testLogic.deleteOrder("ORD-1")

        compare(OrdersStore.orders.length, 0)
        compare(ordDelSpy.count, 1)
    }

    // ── order delete: completed-status guard ────────────────────────────────

    function test_deleteOrder_refused_while_completed() {
        AuthStore.role = "owner"
        OrdersStore.orders = [_order("completed")]

        testLogic.deleteOrder("ORD-1")

        compare(OrdersStore.orders.length, 1, "order must still be present — delete refused")
        compare(errorSpy.count, 1)
        compare(errorSpy.signalArguments[0][0], "order")
        compare(errorSpy.signalArguments[0][1],
                "Completed orders can't be deleted directly — reopen it to pending first, then delete")
        compare(ordDelSpy.count, 0)
    }

    function test_deleteOrder_succeeds_once_reopened_to_pending() {
        // Mirrors the guard's own documented escape hatch: reopen (status
        // -> pending) via the existing revert branch, then delete succeeds.
        AuthStore.role = "owner"
        OrdersStore.orders = [_order("pending")]

        testLogic.deleteOrder("ORD-1")

        compare(OrdersStore.orders.length, 0)
        compare(errorSpy.count, 0)
        compare(ordDelSpy.count, 1)
        compare(ordDelSpy.signalArguments[0][0], "ORD-1")
    }

    // ── order delete: success path for non-completed, non-pending status ────

    function test_deleteOrder_succeeds_for_processing_status() {
        AuthStore.role = "admin"
        OrdersStore.orders = [_order("processing")]

        testLogic.deleteOrder("ORD-1")

        compare(OrdersStore.orders.length, 0)
        compare(ordDelSpy.count, 1)
    }
}
