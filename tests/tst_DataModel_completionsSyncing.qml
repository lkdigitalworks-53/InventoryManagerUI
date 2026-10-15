import QtQuick
import QtTest
import "../qml/model"
import "../qml/helper/SendPolicy.js" as SendPolicy

// Task 11 ("Saved, syncing"): DataModel.syncingOrderIds / completionsSyncing.
// Design: docs/superpowers/specs/2026-10-14-task11-saved-syncing-design.md
// Same harness as tst_DataModel_completeOrderAtomic.qml: the REAL DataModel + Gateway + OutboxStore,
// the server's answer simulated with Gateway._finishOperation after OutboxStore.markSent (as production does).
TestCase {
    name: "DataModel_completionsSyncing"

    DataModel { id: dm }
    SignalSpy { id: idsSpy; target: dm; signalName: "syncingOrderIdsChanged" }
    SignalSpy { id: countSpy; target: dm; signalName: "completionsSyncingChanged" }

    function init() {
        Gateway.clear()   // also resets the stuck/parked bookkeeping between cases
        OrdersStore.orders = [_order("O1", 1), _order("O2", 1), _order("O3", 1)]
        InventoryStore.products = [_product()]
        StockBatchStore.batches = [_batch()]
        TransactionStore.entries = []
        TransactionStore.revision = 0
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        AuthService.isOnline = false
        Gateway.awaitTimeoutMs = SendPolicy.TIMEOUT_AWAIT_MS
        dm.stockErrorMsg = ""
        dm._completingOrderIds = ({})
        dm._openCompletions = ({})
        dm._refreshSyncing()
        idsSpy.clear()
        countSpy.clear()
    }

    function cleanup() {
        dm.dispatcher = null
        AuthService.isOnline = false
        Gateway.awaitTimeoutMs = SendPolicy.TIMEOUT_AWAIT_MS
    }

    // ── fixtures ─────────────────────────────────────────────────────────
    function _product() {
        return {
            productId: "SKU-1", name: "Widget", sku: "W1", category: "", description: "",
            unit: "pc", price: 100, sellingPrice: 100, taxable: false, taxPercent: 0,
            size: "", stock: 10, minStock: 0
        }
    }
    function _batch() {
        return {
            batchId: "B1", productId: "SKU-1", supplierId: "S1",
            qtyReceived: 10, qtyRemaining: 10, unitCost: 50,
            receivedDate: "2026-09-01T00:00:00.000Z", poId: "", note: "",
            createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-01T00:00:00.000Z"
        }
    }
    function _order(id, qty) {
        return {
            orderId: id, customer: "Cust " + id, status: "pending",
            date: "2026-10-14", email: "", phone: "", notes: "",
            orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: qty }]
        }
    }
    function _key(id) { return "completeOrder:" + id + ":1" }
    function _answer(key, result) {
        OutboxStore.markSent(key)
        Gateway._finishOperation({ requestId: key, opType: "completeOrder" }, result)
        Gateway._pruneStuck()   // production runs this from _reschedule() once the item has left the outbox
    }
    function _item(key) {
        return OutboxStore.items.filter(function(i) { return i.requestId === key })[0]
    }
    // Server says "write-rejected" `n` times (>= StuckWrites.THRESHOLD parks it), like tst_Gateway drives it.
    function _reject(key, n) {
        var it = _item(key)
        verify(it !== undefined, "queued item for " + key)
        for (var i = 0; i < n; ++i) Gateway._noteFailure(it, 400, '{"error":"write-rejected"}')
    }
    function _park(key) { _reject(key, 5) }
    function _applied() {
        return { ok: true, idempotentReplay: false,
                 results: [{ entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 9 } }] }
    }
    function _discarded() { return { ok: false, error: "discarded", discarded: true } }
    function _complete(id) { dm._tryCompleteOrder(id, function(ok) {}) }
    function _idsOf(map) {
        var out = []
        for (var k in map) out.push(k)
        out.sort()
        return out
    }
    // Truth recomputed from the raw bookkeeping, independent of _refreshSyncing.
    function _expectedSyncing() {
        var out = {}
        for (var k in dm._openCompletions) {
            var o = dm._openCompletions[k]
            var parked = Gateway._stuckState.stuck[k] === true && Gateway._stuckState.terminal[k] === true
            if (o && o.undo && !parked) out[o.orderId] = true
        }
        return _idsOf(out)
    }
    function _assertConsistent(msg) {
        compare(_idsOf(dm.syncingOrderIds), _expectedSyncing(), msg + ": map matches raw state")
        compare(dm.completionsSyncing, _expectedSyncing().length, msg + ": count matches raw state")
    }

    // ── unit ─────────────────────────────────────────────────────────────

    function test_initially_nothing_is_syncing() {
        compare(dm.completionsSyncing, 0)
        compare(_idsOf(dm.syncingOrderIds).length, 0)
        verify(dm.syncingOrderIds["O1"] !== true)
    }

    function test_offline_completion_is_syncing_until_the_server_answers() {
        _complete("O1")
        compare(OrdersStore.getById("O1").status, "completed", "shown as done")
        compare(dm.completionsSyncing, 1)
        verify(dm.syncingOrderIds["O1"] === true)
        verify(dm.syncingOrderIds["O2"] !== true, "only this order")

        _answer(_key("O1"), _applied())
        compare(dm.completionsSyncing, 0)
        verify(dm.syncingOrderIds["O1"] !== true)
        _assertConsistent("after confirm")
    }

    function test_online_answer_in_time_never_shows_syncing() {
        AuthService.isOnline = true
        _complete("O1")
        compare(dm.completionsSyncing, 0, "awaiting the server, not yet shown as done")
        _answer(_key("O1"), _applied())
        compare(dm.completionsSyncing, 0)
        compare(countSpy.count, 0, "the count never moved")
    }

    function test_await_timeout_then_answer_is_syncing_in_between() {
        AuthService.isOnline = true
        Gateway.awaitTimeoutMs = 30
        _complete("O1")
        tryCompare(dm, "completionsSyncing", 1, 2000, "await window ran out: shown as done, unconfirmed")
        _answer(_key("O1"), _applied())
        compare(dm.completionsSyncing, 0)
    }

    function test_discard_of_a_queued_completion_clears_it() {
        _complete("O1")
        compare(dm.completionsSyncing, 1)
        _answer(_key("O1"), _discarded())
        compare(dm.completionsSyncing, 0)
        compare(OrdersStore.getById("O1").status, "pending")
        _assertConsistent("after discard")
    }

    function test_reopen_while_syncing_clears_it() {
        _complete("O1")
        compare(dm.completionsSyncing, 1)
        dm._reverseCompletedOrder(OrdersStore.getById("O1"))
        compare(dm.completionsSyncing, 0)
        _assertConsistent("after reopen")
        // the late answer for the superseded completion is a no-op and must not resurrect the hint
        _answer(_key("O1"), _applied())
        compare(dm.completionsSyncing, 0)
    }

    function test_late_conflict_that_finishes_the_order_clears_it() {
        _complete("O1")
        var ops = dm._openCompletions[_key("O1")].plan.ops
        var idx = -1
        for (var i = 0; i < ops.length; ++i) if (ops[i].entity === "order") idx = i
        verify(idx >= 0)
        var done = _order("O1", 1)
        done.status = "completed"
        _answer(_key("O1"), { ok: false, error: "conflict", conflict: true, opIndex: idx, current: done })
        compare(dm.completionsSyncing, 0)
        _assertConsistent("after conflict-completed")
    }

    function test_replan_after_a_queued_rejection_stays_one_entry() {
        _complete("O1")
        _answer(_key("O1"), { ok: false, error: "conflict", opIndex: 0, current: 9 })
        // re-planned (clamped) and queued again offline: still exactly one syncing order
        compare(dm.completionsSyncing, 1)
        verify(dm.syncingOrderIds["O1"] === true)
        _assertConsistent("after re-plan")
    }

    function test_permanent_failure_after_replans_clears_it() {
        _complete("O1")
        for (var i = 0; i <= dm.maxReplans + 1; ++i) {
            var ops = []
            for (var j = 0; j < OutboxStore.items.length; ++j)
                if (String(OutboxStore.items[j].requestId).indexOf("completeOrder:") === 0) ops.push(OutboxStore.items[j])
            if (ops.length === 0) break
            _answer(ops[0].requestId, { ok: false, error: "conflict", opIndex: 0, current: 9 })
        }
        compare(dm.completionsSyncing, 0, "re-plans exhausted: reverted, no longer syncing")
        _assertConsistent("after exhaustion")
    }

    function test_local_validation_failure_never_shows_syncing() {
        OrdersStore.orders = [_order("O1", 99)]   // more than stock: rejected before sending
        _complete("O1")
        compare(dm.completionsSyncing, 0)
        _assertConsistent("after local failure")
    }

    // ── parked writes (review of PR #144, finding 2, option B) ───────────

    function test_parked_completion_is_not_syncing() {
        _complete("O1")
        compare(dm.completionsSyncing, 1)
        _park(_key("O1"))
        compare(Gateway.stuckTerminalCount, 1, "the gateway really parked it")
        compare(dm.completionsSyncing, 0, "parked: waiting for Retry/Discard, not syncing")
        verify(dm.syncingOrderIds["O1"] !== true)
        verify(dm._openCompletions[_key("O1")], "the open completion is still tracked")
        compare(OrdersStore.getById("O1").status, "completed", "still shown as done")
        _assertConsistent("after park")
    }

    function test_retry_of_a_parked_completion_shows_the_hint_again() {
        _complete("O1")
        _park(_key("O1"))
        compare(dm.completionsSyncing, 0)
        verify(Gateway.retryStuck(_key("O1")), "retry accepted")
        compare(dm.completionsSyncing, 1, "un-parked and retrying: syncing again")
        verify(dm.syncingOrderIds["O1"] === true)
        _assertConsistent("after retry")
    }

    function test_discard_of_a_parked_completion_ends_cleanly() {
        _complete("O1")
        _park(_key("O1"))
        _answer(_key("O1"), _discarded())
        compare(dm.completionsSyncing, 0)
        compare(OrdersStore.getById("O1").status, "pending")
        verify(!dm._openCompletions[_key("O1")])
        _assertConsistent("after discard of parked")
    }

    function test_parking_one_order_hides_only_that_order() {
        _complete("O1")
        _complete("O2")
        compare(dm.completionsSyncing, 2)
        _park(_key("O1"))
        compare(_idsOf(dm.syncingOrderIds).join(","), "O2")
        compare(dm.completionsSyncing, 1)
        _assertConsistent("after parking one")
    }

    function test_four_rejections_do_not_park_yet() {
        _complete("O1")
        _reject(_key("O1"), 4)
        compare(Gateway.stuckTerminalCount, 0)
        compare(dm.completionsSyncing, 1, "below the threshold the write is still just retrying")
    }

    function test_stuck_but_still_retrying_stays_syncing() {
        // 5 outage-style failures (no write-rejected): stuck, NOT parked -> the app keeps retrying, so "syncing" is true.
        _complete("O1")
        var it = _item(_key("O1"))
        for (var i = 0; i < 5; ++i) Gateway._noteFailure(it, 500, "")
        compare(Gateway.stuckCount, 1)
        compare(Gateway.stuckTerminalCount, 0)
        compare(dm.completionsSyncing, 1)
    }

    // ── functional ───────────────────────────────────────────────────────

    function test_two_orders_are_tracked_independently() {
        _complete("O1")
        _complete("O2")
        compare(dm.completionsSyncing, 2)
        compare(_idsOf(dm.syncingOrderIds).join(","), "O1,O2")
        _answer(_key("O1"), _applied())
        compare(dm.completionsSyncing, 1)
        compare(_idsOf(dm.syncingOrderIds).join(","), "O2")
        _answer(_key("O2"), _applied())
        compare(dm.completionsSyncing, 0)
    }

    function test_each_change_assigns_a_new_object_so_bindings_notify() {
        var before = dm.syncingOrderIds
        _complete("O1")
        verify(idsSpy.count >= 1, "syncingOrderIdsChanged fired when it started")
        verify(dm.syncingOrderIds !== before, "a NEW object, not an in-place edit")
        compare(countSpy.count, 1, "count 0 -> 1")
        var afterStart = idsSpy.count
        _answer(_key("O1"), _applied())
        verify(idsSpy.count > afterStart, "fired again when it ended")
        compare(countSpy.count, 2, "count 1 -> 0")
    }

    function test_same_order_twice_counts_once() {
        _complete("O1")
        // a second open entry for the same order cannot exist in production (guarded); force it to pin the dedupe
        dm._openCompletions["completeOrder:O1:99"] = { orderId: "O1", undo: {}, plan: { ops: [] }, callback: null }
        dm._refreshSyncing()
        compare(dm.completionsSyncing, 1)
        dm._closeOpen("completeOrder:O1:99")
        compare(dm.completionsSyncing, 1, "the real entry is still open")
    }

    function test_closeOpen_of_an_unknown_key_is_harmless() {
        _complete("O1")
        dm._closeOpen("completeOrder:NOPE:1")
        compare(dm.completionsSyncing, 1)
        _assertConsistent("after unknown close")
    }

    function test_completing_an_already_completed_order_adds_nothing() {
        _complete("O1")
        _answer(_key("O1"), _applied())
        _complete("O1")
        compare(dm.completionsSyncing, 0)
    }

    function test_regression_completion_flow_unchanged_by_the_funnel() {
        var result = null
        dm._tryCompleteOrder("O1", function(ok) { result = ok })
        compare(result, true)
        verify(dm._completingOrderIds["O1"], "guard still set until the answer")
        _answer(_key("O1"), _applied())
        verify(!dm._completingOrderIds["O1"])
        verify(!dm._openCompletions[_key("O1")])
    }

    // ── monkey ───────────────────────────────────────────────────────────

    function test_monkey_state_always_matches_the_raw_bookkeeping() {
        function mulberry32(seed) {
            return function() {
                seed |= 0; seed = (seed + 0x6D2B79F5) | 0
                var t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
                t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
                return ((t ^ (t >>> 14)) >>> 0) / 4294967296
            }
        }
        var rnd = mulberry32(20261014)
        var ids = ["O1", "O2", "O3"]
        for (var run = 0; run < 60; ++run) {
            init()
            for (var step = 0; step < 14; ++step) {
                var id = ids[Math.floor(rnd() * ids.length)]
                var act = rnd()
                var o = OrdersStore.getById(id)
                var keys = []
                for (var k in dm._openCompletions) keys.push(k)
                if (act < 0.30) {
                    if (o && o.status === "pending") _complete(id)
                } else if (act < 0.45 && keys.length > 0) {
                    _answer(keys[Math.floor(rnd() * keys.length)], _applied())
                } else if (act < 0.55 && keys.length > 0) {
                    _answer(keys[Math.floor(rnd() * keys.length)], _discarded())
                } else if (act < 0.65 && keys.length > 0) {
                    _answer(keys[Math.floor(rnd() * keys.length)], { ok: false, error: "conflict", opIndex: 0, current: 9 })
                } else if (act < 0.80 && keys.length > 0) {
                    var pk = keys[Math.floor(rnd() * keys.length)]
                    if (_item(pk) !== undefined) _park(pk)
                } else if (act < 0.90 && keys.length > 0) {
                    Gateway.retryStuck(keys[Math.floor(rnd() * keys.length)])
                } else if (o && o.status === "completed") {
                    dm._reverseCompletedOrder(o)
                }
                _assertConsistent("run " + run + " step " + step)
                verify(dm.completionsSyncing >= 0 && dm.completionsSyncing <= ids.length, "bounded")
            }
        }
    }
}
