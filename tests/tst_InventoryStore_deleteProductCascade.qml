import QtQuick
import QtTest
import "../qml/model"

// Coverage for the Tier C design
// (docs/superpowers/specs/2026-09-02-cleanup-batches-photo-on-product-delete.md):
// deleteProduct() now cascades to remove every batch for the deleted product
// (all of them, not just open ones), routes each through the same
// Gateway.recordMutation("stock_batch", ..., "delete", ...) audit pattern
// StockBatchStore already uses, and calls StorageService.deleteProductPhoto
// -- guarded in a try/catch since that call falls through to a native
// ImageProcessor singleton this test environment doesn't have registered
// (same failure class as the DataModel logic/dispatcher bug, Skill 58).
//
// Also covers _activeBatches(), the shared filter introduced in the same
// change to replace four duplicated inline guards (one per bug fix) with
// one place to get it right — see tst_InventoryStore_valueOrphanedBatch.qml
// and tst_InventoryStore_potentialProfitOrphanedBatch.qml, both of which
// exercise the *external* behavior of the functions refactored to use it
// and should still pass unmodified, proving the refactor didn't change
// what those functions return.
//
// CORRECTED 2026-09-14 after a real CI failure: this file originally tried
// to spy on Gateway.recordMutation by reassigning it
// (`Gateway.recordMutation = function(...) {}`) to verify audit routing.
// That throws "Cannot assign to read-only property" -- a QML `function`
// member isn't a reassignable JS property like a plain object's. Removed
// the spy and the one test that needed it; the real (non-mocked)
// deleteProduct() -> Gateway.recordMutation path is exercised directly
// instead, which is safe -- tst_DataModel_deleteGuards.qml already does
// the same for the pre-cascade version of this function and passes on CI.
TestCase {
    name: "InventoryStore_deleteProductCascade"

    function init() {
        InventoryStore.products = []
        StockBatchStore.batches = []
    }

    function _product(id) {
        return { productId: id, name: "Widget " + id, category: "Widgets", sku: "",
                 unit: "pc", price: 100, sellingPrice: 100, stock: 5, minStock: 0 }
    }

    function _batch(id, productId, qtyRemaining, unitCost) {
        return { batchId: id, productId: productId, supplierId: "", qtyReceived: qtyRemaining,
                 qtyRemaining: qtyRemaining, unitCost: unitCost, receivedDate: "2026-08-01" }
    }

    function test_deleteProduct_removes_every_batch_for_that_product_open_and_exhausted() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        StockBatchStore.batches = [
            _batch("B-1", "SKU-1", 10, 20),   // open
            _batch("B-2", "SKU-1", 0, 20),    // already exhausted -- must still be removed
            _batch("B-3", "SKU-2", 5, 10)     // different product -- must survive
        ]

        InventoryStore.deleteProduct("SKU-1")

        var remaining = StockBatchStore.batches
        compare(remaining.length, 1)
        compare(remaining[0].batchId, "B-3")
    }

    // Audit routing itself (does Gateway.recordMutation actually get called
    // with entity="stock_batch") is deliberately NOT verified by a spy here.
    // QML `function` members are read-only at the JS binding layer --
    // `Gateway.recordMutation = function(...) {}` throws "Cannot assign to
    // read-only property" (found via a real CI failure, not assumed).
    // Calling the real function is safe -- tst_DataModel_deleteGuards.qml
    // already exercises the real deleteProduct() -> Gateway.recordMutation
    // path and passes on CI -- but verifying *what it was called with*
    // without a working spy technique would need inspecting OutboxStore's
    // internal queue, unproven territory. Same call this codebase already
    // makes for Gateway's actual network dispatch (see tst_Gateway.qml):
    // not independently unit-tested. The batch-removal tests below cover
    // the part that matters observably -- that every batch for the
    // deleted product is actually gone from local state.

    function test_deleteProduct_with_no_batches_at_all_does_not_throw() {
        InventoryStore.products = [_product("SKU-1")]
        StockBatchStore.batches = []

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0)
    }

    function test_deleteProduct_completes_despite_photo_cleanup_throwing() {
        // ImageProcessor isn't registered in this test environment (it's a
        // context property main.cpp only sets up for the real app) --
        // StorageService.deleteProductPhoto will throw a ReferenceError
        // reaching it. The try/catch in deleteProduct() must swallow that
        // and let the product + batch cascade above it stand.
        InventoryStore.products = [_product("SKU-1")]
        StockBatchStore.batches = [_batch("B-1", "SKU-1", 10, 20)]

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0, "product delete must complete")
        compare(StockBatchStore.batches.length, 0, "batch cascade must complete")
    }

    function test_deleteProduct_still_removes_the_product_itself_unchanged_regression() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        StockBatchStore.batches = []

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].productId, "SKU-2")
    }

    function test_activeBatches_excludes_a_batch_whose_product_was_deleted() {
        InventoryStore.products = [_product("SKU-LIVE")]
        StockBatchStore.batches = [
            _batch("B-1", "SKU-LIVE", 10, 20),
            _batch("B-2", "SKU-ORPHAN", 5, 10)
        ]

        var active = InventoryStore._activeBatches()

        compare(active.length, 1)
        compare(active[0].batchId, "B-1")
    }

    function test_activeBatches_returns_empty_array_when_no_batches_exist() {
        InventoryStore.products = [_product("SKU-LIVE")]
        StockBatchStore.batches = []

        compare(InventoryStore._activeBatches().length, 0)
    }
}
