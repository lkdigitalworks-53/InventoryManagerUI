import QtQuick
import QtTest
import "../qml/model"

// P1 S2d-1: the four DataModel call sites that move product.stock now say WHY to the ledger:
//   customer return (restock)   -> sales_return  "Return - order <id>"
//   order reopened              -> sales_return  "Order reopened - sale reversed - order <id>"
//   exchange / modify-up add    -> sale          "Exchange / modify - order <id>"
//   failed-exchange rollback    -> sales_return  "Rollback - order edit failed - order <id>"
// A DAMAGED return writes no stock row at all (units stay written off; S2e Q4 decides if that gets a
// destroyed row). Server answers are simulated: Gateway._answerDeltaCallbacks, then OutboxStore.markSent
// to mimic "sent and gone" (the network stays shut: AuthStore.idToken is empty).
// Harness copied from tst_DataModel_adjustOrderSyncGuard.qml. NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "DataModel_movementKinds"

    DataModel { id: dm }

    function init() {
        OrdersStore.orders = []
        TransactionStore.entries = []
        TransactionStore.revision = 0
        TransactionStore.hasMore = false
        InventoryStore.products = [_prod("SKU-1", 10), _prod("SKU-2", 5), _prod("SKU-3", 5)]
        StockBatchStore.batches = [_batch("B1", "SKU-1", 0), _batch("B2", "SKU-2", 5), _batch("B3", "SKU-3", 5)]
        OutboxStore.clear()
        Gateway.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        AuthStore.isAuthenticated = false
        AuthService.isOnline = true
        dm.stockErrorMsg = ""
    }
    function cleanup() { OutboxStore.clear() }

    function _prod(id, stock) {
        return { productId: id, name: "Widget " + id, sku: id, category: "", description: "", unit: "pc",
                 price: 100, sellingPrice: 100, taxable: false, taxPercent: 0, size: "", stock: stock, minStock: 0 }
    }
    function _batch(id, pid, remaining) {
        return { batchId: id, productId: pid, supplierId: "S1", qtyReceived: 5, qtyRemaining: remaining, unitCost: 50,
                 receivedDate: "2026-08-01T00:00:00.000Z", poId: "", note: "",
                 createdAt: "2026-08-01T00:00:00.000Z", updatedAt: "2026-08-01T00:00:00.000Z" }
    }
    function _order() {
        return {
            orderId: "ORD-SYNC-1", customer: "Test Customer", status: "completed", date: "2026-08-11",
            email: "", phone: "", notes: "", orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: 2,
                         consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 50 }] }]
        }
    }
    function _line(id, qty) { return { productId: id, name: "Widget " + id, price: 100, quantity: qty } }
    function _inv(id) {
        return OutboxStore.items.filter(function(i) { return i.entity === "inventory" && i.entityId === id && i.deltas })
    }
    function _batchItem(id) {
        return OutboxStore.items.filter(function(i) { return i.entity === "stock_batch" && i.entityId === id && i.deltas })[0]
    }
    // Pretend the server answered this queued delta and it left the outbox.
    function _answer(item, result) {
        verify(item !== undefined, "expected a queued delta to answer")
        Gateway._answerDeltaCallbacks(item.requestId, result)
        OutboxStore.markSent(item.requestId)
    }

    // ── customer return ──────────────────────────────────────────────────
    function test_a_resellable_return_queues_one_sales_return_row_with_the_order_id() {
        OrdersStore.orders = [_order()]
        var ok = null
        dm._tryAdjustOrder("ORD-SYNC-1", [_line("SKU-1", 1)], "return", "resellable", "", function(r) { ok = r })
        compare(ok, true)
        var items = _inv("SKU-1")
        compare(items.length, 1)
        compare(items[0].deltas.stock, 1)
        compare(items[0].movements.length, 1)
        compare(items[0].movements[0].kind, "sales_return")
        compare(items[0].movements[0].qty, 1)
        compare(items[0].movements[0].reason, "Return - order ORD-SYNC-1")
    }
    function test_a_damaged_return_writes_no_stock_row_at_all() {
        OrdersStore.orders = [_order()]
        dm._tryAdjustOrder("ORD-SYNC-1", [_line("SKU-1", 1)], "return", "damaged", "", function() {})
        compare(_inv("SKU-1").length, 0, "damaged units stay written off; no inventory delta, no row (S2e Q4)")
    }
    function test_returning_every_unit_credits_the_full_quantity() {
        OrdersStore.orders = [_order()]
        dm._tryAdjustOrder("ORD-SYNC-1", [_line("SKU-1", 0)], "return", "resellable", "", function() {})
        var items = _inv("SKU-1")
        compare(items.length, 1)
        compare(items[0].movements[0].qty, 2)
        compare(items[0].deltas.stock, 2)
    }

    // ── reopen ───────────────────────────────────────────────────────────
    function test_reopening_a_completed_order_queues_a_sales_return_per_line() {
        dm._reverseCompletedOrder(_order())
        var items = _inv("SKU-1")
        compare(items.length, 1)
        compare(items[0].deltas.stock, 2)
        compare(items[0].movements[0].kind, "sales_return")
        compare(items[0].movements[0].qty, 2)
        compare(items[0].movements[0].reason, "Order reopened - sale reversed - order ORD-SYNC-1")
    }
    function test_reopening_an_order_without_a_product_id_queues_no_stock_row() {
        var o = _order()
        o.products[0].productId = ""
        dm._reverseCompletedOrder(o)
        compare(OutboxStore.items.filter(function(i) { return i.entity === "inventory" }).length, 0)
    }

    // ── exchange / modify-up addition ────────────────────────────────────
    function test_an_added_unit_queues_a_sale_row_once_its_batch_consumption_is_confirmed() {
        OrdersStore.orders = [_order()]
        var ok = null
        dm._tryAdjustOrder("ORD-SYNC-1", [_line("SKU-1", 2), _line("SKU-2", 1)], "exchange", "resellable", "",
                           function(r) { ok = r })
        compare(_inv("SKU-2").length, 0, "no stock delta before the FIFO consumption is confirmed")
        _answer(_batchItem("B2"), { ok: true, after: { qtyRemaining: 4 } })
        var items = _inv("SKU-2")
        compare(items.length, 1)
        compare(items[0].deltas.stock, -1)
        compare(items[0].floors.stock, 0, "reject mode: a floor, not a clamp")
        compare(items[0].clamps.stock, undefined)
        compare(items[0].movements.length, 1)
        compare(items[0].movements[0].kind, "sale")
        compare(items[0].movements[0].qty, -1)
        compare(items[0].movements[0].reason, "Exchange / modify - order ORD-SYNC-1")
        _answer(items[0], { ok: true, after: { stock: 4 } })
        compare(ok, true)
    }

    // ── rollback of a failed exchange ────────────────────────────────────
    function test_a_failed_sibling_rolls_back_the_confirmed_addition_with_a_sales_return() {
        OrdersStore.orders = [_order()]
        var ok = null
        dm._tryAdjustOrder("ORD-SYNC-1", [_line("SKU-1", 2), _line("SKU-2", 1), _line("SKU-3", 1)],
                           "exchange", "resellable", "", function(r) { ok = r })
        _answer(_batchItem("B2"), { ok: true, after: { qtyRemaining: 4 } })
        _answer(_batchItem("B3"), { ok: true, after: { qtyRemaining: 4 } })
        compare(_inv("SKU-2").length, 1)
        compare(_inv("SKU-3").length, 1)
        _answer(_inv("SKU-2")[0], { ok: true, after: { stock: 4 } })
        _answer(_inv("SKU-3")[0], { ok: false, error: "insufficient-quantity", current: 0 })
        compare(ok, false)
        var undo = _inv("SKU-2")
        compare(undo.length, 1, "the confirmed SKU-2 addition is undone")
        compare(undo[0].deltas.stock, 1)
        compare(undo[0].movements[0].kind, "sales_return")
        compare(undo[0].movements[0].qty, 1)
        compare(undo[0].movements[0].reason, "Rollback - order edit failed - order ORD-SYNC-1")
        compare(_inv("SKU-3").length, 0, "the rejected line never moved stock, so nothing to undo")
    }
}
