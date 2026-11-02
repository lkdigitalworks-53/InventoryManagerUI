import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// Atomic-ops R4: InventoryStore.restock now sends ONE recordOperation and settles through
// Gateway.operationApplied/operationRejected (DataModel routes them). The waiting caller and the late
// signal must never apply the same answer twice. The same cases run in Node against the REAL function
// bodies and the REAL server code in functions/test/restockWire.test.js; this file is the qmltestrunner
// copy for the QML-engine glue (Gateway waiters, signals, DataModel Connections, the sale guard).
// Design: docs/superpowers/specs/2026-11-02-r4-restock-wire-design.md
// NOT RUN IN THIS SANDBOX: no Qt/qmltestrunner toolchain here. CI is the oracle.
TestCase {
    name: "InventoryStore_restock"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }
    SignalSpy { id: errSpy; target: testLogic; signalName: "errorOccurred" }
    SignalSpy { id: doneSpy; target: testLogic; signalName: "productRestocked" }

    function init() {
        OutboxStore.clear()
        Gateway.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        AuthStore.isAuthenticated = false
        AuthStore.role = "owner"
        AuthService.isOnline = true
        ActivityLog.clear()
        InventoryStore._pendingDeletes = ({})
        InventoryStore._restockSettled = ({})
        InventoryStore._restockNames = ({})
        InventoryStore.products = [_product("p1"), _product("p2")]
        SupplierStore.suppliers = [{ supplierId: "SUP-009", name: "Acme Farms" }]
        StockBatchStore.batches = []
        StockBatchStore._pendingMints = []
        TransactionStore.entries = []
        OrdersStore.orders = [{ orderId: "ORD-1", customer: "C", status: "pending", date: "2026-10-04", email: "", phone: "",
                                notes: "", orderChannel: "", staffId: "", adjustments: [],
                                products: [{ productId: "p1", name: "Tomato", price: 10, quantity: 1 }] }]
        dm.stockErrorMsg = ""
        dm._completingOrderIds = ({})
        errSpy.clear()
        doneSpy.clear()
    }
    function cleanup() { OutboxStore.clear() }

    function _product(id) {
        return { productId: id, name: id === "p1" ? "Tomato" : "Onion", category: "Veg", sku: "", unit: "pc",
                 price: 12.5, sellingPrice: 20, stock: 10, minStock: 0 }
    }
    function _stock(id) { return InventoryStore.getById(id).stock }
    function _items() { return OutboxStore.items.filter(function(i) { return i.opType === "restock" }) }
    // The answer the server gives for a restock of 5 (new supplier SUP-001 when `fresh`).
    function _answer(fresh) {
        var r = [{ kind: "mint", bind: "batch", counter: "stock_batch", id: "BAT-2026-001" }]
        var sid = "SUP-009"
        if (fresh) {
            sid = "SUP-001"
            r.unshift({ kind: "mint", bind: "sup", counter: "supplier", id: "SUP-001" })
            r.push({ kind: "mutation", entity: "supplier", entityId: "SUP-001", action: "create",
                     after: { supplierId: "SUP-001", name: "Newco" } })
        }
        r.push({ kind: "mutation", entity: "stock_batch", entityId: "BAT-2026-001", action: "create",
                 after: { batchId: "BAT-2026-001", productId: "p1", supplierId: sid, qtyReceived: 5, qtyRemaining: 5, note: "weekly" } })
        r.push({ kind: "delta", entity: "inventory", entityId: "p1", after: { stock: 15 } })
        r.push({ kind: "mutation", entity: "transaction", entityId: "tx-p-BAT-2026-001", action: "create",
                 after: { txId: "tx-p-BAT-2026-001", kind: "purchase", productId: "p1", productName: "Tomato" } })
        return r
    }
    function _tap(over) {
        var out = { calls: [] }
        var a = Object.assign({ id: "p1", qty: 5, party: "", cost: 10, reason: "weekly" }, over || {})
        InventoryStore.restock(a.id, a.qty, a.party, a.cost, a.reason, function(ok, queued, refusal) {
            out.calls.push({ ok: ok, queued: queued, refusal: refusal }) })
        return out
    }

    // ── queued (offline) ─────────────────────────────────────────────────
    function test_offline_restock_is_queued_as_one_operation_and_changes_nothing_locally() {
        AuthService.isOnline = false
        var t = _tap({ party: "Newco" })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, true)
        compare(t.calls[0].queued, true)
        compare(_items().length, 1)
        compare(OutboxStore.items.length, 1, "no other writes: no mint, batch, delta or purchase calls")
        verify(InventoryStore.hasQueuedRestock("p1"))
        verify(!InventoryStore.hasQueuedRestock("p2"))
        compare(_stock("p1"), 10)
        compare(StockBatchStore.batches.length, 0)
        compare(ActivityLog.entries.length, 0)
        compare(StockBatchStore._pendingMints.length, 0)
    }
    function test_the_queued_operation_carries_a_restock_key_and_the_mints() {
        AuthService.isOnline = false
        _tap({ party: "Newco" })
        var it = _items()[0]
        verify(it.requestId.indexOf("restock:") === 0)
        compare(it.ops.map(function(o) { return o.kind }).join(","), "mint,mint,mutation,mutation,delta,mutation")
    }
    function test_a_known_supplier_name_resolves_to_its_id_and_adds_no_supplier() {
        AuthService.isOnline = false
        _tap({ party: "acme farms" })
        var ops = _items()[0].ops
        compare(ops.length, 4)
        compare(ops[1].after.supplierId, "SUP-009")
    }
    function test_a_second_restock_of_the_product_is_refused_until_the_first_leaves_the_outbox() {
        AuthService.isOnline = false
        _tap()
        var t = _tap()
        compare(t.calls[0].ok, false)
        compare(t.calls[0].refusal, InventoryStore.restockPendingMessage)
        compare(_items().length, 1)
        OutboxStore.clear()
        verify(!InventoryStore.hasQueuedRestock("p1"))
        compare(_tap().calls[0].ok, true)
    }
    function test_refusals_queue_nothing() {
        var cases = [[{ qty: 0 }, InventoryStore.restockQtyRefusal], [{ qty: -1 }, InventoryStore.restockQtyRefusal],
                     [{ qty: NaN }, InventoryStore.restockQtyRefusal], [{ qty: "5" }, InventoryStore.restockQtyRefusal],
                     [{ cost: -1 }, "Unit cost is not a valid amount"], [{ party: "   " }, "Supplier name is not valid"]]
        for (var i = 0; i < cases.length; ++i) {
            var t = _tap(cases[i][0])
            compare(t.calls[0].ok, false)
            compare(t.calls[0].refusal, cases[i][1])
        }
        compare(OutboxStore.items.length, 0)
        var u = _tap({ id: "nope" })
        compare(u.calls[0].ok, false)
        compare(u.calls[0].refusal, undefined)
    }

    // ── answered while the caller waits ──────────────────────────────────
    function test_live_answer_applies_once_even_though_the_signal_follows() {
        var t = _tap({ party: "Newco" })
        compare(t.calls.length, 0, "an awaiting caller is not answered before the server")
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(true), idempotentReplay: false })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, true)
        compare(t.calls[0].queued, false)
        compare(_stock("p1"), 15)
        compare(StockBatchStore.batches.length, 1)
        compare(TransactionStore.entries.length, 1)
        compare(SupplierStore.suppliers.length, 2)
        compare(ActivityLog.entries.length, 1, "one Activity entry, not two")
        compare(ActivityLog.entries[0].title, "Restocked: Tomato")
        compare(ActivityLog.entries[0].subtitle, "+5 · now 15 in stock · from Newco · weekly")
        compare(errSpy.count, 0)
    }
    function test_live_rejection_answers_the_caller_with_the_cause_and_nothing_else() {
        var t = _tap()
        Gateway._finishOperation(_items()[0], { ok: false, error: "conflict", opIndex: 4, conflict: true })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, false)
        compare(t.calls[0].refusal, "Another device changed this at the same time. Nothing was added. Try again")
        compare(errSpy.count, 0, "the caller heard it; no second message")
        compare(_stock("p1"), 10)
        compare(ActivityLog.entries.length, 0)
    }

    // ── answered after the caller left ───────────────────────────────────
    function test_a_late_answer_after_a_queued_restock_applies_once() {
        AuthService.isOnline = false
        var t = _tap()
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(false), idempotentReplay: false })
        compare(t.calls.length, 1, "the caller is not called again")
        compare(_stock("p1"), 15)
        compare(ActivityLog.entries.length, 1)
        compare(ActivityLog.entries[0].subtitle, "+5 · now 15 in stock · from Acme Farms · weekly")
        compare(SupplierStore.suppliers.length, 1)
    }
    function test_a_late_rejection_announces_one_message_with_the_cause() {
        AuthService.isOnline = false
        _tap()
        Gateway._finishOperation(_items()[0], { ok: false, error: "not-found", opIndex: 3 })
        compare(errSpy.count, 1)
        compare(errSpy.signalArguments[0][0], "inventory")
        verify(errSpy.signalArguments[0][1].indexOf("A queued restock was not saved. Tomato: this product is no longer on the server") === 0)
        compare(_stock("p1"), 10)
    }
    function test_discard_is_silent() {
        AuthService.isOnline = false
        _tap()
        Gateway._finishOperation(_items()[0], { ok: false, error: "discarded", discarded: true })
        compare(errSpy.count, 0)
    }
    function test_a_replayed_late_answer_leaves_stock_alone() {
        AuthService.isOnline = false
        _tap()
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(false), idempotentReplay: true })
        compare(_stock("p1"), 10, "replayed stock is as of the first application; the inventory is re-read instead")
        compare(StockBatchStore.batches.length, 1)
        compare(ActivityLog.entries.length, 1)
    }
    function test_an_unreadable_answer_applies_nothing() {
        AuthService.isOnline = false
        _tap()
        Gateway._finishOperation(_items()[0], { ok: true, results: [], idempotentReplay: false })
        compare(_stock("p1"), 10)
        compare(StockBatchStore.batches.length, 0)
        compare(ActivityLog.entries.length, 0)
    }

    // ── a queued restock holds the product back from sales (Q-A2) ────────
    function test_a_sale_of_a_product_with_a_queued_restock_is_refused_and_changes_nothing() {
        AuthService.isOnline = false
        _tap()
        var out = { called: 0, ok: null }
        dm._tryCompleteOrder("ORD-1", function(ok) { out.called++; out.ok = ok })
        compare(out.called, 1)
        compare(out.ok, false)
        compare(dm.stockErrorMsg, "Tomato: " + InventoryStore.restockPendingSaleMessage)
        compare(_stock("p1"), 10)
        compare(OrdersStore.getById("ORD-1").status, "pending")
        verify(dm._completingOrderIds["ORD-1"] !== true)
    }
    function test_once_the_restock_is_gone_the_sale_is_not_refused_for_it() {
        AuthService.isOnline = false
        _tap()
        OutboxStore.clear()
        dm._tryCompleteOrder("ORD-1", function() {})
        verify(dm.stockErrorMsg.indexOf(InventoryStore.restockPendingSaleMessage) < 0)
    }
}
