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
// deduction + sale recording from scratch. See
// docs/superpowers/specs/2026-09-14-order-completion-double-submit-CHECKPOINT.md.
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
// NOT RUN IN THIS SANDBOX -- no Qt/qmltestrunner toolchain available
// (standing rule, see AGENTS.md). DataModel.qml is NOT a pragma
// Singleton, so it's instantiated directly as a child item here, same as
// tst_DataModel_adjustOrderSyncGuard.qml.
//
// Simulating the race: every store call in this suite resolves its
// callback SYNCHRONOUSLY (see tst_DataModel_adjustOrderSyncGuard.qml's
// header) -- there is no real network latency in this harness. That
// means a second _tryCompleteOrder call issued *after* the first one
// returns can never actually race it; the only way to get a genuinely
// "still in flight" first call is to have the SECOND call originate from
// INSIDE the first call's own still-executing callback chain. Both tests
// below temporarily stub StockBatchStore.consumeFifo to do exactly that
// -- fire the reentrant call from partway through the first call's FIFO
// consumption step, then let the original call proceed -- which is the
// direct in-process analogue of "second click arrives before the first
// click's write resolves."
TestCase {
    name: "DataModel_completeOrderReentrancy"

    DataModel { id: dm }

    // Holds the real StockBatchStore.consumeFifo while a test has it
    // stubbed, so cleanup() can always restore it. A declared property
    // here rather than an expando property on the (shared, pragma
    // Singleton) store itself, since QML property declarations are
    // guaranteed storage -- an ad hoc JS property tacked onto a
    // singleton is not a pattern used anywhere else in this suite.
    property var _originalConsumeFifo: null

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
    }

    function cleanup() {
        // Belt-and-suspenders restore in case a test fails mid-body
        // before reaching its own restore -- StockBatchStore is a
        // pragma Singleton shared across every test in this file (and
        // potentially this run), so a stuck stub would corrupt every
        // test after it.
        if (_originalConsumeFifo) {
            StockBatchStore.consumeFifo = _originalConsumeFifo
            _originalConsumeFifo = null
        }
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

    // Wires a stub onto StockBatchStore.consumeFifo that fires a second,
    // reentrant _tryCompleteOrder call for the same order the FIRST time
    // it's invoked, then defers to the real implementation. Returns
    // nothing; caller reads results via the closures it captures.
    function _stubReentrantConsumeFifo(onReentrant) {
        var real = StockBatchStore.consumeFifo
        _originalConsumeFifo = real
        var fired = false
        StockBatchStore.consumeFifo = function(productId, qty, cb) {
            if (!fired) {
                fired = true
                onReentrant()
            }
            real.call(StockBatchStore, productId, qty, cb)
        }
    }

    // ── the core regression: a second call while the first is still
    // resolving must be rejected, not re-run the whole completion ────────

    function test_second_call_while_first_still_in_flight_is_rejected() {
        var results = []
        _stubReentrantConsumeFifo(function() {
            dm._tryCompleteOrder("ORD-RACE-1", function(ok) { results.push(ok) })
        })

        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { results.push(ok) })

        StockBatchStore.consumeFifo = _originalConsumeFifo
        _originalConsumeFifo = null

        // The reentrant call resolves first (synchronously, from partway
        // through the outer call's own FIFO step) -- it must have been
        // rejected outright, not queued or merged.
        compare(results.length, 2, "both callbacks must have fired exactly once each")
        compare(results[0], false, "the reentrant call must be rejected while the first is still in flight")
        compare(results[1], true, "the original call must still succeed once it's actually alone")
        verify(dm.stockErrorMsg.length > 0, "must tell the caller why the reentrant attempt was rejected")
    }

    function test_stock_and_transaction_ledger_affected_only_once() {
        _stubReentrantConsumeFifo(function() {
            dm._tryCompleteOrder("ORD-RACE-1", function(ok) {})
        })

        dm._tryCompleteOrder("ORD-RACE-1", function(ok) {})

        StockBatchStore.consumeFifo = _originalConsumeFifo
        _originalConsumeFifo = null

        compare(InventoryStore.getById("SKU-1").stock, 4,
                "stock must be deducted exactly once (5 - 1), not twice")
        compare(StockBatchStore.getById("B1").qtyRemaining, 4,
                "the FIFO batch must be consumed exactly once, not twice")
        compare(TransactionStore.entries.length, 1,
                "exactly one sale ledger entry must be recorded, not one per attempt "
                + "-- this is what Transaction History / Product History / Sales "
                + "Analysis read from, and is exactly what doubled in the reported bug")
    }

    // ── the guard must not weaken the pre-existing status check ──────────

    function test_still_short_circuits_sequential_non_overlapping_completions() {
        var first = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { first = ok })
        compare(first, true, "the first, unraced call must succeed as before this fix")

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
}
