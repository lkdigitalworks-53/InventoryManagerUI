import QtQuick
import QtTest
import "../qml/model"

// Coverage for the write-side half of DELETE-FEATURE-ROADMAP item 3: category
// is now stamped on every TransactionStore entry that feeds the Sales
// Analysis Purchased/Sold/Revenue/Realised-Profit tabs, at time of the
// transaction, so a later product deletion can't erase it. See
// docs/superpowers/specs/2026-09-26-sales-analysis-deleted-product-labels-design.md
// for the full design and BreakdownMath.js/RealisedMath.js for the read-side
// half (covered in tst_BreakdownMath.qml / tst_RealisedMath.qml).
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Written
// to convention (mirrors tst_TransactionStore_priceAdjustTax.qml's
// direct-singleton-call pattern); needs a local qmltestrunner pass before
// merge, same status as every other client-side test in this repo.
TestCase {
    name: "TransactionStore_categoryStamp"

    function init() {
        TransactionStore.entries = []
        TransactionStore.revision = 0
        InventoryStore.products = []
        Gateway.mode = "gateway"    // enqueue into OutboxStore instead of a real write
        OutboxStore.clear()
        AuthStore.idToken = ""              // keeps Gateway._send's guard closed — no real network
        AuthStore._settings.sessionJson = "" // see tst_Gateway.qml header / CHECKPOINT.md 2026-08-18
    }

    // ── recordPurchase ───────────────────────────────────────────────────
    function test_recordPurchase_stamps_explicit_category() {
        TransactionStore.recordPurchase("P1", 5, 10, "Widget", "S1", "restock", "Hardware")
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.entries[0].category, "Hardware")
    }

    function test_recordPurchase_falls_back_to_live_product_category_when_omitted() {
        InventoryStore.products = [{ productId: "P1", name: "Widget", category: "Hardware" }]
        TransactionStore.recordPurchase("P1", 5, 10, "Widget", "S1", "restock")
        compare(TransactionStore.entries[0].category, "Hardware", "no category param -> falls back to the live product")
    }

    function test_recordPurchase_empty_category_when_product_gone_and_none_passed() {
        // InventoryStore.products left empty by init() — nothing to fall back to.
        TransactionStore.recordPurchase("P9", 5, 10, "Ghost Widget", "S1", "restock")
        compare(TransactionStore.entries[0].category, "", "neither an explicit category nor a live product to resolve from")
    }

    function test_recordPurchase_null_category_param_treated_as_omitted() {
        // Monkey case: a falsy-but-not-undefined category must not short-circuit
        // past the live-product fallback (category || fallback, same as productName).
        InventoryStore.products = [{ productId: "P1", name: "Widget", category: "Hardware" }]
        TransactionStore.recordPurchase("P1", 5, 10, "Widget", "S1", "restock", null)
        compare(TransactionStore.entries[0].category, "Hardware")
    }

    // ── recordCreated ────────────────────────────────────────────────────
    function test_recordCreated_stamps_category_from_snapshot() {
        TransactionStore.recordCreated("P2", "New Gadget", 3, 20, { category: "Electronics", sku: "G1" })
        compare(TransactionStore.entries[0].category, "Electronics")
    }

    function test_recordCreated_empty_category_when_snapshot_omits_it() {
        TransactionStore.recordCreated("P2", "New Gadget", 3, 20, { sku: "G1" })
        compare(TransactionStore.entries[0].category, "")
    }

    function test_recordCreated_empty_category_when_snapshot_omitted_entirely() {
        TransactionStore.recordCreated("P2", "New Gadget", 3, 20)
        compare(TransactionStore.entries[0].category, "")
    }

    // ── recordSaleFromOrder ──────────────────────────────────────────────
    function _saleOrder() {
        return { orderId: "ORD-1", orderChannel: "online", staffId: "ST1", date: "2026-09-26",
                 products: [{ productId: "P1", name: "Widget", price: 60, quantity: 2,
                              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 }] }] }
    }

    function test_recordSaleFromOrder_stamps_category_from_live_product() {
        InventoryStore.products = [{ productId: "P1", name: "Widget", category: "Hardware" }]
        TransactionStore.recordSaleFromOrder(_saleOrder())
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.entries[0].category, "Hardware")
    }

    function test_recordSaleFromOrder_empty_category_when_product_already_deleted() {
        // Defensive/edge: a sale recorded for a product that's already gone by
        // sale time (shouldn't normally happen — you can't sell a deleted
        // product — but must not crash either way).
        TransactionStore.recordSaleFromOrder(_saleOrder())
        compare(TransactionStore.entries[0].category, "")
    }

    // ── recordReturn (the non-trivial write path: the product referenced by
    //    a return may already be deleted by return time) ──────────────────
    function test_recordReturn_stamps_category_from_original_sale_when_product_deleted() {
        // The original sale, stamped with the product's category BEFORE it
        // was later deleted (no live product in InventoryStore.products now).
        TransactionStore.entries = [{
            kind: "sale", orderId: "ORD-1", productId: "P1", category: "Hardware",
            quantity: 2, net: 120, tax: 0, discountShare: 0, total: 120,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 }]
        }]
        TransactionStore.recordReturn(
            { orderId: "ORD-1", orderChannel: "online", staffId: "ST1" },
            { productId: "P1", name: "Widget", price: 60 },
            1, [{ batchId: "B1", supplierId: "S1", qtyConsumed: -1, unitCost: 40 }],
            "damaged", "opened", "")
        var ret = TransactionStore.entries[TransactionStore.entries.length - 1]
        compare(ret.kind, "return")
        compare(ret.category, "Hardware", "reuses the ORIGINAL sale's stamped category, not a live re-lookup")
    }

    function test_recordReturn_falls_back_to_live_product_when_no_matching_sale_in_history() {
        // No prior sale event for this order+product in the ledger (edge
        // case / pre-fix data) — falls back to a live lookup.
        InventoryStore.products = [{ productId: "P1", name: "Widget", category: "Hardware" }]
        TransactionStore.recordReturn(
            { orderId: "ORD-1", orderChannel: "online", staffId: "ST1" },
            { productId: "P1", name: "Widget", price: 60 },
            1, [], "damaged", "opened", "")
        compare(TransactionStore.entries[0].category, "Hardware")
    }

    function test_recordReturn_empty_category_when_neither_sale_history_nor_live_product_resolve() {
        TransactionStore.recordReturn(
            { orderId: "ORD-1", orderChannel: "online", staffId: "ST1" },
            { productId: "P9", name: "Ghost Widget", price: 60 },
            1, [], "damaged", "opened", "")
        compare(TransactionStore.entries[0].category, "")
    }

    // ── recordPriceAdjust (same _stampedCategoryFor helper) ─────────────
    function test_recordPriceAdjust_stamps_category_from_original_sale_when_product_deleted() {
        TransactionStore.entries = [{
            kind: "sale", orderId: "ORD-1", productId: "P1", category: "Hardware",
            quantity: 1, net: 60, tax: 0, discountShare: 0, total: 60,
            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 40 }]
        }]
        TransactionStore.recordPriceAdjust(
            { orderId: "ORD-1", orderChannel: "online", staffId: "ST1" },
            { productId: "P1", name: "Widget", price: 60 },
            1, 5, "discount", "price cut")
        var adj = TransactionStore.entries[TransactionStore.entries.length - 1]
        compare(adj.kind, "price_adjust")
        compare(adj.category, "Hardware")
    }

    function test_recordPriceAdjust_orderwide_adjustment_has_empty_category() {
        // No single productId -> no single category to attribute; matches how
        // productId/productName are already "" for an order-wide adjustment.
        TransactionStore.recordPriceAdjust(
            { orderId: "ORD-1", orderChannel: "online", staffId: "ST1" },
            { productId: "", name: "" },
            1, 5, "modify", "order-wide tweak")
        compare(TransactionStore.entries[0].category, "")
    }
}
