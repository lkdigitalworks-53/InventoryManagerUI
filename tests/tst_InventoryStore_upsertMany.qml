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
//
// Also covers the 2026-08-27 async batch-id-minting change's addition to
// upsertMany (docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-design.md):
// specifically _scanUpsertManyNeeds, the pure pre-scan that decides how many
// product ids AND how many stock-batch ids to reserve before the
// synchronous import loop runs. This is the correctness-critical new piece
// -- an undercount here means the loop runs out of pre-reserved batch ids
// mid-import -- and it's deliberately pure (no FirebaseService calls, no
// reliance on the InventoryStore/SupplierStore singletons' own state) so
// it's fully testable without a live emulator, unlike upsertMany() itself
// (see test_upsertMany_with_records_dispatches_without_throwing below,
// matching tst_OrdersStore_mutations.qml's identical convention for its
// own upsertMany).
//
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available.
// Written to convention and manually reviewed; needs a local
// `qmltestrunner` pass before merge (same status as tst_FirebaseService.qml,
// tst_Gateway.qml).
TestCase {
    name: "InventoryStore_upsertMany"

    function init() { InventoryStore.products = [] }
    function cleanup() { InventoryStore.products = [] }

    function _neverExists(name) { return false }

    function _stubPullProductId(id) {
        return function() { return id }
    }

    function _stubResolveSupplier() {
        return function(r) { return r.supplierId || "" }
    }

    // _upsertManySync's signature grew a pullBatchId param (see the design
    // doc above) -- every call below needs one now. Most of these tests
    // don't care about the actual batch id (they assert on SKU/product
    // state, not on StockBatchStore), so a single fixed id is enough; it
    // only has to not throw and return a string.
    function _stubPullBatchId() {
        return function() { return "BAT-" + new Date().getFullYear() + "-900" }
    }

    // ============================================================
    // SKU / _upsertManySync coverage (pr_taher_bug_fixes)
    // ============================================================

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

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-999"), _stubResolveSupplier(), _stubPullBatchId(), counts)

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

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-999"), _stubResolveSupplier(), _stubPullBatchId(), counts)

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

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-999"), _stubResolveSupplier(), _stubPullBatchId(), counts)

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

        InventoryStore._upsertManySync(records, pullProductId, _stubResolveSupplier(), _stubPullBatchId(), counts)

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

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-061"), _stubResolveSupplier(), _stubPullBatchId(), counts)

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

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-063"), _stubResolveSupplier(), _stubPullBatchId(), counts)

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

        InventoryStore._upsertManySync(records, _stubPullProductId("PRD-999"), _stubResolveSupplier(), _stubPullBatchId(), counts)

        compare(counts.skipped, 1)
        compare(counts.added, 0)
        compare(counts.updatedProducts.length, 0)
        compare(InventoryStore.products.length, 1, "skip must not add a second product")
        compare(InventoryStore.products[0].name, "Existing", "skip must leave the existing product's fields untouched")
        compare(InventoryStore.products[0].sku, "AB-2026-070")
    }

    // ============================================================
    // _scanUpsertManyNeeds / batch-id reservation coverage
    // (feature/async-stock-batch-id-minting)
    // ============================================================

    // ── _scanUpsertManyNeeds: neededProductIds (existing behavior, kept) ──

    function test_scan_counts_a_brand_new_row_as_needing_a_product_id() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "", name: "New Widget", stock: 0 }], {}, _neverExists)
        compare(result.neededProductIds, 1)
    }

    function test_scan_does_not_count_a_skip_row_matching_an_existing_product() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "PRD-001", stock: 0, _conflictPolicy: "skip" }],
            { "PRD-001": true }, _neverExists)
        compare(result.neededProductIds, 0)
    }

    function test_scan_does_not_count_an_overwrite_row_matching_an_existing_product() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "PRD-001", stock: 0, _conflictPolicy: "overwrite" }],
            { "PRD-001": true }, _neverExists)
        compare(result.neededProductIds, 0)
    }

    function test_scan_counts_a_rename_row_matching_an_existing_product() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "PRD-001", stock: 0, _conflictPolicy: "rename" }],
            { "PRD-001": true }, _neverExists)
        compare(result.neededProductIds, 1)
    }

    // ── _scanUpsertManyNeeds: neededBatchIds (new) ────────────────────────

    function test_scan_counts_a_batch_id_for_a_new_row_with_positive_stock() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "", stock: 5 }], {}, _neverExists)
        compare(result.neededBatchIds, 1)
    }

    function test_scan_does_not_count_a_batch_id_for_a_new_row_with_zero_stock() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "", stock: 0 }], {}, _neverExists)
        compare(result.neededBatchIds, 0)
    }

    function test_scan_does_not_count_a_batch_id_for_a_new_row_with_no_stock_field() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "" }], {}, _neverExists)
        compare(result.neededBatchIds, 0)
    }

    function test_scan_counts_a_batch_id_for_a_rename_row_with_positive_stock() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "PRD-001", stock: 5, _conflictPolicy: "rename" }],
            { "PRD-001": true }, _neverExists)
        compare(result.neededBatchIds, 1)
    }

    function test_scan_does_not_count_a_batch_id_for_a_skip_row_even_with_positive_stock() {
        // A "skip" row never reaches _bookImportedProduct -- no product
        // doc gets created for it, so no companion batch either.
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "PRD-001", stock: 5, _conflictPolicy: "skip" }],
            { "PRD-001": true }, _neverExists)
        compare(result.neededBatchIds, 0)
    }

    function test_scan_does_not_count_a_batch_id_for_an_overwrite_row_even_with_positive_stock() {
        // An "overwrite" row updates the existing product doc -- also
        // never reaches _bookImportedProduct.
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "PRD-001", stock: 5, _conflictPolicy: "overwrite" }],
            { "PRD-001": true }, _neverExists)
        compare(result.neededBatchIds, 0)
    }

    function test_scan_ignores_a_non_numeric_stock_value_as_zero() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "", stock: "not-a-number" }], {}, _neverExists)
        compare(result.neededBatchIds, 0)
    }

    function test_scan_sums_batch_ids_across_multiple_qualifying_rows() {
        var result = InventoryStore._scanUpsertManyNeeds([
            { productId: "", stock: 5 },
            { productId: "", stock: 0 },
            { productId: "PRD-001", stock: 3, _conflictPolicy: "rename" },
            { productId: "PRD-002", stock: 9, _conflictPolicy: "skip" }
        ], { "PRD-001": true, "PRD-002": true }, _neverExists)
        // Three rows create a new product doc: the two blank-productId rows
        // (row 2's zero stock still needs a product id -- only the BATCH id
        // is stock-gated) plus the "rename" row. The "skip" row doesn't.
        compare(result.neededProductIds, 3)
        compare(result.neededBatchIds, 2) // rows 1 and 3 -- the two of those three with stock > 0
    }

    // ── _scanUpsertManyNeeds: newSupplierNames (existing behavior, kept) ──

    function test_scan_collects_a_new_supplier_name_once() {
        var result = InventoryStore._scanUpsertManyNeeds([
            { productId: "", stock: 0, supplier: "Acme Co" },
            { productId: "", stock: 0, supplier: "Acme Co" }
        ], {}, _neverExists)
        compare(result.newSupplierNames.length, 1)
        compare(result.newSupplierNames[0], "Acme Co")
    }

    function test_scan_skips_a_supplier_name_that_already_exists() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "", stock: 0, supplier: "Acme Co" }], {},
            function(name) { return name === "Acme Co" })
        compare(result.newSupplierNames.length, 0)
    }

    function test_scan_skips_a_row_that_already_carries_a_supplierId() {
        var result = InventoryStore._scanUpsertManyNeeds(
            [{ productId: "", stock: 0, supplierId: "SUP-001", supplier: "Acme Co" }],
            {}, _neverExists)
        compare(result.newSupplierNames.length, 0)
    }

    // ── upsertMany itself (smoke tests -- see file header) ───────────────

    function test_upsertMany_empty_records_array_returns_zeroed_counts_synchronously() {
        var received = null
        InventoryStore.upsertMany([], function(counts) { received = counts })
        verify(received !== null, "callback must fire synchronously for an empty array")
        compare(received.added, 0)
    }

    function test_upsertMany_null_records_returns_zeroed_counts_synchronously() {
        var received = null
        InventoryStore.upsertMany(null, function(counts) { received = counts })
        verify(received !== null, "callback must fire synchronously for null records")
        compare(received.added, 0)
    }

    function test_upsertMany_with_records_dispatches_without_throwing() {
        // Non-empty input reaches FirebaseService.mintCounterBatch (three
        // chained calls now: products, suppliers, stock batches) -- real
        // outcome needs the emulator (E2E slice), this only confirms the
        // synchronous portion before those calls doesn't throw.
        InventoryStore.upsertMany(
            [{ productId: "", name: "New Product", stock: 5, _conflictPolicy: "skip" }],
            function(counts) {}
        )
        verify(true)
    }
}
