import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// 2026-10-04, decision B (Taher): DataModel._tryCompleteOrder REFUSES, up front, when any line's
// product has a PARKED outbox write (server rejected it, waiting for Retry/Discard).
// Bug it fixes: the parked item holds `inventory/<id>` in OutboxStore.dueItems, so the stock delta
// queued by deductStock was never sent, its callback never fired, `_completingOrderIds[orderId]`
// stayed set ("already being completed" forever) and FIFO batches drifted from product.stock.
// A refusal answers callback(false) at once, sets stockErrorMsg (product name + the shared D2/D3
// message), leaves the order "pending", enqueues nothing and consumes no batch.
// Harness note (same as tst_DataModel_completeOrderReentrancy.qml): offline (no idToken), so a
// completion that is NOT refused never resolves its callback; "proceeded" below means
// `_completingOrderIds[orderId]` is set, which is exactly the real mid-flight state.
// NOT RUN IN THIS SANDBOX: CI runs it. The emulator round trip is in test/e2e/tst_OrdersE2E.qml.
TestCase {
    name: "DataModel_completeOrderParkedGuard"

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

    // ── refusal: nothing happens ──────────────────────────────────────────

    function test_refused_behind_a_park_answers_false_at_once() {
        _park("SKU-1")
        var r = _complete("ORD-1")
        compare(r.called, 1, "must answer synchronously, not hang")
        compare(r.ok, false)
    }
    function test_refusal_message_names_the_product_and_says_fix_or_discard() {
        _park("SKU-1")
        _complete("ORD-1")
        compare(dm.stockErrorMsg, "Widget SKU-1: " + InventoryStore.parkedWriteMessage)
    }
    function test_refusal_changes_nothing() {
        _park("SKU-1")
        var outboxBefore = OutboxStore.items.length
        _complete("ORD-1")
        compare(InventoryStore.getById("SKU-1").stock, 5)
        compare(_batchQty("SKU-1"), 5, "no FIFO consumption")
        compare(OutboxStore.items.length, outboxBefore, "no delta enqueued")
        compare(_status("ORD-1"), "pending", "order is NOT marked out of stock")
        compare(TransactionStore.entries.length, 0, "no sale recorded")
    }
    function test_refusal_does_not_leave_the_in_flight_guard_set() {
        _park("SKU-1")
        _complete("ORD-1")
        verify(!dm._completingOrderIds["ORD-1"])
    }
    function test_second_tap_after_a_refusal_is_refused_again_not_already_being_completed() {
        _park("SKU-1")
        _complete("ORD-1")
        var r = _complete("ORD-1")
        compare(r.ok, false)
        compare(dm.stockErrorMsg.indexOf("already being completed"), -1)
        verify(dm.stockErrorMsg.indexOf(InventoryStore.parkedWriteMessage) !== -1)
    }
    function test_refusal_without_a_callback_does_not_throw() {
        _park("SKU-1")
        dm._tryCompleteOrder("ORD-1")
        compare(_status("ORD-1"), "pending")
    }
    function test_stuck_but_not_parked_write_is_not_refused_edge() {
        // Retrying (stuck, not terminal) is not parked: the delta queues behind it and drains once it clears.
        var it = OutboxStore.enqueue({ requestId: "retrying", entity: "inventory", entityId: "SKU-1",
                                       action: "update", before: { v: 0 }, after: { v: 1 } })
        OutboxStore.setStuckMeta(it.requestId, { failures: 2, stuck: true })
        _complete("ORD-1")
        verify(dm._completingOrderIds["ORD-1"] === true, "must proceed")
    }
    function test_plain_pending_write_is_not_refused_edge() {
        OutboxStore.enqueue({ requestId: "pending", entity: "inventory", entityId: "SKU-1",
                              action: "update", before: { v: 0 }, after: { v: 1 } })
        _complete("ORD-1")
        verify(dm._completingOrderIds["ORD-1"] === true)
    }

    // ── multi-line orders ─────────────────────────────────────────────────

    function test_one_parked_line_refuses_the_whole_order_and_consumes_nothing() {
        _park("SKU-2")
        var r = _complete("ORD-2")
        compare(r.ok, false)
        compare(dm.stockErrorMsg, "Widget SKU-2: " + InventoryStore.parkedWriteMessage, "only the parked line is named")
        compare(_batchQty("SKU-1"), 5, "the healthy line must not be consumed either")
        compare(_batchQty("SKU-2"), 5)
        compare(_status("ORD-2"), "pending")
    }
    function test_two_parked_lines_are_both_named() {
        _park("SKU-1"); _park("SKU-2")
        _complete("ORD-2")
        compare(dm.stockErrorMsg, "Widget SKU-1, Widget SKU-2: " + InventoryStore.parkedWriteMessage)
    }
    function test_same_product_on_two_lines_is_named_once() {
        _park("SKU-1")
        _complete("ORD-3")
        compare(dm.stockErrorMsg, "Widget SKU-1: " + InventoryStore.parkedWriteMessage)
    }

    // ── not refused ───────────────────────────────────────────────────────

    function test_no_park_proceeds() {
        _complete("ORD-1")
        verify(dm._completingOrderIds["ORD-1"] === true)
        compare(dm.stockErrorMsg.indexOf(InventoryStore.parkedWriteMessage), -1)
    }
    function test_park_on_another_product_does_not_refuse() {
        _park("SKU-2")
        _complete("ORD-1")
        verify(dm._completingOrderIds["ORD-1"] === true)
    }
    function test_park_on_another_entity_with_the_same_id_does_not_refuse() {
        _park("SKU-1", "stock_batch")
        _complete("ORD-1")
        verify(dm._completingOrderIds["ORD-1"] === true)
    }
    function test_proceeds_after_the_parked_write_is_discarded() {
        var rid = _park("SKU-1")
        compare(_complete("ORD-1").ok, false)
        OutboxStore.markSent(rid)
        _complete("ORD-1")
        verify(dm._completingOrderIds["ORD-1"] === true)
    }
    function test_completed_order_short_circuits_true_even_behind_a_park() {
        _park("SKU-1")
        var r = _complete("ORD-5")
        compare(r.ok, true)
        compare(dm.stockErrorMsg, "")
    }
    function test_unknown_order_answers_false_without_a_message() {
        var r = _complete("NOPE")
        compare(r.ok, false)
        compare(dm.stockErrorMsg, "")
    }
    function test_unresolvable_line_keeps_the_old_not_found_failure() {
        _park("SKU-1")
        var r = _complete("ORD-4")
        compare(r.ok, false)
        verify(dm.stockErrorMsg.indexOf("not found in inventory") !== -1)
        compare(dm.stockErrorMsg.indexOf(InventoryStore.parkedWriteMessage), -1)
    }

    // ── DataModel routing: every caller shows the message ─────────────────

    function test_completeOrder_signal_routes_the_refusal_to_orderCompletionFailed() {
        _park("SKU-1")
        testLogic.completeOrder("ORD-1")
        compare(failSpy.count, 1)
        compare(failSpy.signalArguments[0][0], "ORD-1")
        compare(failSpy.signalArguments[0][1], "Widget SKU-1: " + InventoryStore.parkedWriteMessage)
        compare(_status("ORD-1"), "pending")
    }
    function test_updateOrder_to_completed_routes_the_refusal_to_orderCompletionFailed() {
        _park("SKU-1")
        testLogic.updateOrder("ORD-1", { status: "completed" })
        compare(failSpy.count, 1)
        compare(failSpy.signalArguments[0][1], "Widget SKU-1: " + InventoryStore.parkedWriteMessage)
        compare(_status("ORD-1"), "pending")
    }
    function test_no_park_does_not_emit_orderCompletionFailed() {
        testLogic.completeOrder("ORD-1")
        compare(failSpy.count, 0)
    }

    // ── monkey: seeded park / unpark / complete on two products ───────────

    function test_monkey_refusal_never_touches_state_and_proceed_always_sets_the_guard() {
        var seed = 20261004
        function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n }
        var parks = { "SKU-1": null, "SKU-2": null }
        for (var step = 0; step < 60; ++step) {
            var pid = rnd(2) === 0 ? "SKU-1" : "SKU-2"
            var act = rnd(3)
            if (act === 0 && !parks[pid]) parks[pid] = _park(pid)
            else if (act === 1 && parks[pid]) { OutboxStore.markSent(parks[pid]); parks[pid] = null }
            else {
                var orderId = rnd(2) === 0 ? "ORD-1" : "ORD-2"
                var wantRefuse = (orderId === "ORD-1") ? !!parks["SKU-1"] : (!!parks["SKU-1"] || !!parks["SKU-2"])
                OrdersStore.orders = [_order("ORD-1", [_line("SKU-1")]), _order("ORD-2", [_line("SKU-1"), _line("SKU-2")])]
                InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
                StockBatchStore.batches = [_batch("B-1", "SKU-1"), _batch("B-2", "SKU-2")]
                dm._completingOrderIds = ({})
                // Rebuild the outbox from the live parks only: a proceeded step leaves stock deltas
                // behind, and enqueue() would merge a later park into one of them.
                OutboxStore.clear()
                if (parks["SKU-1"]) parks["SKU-1"] = _park("SKU-1")
                if (parks["SKU-2"]) parks["SKU-2"] = _park("SKU-2")
                var outboxBefore = OutboxStore.items.length
                var r = _complete(orderId)
                if (wantRefuse) {
                    compare(r.ok, false, "step " + step)
                    compare(_batchQty("SKU-1"), 5, "step " + step)
                    compare(_batchQty("SKU-2"), 5, "step " + step)
                    compare(OutboxStore.items.length, outboxBefore, "step " + step)
                    verify(!dm._completingOrderIds[orderId], "step " + step)
                } else {
                    verify(dm._completingOrderIds[orderId] === true, "step " + step)
                }
            }
        }
    }
}
