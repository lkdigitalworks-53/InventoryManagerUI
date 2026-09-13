import QtQuick
import QtTest
import "../qml/model"
import "../qml/components"

// InventoryStore._onMutationConflicted had zero test coverage before this
// file (unlike OrdersStore's twin, see tst_OrdersStore_sync.qml). Written
// against the same structure as that file, extended with the new `action`
// param (2026-08-30, Gateway.mutationConflicted's 4th arg) that lets this
// handler word its reconcile toast correctly for a rejected delete vs a
// rejected update — see qml/model/InventoryStore.qml's _onMutationConflicted
// and docs/superpowers/specs/2026-08-30-product-order-delete-ui.md.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Uses SignalSpy on the Toast singleton (Toast.showRequested) to verify the
// actual message text, since that's the concrete "does the user get told"
// check this branch was asked to add — no existing file in this suite
// spies on Toast, so this is a new-to-repo pattern, standard QtTest usage.
TestCase {
    name: "InventoryStore_mutationConflicted"

    SignalSpy { id: toastSpy; target: Toast; signalName: "showRequested" }

    function init() {
        InventoryStore.products = []
        toastSpy.clear()
    }

    function test_ignores_a_non_inventory_entity() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget", stock: 5 }]
        InventoryStore._onMutationConflicted("order", "SKU-1", { productId: "SKU-1", name: "Renamed", stock: 9 }, "update")
        compare(InventoryStore.products[0].name, "Widget", "untouched")
        compare(toastSpy.count, 0, "no toast for an entity this handler doesn't own")
    }

    function test_replaces_the_local_product_with_the_servers_current_version_on_update_conflict() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget", sku: "", category: "",
                                      unit: "pc", price: 100, sellingPrice: 100, stock: 5, minStock: 0 }]
        InventoryStore._onMutationConflicted("inventory", "SKU-1",
            { product_id: "SKU-1", name: "Widget", sku: "", category: "", unit: "pc",
              price: 100, sellingPrice: 100, currentStock: 9, minimumStock: 0 }, "update")

        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].stock, 9)
    }

    function test_update_conflict_shows_the_update_worded_toast() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget", sku: "", category: "",
                                      unit: "pc", price: 100, sellingPrice: 100, stock: 5, minStock: 0 }]
        InventoryStore._onMutationConflicted("inventory", "SKU-1",
            { product_id: "SKU-1", name: "Widget", sku: "", category: "", unit: "pc",
              price: 100, sellingPrice: 100, currentStock: 9, minimumStock: 0 }, "update")

        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0],
                "This product was updated elsewhere — your change didn't save. Refreshed to the latest version.")
    }

    function test_delete_conflict_restores_the_product_and_shows_delete_worded_toast() {
        // The product was optimistically removed locally by deleteProduct()
        // before the mutation was sent; the server rejected the delete
        // because someone else's edit landed first, so `current` is that
        // edit and the product must reappear.
        InventoryStore.products = [] // already spliced out by deleteProduct()'s optimistic apply
        InventoryStore._onMutationConflicted("inventory", "SKU-1",
            { product_id: "SKU-1", name: "Widget", sku: "", category: "", unit: "pc",
              price: 100, sellingPrice: 100, currentStock: 9, minimumStock: 0 }, "delete")

        compare(InventoryStore.products.length, 1, "product must be restored, not stay deleted")
        compare(InventoryStore.products[0].productId, "SKU-1")
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0],
                "Couldn't delete — this product was updated elsewhere. It's been restored with the latest version.")
    }

    function test_pushes_current_when_the_product_is_not_locally_known() {
        InventoryStore.products = []
        InventoryStore._onMutationConflicted("inventory", "SKU-9",
            { product_id: "SKU-9", name: "New", sku: "", category: "", unit: "pc",
              price: 1, sellingPrice: 1, currentStock: 1, minimumStock: 0 }, "update")
        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].productId, "SKU-9")
    }

    function test_removes_the_local_product_when_current_is_falsy_and_it_was_found() {
        // current === null: genuinely deleted elsewhere (not this branch's
        // new case — the pre-existing "someone else deleted it" path).
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget", stock: 5 }]
        InventoryStore._onMutationConflicted("inventory", "SKU-1", null, "update")
        compare(InventoryStore.products.length, 0)
    }

    function test_is_a_no_op_on_products_array_when_current_is_falsy_and_not_found() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget", stock: 5 }]
        InventoryStore._onMutationConflicted("inventory", "SKU-9", null, "update")
        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].productId, "SKU-1")
    }
}
