import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// PR #121 follow-up (Taher, Q1 = Z): DataModel._tryCompleteOrder REFUSES, up front, a line whose
// product has ANY unsynced edit in the outbox (retrying, in flight or parked): the price/stock this
// device shows may not be what the server will hold. Device bugs it locks down: (2) edit 25 -> 30
// rejected by Firestore and retried for ~3 min, a sale in that window completed at 30; (3) app
// reopened in that window re-read 25 from Firestore and the sale completed at 25.
// Stock DELTAS from earlier sales are not edits (back-to-back sales must work). A PARKED write keeps
// its own message and wins when both apply. Same harness as tst_DataModel_completeOrderParkedGuard.qml.
// NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "DataModel_completeOrderUnsyncedEditGuard"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }
    SignalSpy { id: failSpy; target: testLogic; signalName: "orderCompletionFailed" }

    property string _prevMode: ""

    function init() {
        _prevMode = Gateway.mode
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        StockBatchStore.batches = [_batch("B-1", "SKU-1"), _batch("B-2", "SKU-2")]
        OrdersStore.orders = [
            _order("ORD-1", [_line("SKU-1")]),
            _order("ORD-2", [_line("SKU-1"), _line("SKU-2")]),
            _order("ORD-3", [_line("SKU-1"), _line("SKU-1")]),
            _order("ORD-4", [{ name: "Ghost", price: 1, quantity: 1 }]),
            _order("ORD-5", [_line("SKU-1")], "completed")
        ]
        TransactionStore.entries = []
        TransactionStore.revision = 0
        dm.stockErrorMsg = ""
        dm._completingOrderIds = ({})
        failSpy.clear()
    }

    function cleanup() { OutboxStore.clear(); Gateway.mode = _prevMode }

    function _product(id) {
        return { productId: id, name: "Widget " + id, category: "", description: "", unit: "pc",
                 price: 100, sellingPrice: 100, taxable: false, taxPercent: 0, size: "", stock: 5, minStock: 0 }
    }
    function _batch(id, productId) {
        return { batchId: id, productId: productId, supplierId: "S1", qtyReceived: 5, qtyRemaining: 5,
                 unitCost: 50, receivedDate: "2026-09-01T00:00:00.000Z", poId: "", note: "",
                 createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-01T00:00:00.000Z" }
    }
    function _line(productId) {
        return { productId: productId, name: "Widget " + productId, price: 100, quantity: 1 }
    }
    function _order(id, lines, status) {
        return { orderId: id, customer: "Test Customer", status: status || "pending", date: "2026-10-04",
                 email: "", phone: "", notes: "", orderChannel: "", staffId: "", adjustments: [], products: lines }
    }
    // A rejected edit of `productId` that is now parked (terminal + stuck).
    function _park(productId, entity) {
        var it = OutboxStore.enqueue({ requestId: "park-" + productId + "-" + (entity || "inventory"),
                                       entity: entity || "inventory", entityId: productId,
                                       action: "update", before: { v: 0 }, after: { v: 1 } })
        OutboxStore.setStuckMeta(it.requestId, { failures: 5, stuck: true, terminal: true })
        return it.requestId
    }
    function _complete(orderId) {
        var out = { called: 0, ok: null }
        dm._tryCompleteOrder(orderId, function(ok) { out.called++; out.ok = ok })
        return out
    }
    function _batchQty(productId) { return StockBatchStore.batches.filter(function(b) {
        return b.productId === productId })[0].qtyRemaining }
    function _status(orderId) { return OrdersStore.getById(orderId).status }

    function _edit(productId, id) {
        return OutboxStore.enqueue({ requestId: id || ("edit-" + productId), entity: "inventory", entityId: productId,
                                     action: "update", before: { sellingPrice: 25 }, after: { sellingPrice: 30 } }).requestId
    }
    function _delta(productId) {
        OutboxStore.enqueueDelta({ requestId: "d-" + productId, entity: "inventory", entityId: productId,
                                   deltas: { stock: -1 }, floors: { stock: 0 } })
    }
    function _proceeded(orderId) { return dm._completingOrderIds[orderId] === true }

    // ── refused ──────────────────────────────────────────────────────────

    function test_queued_edit_refuses_with_the_unsynced_message_at_once() {
        _edit("SKU-1")
        var r = _complete("ORD-1")
        compare(r.called, 1, "answers synchronously")
        compare(r.ok, false)
        compare(dm.stockErrorMsg, "Widget SKU-1: " + InventoryStore.unsyncedEditMessage)
    }
    function test_refusal_changes_nothing() {
        _edit("SKU-1")
        var before = OutboxStore.items.length
        _complete("ORD-1")
        compare(InventoryStore.getById("SKU-1").stock, 5)
        compare(_batchQty("SKU-1"), 5)
        compare(OutboxStore.items.length, before)
        compare(_status("ORD-1"), "pending")
        compare(TransactionStore.entries.length, 0)
        verify(!_proceeded("ORD-1"))
    }
    function test_real_price_edit_then_sale_is_refused_not_sold_at_the_unsynced_price() {
        InventoryStore.updateProduct("SKU-1", { sellingPrice: 30 }, "")
        var r = _complete("ORD-1")
        compare(r.ok, false)
        verify(dm.stockErrorMsg.indexOf(InventoryStore.unsyncedEditMessage) !== -1)
    }
    function test_still_refused_after_a_relaunch_reload_of_the_outbox() {
        _edit("SKU-1")
        OutboxStore.items = []
        OutboxStore._load()
        compare(_complete("ORD-1").ok, false)
    }
    function test_in_flight_edit_refuses_edge() {
        var it = OutboxStore.enqueue({ requestId: "inflight", entity: "inventory", entityId: "SKU-1",
                                       action: "update", before: {}, after: { a: 1 } })
        OutboxStore.markInFlight(it)
        compare(_complete("ORD-1").ok, false)
    }
    function test_queued_create_refuses_edge() {
        OutboxStore.enqueue({ requestId: "c", entity: "inventory", entityId: "SKU-1", action: "create", before: null, after: {} })
        compare(_complete("ORD-1").ok, false)
    }
    function test_second_tap_refused_again_not_already_being_completed() {
        _edit("SKU-1")
        _complete("ORD-1")
        var r = _complete("ORD-1")
        compare(r.ok, false)
        compare(dm.stockErrorMsg.indexOf("already being completed"), -1)
    }
    function test_refusal_without_a_callback_does_not_throw_edge() {
        _edit("SKU-1")
        dm._tryCompleteOrder("ORD-1")
        compare(_status("ORD-1"), "pending")
    }

    // ── multi-line ───────────────────────────────────────────────────────

    function test_one_unsynced_line_refuses_the_whole_order() {
        _edit("SKU-2")
        compare(_complete("ORD-2").ok, false)
        compare(dm.stockErrorMsg, "Widget SKU-2: " + InventoryStore.unsyncedEditMessage)
        compare(_batchQty("SKU-1"), 5)
    }
    function test_two_unsynced_lines_are_both_named() {
        _edit("SKU-1"); _edit("SKU-2")
        _complete("ORD-2")
        compare(dm.stockErrorMsg, "Widget SKU-1, Widget SKU-2: " + InventoryStore.unsyncedEditMessage)
    }
    function test_same_product_on_two_lines_is_named_once() {
        _edit("SKU-1")
        _complete("ORD-3")
        compare(dm.stockErrorMsg, "Widget SKU-1: " + InventoryStore.unsyncedEditMessage)
    }
    function test_parked_line_and_unsynced_line_both_reported_parked_first() {
        _park("SKU-2"); _edit("SKU-1")
        _complete("ORD-2")
        compare(dm.stockErrorMsg, "Widget SKU-2: " + InventoryStore.parkedWriteMessage
                                  + "; Widget SKU-1: " + InventoryStore.unsyncedEditMessage)
    }
    function test_parked_product_gets_only_the_parked_message_edge() {
        _park("SKU-1")
        _complete("ORD-1")
        compare(dm.stockErrorMsg, "Widget SKU-1: " + InventoryStore.parkedWriteMessage)
        compare(dm.stockErrorMsg.indexOf(InventoryStore.unsyncedEditMessage), -1)
    }

    // ── not refused ──────────────────────────────────────────────────────

    function test_no_edit_proceeds() {
        _complete("ORD-1")
        verify(_proceeded("ORD-1"))
    }
    function test_stock_delta_from_an_earlier_sale_does_not_block_the_next_sale() {
        _delta("SKU-1")
        _complete("ORD-1")
        verify(_proceeded("ORD-1"), "back-to-back sales of one product must work")
    }
    function test_unsynced_edit_on_another_product_does_not_refuse() {
        _edit("SKU-2")
        _complete("ORD-1")
        verify(_proceeded("ORD-1"))
    }
    function test_unsynced_edit_on_another_entity_with_the_same_id_does_not_refuse() {
        OutboxStore.enqueue({ requestId: "b", entity: "stock_batch", entityId: "SKU-1", action: "update", before: {}, after: { a: 1 } })
        _complete("ORD-1")
        verify(_proceeded("ORD-1"))
    }
    function test_held_ledger_row_for_the_product_does_not_refuse_edge() {
        OutboxStore.enqueue({ requestId: "tx1", entity: "transaction", entityId: "SKU-1", action: "create",
                              after: {}, dependsOn: "gone" })
        _complete("ORD-1")
        verify(_proceeded("ORD-1"))
    }
    function test_proceeds_once_the_edit_is_acked() {
        InventoryStore.updateProduct("SKU-1", { sellingPrice: 30 }, "")
        compare(_complete("ORD-1").ok, false)
        Gateway._ackSingle(OutboxStore.items.filter(function(i) { return i.entity === "inventory" })[0])
        _complete("ORD-1")
        verify(_proceeded("ORD-1"))
    }
    function test_proceeds_once_the_edit_is_discarded() {
        var rid = _edit("SKU-1")
        compare(_complete("ORD-1").ok, false)
        OutboxStore.markSent(rid)
        _complete("ORD-1")
        verify(_proceeded("ORD-1"))
    }
    function test_completed_order_short_circuits_true_even_with_an_unsynced_edit() {
        _edit("SKU-1")
        var r = _complete("ORD-5")
        compare(r.ok, true)
        compare(dm.stockErrorMsg, "")
    }
    function test_unresolvable_line_keeps_the_not_found_failure_edge() {
        _edit("SKU-1")
        var r = _complete("ORD-4")
        compare(r.ok, false)
        verify(dm.stockErrorMsg.indexOf("not found in inventory") !== -1)
    }

    // ── routing ──────────────────────────────────────────────────────────

    function test_completeOrder_signal_routes_the_refusal_to_orderCompletionFailed() {
        _edit("SKU-1")
        testLogic.completeOrder("ORD-1")
        compare(failSpy.count, 1)
        compare(failSpy.signalArguments[0][1], "Widget SKU-1: " + InventoryStore.unsyncedEditMessage)
        compare(_status("ORD-1"), "pending")
    }
    function test_updateOrder_to_completed_routes_the_refusal_edge() {
        _edit("SKU-1")
        testLogic.updateOrder("ORD-1", { status: "completed" })
        compare(failSpy.count, 1)
        compare(_status("ORD-1"), "pending")
    }
    function test_no_edit_does_not_emit_orderCompletionFailed() {
        testLogic.completeOrder("ORD-1")
        compare(failSpy.count, 0)
    }

    // ── monkey ───────────────────────────────────────────────────────────

    function test_monkey_refuse_iff_a_non_delta_write_is_queued_for_a_line() {
        var seed = 20261005
        function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n }
        for (var step = 0; step < 60; ++step) {
            OutboxStore.clear()
            OrdersStore.orders = [_order("ORD-1", [_line("SKU-1")]), _order("ORD-2", [_line("SKU-1"), _line("SKU-2")])]
            InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
            StockBatchStore.batches = [_batch("B-1", "SKU-1"), _batch("B-2", "SKU-2")]
            dm._completingOrderIds = ({})
            var e1 = rnd(3), e2 = rnd(3)   // 0 none, 1 edit, 2 delta only
            if (e1 === 1) _edit("SKU-1"); else if (e1 === 2) _delta("SKU-1")
            if (e2 === 1) _edit("SKU-2"); else if (e2 === 2) _delta("SKU-2")
            var orderId = rnd(2) === 0 ? "ORD-1" : "ORD-2"
            var want = (e1 === 1) || (orderId === "ORD-2" && e2 === 1)
            var before = OutboxStore.items.length
            var r = _complete(orderId)
            if (want) {
                compare(r.ok, false, "step " + step)
                compare(OutboxStore.items.length, before, "step " + step)
                verify(!_proceeded(orderId), "step " + step)
            } else {
                verify(_proceeded(orderId), "step " + step)
            }
        }
    }
}
