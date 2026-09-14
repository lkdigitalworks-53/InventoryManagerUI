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
// NOT RUN IN THIS SANDBOX — same Felgo-free import tier as the three
// InventoryStore test files that already passed on real CI this session.
TestCase {
    name: "InventoryStore_deleteProductCascade"

    property var _recordedMutations: []
    property var _realRecordMutation: null

    function init() {
        InventoryStore.products = []
        StockBatchStore.batches = []
        _recordedMutations = []
        // Spy on Gateway.recordMutation rather than letting it run for
        // real -- it ends in a network write (drainNow/_send), same
        // "no mock HTTP layer" limitation tst_Gateway.qml documents.
        // Recording calls here verifies the audit *routing* (right entity,
        // right action, right id) without touching the network at all.
        _realRecordMutation = Gateway.recordMutation
        Gateway.recordMutation = function(entity, entityId, action, before, after) {
            _recordedMutations.push({ entity: entity, entityId: entityId, action: action })
            return "spy-request-id"
        }
    }

    function cleanup() {
        Gateway.recordMutation = _realRecordMutation
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

    function test_deleteProduct_routes_each_batch_through_audit_as_a_delete() {
        InventoryStore.products = [_product("SKU-1")]
        StockBatchStore.batches = [
            _batch("B-1", "SKU-1", 10, 20),
            _batch("B-2", "SKU-1", 0, 20)
        ]

        InventoryStore.deleteProduct("SKU-1")

        // One mutation for the product itself, one per batch.
        compare(_recordedMutations.length, 3)
        compare(_recordedMutations[0].entity, "inventory")
        compare(_recordedMutations[0].action, "delete")
        var batchMutations = _recordedMutations.slice(1)
        compare(batchMutations.length, 2)
        for (var i = 0; i < batchMutations.length; ++i) {
            compare(batchMutations[i].entity, "stock_batch")
            compare(batchMutations[i].action, "delete")
        }
        var ids = [batchMutations[0].entityId, batchMutations[1].entityId].sort()
        compare(ids, ["B-1", "B-2"])
    }

    function test_deleteProduct_with_no_batches_at_all_does_not_throw() {
        InventoryStore.products = [_product("SKU-1")]
        StockBatchStore.batches = []

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0)
        compare(_recordedMutations.length, 1) // just the product itself
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
