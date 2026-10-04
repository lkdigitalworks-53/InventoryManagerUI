import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// D2/D3 (PR #119, decisions in docs/superpowers/specs/2026-10-04-product-delete-batch-cascade-design.md):
// restock and delete REFUSE while the product has a PARKED outbox write (server said "rejected",
// waiting for Retry/Discard). Nothing is written, no batch, no hidden product, no Activity entry.
// Covers InventoryStore.restock / deleteProduct / hasParkedWrite and the DataModel handlers
// (message routed through dispatcher.errorOccurred, productDeleted / productRestocked NOT emitted).
// RestockDialog's toast line is a one-liner pinned by the on-device steps in the test plan.
// NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "ParkedWriteGuard"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }
    SignalSpy { id: errorSpy;   target: testLogic; signalName: "errorOccurred" }
    SignalSpy { id: delSpy;     target: testLogic; signalName: "productDeleted" }
    SignalSpy { id: restockSpy; target: testLogic; signalName: "productRestocked" }

    property string _prevMode: ""
    property var _cb: null

    function init() {
        _prevMode = Gateway.mode
        Gateway.mode = "gateway"
        OutboxStore.clear()
        ActivityLog.clear()
        InventoryStore._pendingDeletes = ({})
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        StockBatchStore.batches = [_batch("B-1", "SKU-1"), _batch("B-2", "SKU-2")]
        AuthStore.role = "owner"
        _cb = null
        errorSpy.clear(); delSpy.clear(); restockSpy.clear()
    }

    function cleanup() { OutboxStore.clear(); Gateway.mode = _prevMode }

    function _product(id) {
        return { productId: id, name: "Widget " + id, category: "Widgets", sku: "", unit: "pc",
                 price: 100, sellingPrice: 100, stock: 5, minStock: 0 }
    }
    function _batch(id, productId) {
        return { batchId: id, productId: productId, supplierId: "", qtyReceived: 5, qtyRemaining: 5,
                 unitCost: 100, receivedDate: "2026-08-01" }
    }
    // A rejected edit of `productId` that is now parked.
    function _park(productId, entity) {
        var rid = "park-" + productId + "-" + (entity || "inventory")
        OutboxStore.enqueue({ requestId: rid, entity: entity || "inventory", entityId: productId,
                              action: "update", before: { v: 0 }, after: { v: 1 } })
        OutboxStore.setStuckMeta(rid, { failures: 5, stuck: true, terminal: true })
        return rid
    }
    function _count(entity, action) {
        return OutboxStore.items.filter(function(i) { return i.entity === entity && i.action === action }).length
    }
    function _restock(id) {
        var out = { called: 0, ok: null, supplierFailed: null, refusal: null }
        InventoryStore.restock(id, 3, "", 10, "", function(ok, sf, refusal) {
            out.called++; out.ok = ok; out.supplierFailed = sf; out.refusal = refusal })
        return out
    }

    // ── hasParkedWrite ────────────────────────────────────────────────────

    function test_hasParkedWrite_false_without_a_park() {
        compare(InventoryStore.hasParkedWrite("SKU-1"), false)
    }
    function test_hasParkedWrite_true_only_for_the_parked_product() {
        _park("SKU-1")
        compare(InventoryStore.hasParkedWrite("SKU-1"), true)
        compare(InventoryStore.hasParkedWrite("SKU-2"), false)
    }
    function test_hasParkedWrite_ignores_a_parked_write_for_a_different_entity_with_the_same_id() {
        _park("SKU-1", "stock_batch")
        compare(InventoryStore.hasParkedWrite("SKU-1"), false)
    }

    // ── D3: deleteProduct refuses ─────────────────────────────────────────

    function test_deleteProduct_refused_behind_a_park_changes_nothing() {
        _park("SKU-1")
        var outboxBefore = OutboxStore.items.length

        compare(InventoryStore.deleteProduct("SKU-1"), InventoryStore.parkedWriteMessage)

        compare(InventoryStore.products.length, 2, "product stays visible")
        compare(StockBatchStore.batches.length, 2, "batches stay")
        compare(OutboxStore.items.length, outboxBefore, "no delete queued")
        compare(_count("inventory", "delete"), 0)
        compare(Object.keys(InventoryStore._pendingDeletes).length, 0, "nothing remembered for the ack")
        compare(ActivityLog.entries.length, 0)
    }

    function test_deleteProduct_other_product_still_deletes_while_one_is_parked() {
        _park("SKU-1")
        compare(InventoryStore.deleteProduct("SKU-2"), undefined)
        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].productId, "SKU-1")
        compare(_count("inventory", "delete"), 1)
    }

    function test_deleteProduct_allowed_again_after_the_park_is_cleared() {
        var rid = _park("SKU-1")
        compare(InventoryStore.deleteProduct("SKU-1"), InventoryStore.parkedWriteMessage)
        OutboxStore.markSent(rid) // Discard / success removes the parked item
        compare(InventoryStore.deleteProduct("SKU-1"), undefined)
        compare(InventoryStore.products.length, 1)
        compare(_count("inventory", "delete"), 1)
    }

    function test_deleteProduct_unparked_pending_write_does_not_block() {
        OutboxStore.enqueue({ requestId: "r1", entity: "inventory", entityId: "SKU-1", action: "update", after: { v: 1 } })
        compare(InventoryStore.deleteProduct("SKU-1"), undefined)
        compare(InventoryStore.products.length, 1)
    }

    function test_deleteProduct_unknown_id_is_still_a_quiet_no_op() {
        compare(InventoryStore.deleteProduct("nope"), undefined)
        compare(InventoryStore.products.length, 2)
    }

    // ── D2: restock refuses ───────────────────────────────────────────────

    function test_restock_refused_behind_a_park_writes_nothing() {
        _park("SKU-1")
        var batchesBefore = StockBatchStore.batches.length
        var outboxBefore = OutboxStore.items.length

        var r = _restock("SKU-1")

        compare(r.called, 1)
        compare(r.ok, false)
        compare(r.supplierFailed, false)
        compare(r.refusal, InventoryStore.parkedWriteMessage)
        compare(StockBatchStore.batches.length, batchesBefore, "no batch written (no drift)")
        compare(OutboxStore.items.length, outboxBefore, "no delta queued")
        compare(InventoryStore.products[0].stock, 5)
        compare(ActivityLog.entries.length, 0)
    }

    function test_restock_refused_with_no_callback_does_not_throw() {
        _park("SKU-1")
        InventoryStore.restock("SKU-1", 3, "", 10, "")
        compare(StockBatchStore.batches.length, 2)
    }

    function test_restock_unknown_product_keeps_the_plain_failure_without_a_refusal() {
        _park("SKU-1")
        var r = _restock("nope")
        compare(r.ok, false)
        compare(r.refusal, undefined)
    }

    function test_restock_other_product_is_not_refused() {
        _park("SKU-1")
        var r = _restock("SKU-2")
        compare(r.refusal, undefined, "not refused; the delta is queued, callback waits for the server")
    }

    // ── DataModel routing ─────────────────────────────────────────────────

    function test_dataModel_delete_behind_a_park_shows_the_message_and_skips_productDeleted() {
        _park("SKU-1")
        testLogic.deleteProduct("SKU-1")
        compare(delSpy.count, 0)
        compare(errorSpy.count, 1)
        compare(errorSpy.signalArguments[0][1], InventoryStore.parkedWriteMessage)
        compare(InventoryStore.products.length, 2)
    }

    function test_dataModel_delete_without_a_park_still_emits_productDeleted() {
        testLogic.deleteProduct("SKU-1")
        compare(errorSpy.count, 0)
        compare(delSpy.count, 1)
    }

    function test_dataModel_restock_behind_a_park_shows_the_message_and_skips_productRestocked() {
        _park("SKU-1")
        testLogic.restockProduct("SKU-1", 3)
        compare(restockSpy.count, 0)
        compare(errorSpy.count, 1)
        compare(errorSpy.signalArguments[0][1], InventoryStore.parkedWriteMessage)
    }

    function test_dataModel_delete_role_guard_still_wins_over_the_park_message() {
        AuthStore.role = "staff"
        _park("SKU-1")
        testLogic.deleteProduct("SKU-1")
        compare(errorSpy.count, 1)
        verify(errorSpy.signalArguments[0][1] !== InventoryStore.parkedWriteMessage)
    }

    // ── monkey: random park / clear / delete / restock never leaves a half state ──

    function test_monkey_random_sequences_never_hide_a_product_or_write_a_batch_while_parked() {
        var seed = 7
        function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff }
        var ids = ["SKU-1", "SKU-2"]
        var rid = { "SKU-1": null, "SKU-2": null }
        for (var step = 0; step < 60; ++step) {
            var id = ids[rnd() < 0.5 ? 0 : 1]
            var roll = rnd()
            if (roll < 0.3 && !rid[id]) rid[id] = _park(id)
            else if (roll < 0.5 && rid[id]) { OutboxStore.markSent(rid[id]); rid[id] = null }
            else if (roll < 0.75) {
                var shown = InventoryStore.products.length
                var res = InventoryStore.deleteProduct(id)
                if (rid[id]) {
                    compare(res, InventoryStore.parkedWriteMessage, "step " + step)
                    compare(InventoryStore.products.length, shown, "step " + step)
                } else if (!InventoryStore.getById(id)) {
                    // already deleted earlier in the run: quiet no-op
                    compare(res, undefined, "step " + step)
                }
            } else {
                var nb = StockBatchStore.batches.length
                var r = _restock(id)
                if (rid[id] && InventoryStore.getById(id)) {
                    compare(r.refusal, InventoryStore.parkedWriteMessage, "step " + step)
                    compare(StockBatchStore.batches.length, nb, "step " + step)
                }
            }
        }
    }
}
