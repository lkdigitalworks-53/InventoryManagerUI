import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// Atomic-ops AP3a: InventoryStore.addProduct sends ONE recordOperation("addProduct", ..., { awaitServer: true }) and settles through
// Gateway.operationApplied/operationRejected (DataModel routes them). The waiting caller and the late signal must never apply the same
// answer twice. The same cases run in Node against the REAL function bodies and the REAL server code in
// functions/test/addProductWire.test.js; this file is the qmltestrunner copy for the QML-engine glue (Gateway waiters, signals,
// DataModel Connections, the stores' real adopt/addLocal functions).
// Design: docs/superpowers/specs/2026-11-16-ap3a-add-product-wire-design.md
// NOT RUN IN THIS SANDBOX: no Qt/qmltestrunner toolchain here. CI is the oracle.
TestCase {
    name: "InventoryStore_addProduct"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }
    SignalSpy { id: errSpy; target: testLogic; signalName: "errorOccurred" }

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
        InventoryStore._addSettled = ({})
        InventoryStore._addNames = ({})
        InventoryStore.products = []
        SupplierStore.suppliers = [{ supplierId: "SUP-009", name: "Acme Farms" }]
        StockBatchStore.batches = []
        StockBatchStore._pendingMints = []
        TransactionStore.entries = []
        errSpy.clear()
    }
    function cleanup() { OutboxStore.clear() }

    function _items() { return OutboxStore.items.filter(function(i) { return i.opType === "addProduct" }) }
    function _tap(over) {
        var out = { calls: [] }
        var a = Object.assign({ name: " Tomato ", sku: "TO-1", category: "Veg", description: "Red", price: 20, unit: "kg", stock: 12, minStock: 2,
                                sellingPrice: 30, taxable: true, taxPercent: 5, party: "", unitCost: 18, size: "" }, over || {})
        InventoryStore.addProduct(a.name, a.sku, a.category, a.description, a.price, a.unit, a.stock, a.minStock, a.sellingPrice, a.taxable,
                                  a.taxPercent, a.party, a.unitCost, a.size, function(ok, id, refusal, status) {
            out.calls.push({ ok: ok, id: id, refusal: refusal, status: status }) })
        return out
    }
    // The answer the server gives for the add above (new supplier SUP-001 when `fresh`); nonce taken from the queued item's key.
    function _answer(item, fresh, noStock) {
        var nonce = item.requestId.substring("addProduct:".length)
        var sid = fresh ? "SUP-001" : ""
        var r = [{ kind: "mint", bind: "prd", counter: "product", id: "PRD-001" }]
        if (fresh) r.push({ kind: "mint", bind: "sup", counter: "supplier", id: "SUP-001" })
        if (!noStock) r.push({ kind: "mint", bind: "batch", counter: "stock_batch", id: "BAT-2026-001" })
        if (fresh) r.push({ kind: "mutation", entity: "supplier", entityId: "SUP-001", action: "create", after: { supplierId: "SUP-001", name: "Newco" } })
        r.push({ kind: "mutation", entity: "inventory", entityId: "PRD-001", action: "create",
                 after: { productId: "PRD-001", name: "Tomato", sku: "TO-1", category: "Veg", description: "Red", price: 20, unit: "kg", stock: noStock ? 0 : 12,
                          minStock: 2, sellingPrice: 30, taxable: true, taxPercent: 5, size: "", supplierId: sid, photoIds: [] } })
        if (!noStock) r.push({ kind: "mutation", entity: "stock_batch", entityId: "BAT-2026-001", action: "create",
                 after: { batchId: "BAT-2026-001", productId: "PRD-001", supplierId: sid, qtyReceived: 12, qtyRemaining: 12 } })
        r.push({ kind: "mutation", entity: "transaction", entityId: "tx-c-PRD-001-" + nonce, action: "create",
                 after: { txId: "tx-c-PRD-001-" + nonce, kind: "created", productId: "PRD-001", productName: "Tomato" } })
        r.push({ kind: "mutation", entity: "activity", entityId: "act-PRD-001-" + nonce, action: "create",
                 after: { id: "act-PRD-001-" + nonce, kind: "product_added", title: "Product added: Tomato", subtitle: "TO-1 · stock 12",
                          entityId: "PRD-001", timestamp: "2026-06-15T12:00:00.000Z" } })
        return r
    }

    // ── refusals ──────────────────────────────────────────────────────────
    function test_offline_is_refused_at_once_and_queues_nothing() {
        AuthService.isOnline = false
        var t = _tap()
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, false)
        compare(t.calls[0].refusal, InventoryStore.addOfflineMessage)
        compare(OutboxStore.items.length, 0)
    }
    function test_a_bad_value_gets_its_own_text_even_offline() {
        AuthService.isOnline = false
        var t = _tap({ price: -1 })
        compare(t.calls[0].ok, false)
        verify(t.calls[0].refusal !== InventoryStore.addOfflineMessage)
        compare(OutboxStore.items.length, 0)
    }
    function test_no_callback_does_not_throw() {
        InventoryStore.addProduct("A", "S", "C", "", 1, "pc", 1, 0, 2, false, 0)
        AuthService.isOnline = false
        InventoryStore.addProduct("A", "S", "C", "", 1, "pc", 1, 0, 2, false, 0)
        compare(errSpy.count, 0)
    }
    function test_the_same_new_supplier_name_while_one_is_queued_is_refused() {
        var first = _tap({ party: "Newco" })
        compare(first.calls.length, 0)
        var second = _tap({ party: "newco" })
        compare(second.calls.length, 1)
        compare(second.calls[0].ok, false)
        compare(_items().length, 1)
        compare(_tap({ party: "SUP-009" }).calls.length, 0)
    }

    // ── answered while the caller waits ───────────────────────────────────
    function test_live_answer_applies_once_even_though_the_signal_follows() {
        var t = _tap({ party: "Newco" })
        compare(t.calls.length, 0, "an awaiting caller is not answered before the server")
        compare(InventoryStore.products.length, 0, "no optimistic product")
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(_items()[0], true), idempotentReplay: false })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, true)
        compare(t.calls[0].id, "PRD-001")
        compare(t.calls[0].status, "applied")
        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].name, "Tomato")
        compare(StockBatchStore.batches.length, 1)
        compare(TransactionStore.entries.length, 1)
        compare(SupplierStore.suppliers.length, 2)
        compare(ActivityLog.entries.length, 1, "one Activity entry, not two")
        compare(ActivityLog.entries[0].title, "Product added: Tomato")
        compare(errSpy.count, 0)
    }
    function test_live_rejection_answers_the_caller_and_says_nothing_more() {
        var t = _tap()
        Gateway._finishOperation(_items()[0], { ok: false, error: "conflict", opIndex: 2, conflict: true })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, false)
        verify(t.calls[0].refusal.indexOf("Tomato: ") === 0)
        compare(errSpy.count, 0)
        compare(InventoryStore.products.length, 0)
        compare(ActivityLog.entries.length, 0)
    }

    // ── answered after the caller left ────────────────────────────────────
    // The await window is shortened so the real Gateway timer answers the caller "queued"; the op stays in the outbox and the
    // later answer arrives as the signal only.
    function _tapSlow(over) {
        var saved = Gateway.awaitTimeoutMs
        Gateway.awaitTimeoutMs = 20
        var t = _tap(over)
        Gateway.awaitTimeoutMs = saved
        tryVerify(function() { return t.calls.length === 1 })
        return t
    }
    function test_a_late_answer_after_a_queued_status_applies_once() {
        var t = _tapSlow()
        compare(t.calls[0].ok, true)
        compare(t.calls[0].status, "queued")
        compare(t.calls[0].id, "")
        compare(InventoryStore.products.length, 0)
        var item = _items()[0]
        Gateway._finishOperation(item, { ok: true, results: _answer(item, false), idempotentReplay: false })
        compare(t.calls.length, 1, "the caller is not called again")
        compare(InventoryStore.products.length, 1)
        compare(ActivityLog.entries.length, 1)
    }
    function test_a_late_rejection_announces_one_message_with_the_typed_name() {
        var t = _tapSlow({ name: "Mango" })
        var item = _items()[0]
        Gateway._finishOperation(item, { ok: false, error: "mint-exhausted" })
        compare(t.calls.length, 1)
        compare(errSpy.count, 1)
        compare(errSpy.signalArguments[0][0], "inventory")
        verify(errSpy.signalArguments[0][1].indexOf("A queued product was not added.") === 0)
        compare(InventoryStore.products.length, 0)
    }
    function test_a_late_discard_announces_nothing() {
        _tapSlow()
        Gateway._finishOperation(_items()[0], { ok: false, error: "discarded", discarded: true })
        compare(errSpy.count, 0)
    }
    function test_a_replayed_answer_adds_no_product_locally() {
        var t = _tap()
        var item = _items()[0]
        Gateway._finishOperation(item, { ok: true, results: _answer(item, false), idempotentReplay: true })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, true)
        compare(t.calls[0].status, "applied")
        compare(t.calls[0].id, "PRD-001")
        compare(InventoryStore.getById("PRD-001"), null, "a replayed product is never written from the answer; the inventory is re-read instead")
        compare(InventoryStore.products.length, 0)
    }
    function test_an_unreadable_answer_is_unconfirmed_once_and_applies_nothing() {
        var t = _tap()
        var item = _items()[0]
        var damaged = _answer(item, false).filter(function(r) { return r.entity !== "activity" })
        Gateway._finishOperation(item, { ok: true, results: damaged, idempotentReplay: false })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, true)
        compare(t.calls[0].status, "unconfirmed")
        compare(t.calls[0].id, "")
        compare(ActivityLog.entries.length, 0)
        compare(StockBatchStore.batches.length, 0)
    }
    function test_stock_zero_adds_the_product_and_history_but_no_batch() {
        var t = _tap({ stock: 0, unitCost: undefined })
        var item = _items()[0]
        Gateway._finishOperation(item, { ok: true, results: _answer(item, false, true), idempotentReplay: false })
        compare(t.calls.length, 1)
        compare(t.calls[0].status, "applied")
        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].stock, 0)
        compare(StockBatchStore.batches.length, 0, "no batch for a zero-stock product")
        compare(TransactionStore.entries.length, 1)
        compare(ActivityLog.entries.length, 1)
        compare(SupplierStore.suppliers.length, 1, "no supplier was asked for")
    }
    function test_a_product_a_sync_landed_first_is_not_added_twice() {
        var t = _tap()
        var item = _items()[0]
        InventoryStore.products = [{ productId: "PRD-001", name: "Tomato", sku: "TO-1", category: "Veg", stock: 12, minStock: 2, price: 20,
                                     sellingPrice: 30, taxable: true, taxPercent: 5, size: "", unit: "kg", description: "Red", photoIds: [], supplierId: "" }]
        Gateway._finishOperation(item, { ok: true, results: _answer(item, false), idempotentReplay: false })
        compare(t.calls[0].status, "applied")
        compare(InventoryStore.products.length, 1, "one product, not two")
        compare(StockBatchStore.batches.length, 1, "the rest of the answer is still reflected")
        compare(ActivityLog.entries.length, 1)
    }
    function test_a_settled_add_leaves_no_bookkeeping_behind() {
        _tap({ party: "Newco" })
        var item = _items()[0]
        Gateway._finishOperation(item, { ok: true, results: _answer(item, true), idempotentReplay: false })
        compare(Object.keys(InventoryStore._addSettled).length, 0, "the signal consumed the settled flag")
        compare(Object.keys(InventoryStore._addNames).length, 0, "the typed name is forgotten once settled")
        _tap()
        var item2 = _items()[1]
        Gateway._finishOperation(item2, { ok: false, error: "conflict", opIndex: 2, conflict: true })
        compare(Object.keys(InventoryStore._addSettled).length, 0)
        compare(Object.keys(InventoryStore._addNames).length, 0)
    }
    function test_every_tap_is_its_own_operation() {
        _tap()
        _tap()
        var keys = _items().map(function(i) { return i.requestId })
        compare(keys.length, 2)
        verify(keys[0] !== keys[1])
    }
}
