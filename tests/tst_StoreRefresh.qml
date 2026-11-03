import QtQuick
import QtTest
import "../qml/model"

// Real store singletons, no network: only the parts of the L4a refresh that do not call FirebaseService are
// exercised here (commit, finish/cancel, refusal to start). The paging and the guard are run against the real
// function bodies by .github/scripts/__tests__/refreshBehavior.test.js (Node sandbox). This file proves the six
// stores COMPILE with the new members and honour the same contract in the real QML engine.
// Design: docs/superpowers/specs/2026-11-02-l4a-resume-refresh-design.md
// Test plan: docs/superpowers/test-plans/2026-11-02-l4a-resume-refresh-test-plan.md
TestCase {
    name: "StoreRefresh"

    function _stores() {
        return [
            { s: OrdersStore, list: "orders" }, { s: InventoryStore, list: "products" }, { s: StockBatchStore, list: "batches" },
            { s: SupplierStore, list: "suppliers" }, { s: StaffStore, list: "staff" }, { s: TransactionStore, list: "entries" }
        ]
    }

    function init() {
        var all = _stores()
        for (var i = 0; i < all.length; ++i) {
            all[i].s._cancelRefresh()
            all[i].s.loadingMore = false
            all[i].s._resetPending = false
        }
    }

    function test_every_store_exposes_the_refresh_contract() {
        var all = _stores()
        for (var i = 0; i < all.length; ++i) {
            var s = all[i].s
            compare(typeof s.refreshFromFirebase, "function", all[i].list)
            compare(typeof s._cancelRefresh, "function", all[i].list)
            compare(s.refreshing, false, all[i].list)
        }
    }

    function test_refuses_to_start_while_loading_resetting_or_refreshing() {
        var all = _stores()
        for (var i = 0; i < all.length; ++i) {
            var s = all[i].s
            s.loadingMore = true
            compare(s.refreshFromFirebase(function() { return true }, function() {}), false, all[i].list + " loadingMore")
            s.loadingMore = false
            s._resetPending = true
            compare(s.refreshFromFirebase(function() { return true }, function() {}), false, all[i].list + " resetPending")
            s._resetPending = false
            s.refreshing = true
            compare(s.refreshFromFirebase(function() { return true }, function() {}), false, all[i].list + " refreshing")
            s.refreshing = false
        }
    }

    function test_cancel_with_nothing_running_is_a_no_op() {
        var all = _stores()
        for (var i = 0; i < all.length; ++i) {
            var seq = all[i].s._refreshSeq
            all[i].s._cancelRefresh()
            compare(all[i].s._refreshSeq, seq, all[i].list)
        }
    }

    function test_cancel_answers_superseded_exactly_once() {
        var all = _stores()
        for (var i = 0; i < all.length; ++i) {
            var s = all[i].s
            var seen = []
            s.refreshing = true
            s._refreshDone = function(k) { seen.push(k) }
            s._cancelRefresh()
            s._cancelRefresh()
            compare(seen.length, 1, all[i].list)
            compare(seen[0], "superseded", all[i].list)
            compare(s.refreshing, false, all[i].list)
        }
    }

    function test_commit_replaces_the_list_and_ends_the_listComplete_state() {
        OrdersStore.orders = [{ orderId: "OLD" }]
        var before = OrdersStore.revision
        OrdersStore._commitRefresh([{ orderId: "A", status: "pending", products: [] }, { orderId: "B", status: "completed", products: [] }], null)
        compare(OrdersStore.orders.length, 2)
        compare(OrdersStore.hasMore, false)
        verify(OrdersStore.revision > before)
        OrdersStore.orders = []

        SupplierStore._commitRefresh([{ supplierId: "2", name: "b" }, { supplierId: "1", name: "a" }], null)
        compare(SupplierStore.suppliers[0].name, "a")
        SupplierStore.suppliers = []

        TransactionStore._commitRefresh([{ txId: "1", timestamp: "1" }, { txId: "3", timestamp: "3" }, { txId: "2", timestamp: "2" }], null)
        compare(TransactionStore.entries[0].txId, "3")
        compare(TransactionStore.entries[2].txId, "1")
        TransactionStore.entries = []
    }

    // Review F1: a Transaction backoff retry must not outlive a committed refresh (it would re-read pages the
    // list already holds and append them again).
    function test_transaction_commit_stops_a_pending_retry_timer() {
        TransactionStore._scheduleRetry()
        verify(TransactionStore._retryTimer !== null)
        verify(TransactionStore._retryTimer.running)
        TransactionStore._commitRefresh([{ txId: "1", timestamp: "1" }], null)
        compare(TransactionStore._retryTimer.running, false)
        TransactionStore.entries = []
    }
}
