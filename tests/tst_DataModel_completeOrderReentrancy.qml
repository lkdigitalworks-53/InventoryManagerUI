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
// -- and CI caught two real mistakes in earlier versions of this file:
//
// 1. Tried to reassign StockBatchStore.consumeFifo to simulate a race --
//    throws "Cannot assign to read-only property" at runtime. A QML
//    `function` declaration compiles to a read-only invokable member, not
//    a mutable JS property the way a plain object's method would be. See
//    SKILLS Skill 61.
//
// 2. Assumed _tryCompleteOrder's happy path resolves its callback
//    SYNCHRONOUSLY, the way every other DataModel orchestration function
//    in this test suite does (see tst_DataModel_adjustOrderSyncGuard.qml's
//    header). It does NOT: deductStock's callback is wired directly to
//    Gateway.recordDelta's own callback (InventoryStore.qml), which only
//    fires once a REAL XMLHttpRequest round trip to the Cloud Function
//    completes (Gateway.qml's _sendDelta) -- there is no local-apply
//    shortcut the way _tryAdjustOrder's callback-LESS creditStockNoBatch/
//    restoreFifo have. With AuthStore.idToken empty (this suite's
//    "offline" convention), _sendDelta returns immediately without ever
//    invoking the callback at all (see its `if (!AuthStore.idToken...)
//    return` guard) -- so in THIS harness, with no live emulator, a
//    genuine completion's callback simply never resolves. This isn't a
//    bug to work around; it's exactly the real "still in flight" state
//    the guard exists to protect against, and the tests below use it
//    directly instead of manufacturing a fake one. See SKILLS Skill 62.
//    The genuine happy-path (a real Cloud Function actually returning
//    ok:true) is out of reach for plain `qmltestrunner` and belongs to
//    the E2E/on-device layer -- see the test plan.
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

    // ── the core regression, using two REAL sequential calls ─────────────
    //
    // The first call's own callback genuinely never resolves in this
    // harness (see header) -- so by the time the second call is issued,
    // right after, the first call's _completingOrderIds entry is still
    // set exactly as it would be mid-network-round-trip in production.
    // No monkey-patching or manual state seeding needed: this is the
    // real code path, hitting the real (never-resolving-here) guard.

    function test_second_call_rejected_while_first_still_in_flight() {
        var firstResult = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { firstResult = ok })

        var secondResult = null
        dm._tryCompleteOrder("ORD-RACE-1", function(ok) { secondResult = ok })

        compare(firstResult, null,
                "the first call's callback should not have resolved yet in this harness (no "
                + "live Gateway backend) -- if this starts failing, Gateway's synchronous-vs-async "
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
                "the retry itself proceeds into the (here, never-resolving) Gateway round trip "
                + "rather than being rejected by a leftover guard entry -- see header")
    }
}
