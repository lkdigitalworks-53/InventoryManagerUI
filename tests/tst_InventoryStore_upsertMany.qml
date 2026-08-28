import QtQuick
import QtTest
import "../qml/model"
import "../qml/helper/ImportMath.js" as ImportMath

// Coverage for pr_taher_bug_fixes's changes to InventoryStore's bulk-import
// SKU handling (generateSku() and _upsertManySync()) — previously zero
// tests touched this path at all (checked: no existing tests/*.qml file
// referenced upsertMany, _upsertManySync, or generateSku), which is how
// both the original bug this PR fixes and a new one it introduces made it
// this far untested.
TestCase {
    name: "InventoryStore_upsertMany"

    function init() { InventoryStore.products = [] }
    function cleanup() { InventoryStore.products = [] }

    // --- generateSku() direct coverage -------------------------------

    function test_generateSku_uses_the_explicit_numOfProducts_suffix() {
        var sku = InventoryStore.generateSku("Blue Widget", 7)
        var year = new Date().getFullYear()
        compare(sku, "BW-" + year + "-007")
    }

    function test_generateSku_with_different_explicit_numbers_never_collide() {
        // This is the actual mechanism of the bug this PR fixes: before,
        // the fallback read the *outer* `products` property, which stays
        // frozen at its pre-import count for an entire bulk-import loop
        // (products is only reassigned once, after the loop) — so every
        // row lacking a SKU in one batch got the exact same suffix. Two
        // explicit numbers (as _upsertManySync now always passes, derived
        // from each row's own unique productId) must never collide.
        var skuA = InventoryStore.generateSku("Same Name", 10)
        var skuB = InventoryStore.generateSku("Same Name", 11)
        verify(skuA !== skuB, "distinct numOfProducts must produce distinct SKUs: " + skuA + " vs " + skuB)
    }

    // --- _upsertManySync(): overwrite must not clobber an existing SKU ---
    //
    // Bug found in review (2026-08-21): the "overwrite" branch (existing
    // product, matched by productId) generated a brand-new SKU whenever
    // the imported row's sku column was blank — even though the product
    // being overwritten almost certainly already has a real SKU; a blank
    // sku column on an overwrite row just means the CSV round-trip didn't
    // carry that column, not that the SKU should be replaced. The
    // rename/new-row branches are correct to generate fresh SKUs (those
    // really are new products with nothing to preserve) — only overwrite
    // was wrong.

    function _stubPullProductId(id) {
        return function() { return id }
    }

    function _stubResolveSupplier() {
        return function(r) { return r.supplierId || "" }
    }

    function test_overwrite_with_blank_sku_preserves_the_existing_sku() {
        InventoryStore.products = [{
            productId: "PRD-050", name: "Old Name", sku: "AB-2026-050",
            category: "General", stock: 5, minStock: 1, price: 100,
            sellingPrice: 120, taxable: false, taxPercent: 0, size: "",
            unit: "pc", description: "", supplierId: "SUP-001"
        }]

        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [{
            productId: "PRD-050", _conflictPolicy: "overwrite",
            name: "Updated Name", sku: "", category: "General",
            stock: 8, minStock: 1, price: 100, sellingPrice: 120,
            taxable: false, taxPercent: 0, size: "", supplierId: "SUP-001"
        }]

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-999"), _stubResolveSupplier(), counts)

        compare(counts.updated, 1)
        compare(counts.updatedProducts.length, 1)
        compare(counts.updatedProducts[0].fields.sku, "AB-2026-050",
                "a blank sku on an overwrite row must not replace the product's real, existing SKU")
    }

    function test_overwrite_with_blank_sku_falls_back_to_generated_when_existing_also_has_none() {
        // Legacy-data edge case: the stored product itself has no SKU
        // either. Nothing to preserve, so generating one is correct here.
        InventoryStore.products = [{
            productId: "PRD-051", name: "Old Name", sku: "",
            category: "General", stock: 5, minStock: 1, price: 100,
            sellingPrice: 120, taxable: false, taxPercent: 0, size: "",
            unit: "pc", description: "", supplierId: "SUP-001"
        }]

        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [{
            productId: "PRD-051", _conflictPolicy: "overwrite",
            name: "Updated Name", sku: "", category: "General",
            stock: 8, minStock: 1, price: 100, sellingPrice: 120,
            taxable: false, taxPercent: 0, size: "", supplierId: "SUP-001"
        }]

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-999"), _stubResolveSupplier(), counts)

        verify(counts.updatedProducts[0].fields.sku.length > 0,
               "should still synthesize a SKU when the existing product has none at all")
    }

    function test_overwrite_with_a_provided_sku_keeps_the_provided_value() {
        InventoryStore.products = [{
            productId: "PRD-052", name: "Old Name", sku: "AB-2026-052",
            category: "General", stock: 5, minStock: 1, price: 100,
            sellingPrice: 120, taxable: false, taxPercent: 0, size: "",
            unit: "pc", description: "", supplierId: "SUP-001"
        }]

        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [{
            productId: "PRD-052", _conflictPolicy: "overwrite",
            name: "Updated Name", sku: "CUSTOM-SKU-1", category: "General",
            stock: 8, minStock: 1, price: 100, sellingPrice: 120,
            taxable: false, taxPercent: 0, size: "", supplierId: "SUP-001"
        }]

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-999"), _stubResolveSupplier(), counts)

        compare(counts.updatedProducts[0].fields.sku, "CUSTOM-SKU-1")
    }

    // --- _upsertManySync(): new rows in the same batch get distinct SKUs ---

    function test_new_rows_in_one_batch_get_distinct_skus() {
        var ids = ["PRD-101", "PRD-102"]
        var callIdx = 0
        function pullProductId() { return ids[callIdx++] }

        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [
            { name: "Red Widget", sku: "", category: "General", stock: 1, minStock: 1,
              price: 10, sellingPrice: 12, taxable: false, taxPercent: 0, size: "", supplierId: "" },
            { name: "Red Widget", sku: "", category: "General", stock: 1, minStock: 1,
              price: 10, sellingPrice: 12, taxable: false, taxPercent: 0, size: "", supplierId: "" }
        ]

        InventoryStore._upsertManySync(records, pullProductId, _stubResolveSupplier(), counts)

        compare(counts.added, 2)
        compare(InventoryStore.products.length, 2)
        verify(InventoryStore.products[0].sku !== InventoryStore.products[1].sku,
               "two same-named products created in the same import batch must not collide on SKU: " +
               InventoryStore.products[0].sku + " vs " + InventoryStore.products[1].sku)
    }

    // --- _upsertManySync(): the two remaining conflict-policy branches ---
    // (found missing while writing this file's test plan -- rename/skip
    // weren't covered even though "rename" is exactly what fb180d8 touched)

    function test_rename_policy_with_blank_sku_generates_a_fresh_unique_sku() {
        InventoryStore.products = [{
            productId: "PRD-060", name: "Existing", sku: "AB-2026-060",
            category: "General", stock: 5, minStock: 1, price: 100,
            sellingPrice: 120, taxable: false, taxPercent: 0, size: "",
            unit: "pc", description: "", supplierId: "SUP-001"
        }]

        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [{
            productId: "PRD-060", _conflictPolicy: "rename",
            name: "Imported Duplicate", sku: "", category: "General",
            stock: 3, minStock: 1, price: 90, sellingPrice: 110,
            taxable: false, taxPercent: 0, size: "", supplierId: ""
        }]

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-061"), _stubResolveSupplier(), counts)

        compare(counts.added, 1, "rename treats the row as a brand-new product, not an update")
        compare(InventoryStore.products.length, 2, "the original product must be untouched, not replaced")
        compare(InventoryStore.products[0].sku, "AB-2026-060", "the original product's SKU must survive a rename import")
        verify(InventoryStore.products[1].sku.length > 0, "the renamed row needs a real generated SKU")
        verify(InventoryStore.products[1].sku !== InventoryStore.products[0].sku)
    }

    function test_rename_policy_with_provided_sku_gets_a_renamed_suffix_not_a_fresh_one() {
        InventoryStore.products = [{
            productId: "PRD-062", name: "Existing", sku: "AB-2026-062",
            category: "General", stock: 5, minStock: 1, price: 100,
            sellingPrice: 120, taxable: false, taxPercent: 0, size: "",
            unit: "pc", description: "", supplierId: "SUP-001"
        }]

        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [{
            productId: "PRD-062", _conflictPolicy: "rename",
            name: "Imported Duplicate", sku: "AB-2026-062", category: "General",
            stock: 3, minStock: 1, price: 90, sellingPrice: 110,
            taxable: false, taxPercent: 0, size: "", supplierId: ""
        }]

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-063"), _stubResolveSupplier(), counts)

        // ImportMath.renameSku, not generateSku, must handle a row that
        // already has a sku -- generateSku is only for the blank-sku case.
        compare(InventoryStore.products[1].sku, ImportMath.renameSku("AB-2026-062", 0))
    }

    function test_skip_policy_leaves_the_existing_product_untouched() {
        InventoryStore.products = [{
            productId: "PRD-070", name: "Existing", sku: "AB-2026-070",
            category: "General", stock: 5, minStock: 1, price: 100,
            sellingPrice: 120, taxable: false, taxPercent: 0, size: "",
            unit: "pc", description: "", supplierId: "SUP-001"
        }]

        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [{
            productId: "PRD-070", _conflictPolicy: "skip",
            name: "Should Not Apply", sku: "SHOULD-NOT-APPLY", category: "General",
            stock: 999, minStock: 1, price: 1, sellingPrice: 1,
            taxable: false, taxPercent: 0, size: "", supplierId: ""
        }]

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-999"), _stubResolveSupplier(), counts)

        compare(counts.skipped, 1)
        compare(counts.added, 0)
        compare(counts.updatedProducts.length, 0)
        compare(InventoryStore.products.length, 1, "skip must not add a second product")
        compare(InventoryStore.products[0].name, "Existing", "skip must leave the existing product's fields untouched")
        compare(InventoryStore.products[0].sku, "AB-2026-070")
    }
}
