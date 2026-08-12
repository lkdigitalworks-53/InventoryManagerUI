import QtQuick
import QtTest
import "../qml/model"

// Regression test for the ledger-sync race Taher found 2026-08-11: complete
// an order -> verify in Firestore -> close the app -> reopen -> return an
// item promptly. TransactionStore re-fetches its whole transaction history
// page by page on cold start (see TransactionStore.qml's Component.
// onCompleted), and because transaction doc IDs are locally generated with
// an embedded, ever-increasing timestamp ("tx-<kind>-<Date.now()>-<rand>"),
// Firestore's ascending orderBy(__name__) pagination surfaces the OLDEST
// transactions first and the NEWEST — including the very sale a fresh
// return needs to net against — last. If a completed-order return runs
// before that sync finishes, OrdersStore.applyAdjustment's ledger-based
// total (TransactionStore.totalsForOrder) sums an incomplete ledger and
// silently produces a wrong total.
//
// Fix: DataModel._tryAdjustOrder now refuses to touch a completed order
// while TransactionStore.hasMore is true, rather than trust a partial
// ledger. See docs/superpowers/specs/2026-08-11-ledger-sync-race-CHECKPOINT.md
// and SKILLS Skill 38.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// DataModel.qml is NOT a pragma Singleton (unlike the stores), so it's
// instantiated directly as a child item here rather than referenced by
// name — it has no Component.onCompleted and no dependency on the
// dispatcher/_logicBus wiring for the functions under test, so this is
// safe to do standalone.
TestCase {
    name: "DataModel_adjustOrderSyncGuard"

    DataModel { id: dm }

    function init() {
        OrdersStore.orders = []
        TransactionStore.entries = []
        TransactionStore.revision = 0
        InventoryStore.products = []
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        dm.stockErrorMsg = ""
    }

    function _completedOrder() {
        return {
            orderId: "ORD-SYNC-1", customer: "Test Customer", status: "completed",
            date: "2026-08-11", email: "", phone: "", notes: "",
            orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: 2,
                         consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 50 }] }]
        }
    }

    function _returnToOneUnit() {
        return [{ productId: "SKU-1", name: "Widget", price: 100, quantity: 1 }]
    }

    // ── the core regression: refuse while the ledger might be incomplete ───

    function test_refuses_completed_order_adjustment_while_transaction_history_still_syncing() {
        OrdersStore.orders = [_completedOrder()]
        TransactionStore.hasMore = true // still paginating in older transactions

        var result = null
        dm._tryAdjustOrder("ORD-SYNC-1", _returnToOneUnit(), "return", "resellable", "",
                            function(ok) { result = ok })

        compare(result, false, "must refuse rather than commit against an unverified ledger")
        verify(dm.stockErrorMsg.length > 0, "must tell the user why, not fail silently")
        verify(dm.stockErrorMsg.toLowerCase().indexOf("sync") >= 0)
    }

    function test_refusal_has_no_side_effects() {
        OrdersStore.orders = [_completedOrder()]
        TransactionStore.hasMore = true

        dm._tryAdjustOrder("ORD-SYNC-1", _returnToOneUnit(), "return", "resellable", "", function(ok) {})

        compare(TransactionStore.entries.length, 0,
                "no return ledger entry should be written for a refused adjustment")
        compare(OutboxStore.pendingCount, 0,
                "no order mutation should be enqueued for a refused adjustment")
        compare(OrdersStore.orders[0].products[0].quantity, 2,
                "the order's own line data must be untouched")
    }

    // ── once synced, the exact same call must succeed as before ────────────

    function test_proceeds_normally_once_transaction_history_is_synced() {
        OrdersStore.orders = [_completedOrder()]
        InventoryStore.products = [{
            productId: "SKU-1", name: "Widget", sku: "W1", category: "", description: "",
            unit: "pc", price: 100, sellingPrice: 100, taxable: false, taxPercent: 0,
            size: "", stock: 10, minStock: 0
        }]
        TransactionStore.hasMore = false // fully synced

        var result = null
        dm._tryAdjustOrder("ORD-SYNC-1", _returnToOneUnit(), "return", "resellable", "",
                            function(ok) { result = ok })

        compare(result, true, "must proceed exactly as it did before this fix once the ledger is complete")
        compare(dm.stockErrorMsg, "")
        verify(TransactionStore.entries.length > 0, "the return should be recorded once allowed to proceed")
        compare(OutboxStore.pendingCount, 1, "the order mutation should be enqueued once allowed to proceed")
    }

    // ── the guard must not weaken the pre-existing status check ────────────

    function test_still_refuses_non_completed_orders_regardless_of_sync_state() {
        var pending = _completedOrder()
        pending.status = "pending"
        OrdersStore.orders = [pending]
        TransactionStore.hasMore = false // fully synced -- must still refuse, for the OTHER reason

        var result = null
        dm._tryAdjustOrder("ORD-SYNC-1", _returnToOneUnit(), "return", "resellable", "",
                            function(ok) { result = ok })

        compare(result, false)
        compare(dm.stockErrorMsg, "Only completed orders can be adjusted",
                "must still be the pre-existing status message, not the new sync message")
    }
}
