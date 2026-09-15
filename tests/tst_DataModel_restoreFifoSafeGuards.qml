import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// Bug found during Taher's on-device review of the Tier C cascade-delete
// PR (2026-09-14): deleteProduct()'s batch cascade removes every batch for
// a deleted product, correctly. But StockBatchStore.restoreFifo/
// topUpOldest -- called from 11 places in DataModel.qml whenever a
// completed order gets reopened, reversed, or adjusted (a return/exchange
// with restock, for instance) -- fall through to synthesizing a brand-new
// "Adjustment (drift repair)" batch at unitCost 0 when no batch exists for
// the productId. That's correct for genuine drift on a product that still
// exists; it's wrong once the product is gone -- it resurrects exactly the
// orphaned-batch problem the cascade was built to prevent, except now with
// the wrong (zero) cost basis, for a product a user explicitly deleted.
//
// Fixed with two shared wrappers in DataModel.qml (_restoreFifoSafe,
// _topUpOldestSafe) that check InventoryStore.getById(productId) first and
// skip the call entirely -- rather than letting it fall through -- when the
// product no longer exists. All 11 call sites route through these instead
// of calling StockBatchStore directly.
//
// Only the skip path is tested here. The "product still exists, delegates
// through normally" path chains into StockBatchStore.addBatch -> 
// nextBatchId -> a network round-trip to mint an id -- fully async, same
// "not independently unit-testable without mock-HTTP infrastructure"
// territory as every other Gateway-adjacent path in this suite. The skip
// path is exactly the bug fix and returns synchronously, before touching
// StockBatchStore at all -- cleanly testable.
//
// NOT RUN IN THIS SANDBOX -- same Felgo-free import tier as the other
// DataModel/InventoryStore test files that already passed on real CI.
TestCase {
    name: "DataModel_restoreFifoSafeGuards"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }

    function init() {
        InventoryStore.products = []
        StockBatchStore.batches = []
    }

    function _product(id) {
        return { productId: id, name: "Widget " + id, category: "Widgets", sku: "",
                 unit: "pc", price: 100, sellingPrice: 100, stock: 5, minStock: 0 }
    }

    function test_restoreFifoSafe_skips_entirely_for_a_deleted_product() {
        // No product "SKU-DELETED" in InventoryStore.products -- exactly
        // the state left behind by deleteProduct()'s cascade.
        StockBatchStore.batches = []

        dm._restoreFifoSafe("B-GONE", "SKU-DELETED", 3)

        compare(StockBatchStore.batches.length, 0,
                "must not synthesize a phantom batch for a deleted product")
    }

    function test_restoreFifoSafe_still_invokes_the_callback_when_skipping() {
        var called = false
        dm._restoreFifoSafe("B-GONE", "SKU-DELETED", 3, function() { called = true })
        compare(called, true, "callers waiting on the callback must not hang")
    }

    function test_topUpOldestSafe_skips_entirely_for_a_deleted_product() {
        StockBatchStore.batches = []

        dm._topUpOldestSafe("SKU-DELETED", 5)

        compare(StockBatchStore.batches.length, 0,
                "must not synthesize a phantom batch for a deleted product")
    }

    function test_topUpOldestSafe_still_invokes_the_callback_when_skipping() {
        var called = false
        dm._topUpOldestSafe("SKU-DELETED", 5, function() { called = true })
        compare(called, true)
    }

    function test_restoreFifoSafe_with_empty_productId_does_not_throw() {
        // A handful of call sites pass through whatever productId a line
        // carries, which could legitimately be empty for old/malformed
        // data -- the guard must not choke on that, just fall through to
        // the real function's own existing handling.
        StockBatchStore.batches = []
        dm._restoreFifoSafe("B-1", "", 1)
        compare(StockBatchStore.batches.length, 0)
    }
}
