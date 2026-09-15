import QtQuick
import QtTest
import "../qml/model"

// Regression test for the double-completion bug Taher reported 2026-09-14
// (/superpowers:systematic-debugging): approving a pending order, then
// pressing Approve again before the first completion's Firestore round
// trip resolves (no busy indicator told the user one was in flight),
// deducted stock and recorded the sale TWICE. Order cart still showed the
// correct 1 item (the order's own product-line quantity is never itself
// duplicated -- only the SIDE EFFECTS of completion run twice), but
// Transaction History, Product History, and Sales Analysis all doubled.
//
// Root cause: _tryCompleteOrder's only "already completing" guard reads
// OrdersStore.getById(orderId).status, but that field only flips to
// "completed" at the very END of the async chain (inside
// _afterAllDeltas), so a second call arriving before the first resolves
// sees the SAME stale "pending" status and re-runs the entire stock
// deduction + sale recording from scratch.
//
// Fix: an explicit _completingOrderIds in-flight set, set synchronously
// at entry (before ANY async call) and cleared on every exit path --
// independent of OrdersStore's own (still-stale) status field. This is
// deliberately at the DataModel layer, not just OrderDetailDialog's new
// busy state, because LockManager's server-side acquireLock always
// re-grants a request from the SAME actorUid (functions/lib/lockLogic.js
// "sameHolder" check -- needed for renewal heartbeats), so a lock-based
// guard alone would NOT have stopped this. This also protects
// OrdersPage._approveAllPending(), which calls the same
// _tryCompleteOrder engine with no re-entrancy guard of its own.
//
// GENUINELY RUN VIA CI (this repo's qml-tests job), not just hand-traced
// -- and CI caught a real mistake in the first version of this file: it
// tried to reassign StockBatchStore.consumeFifo (a QML `function`
// declaration, compiled into the singleton as a read-only invokable) the
// way you'd stub a plain JS object's method. That throws "Cannot assign
// to read-only property" at runtime -- QML top-level function members are
// not mutable JS property slots, unlike a `property var` holding a
// function value. See SKILLS Skill 61.
//
// Because of that constraint (and because every store call in this
// suite's harness resolves its callback SYNCHRONOUSLY -- see
// tst_DataModel_adjustOrderSyncGuard.qml's header -- so a second
// _tryCompleteOrder call issued *after* the first one returns can never
// actually race it), the tests below verify the guard directly by
// pre-seeding _completingOrderIds to the state a genuinely-racing first
// call would have left it in, then confirming a second call is rejected
// BEFORE doing any work -- same style as tst_DataModel_adjustOrderSyncGuard.qml's
// own guard tests, which set TransactionStore.hasMore directly rather
// than orchestrating a real in-progress fetch.
TestCase {
    name: "DataModel_completeOrderReentrancy"

    DataModel { id: dm }

    function init() {
        OrdersStore.orders = [_pendingOrder()]
        InventoryStore.products = [_product()]
        StockBatchStore.batches = [_batch()]
        TransactionStore.entries = []
        TransactionStore.revision = 0
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        dm.stockErrorMsg = ""
        // dm is constructed once for this whole TestCase (not per test),
        // so its _completingOrderIds property survives across every test
        // function unless explicitly reset here -- without this line,
        // one test's guard state can silently leak into the next.
        dm._completingOrderIds = ({})
    }

    function _product() {
        return {
            productId: "SKU-1", name: "Widget", sku: "W1", category: "", description: "",
            unit: "pc", price: 100, sellingPrice: 100, taxable: false, taxPercent: 0,
            size: "", stock: 5, minStock: 0
        }
    }

    function _batch() {
        return {
            batchId: "B1", productId: "SKU-1", supplierId: "S1",
            qtyReceived: 5, qtyRemaining: 5, unitCost: 50,
            receivedDate: "2026-09-01T00:00:00.000Z", poId: "", note: "",
            createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-01T00:00:00.000Z"
        }
    }

    function _pendingOrder() {
        return {
            orderId: "ORD-RACE-1", customer: "Test Customer", status: "pending",
            date: "2026-09-14", email: "", phone: "", notes: "",
            orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: 1 }]
        }
    }

    // ── the core regression: a call must be rejected while the order is
    // already marked in-flight, before doing ANY work ─────────────────────

    function test_rejected_while_already_in_flight() {
        // Simulates the exact state a genuinely-racing first call leaves
        // behind between its own entry and its callback -- the state a
        // second click's call would see if it arrived mid-chain.
        dm._completingOrderIds = { "ORD-RACE-1": true }

        var result = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { result = ok })

        compare(result, false, "must be rejected while the guard marks this order in-flight")
        verify(dm.stockErrorMsg.length > 0, "must tell the caller why, not fail silently")
    }

    function test_rejection_has_no_side_effects() {
        dm._completingOrderIds = { "ORD-RACE-1": true }

        dm._tryCompleteOrder("ORD-RACE-1", function(ok) {})

        // This is the property that actually prevents the reported bug:
        // rejecting must happen BEFORE any stock/ledger work, not just
        // eventually resolve to false.
        compare(InventoryStore.getById("SKU-1").stock, 5,
                "no stock must be touched by a rejected in-flight attempt")
        compare(StockBatchStore.getById("B1").qtyRemaining, 5,
                "no FIFO batch must be touched by a rejected in-flight attempt")
        compare(TransactionStore.entries.length, 0,
                "no ledger entry must be written by a rejected in-flight attempt -- this is "
                + "exactly what Transaction History / Product History / Sales Analysis read "
                + "from, and exactly what doubled in the reported bug")
        compare(OrdersStore.orders[0].status, "pending",
                "the order's own status must be untouched by a rejected in-flight attempt")
    }

    // ── the guard must not weaken the pre-existing status check, and must
    // not linger after a call actually finishes ───────────────────────────

    function test_unraced_call_still_succeeds_and_clears_the_guard() {
        var first = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { first = ok })
        compare(first, true, "an ordinary, unraced call must still succeed exactly as before this fix")
        compare(InventoryStore.getById("SKU-1").stock, 4, "stock must be deducted normally")
        compare(TransactionStore.entries.length, 1, "one sale ledger entry must be recorded normally")
        verify(!dm._completingOrderIds["ORD-RACE-1"],
                "the guard must be cleared once the call actually finishes -- otherwise every "
                + "later legitimate action on this order (adjustments, a future re-open) would "
                + "be permanently locked out")

        // A second, fully SEQUENTIAL call after the first has genuinely
        // finished (status now "completed" -- the pre-existing guard)
        // must still short-circuit to true without re-deducting, exactly
        // as it did before this fix.
        var second = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { second = ok })

        compare(second, true, "an already-completed order must still short-circuit successfully")
        compare(InventoryStore.getById("SKU-1").stock, 4,
                "no further deduction on the already-completed short-circuit")
        compare(TransactionStore.entries.length, 1,
                "no further ledger entry on the already-completed short-circuit")
    }

    function test_missing_order_still_rejects_cleanly() {
        var result = null
        dm._tryCompleteOrder("ORD-DOES-NOT-EXIST", function(ok) { result = ok })
        compare(result, false, "an unknown order id must still fail as before this fix")
    }

    function test_guard_clears_even_on_stock_validation_failure() {
        // Exercises the OTHER early-exit path (insufficient stock),
        // confirming the guard's cleanup on that branch (added alongside
        // the two _afterAllDeltas branches) actually runs -- a leaked
        // guard entry here would permanently lock out retrying the order
        // once stock is replenished.
        InventoryStore.products = [{
            productId: "SKU-1", name: "Widget", sku: "W1", category: "", description: "",
            unit: "pc", price: 100, sellingPrice: 100, taxable: false, taxPercent: 0,
            size: "", stock: 0, minStock: 0
        }]

        var result = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { result = ok })

        compare(result, false, "must fail when stock is insufficient, as before this fix")
        verify(!dm._completingOrderIds["ORD-RACE-1"],
                "the guard must be cleared on the stock-validation-failure path too")
    }
}
