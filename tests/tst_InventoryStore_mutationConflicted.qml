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

    // hasProduct() reads the paging flags (hasMore / loadingMore / _resetPending): put the singleton back to
    // its defaults so no test leaks a "list complete" state into another file.
    function cleanup() {
        InventoryStore.hasMore = true
        InventoryStore.loadingMore = false
        InventoryStore._resetPending = false
    }

    function _completeList() {
        InventoryStore.hasMore = false
        InventoryStore.loadingMore = false
        InventoryStore._resetPending = false
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

    // Q13 / C26 (PH4 item 5): the server row is already gone -> nothing was "restored".
    function test_C26_delete_conflict_with_null_current_says_already_deleted_not_restored() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        InventoryStore._onMutationConflicted("inventory", "SKU-1", null, "delete")
        compare(InventoryStore.products.length, 0, "the local row stays removed")
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0], "This product was already deleted elsewhere.")
    }

    function test_C26_delete_conflict_with_undefined_current_and_an_unknown_row_still_says_already_deleted() {
        InventoryStore.products = []
        InventoryStore._onMutationConflicted("inventory", "SKU-404", undefined, "delete")
        compare(InventoryStore.products.length, 0)
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0], "This product was already deleted elsewhere.")
    }

    function test_C26_update_conflict_with_null_current_keeps_the_update_worded_toast() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        InventoryStore._onMutationConflicted("inventory", "SKU-1", null, "update")
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0],
                "This product was updated elsewhere \u2014 your change didn't save. Refreshed to the latest version.")
    }

    // ---- Taher 2026-10-06: product row gone -> discard its queued photos; product still there -> keep them ----
    function _queuePhoto(photoId, productId) {
        return PhotoQueue.enqueue({ photoId: photoId, productId: productId, uid: "u-none", tenantId: "t-none",
                                    mainFilePath: "/d/" + photoId + ".jpg", thumbFilePath: "/d/" + photoId + "_t.jpg" })
    }
    function _queuedIds() { return PhotoQueue.items.map(function(x) { return x.photoId }).sort() }

    function test_C27_delete_conflict_with_null_current_discards_that_products_queued_photos_only() {
        PhotoQueue.clear()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }, { productId: "SKU-2", name: "Other" }]
        _queuePhoto("p-a", "SKU-1"); _queuePhoto("p-b", "SKU-1"); _queuePhoto("p-c", "SKU-2")
        InventoryStore._onMutationConflicted("inventory", "SKU-1", null, "delete")
        compare(_queuedIds(), ["p-c"], "SKU-1's photos are gone, SKU-2's survives")
        PhotoQueue.clear()
    }

    function test_C28_update_conflict_with_null_current_also_discards_queued_photos() {
        PhotoQueue.clear()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        _queuePhoto("p-a", "SKU-1")
        InventoryStore._onMutationConflicted("inventory", "SKU-1", null, "update")
        compare(PhotoQueue.pendingCount, 0)
        PhotoQueue.clear()
    }

    function test_C29_conflict_WITH_a_current_keeps_the_queued_photos() {
        PhotoQueue.clear()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        _queuePhoto("p-a", "SKU-1")
        InventoryStore._onMutationConflicted("inventory", "SKU-1", { productId: "SKU-1", name: "Widget v2" }, "delete")
        InventoryStore._onMutationConflicted("inventory", "SKU-1", { productId: "SKU-1", name: "Widget v3" }, "update")
        compare(_queuedIds(), ["p-a"])
        PhotoQueue.clear()
    }

    function test_C30_a_current_without_photoIds_is_a_first_photo_not_an_error() {
        PhotoQueue.clear()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget", photoIds: ["old-1"] }]
        InventoryStore._onMutationConflicted("inventory", "SKU-1", { productId: "SKU-1", name: "Widget" }, "update")
        compare(InventoryStore.products[0].photoIds, [], "missing photoIds normalises to an empty list")
        compare(InventoryStore.photoIdsFor("SKU-1"), [])
        InventoryStore.products = []
        InventoryStore._onMutationConflicted("inventory", "SKU-9", { productId: "SKU-9", name: "New" }, "update")
        compare(InventoryStore.photoIdsFor("SKU-9"), [], "a product pushed back from the server with no photoIds is photo-ready")
    }

    function test_C31_hasProduct_true_for_a_loaded_row_false_only_when_the_list_is_complete() {
        _completeList()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        compare(InventoryStore.hasProduct("SKU-1"), true)
        compare(InventoryStore.hasProduct("SKU-2"), false, "complete list, row absent")
        InventoryStore.products = []
        compare(InventoryStore.hasProduct("SKU-1"), false, "complete empty list")
    }

    function test_C33_a_row_missing_from_a_PARTIAL_list_is_unknown_never_false() {
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]   // page 1 of N: hasMore still true
        InventoryStore.hasMore = true
        compare(InventoryStore.hasProduct("SKU-1"), true, "a loaded row is always true")
        compare(InventoryStore.hasProduct("SKU-120"), undefined, "may live on a page that is not loaded yet")
        compare(InventoryStore.listComplete, false)
    }

    function test_C34_each_in_flight_flag_alone_makes_the_answer_unknown() {
        _completeList()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        compare(InventoryStore.hasProduct("SKU-2"), false)
        InventoryStore.loadingMore = true
        compare(InventoryStore.hasProduct("SKU-2"), undefined, "a page fetch is in flight")
        InventoryStore.loadingMore = false
        InventoryStore._resetPending = true
        compare(InventoryStore.hasProduct("SKU-2"), undefined, "a reset is queued: the list is about to be replaced")
        InventoryStore._resetPending = false
        InventoryStore.hasMore = true
        compare(InventoryStore.hasProduct("SKU-2"), undefined, "failed/unfinished paging leaves hasMore true")
        compare(InventoryStore.hasProduct("SKU-1"), true)
    }

    function test_C35_an_empty_or_non_string_id_is_unknown() {
        _completeList()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        compare(InventoryStore.hasProduct(""), undefined)
        compare(InventoryStore.hasProduct(undefined), undefined)
        compare(InventoryStore.hasProduct(null), undefined)
        compare(InventoryStore.hasProduct(42), undefined)
    }

    function test_C36_clear_makes_hasProduct_unknown_after_sign_out() {
        _completeList()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        InventoryStore.clear()
        compare(InventoryStore.products.length, 0)
        compare(InventoryStore.hasMore, true)
        compare(InventoryStore.hasProduct("SKU-1"), undefined, "nothing loaded after clear(): unknown, not absent")
    }

    function test_C32_a_throwing_photo_purge_never_blocks_the_conflict_reconcile() {
        PhotoQueue.clear()
        InventoryStore.products = [{ productId: "SKU-1", name: "Widget" }]
        PhotoQueue.items = null   // PhotoQueue.items.filter throws inside the purge (it is wrapped in try/catch)
        InventoryStore._onMutationConflicted("inventory", "SKU-1", null, "delete")
        compare(InventoryStore.products.length, 0, "the local row is still removed")
        PhotoQueue.items = []
        PhotoQueue.clear()
    }
}
