import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// PR #183 review sweep, finding D-1: while a restock of a product is queued, an edit or a delete of that product
// is refused up front. The local copy does not hold the restock's stock yet, so a whole-record write made now
// would be sent after the restock landed with a stale `before`, and the server's compare-and-swap would answer
// 409 and leave a stuck change. The same cases run in Node against the REAL function bodies and the REAL server
// code in functions/test/restockHold.test.js (including the proof of the 409); this file is the qmltestrunner copy
// for the QML engine (store, DataModel dispatch, outbox).
// NOT RUN IN THIS SANDBOX: no Qt/qmltestrunner toolchain here. CI is the oracle.
TestCase {
    name: "InventoryStore_restockHold"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }
    SignalSpy { id: errSpy; target: testLogic; signalName: "errorOccurred" }
    SignalSpy { id: updatedSpy; target: testLogic; signalName: "productUpdated" }
    SignalSpy { id: deletedSpy; target: testLogic; signalName: "productDeleted" }

    function init() {
        OutboxStore.clear()
        Gateway.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        AuthStore.isAuthenticated = false
        AuthStore.role = "owner"
        AuthService.isOnline = false          // offline: a restock stays queued, which is the case under test
        ActivityLog.clear()
        InventoryStore._pendingDeletes = ({})
        InventoryStore._restockSettled = ({})
        InventoryStore._restockNames = ({})
        InventoryStore.products = [_product("p1"), _product("p2")]
        SupplierStore.suppliers = [{ supplierId: "SUP-009", name: "Acme Farms" }]
        StockBatchStore.batches = [{ batchId: "b1", productId: "p1", qtyRemaining: 3 }]
        StockBatchStore._pendingMints = []
        TransactionStore.entries = []
        OrdersStore.orders = []
        dm.stockErrorMsg = ""
        errSpy.clear()
        updatedSpy.clear()
        deletedSpy.clear()
    }
    function cleanup() { OutboxStore.clear() }

    function _product(id) {
        return { productId: id, name: id === "p1" ? "Tomato" : "Onion", category: "Veg", sku: "", unit: "pc",
                 price: 12.5, sellingPrice: 20, stock: 10, minStock: 0 }
    }
    function _restockItem() { return OutboxStore.items.filter(function(i) { return i.opType === "restock" })[0] }
    function _queueRestock(id) {
        var out = { calls: [] }
        InventoryStore.restock(id || "p1", 5, "", 10, "weekly", function(ok, queued, refusal) {
            out.calls.push({ ok: ok, queued: queued, refusal: refusal }) })
        compare(out.calls.length, 1)
        compare(out.calls[0].queued, true)
        return out
    }
    function _editsFor(id) { return OutboxStore.items.filter(function(i) { return i.entity === "inventory" && i.entityId === id }).length }

    // -- the store ----------------------------------------------------------
    function test_restockHoldMessage_is_empty_without_a_queued_restock() {
        compare(InventoryStore.restockHoldMessage("p1"), "")
    }

    function test_restockHoldMessage_says_wait_for_a_queued_restock_and_only_for_that_product() {
        _queueRestock("p1")
        compare(InventoryStore.restockHoldMessage("p1"), InventoryStore.restockPendingMessage)
        compare(InventoryStore.restockHoldMessage("p2"), "")
    }

    function test_restockHoldMessage_says_stuck_change_when_the_restock_itself_is_parked() {
        _queueRestock("p1")
        OutboxStore.setStuckMeta(_restockItem().requestId, { failures: 5, stuck: true, terminal: true })
        compare(InventoryStore.restockHoldMessage("p1"), InventoryStore.parkedWriteMessage)
    }

    function test_updateRefusal_and_updateProduct_refuse_an_edit_while_a_restock_is_queued() {
        _queueRestock("p1")
        compare(InventoryStore.updateRefusal("p1", { name: "Tomato 2" }), InventoryStore.restockPendingMessage)
        compare(InventoryStore.updateProduct("p1", { name: "Tomato 2" }, ""), InventoryStore.restockPendingMessage)
        compare(InventoryStore.getById("p1").name, "Tomato", "nothing changed locally")
        compare(OutboxStore.items.length, 1, "nothing queued behind the restock")
        compare(_editsFor("p1"), 0)
    }

    function test_an_edit_of_another_product_is_not_held() {
        _queueRestock("p1")
        compare(InventoryStore.updateRefusal("p2", { name: "Onion 2" }), "")
        verify(InventoryStore.updateProduct("p2", { name: "Onion 2" }, "") === undefined)
        compare(InventoryStore.getById("p2").name, "Onion 2")
        compare(_editsFor("p2"), 1)
        compare(_editsFor("p1"), 0, "p1 has only its restock operation, no plain edit")
    }

    function test_the_hold_wins_over_the_size_message() {
        _queueRestock("p1")
        var huge = ""
        for (var i = 0; i < 1100; ++i) huge += new Array(1025).join("x")
        compare(InventoryStore.updateRefusal("p1", { description: huge }), InventoryStore.restockPendingMessage)
    }

    function test_the_size_message_is_unchanged_without_a_queued_restock() {
        var huge = ""
        for (var i = 0; i < 1100; ++i) huge += new Array(1025).join("x")
        compare(InventoryStore.updateRefusal("p1", { description: huge }), InventoryStore.tooLargeMessage)
        compare(InventoryStore.updateRefusal("p1", { name: "ok" }), "")
    }

    function test_deleteProduct_is_refused_while_a_restock_is_queued_and_changes_nothing() {
        _queueRestock("p1")
        compare(InventoryStore.deleteProduct("p1"), InventoryStore.restockPendingMessage)
        verify(InventoryStore.getById("p1") !== null)
        compare(StockBatchStore.batches.length, 1)
        compare(OutboxStore.items.length, 1)
        compare(Object.keys(InventoryStore._pendingDeletes).length, 0)
    }

    function test_deleteProduct_with_a_parked_restock_names_the_stuck_change() {
        _queueRestock("p1")
        OutboxStore.setStuckMeta(_restockItem().requestId, { failures: 5, stuck: true, terminal: true })
        compare(InventoryStore.deleteProduct("p1"), InventoryStore.parkedWriteMessage)
        verify(InventoryStore.getById("p1") !== null)
    }

    function test_the_hold_ends_when_the_restock_leaves_the_outbox() {
        _queueRestock("p1")
        verify(InventoryStore.restockHoldMessage("p1") !== "")
        OutboxStore.clear()
        compare(InventoryStore.restockHoldMessage("p1"), "")
        compare(InventoryStore.updateRefusal("p1", { name: "Tomato 2" }), "")
    }

    // -- through DataModel (what the UI actually calls) --------------------
    function test_logic_updateProduct_says_why_and_emits_no_productUpdated() {
        _queueRestock("p1")
        testLogic.updateProduct("p1", { name: "Tomato 2" }, "")
        compare(errSpy.count, 1)
        compare(errSpy.signalArguments[0][0], "inventory")
        compare(errSpy.signalArguments[0][1], InventoryStore.restockPendingMessage)
        compare(updatedSpy.count, 0)
        compare(InventoryStore.getById("p1").name, "Tomato")
    }

    function test_logic_deleteProduct_says_why_and_emits_no_productDeleted() {
        _queueRestock("p1")
        testLogic.deleteProduct("p1")
        compare(errSpy.count, 1)
        compare(errSpy.signalArguments[0][1], InventoryStore.restockPendingMessage)
        compare(deletedSpy.count, 0)
        verify(InventoryStore.getById("p1") !== null)
    }

    function test_logic_updateProduct_still_works_for_a_product_with_no_queued_restock() {
        testLogic.updateProduct("p2", { name: "Onion 2" }, "")
        compare(errSpy.count, 0)
        compare(updatedSpy.count, 1)
        compare(InventoryStore.getById("p2").name, "Onion 2")
    }
}
