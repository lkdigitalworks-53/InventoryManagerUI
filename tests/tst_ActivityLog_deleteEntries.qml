import QtQuick
import QtTest
import "../qml/model"

// Bug report (2026-09-15): the Activity feed doesn't show delete operations
// at all -- product_added/product_updated/product_restocked/staff_added/
// staff_updated all log via ActivityLog.record(), but none of the three
// delete functions (InventoryStore.deleteProduct, OrdersStore.deleteOrder,
// StaffStore.deleteStaff) ever called it. Fixed by adding the same
// ActivityLog.record(...) call already used by every other mutation in
// each of those three functions, plus matching icon/gradient entries in
// ActivityPage.qml (kind → "delete" icon, Constants.gradWarm) for the three
// new kinds (product_deleted, order_deleted, staff_deleted).
//
// ActivityLog.record()'s local entries update is synchronous -- only
// _pushOneToFirebase (fire-and-forget, same as everything else) touches
// the network -- so this is cleanly, reliably testable, unlike most of
// this session's Gateway-adjacent fixes.
//
// NOT RUN IN THIS SANDBOX -- same Felgo-free import tier as the other
// InventoryStore/OrdersStore/StaffStore test files that already passed on
// real CI.
TestCase {
    name: "ActivityLog_deleteEntries"

    function init() {
        ActivityLog.clear()
        InventoryStore.products = []
        OrdersStore.orders = []
        StaffStore.staff = []
    }

    function test_deleteProduct_logs_a_product_deleted_entry() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget", sku: "W1",
                                      unit: "pc", price: 100, sellingPrice: 100, stock: 7, minStock: 0 }]

        InventoryStore.deleteProduct("SKU-1")

        compare(ActivityLog.entries.length, 1)
        compare(ActivityLog.entries[0].kind, "product_deleted")
        verify(ActivityLog.entries[0].title.indexOf("Widget") >= 0,
               "title must name the deleted product")
        compare(ActivityLog.entries[0].entityId, "SKU-1")
    }

    function test_deleteOrder_logs_an_order_deleted_entry() {
        OrdersStore.orders = [{ orderId: "ORD-1", customer: "Jane Doe", status: "pending",
                                 total: 250, products: [] }]

        OrdersStore.deleteOrder("ORD-1")

        compare(ActivityLog.entries.length, 1)
        compare(ActivityLog.entries[0].kind, "order_deleted")
        verify(ActivityLog.entries[0].title.indexOf("Jane Doe") >= 0,
               "title must name the customer")
        compare(ActivityLog.entries[0].entityId, "ORD-1")
    }

    function test_deleteStaff_logs_a_staff_deleted_entry() {
        StaffStore.staff = [{ staffId: "STF-1", name: "Alex Kim", role: "manager", department: "" }]

        StaffStore.deleteStaff("STF-1")

        compare(ActivityLog.entries.length, 1)
        compare(ActivityLog.entries[0].kind, "staff_deleted")
        verify(ActivityLog.entries[0].title.indexOf("Alex Kim") >= 0,
               "title must name the removed teammate")
        compare(ActivityLog.entries[0].entityId, "STF-1")
    }

    function test_deleteProduct_of_an_unknown_id_logs_nothing() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget", sku: "",
                                      unit: "pc", price: 100, sellingPrice: 100, stock: 1, minStock: 0 }]

        InventoryStore.deleteProduct("SKU-DOES-NOT-EXIST")

        compare(ActivityLog.entries.length, 0, "a no-op delete must not log a phantom entry")
    }
}
