import QtQuick
import QtTest
import "../qml/model"

// Bug report (2026-09-02, second one this same debugging session): after
// deleting a product, the Inventory Value tab in Sales Analysis isn't
// affected at all -- not the total, not any of its by-dimension charts.
//
// Same upstream root cause as the Potential-profit bug fixed earlier this
// session (deleteProduct() doesn't clean up StockBatchStore -- see
// KNOWN-ISSUES.md), but a DIFFERENT symptom: Potential profit went NEGATIVE
// because it needs a live sellingPrice to compute revenue and collapsed to
// 0 while cogs stayed real. Inventory Value doesn't need a live product at
// all to compute qtyRemaining * unitCost -- none of totalValue(),
// valueByProduct(), valueBySupplier() even call getById(); valueByCategory()
// calls it only for the category label, still including the value either
// way. So a deleted product's remaining stock keeps counting in full,
// forever, with zero visible effect from the delete -- exactly what was
// reported.
//
// Fix mirrors the Potential-profit one: exclude a batch entirely once its
// product no longer resolves via getById, for all four functions. Makes
// Value tab consistent with the Current tab, which already excludes a
// deleted product's stock (it walks InventoryStore.products directly).
//
// NOT RUN IN THIS SANDBOX -- same Felgo-free import tier as
// tst_InventoryStore_mutationConflicted.qml and
// tst_InventoryStore_potentialProfitOrphanedBatch.qml, both of which passed
// on real CI this session.
TestCase {
    name: "InventoryStore_valueOrphanedBatch"

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

    function test_totalValue_excludes_a_batch_whose_product_was_deleted() {
        InventoryStore.products = [_liveProduct()]
        StockBatchStore.batches = [
            _batch("SKU-LIVE", 10, 20),      // 10 * 20 = 200
            _batch("SKU-DELETED", 15, 30)    // 15 * 30 = 450 -- must NOT count
        ]

        compare(InventoryStore.totalValue(), 200,
                "a deleted product's remaining stock must not count toward total inventory value")
    }

    function test_valueByProduct_has_no_entry_for_the_deleted_product() {
        InventoryStore.products = [_liveProduct()]
        StockBatchStore.batches = [
            _batch("SKU-LIVE", 10, 20),
            _batch("SKU-DELETED", 15, 30)
        ]

        var byProduct = InventoryStore.valueByProduct()
        verify(!byProduct["SKU-DELETED"])
        compare(byProduct["SKU-LIVE"], 200)
    }

    function test_valueBySupplier_excludes_the_deleted_products_batch() {
        InventoryStore.products = [_liveProduct()]
        StockBatchStore.batches = [
            _batch("SKU-LIVE", 10, 20, "SUP-A"),
            _batch("SKU-DELETED", 15, 30, "SUP-A")   // same supplier -- must not inflate SUP-A's total
        ]

        var bySupplier = InventoryStore.valueBySupplier()
        compare(bySupplier["SUP-A"], 200)
    }

    function test_valueByCategory_excludes_the_deleted_products_batch_not_just_relabels_it() {
        InventoryStore.products = [_liveProduct()]
        StockBatchStore.batches = [
            _batch("SKU-LIVE", 10, 20),
            _batch("SKU-DELETED", 15, 30)
        ]

        var byCategory = InventoryStore.valueByCategory()
        compare(byCategory["Widgets"], 200)
        verify(!byCategory["(uncategorised)"] || byCategory["(uncategorised)"] === 0,
               "the deleted product's value must be excluded, not just reclassified as uncategorised")
    }

    function test_deleting_the_only_product_drops_total_value_to_zero() {
        InventoryStore.products = []
        StockBatchStore.batches = [_batch("SKU-DELETED", 15, 30)]

        compare(InventoryStore.totalValue(), 0)
        compare(Object.keys(InventoryStore.valueByProduct()).length, 0)
    }
}
