import QtQuick
import QtTest
import "../qml/model"

// InventoryStore.applyRestockResults: reflects a server-confirmed restock (a live answer or a stored
// replay) into the local stores without sending anything (atomic-ops R3; R4 calls it). Node twin:
// functions/test/restockSurface.test.js (H-3..H-5), where the answer comes from the REAL server code.
//
// NOT RUN IN THIS SANDBOX: no Qt/qmltestrunner toolchain here. CI is the oracle.
TestCase {
    name: "InventoryStore_applyRestockResults"

    function init() {
        InventoryStore.products = [{ productId: "p1", name: "Tomato", sku: "", category: "Veg", unit: "pc",
                                     price: 10, sellingPrice: 10, stock: 10, minStock: 0 }]
        SupplierStore.suppliers = []
        StockBatchStore.batches = []
        TransactionStore.entries = []
        OutboxStore.clear()
    }

    function cleanup() { init() }

    // The answer applyOperation gives for a new-supplier restock of 5 on top of 10.
    function _good() {
        return [
            { kind: "mint", bind: "sup", counter: "supplier", id: "SUP-001" },
            { kind: "mint", bind: "batch", counter: "stock_batch", id: "BAT-2026-001" },
            { kind: "mutation", entity: "supplier", entityId: "SUP-001", action: "create",
              after: { supplierId: "SUP-001", name: "Acme" } },
            { kind: "mutation", entity: "stock_batch", entityId: "BAT-2026-001", action: "create",
              after: { batchId: "BAT-2026-001", productId: "p1", supplierId: "SUP-001", qtyRemaining: 5 } },
            { kind: "delta", entity: "inventory", entityId: "p1", after: { stock: 15 } },
            { kind: "mutation", entity: "transaction", entityId: "tx-p-BAT-2026-001", action: "create",
              after: { txId: "tx-p-BAT-2026-001", kind: "purchase", productId: "p1" } }
        ]
    }

    function _stockOf(id) {
        for (var i = 0; i < InventoryStore.products.length; ++i)
            if (InventoryStore.products[i].productId === id) return InventoryStore.products[i].stock
        return undefined
    }

    function test_a_live_answer_fills_supplier_batch_purchase_and_stock() {
        var out = InventoryStore.applyRestockResults(_good())
        verify(out.ok)
        compare(SupplierStore.suppliers.length, 1)
        compare(SupplierStore.suppliers[0].supplierId, "SUP-001")
        compare(StockBatchStore.batches.length, 1)
        compare(StockBatchStore.batches[0].batchId, "BAT-2026-001")
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.entries[0].txId, "tx-p-BAT-2026-001")
        compare(_stockOf("p1"), 15)
    }

    function test_a_known_supplier_adds_no_supplier() {
        var known = _good().filter(function(r) { return r.bind !== "sup" && r.entity !== "supplier" })
        verify(InventoryStore.applyRestockResults(known).ok)
        compare(SupplierStore.suppliers.length, 0)
        compare(StockBatchStore.batches.length, 1)
        compare(_stockOf("p1"), 15)
    }

    function test_a_replay_fills_the_gaps_but_leaves_the_stock_alone() {
        verify(InventoryStore.applyRestockResults(_good(), { replay: true }).ok)
        compare(StockBatchStore.batches.length, 1)
        compare(TransactionStore.entries.length, 1)
        compare(_stockOf("p1"), 10, "a stored answer can be older than what this device knows")
    }

    function test_replay_false_or_missing_opts_still_applies_the_stock() {
        verify(InventoryStore.applyRestockResults(_good(), { replay: false }).ok)
        compare(_stockOf("p1"), 15)
        init()
        verify(InventoryStore.applyRestockResults(_good(), {}).ok)
        compare(_stockOf("p1"), 15)
    }

    function test_applying_the_same_answer_twice_duplicates_nothing() {
        InventoryStore.applyRestockResults(_good())
        InventoryStore.applyRestockResults(_good())
        compare(SupplierStore.suppliers.length, 1)
        compare(StockBatchStore.batches.length, 1)
        compare(TransactionStore.entries.length, 1)
        compare(_stockOf("p1"), 15)
    }

    function test_an_answer_that_is_not_exactly_one_restock_applies_nothing_data() {
        var g = _good()
        return [
            { tag: "null", results: null }, { tag: "undefined", results: undefined }, { tag: "empty", results: [] },
            { tag: "object", results: {} }, { tag: "unknown kind", results: [{ kind: "zap" }] },
            { tag: "no supplier mint", results: g.slice(1) },
            { tag: "no delta", results: g.filter(function(r) { return r.kind !== "delta" }) }
        ]
    }

    function test_an_answer_that_is_not_exactly_one_restock_applies_nothing(data) {
        var out = InventoryStore.applyRestockResults(data.results)
        compare(out.ok, false)
        compare(SupplierStore.suppliers.length, 0)
        compare(StockBatchStore.batches.length, 0)
        compare(TransactionStore.entries.length, 0)
        compare(_stockOf("p1"), 10)
    }

    function test_a_stock_for_a_product_this_device_does_not_have_is_ignored_safely() {
        InventoryStore.products = []
        verify(InventoryStore.applyRestockResults(_good()).ok)
        compare(StockBatchStore.batches.length, 1, "the ledger docs are still filled")
    }

    // ── R5b: the feed row the server wrote is adopted, once ────────────────────

    function _goodWithRow() {
        return _good().concat([{ kind: "mutation", entity: "activity", entityId: "act-BAT-2026-001", action: "create",
            after: { id: "act-BAT-2026-001", kind: "product_restocked", title: "Restocked: Tomato", subtitle: "+5 \u00b7 now 15 in stock",
                     entityId: "p1", read: false, dismissed: false, actorUid: "u", timestamp: "2026-06-15T12:00:00.000Z" } }])
    }

    function test_the_servers_feed_row_is_adopted_and_a_replay_adds_nothing() {
        verify(InventoryStore.applyRestockResults(_goodWithRow()).ok)
        compare(ActivityLog.entries.length, 1)
        compare(ActivityLog.entries[0].id, "act-BAT-2026-001")
        verify(InventoryStore.applyRestockResults(_goodWithRow(), { replay: true }).ok)
        compare(ActivityLog.entries.length, 1)
    }

    function test_a_legacy_answer_has_no_feed_row_and_applyRestockResults_adds_none() {
        verify(InventoryStore.applyRestockResults(_good()).ok)
        compare(ActivityLog.entries.length, 0)
    }

    function test_a_damaged_feed_row_applies_nothing() {
        var bad = _goodWithRow()
        bad[bad.length - 1].after.entityId = "p2"
        compare(InventoryStore.applyRestockResults(bad).ok, false)
        compare(ActivityLog.entries.length, 0)
        compare(StockBatchStore.batches.length, 0)
    }
}
