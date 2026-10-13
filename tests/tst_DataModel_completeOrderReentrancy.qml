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
// "completed" at the very END of the async chain, so a second call
// arriving before the first resolves sees the SAME stale "pending" status
// and re-runs the entire stock deduction + sale recording from scratch.
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
// UPDATED for the C-3 atomic-operation rewrite (Task 10, 2026-09-26; see
// tst_DataModel_completeOrderAtomic.qml for the fuller suite around that
// rewrite). The guard itself, and every assertion below, is unchanged --
// only HOW a genuine "still in flight" window is produced changed, because
// it stopped being true that a queued completion's callback simply never
// resolves in this harness:
//
// Before Task 10, deductStock's callback was wired directly to a real
// XMLHttpRequest round trip (Gateway.qml's _sendDelta), which returns
// immediately without ever calling back when AuthStore.idToken is empty --
// so "offline" WAS "never resolves" in this harness, and that's what these
// tests exploited for a genuine in-flight window.
//
// After Task 10, completion goes through Gateway.recordOperation, whose
// callback fires SYNCHRONOUSLY unless BOTH AuthService.isOnline is true AND
// awaitServer is requested (DataModel passes awaitServer: online) -- so the
// old "AuthStore.idToken empty" setup now resolves the FIRST call
// synchronously (queued) before a second call could ever race it; there is
// no window left to test through that door. The genuine in-flight window
// now exists only in the online+awaiting case, where recordOperation
// registers a waiter (Gateway.qml's _addOperationWaiter) that does not
// resolve until something calls Gateway._finishOperation for that key --
// which these tests, deliberately, never do. See
// tst_Gateway.qml's own recordOperation tests for the same technique.
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
        // Online + awaiting is what now produces a genuine in-flight window
        // (see the header) -- recordOperation registers a waiter instead of
        // resolving immediately, and nothing in this file ever answers it.
        AuthService.isOnline = true
        dm.stockErrorMsg = ""
        // dm is constructed once for this whole TestCase (not per test),
        // so its _completingOrderIds/_openCompletions properties survive
        // across every test function unless explicitly reset here --
        // without this, one test's guard state can silently leak into the
        // next.
        dm._completingOrderIds = ({})
        dm._openCompletions = ({})
    }

    function cleanup() {
        AuthService.isOnline = false
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

    // ── the core regression, using two REAL sequential calls ─────────────
    //
    // The first call's own callback genuinely does not resolve within this
    // test function (see header: online + awaitServer registers a waiter
    // that only Gateway._finishOperation can resolve, and nothing here
    // calls it) -- so by the time the second call is issued, right after,
    // the first call's _completingOrderIds entry is still set exactly as
    // it would be mid-network-round-trip in production. No monkey-patching
    // or manual state seeding needed: this is the real code path, hitting
    // the real (still-open-here) guard.

    function test_second_call_rejected_while_first_still_in_flight() {
        var firstResult = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { firstResult = ok })

        var secondResult = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { secondResult = ok })

        compare(firstResult, null,
                "the first call's callback should not have resolved yet in this harness (an awaited "
                + "operation with no answer) -- if this starts failing, Gateway's synchronous-vs-async "
                + "behavior changed and this test needs revisiting, not just re-asserting")
        compare(secondResult, false, "the second call must be rejected while the first is still in flight")
        verify(dm.stockErrorMsg.length > 0, "must tell the caller why the reentrant attempt was rejected")
    }

    function test_second_call_has_no_side_effects_while_first_in_flight() {
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) {})
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) {})

        // This is the property that actually prevents the reported bug:
        // the second call must touch nothing, not just eventually
        // resolve to false.
        compare(InventoryStore.getById("SKU-1").stock, 5,
                "no stock must be touched by the second, rejected call")
        compare(StockBatchStore.getById("B1").qtyRemaining, 5,
                "no FIFO batch must be touched by the second, rejected call")
        compare(TransactionStore.entries.length, 0,
                "no ledger entry must be written by the second, rejected call -- this is exactly "
                + "what Transaction History / Product History / Sales Analysis read from, and "
                + "exactly what doubled in the reported bug")
        compare(OrdersStore.orders[0].status, "pending",
                "the order's own status must be untouched by the second, rejected call")
    }

    // ── the guard must not weaken the pre-existing status short-circuit,
    // and must clear on the (synchronous, local) failure path ────────────

    function test_already_completed_order_short_circuits_unaffected_by_new_guard() {
        // Seeds the postcondition directly rather than driving a real
        // completion to it (which needs a live Gateway backend -- see
        // header) -- same convention tst_DataModel_adjustOrderSyncGuard.qml
        // uses for its own guard precondition.
        OrdersStore.orders = [{
            orderId: "ORD-RACE-1", customer: "Test Customer", status: "completed",
            date: "2026-09-14", email: "", phone: "", notes: "",
            orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: 1 }]
        }]

        var result = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { result = ok })

        compare(result, true, "an already-completed order must short-circuit to true, unaffected by the new guard")
        compare(InventoryStore.getById("SKU-1").stock, 5, "must do zero further work")
    }

    function test_missing_order_still_rejects_cleanly() {
        var result = null
        dm._tryCompleteOrder("ORD-DOES-NOT-EXIST", function(ok) { result = ok })
        compare(result, false, "an unknown order id must still fail as before this fix")
    }

    function test_guard_clears_even_on_stock_validation_failure() {
        // Exercises the OTHER early-exit path (insufficient stock) --
        // purely local/synchronous, unlike the Gateway-dependent success
        // path above, so it's genuine proof the cleanup code actually
        // runs, not just present in the diff. A leak here would
        // permanently lock out retrying the order once stock is
        // replenished.
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

        // With the guard correctly cleared, a RETRY after restocking must
        // not be locked out by a leaked guard entry.
        InventoryStore.products = [_product()]
        var retryResult = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { retryResult = ok })
        compare(retryResult, null,
                "the retry itself proceeds into the (here, awaited-but-never-answered) Gateway round "
                + "trip rather than being rejected by a leftover guard entry -- see header")
    }
}
