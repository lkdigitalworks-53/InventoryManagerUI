import QtQuick
import QtTest
import "../qml/model"

// Bug report (2026-09-02): after deleting a product, the "Potential profit on
// open stock" total in Sales Analysis goes wrong instead of staying correct
// or simply excluding that product.
//
// Root cause, traced per systematic-debugging: InventoryStore.deleteProduct()
// does not clean up that product's StockBatchStore entries (already a known,
// documented gap — see docs/superpowers/KNOWN-ISSUES.md). The orphaned batch
// then gets walked by potentialProfitByDimension(), which prices it at
// `getById(productId).sellingPrice` — since the product is gone, `sell`
// collapses to 0, but `cogs` (unitCost × qtyRemaining) does not. The batch
// contributes `0 - cogs`, a phantom LOSS, to the aggregate total instead of
// being excluded — dragging potential profit down by the full COGS of stock
// that, from the user's perspective, no longer exists at all.
//
// SalesPage.qml's on-screen "Potential" tab duplicates this exact walk
// inline (not by calling this function) and has the identical bug — fixed
// there too, verified by code symmetry with this test rather than an
// independent test (that page needs Felgo, see test/felgo-dependent/README.md
// for why a page-level test can't run under this CI job).
//
// NOT RUN IN THIS SANDBOX — but this file imports only qml/model, the same
// tier as tst_InventoryStore_mutationConflicted.qml, which did pass on a
// real CI run this session (2026-09-01). No Felgo dependency here.
TestCase {
    name: "InventoryStore_potentialProfitOrphanedBatch"

    function init() {
        InventoryStore.products = []
        StockBatchStore.batches = []
    }

    function _liveProduct() {
        return { productId: "SKU-LIVE", name: "Live Widget", category: "Widgets",
                 sku: "", unit: "pc", price: 100, sellingPrice: 100, stock: 5, minStock: 0 }
    }

    function _batch(productId, qtyRemaining, unitCost, supplierId) {
        return { batchId: "B-" + productId, productId: productId, supplierId: supplierId || "",
                 qtyReceived: qtyRemaining, qtyRemaining: qtyRemaining, unitCost: unitCost,
                 receivedDate: "2026-08-01" }
    }

    function test_orphaned_batch_from_deleted_product_is_excluded_not_negative() {
        // SKU-DELETED has an open batch but no matching product record --
        // exactly the state left behind by deleteProduct() today.
        InventoryStore.products = [_liveProduct()]
        StockBatchStore.batches = [
            _batch("SKU-LIVE", 10, 50),      // live: 10 * (100 - 50) = 500 potential profit
            _batch("SKU-DELETED", 20, 30)    // orphaned: must NOT contribute -600
        ]

        var byProduct = InventoryStore.potentialProfitByDimension("productId", null)

        verify(!byProduct["SKU-DELETED"],
               "an orphaned batch must be excluded entirely, not counted as a loss")
        compare(byProduct["SKU-LIVE"].profit, 500)
    }

    function test_aggregate_total_is_unaffected_by_an_orphaned_batch() {
        InventoryStore.products = [_liveProduct()]
        StockBatchStore.batches = [
            _batch("SKU-LIVE", 10, 50),
            _batch("SKU-DELETED", 20, 30)
        ]

        var byProduct = InventoryStore.potentialProfitByDimension("productId", null)
        var total = 0
        var keys = Object.keys(byProduct)
        for (var i = 0; i < keys.length; ++i) total += byProduct[keys[i]].profit

        compare(total, 500, "the deleted product's orphaned batch must not pull the total negative")
    }

    function test_category_dimension_does_not_get_a_phantom_uncategorised_loss() {
        InventoryStore.products = [_liveProduct()]
        StockBatchStore.batches = [
            _batch("SKU-LIVE", 10, 50),
            _batch("SKU-DELETED", 20, 30)
        ]

        var byCategory = InventoryStore.potentialProfitByDimension("category", null)

        compare(byCategory["Widgets"].profit, 500)
        verify(!byCategory["(uncategorised)"] || byCategory["(uncategorised)"].profit === 0,
               "the orphaned batch must not show up as an uncategorised loss either")
    }

    function test_no_live_products_at_all_still_returns_empty_not_negative() {
        // Edge case: every product in the shop has been deleted but batches
        // linger -- must not throw, must not produce a bogus negative total.
        InventoryStore.products = []
        StockBatchStore.batches = [_batch("SKU-DELETED", 5, 10)]

        var byProduct = InventoryStore.potentialProfitByDimension("productId", null)
        compare(Object.keys(byProduct).length, 0)
    }
}
