import QtQuick
import QtTest
import "../qml/model"
import "../qml/helper/SendPolicy.js" as SendPolicy

// C-3 order-completion atomic rewrite (Task 10, 2026-09-26 plan). Design:
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// Drives DataModel._tryCompleteOrder through the REAL Gateway.recordOperation
// path (real OutboxStore enqueue, real signals) rather than mocking DataModel's
// own internals, then simulates the server's answer the same way
// tests/tst_Gateway.qml's own recordOperation tests do: by calling
// Gateway._finishOperation({requestId, opType}, result) directly, since a real
// XHR round trip can't run headlessly here (see that file's header note).
//
// One thing that ISN'T obvious from tst_Gateway.qml's own tests and matters a
// lot for the re-plan cases below (4, 5, 8, 10): _finishOperation alone does
// NOT remove the item from OutboxStore. In production that only happens
// because _sendOperation's real XHR completion calls OutboxStore.markSent()
// immediately before calling _finishOperation (Gateway.qml, both success and
// terminal-rejection branches). Skip that and a re-plan's second
// recordOperation call for the SAME key silently coalesces into the FIRST
// (rejected) payload instead of sending the corrected one — see
// OutboxStore.markSent's own definition and
// test_recordOperation_the_same_key_twice_enqueues_once... in tst_Gateway.qml.
// _answer() below does both, in the same order production does.
TestCase {
    name: "DataModel_completeOrderAtomic"

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
        AuthService.isOnline = false
        Gateway.awaitTimeoutMs = SendPolicy.TIMEOUT_AWAIT_MS
        dm.stockErrorMsg = ""
        dm._completingOrderIds = ({})
        dm._openCompletions = ({})
    }

    function cleanup() {
        AuthService.isOnline = false
        Gateway.awaitTimeoutMs = SendPolicy.TIMEOUT_AWAIT_MS
    }

    // ── fixtures ─────────────────────────────────────────────────────────

    function _product(stock) {
        return {
            productId: "SKU-1", name: "Widget", sku: "W1", category: "", description: "",
            unit: "pc", price: 100, sellingPrice: 100, taxable: false, taxPercent: 0,
            size: "", stock: stock === undefined ? 5 : stock, minStock: 0
        }
    }

    function _batch(qtyRemaining) {
        return {
            batchId: "B1", productId: "SKU-1", supplierId: "S1",
            qtyReceived: 5, qtyRemaining: qtyRemaining === undefined ? 5 : qtyRemaining, unitCost: 50,
            receivedDate: "2026-09-01T00:00:00.000Z", poId: "", note: "",
            createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-01T00:00:00.000Z"
        }
    }

    function _pendingOrder(qty) {
        return {
            orderId: "ORD-ATOMIC-1", customer: "Test Customer", status: "pending",
            date: "2026-09-26", email: "", phone: "", notes: "",
            orderChannel: "", staffId: "", adjustments: [],
            products: [{ productId: "SKU-1", name: "Widget", price: 100, quantity: qty === undefined ? 1 : qty }]
        }
    }

    function _key(epoch) { return "completeOrder:ORD-ATOMIC-1:" + epoch }

    // Only the completeOrder OPERATION requests in the outbox. OutboxStore
    // also holds the recordMutation items OrdersStore.updateOrder enqueues
    // (e.g. the `out of stock` status write _failCompletion makes, or a
    // reopen), which are not what "was a request sent" means here.
    function _ops() {
        var out = []
        for (var i = 0; i < OutboxStore.items.length; ++i)
            if (String(OutboxStore.items[i].requestId).indexOf("completeOrder:") === 0) out.push(OutboxStore.items[i])
        return out
    }

    // Mirrors production's _sendOperation: mark the outbox item sent (so a
    // re-plan under the same key starts a fresh item, not a coalesce) THEN
    // deliver the outcome. Use for any answer that is meant to be terminal
    // (applied, or a rejection) — never for a "queued" callback, which isn't
    // an answer at all.
    function _answer(key, result) {
        OutboxStore.markSent(key)
        Gateway._finishOperation({ requestId: key, opType: "completeOrder" }, result)
    }

    function _appliedResult(afters) {
        // afters: [{entity, entityId, kind, after}]; idempotentReplay defaults false.
        return { ok: true, results: afters, idempotentReplay: false }
    }

    function _rejection(opIndex, extra) {
        var r = { ok: false, error: "conflict", opIndex: opIndex }
        for (var k in extra) r[k] = extra[k]
        return r
    }

    // ── 1. Online, server applies ───────────────────────────────────────

    function test_online_server_applies_immediately() {
        AuthService.isOnline = true
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })

        compare(_ops().length, 1, "awaiting online: still queued until the answer")
        compare(_ops()[0].requestId, _key(1))
        compare(result, null, "nothing yet -- only the server's answer resolves this")

        _answer(_key(1), _appliedResult([
            { entity: "stock_batch", entityId: "B1", kind: "delta", after: { qtyRemaining: 4 } },
            { entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 4 } },
            { entity: "order", entityId: "ORD-ATOMIC-1", kind: "mutation",
              after: Object.assign({}, _pendingOrder(), { status: "completed", completionEpoch: 1 }) },
            { entity: "transaction", entityId: "tx-s-ORD-ATOMIC-1-1-0", kind: "mutation",
              after: { txId: "tx-s-ORD-ATOMIC-1-1-0", kind: "sale", productId: "SKU-1", quantity: 1 } }
        ]))

        compare(result, true)
        compare(OrdersStore.orders[0].status, "completed")
        compare(StockBatchStore.getById("B1").qtyRemaining, 4)
        compare(InventoryStore.getById("SKU-1").stock, 4)
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.entries[0].txId, "tx-s-ORD-ATOMIC-1-1-0")
        verify(!dm._completingOrderIds["ORD-ATOMIC-1"], "guard released")
        verify(!dm._openCompletions[_key(1)], "no longer open")
        compare(_ops().length, 0, "exactly one request was ever sent")
    }

    // ── 2. Insufficient product stock (local validation) ────────────────

    function test_insufficient_local_stock_rejects_before_sending() {
        InventoryStore.products = [_product(0)]
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })

        compare(result, false)
        compare(dm.stockErrorMsg, "Widget: need 1, only 0 in stock")
        compare(OrdersStore.orders[0].status, "out of stock")
        compare(_ops().length, 0, "no request sent for a locally-invalid order")
        verify(!dm._completingOrderIds["ORD-ATOMIC-1"], "guard released")
    }

    // ── 3. Online, server rejects the inventory op: insufficient-quantity ─

    function test_server_rejects_inventory_op_insufficient_quantity() {
        AuthService.isOnline = true
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })
        // ops order from CompletionPlan.build: [stock_batch delta, inventory delta, order, transaction]
        _answer(_key(1), _rejection(1, { error: "insufficient-quantity", current: 0 }))

        compare(result, false)
        compare(dm.stockErrorMsg, "Widget: stock ran out before this order could complete")
        compare(OrdersStore.orders[0].status, "out of stock")
        compare(InventoryStore.getById("SKU-1").stock, 5, "no local stock change from the rejected attempt")
        compare(_ops().length, 0, "terminal rejection, not retried")
        verify(!dm._completingOrderIds["ORD-ATOMIC-1"])
    }

    // ── 4. Online, server rejects a stock_batch op with `current`: reconcile + resend ─

    function test_stock_batch_conflict_reconciles_and_resends_same_key() {
        AuthService.isOnline = true
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })
        compare(_ops()[0].requestId, _key(1))

        // Another device drained the batch to 0 first.
        _answer(_key(1), _rejection(0, { current: 0 }))
        compare(result, null, "not resolved yet -- the re-plan is still in flight")
        compare(StockBatchStore.getById("B1").qtyRemaining, 0, "reconciled to the server's current value")
        compare(_ops().length, 1, "re-plan resent")
        compare(_ops()[0].requestId, _key(1), "same key -- same order, same epoch")

        // Re-plan now sees 0 remaining in the batch, so it drift-repairs and applies.
        _answer(_key(1), _appliedResult([
            { entity: "order", entityId: "ORD-ATOMIC-1", kind: "mutation",
              after: Object.assign({}, _pendingOrder(), { status: "completed", completionEpoch: 1 }) }
        ]))
        compare(result, true)
        compare(OrdersStore.orders[0].status, "completed")
    }

    // ── 5. Re-plan is bounded ────────────────────────────────────────────

    function test_replan_bound_is_exactly_maxReplans() {
        AuthService.isOnline = true
        compare(dm.maxReplans, 3)
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })

        for (var i = 0; i < dm.maxReplans; ++i) {
            compare(_ops().length, 1, "attempt " + i + " outstanding")
            _answer(_key(1), _rejection(0, { current: 0 }))
            compare(result, null, "still retrying after rejection " + i)
            compare(_ops().length, 1, "a re-plan was sent after rejection " + i)
        }
        // The loop above answered the original attempt plus maxReplans-1
        // re-plans (all non-terminal). One more request is now outstanding
        // (the maxReplans-th re-plan, attempt index == maxReplans) -- ITS
        // rejection must be the terminal one: no 5th request.
        _answer(_key(1), _rejection(0, { current: 0 }))
        compare(_ops().length, 0, "no further request sent -- the bound was hit")
        compare(result, false)
        compare(OrdersStore.orders[0].status, "out of stock")
        verify(!dm._completingOrderIds["ORD-ATOMIC-1"])
    }

    // ── 6. Await window ends, then the real answer arrives ──────────────

    function test_await_timeout_shows_completed_then_server_answer_overwrites() {
        AuthService.isOnline = true
        Gateway.awaitTimeoutMs = 30
        var results = []
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { results.push(ok) })
        tryCompare(results, "length", 1, 2000)
        compare(results[0], true)

        compare(OrdersStore.orders[0].status, "completed", "shown as completed once the wait times out")
        compare(InventoryStore.getById("SKU-1").stock, 4, "predicted state applied locally")
        verify(dm._completingOrderIds["ORD-ATOMIC-1"], "guard stays set -- the operation is still open")
        verify(dm._openCompletions[_key(1)], "still open, awaiting the real answer")

        // The real answer, later, in the background.
        _answer(_key(1), _appliedResult([
            { entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 3 } }
        ]))
        compare(InventoryStore.getById("SKU-1").stock, 3, "server's answer overwrites the prediction")
        verify(!dm._completingOrderIds["ORD-ATOMIC-1"], "guard released once truly settled")
        verify(!dm._openCompletions[_key(1)])
    }

    // ── 7. Offline: same shape as 6, without waiting ────────────────────

    function test_offline_shows_completed_immediately_then_real_answer_overwrites() {
        // AuthService.isOnline is false by default (init()).
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })

        compare(result, true, "queued offline resolves immediately, shown as done")
        compare(OrdersStore.orders[0].status, "completed")
        compare(InventoryStore.getById("SKU-1").stock, 4)
        verify(dm._completingOrderIds["ORD-ATOMIC-1"], "guard stays set until the real answer")
        verify(dm._openCompletions[_key(1)])

        _answer(_key(1), _appliedResult([
            { entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 4 } }
        ]))
        verify(!dm._completingOrderIds["ORD-ATOMIC-1"])
        verify(!dm._openCompletions[_key(1)])
    }

    // ── 8. Queued, then rejected at sync: revert, clamp, repair, resend ──

    function test_queued_then_rejected_at_sync_reverts_and_resends_clamped() {
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })
        compare(result, true, "shown as done while offline")
        compare(InventoryStore.getById("SKU-1").stock, 4, "predicted state applied")

        // Now "online": the queued item is actually sent and rejected --
        // another device already drained the batch below what this order needs.
        _answer(_key(1), _rejection(0, { current: 0 }))

        // The first prediction is reverted inside _onCompletionRejected, but
        // offline the re-plan is queued and immediately re-applies ITS OWN
        // prediction, so 'stock back to 5' is never observable here. What is
        // observable: the order stays shown as completed and one re-plan is out.
        compare(OrdersStore.orders[0].status, "completed")
        compare(_ops().length, 1, "resent under clampStock -- the sale already happened (D3)")
        compare(_ops()[0].requestId, _key(1))

        _answer(_key(1), _appliedResult([
            { entity: "order", entityId: "ORD-ATOMIC-1", kind: "mutation",
              after: Object.assign({}, _pendingOrder(), { status: "completed", completionEpoch: 1 }) },
            { entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 0 } }
        ]))
        compare(OrdersStore.orders[0].status, "completed", "stays completed -- the sale is not undone twice")
        compare(InventoryStore.getById("SKU-1").stock, 0, "clamped at 0, not negative")
    }

    // ── 9. Replay with different local state ────────────────────────────

    function test_idempotent_replay_reflects_servers_after_not_the_prediction() {
        AuthService.isOnline = true
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })
        var replay = _appliedResult([
            { entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 2 } }
        ])
        replay.idempotentReplay = true
        _answer(_key(1), replay)

        compare(result, true)
        compare(InventoryStore.getById("SKU-1").stock, 2, "the server's after wins, not this client's own predicted 4")
    }

    // ── 10. THE C-3 REGRESSION: never-answers, sign-out, reload, retry ───

    function test_c3_regression_relaunch_after_no_answer_replays_same_key() {
        var result1 = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result1 = ok })
        compare(result1, true, "queued offline, shown as done")
        compare(_ops().length, 1)
        compare(_ops()[0].requestId, _key(1))

        // Sign-out: the queued request is gone, never having answered.
        Gateway.clear()
        compare(_ops().length, 0)

        // Relaunch: a fresh DataModel would start with empty guards; this one
        // doesn't get destroyed, so simulate that explicitly (see header of
        // tst_DataModel_completeOrderReentrancy.qml for the same convention).
        dm._completingOrderIds = ({})
        dm._openCompletions = ({})
        // The order sync comes back showing it never actually completed
        // server-side (the completion never reached it before sign-out).
        OrdersStore.orders = [_pendingOrder()]
        InventoryStore.products = [_product()]
        StockBatchStore.batches = [_batch()]

        var result2 = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result2 = ok })
        compare(result2, true)
        compare(_ops()[0].requestId, _key(1), "same order, same (never-persisted) epoch -- same key")

        var replay = _appliedResult([
            { entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 4 } },
            { entity: "stock_batch", entityId: "B1", kind: "delta", after: { qtyRemaining: 4 } }
        ])
        replay.idempotentReplay = true
        _answer(_key(1), replay)

        compare(InventoryStore.getById("SKU-1").stock, 4, "changed once -- from 5 to 4, not 3")
        compare(StockBatchStore.getById("B1").qtyRemaining, 4, "changed once")
    }

    // ── 11. Reopen then re-complete: epoch advances ─────────────────────

    function test_reopen_then_recomplete_bumps_epoch() {
        AuthService.isOnline = true
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })
        _answer(_key(1), _appliedResult([
            { entity: "order", entityId: "ORD-ATOMIC-1", kind: "mutation",
              after: Object.assign({}, _pendingOrder(), { status: "completed", completionEpoch: 1 }) }
        ]))
        compare(result, true)
        compare(OrdersStore.orders[0].completionEpoch, 1)

        OrdersStore.updateOrder("ORD-ATOMIC-1", { status: "pending" })

        var result2 = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result2 = ok })
        compare(_ops()[0].requestId, _key(2), "epoch bumped to 2 after reopen + re-complete")
    }

    // ── 12. too-many-ops ─────────────────────────────────────────────────

    function test_too_many_ops_does_not_mark_out_of_stock() {
        var products = []
        // 101 distinct-product lines -> 101 inventory deltas + 101 order-line
        // batch deltas (well over MAX_OPS=200 once the order+sale ops are
        // added) without needing any single line's quantity to be large.
        var invProducts = []
        var batches = []
        for (var i = 0; i < 101; ++i) {
            var pid = "SKU-" + i
            products.push({ productId: pid, name: "P" + i, price: 10, quantity: 1 })
            invProducts.push({ productId: pid, name: "P" + i, sku: "W" + i, category: "", description: "",
                                unit: "pc", price: 10, sellingPrice: 10, taxable: false, taxPercent: 0,
                                size: "", stock: 5, minStock: 0 })
            batches.push({ batchId: "B-" + i, productId: pid, supplierId: "S1", qtyReceived: 5, qtyRemaining: 5,
                           unitCost: 5, receivedDate: "2026-09-01T00:00:00.000Z", poId: "", note: "",
                           createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-01T00:00:00.000Z" })
        }
        OrdersStore.orders = [{
            orderId: "ORD-ATOMIC-1", customer: "Test", status: "pending", date: "2026-09-26",
            email: "", phone: "", notes: "", orderChannel: "", staffId: "", adjustments: [], products: products
        }]
        InventoryStore.products = invProducts
        StockBatchStore.batches = batches

        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })

        compare(result, false)
        verify(dm.stockErrorMsg.indexOf("too large") >= 0 || dm.stockErrorMsg.indexOf("limit") >= 0,
               "message carries the ops-limit reason: " + dm.stockErrorMsg)
        compare(OrdersStore.orders[0].status, "pending", "too-many-ops must NOT set out of stock")
        compare(_ops().length, 0)
        verify(!dm._completingOrderIds["ORD-ATOMIC-1"])
    }

    // ── 13. Already-completed / in-flight guard ─────────────────────────

    function test_already_completed_short_circuits_true_with_no_request() {
        OrdersStore.orders = [Object.assign({}, _pendingOrder(), { status: "completed" })]
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })
        compare(result, true)
        compare(_ops().length, 0)
    }

    function test_in_flight_guard_rejects_second_call() {
        AuthService.isOnline = true
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) {})
        var second = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { second = ok })
        compare(second, false)
        compare(dm.stockErrorMsg, "This order is already being completed — please wait")
        compare(_ops().length, 1, "the second call sent nothing")
    }

    // ── 14. Sale doc ids, not duplicated by replay ──────────────────────

    function test_sale_doc_ids_follow_the_epoch_scheme_and_replay_does_not_duplicate() {
        AuthService.isOnline = true
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) {})
        var saleDoc = { txId: "tx-s-ORD-ATOMIC-1-1-0", kind: "sale", productId: "SKU-1", quantity: 1 }
        _answer(_key(1), _appliedResult([{ entity: "transaction", entityId: saleDoc.txId, kind: "mutation", after: saleDoc }]))
        compare(TransactionStore.entries.length, 1)

        // A duplicate delivery of the SAME result (e.g. signal + callback
        // both reaching _settleApplied) must not add a second row.
        TransactionStore.addLocalEntries([saleDoc])
        compare(TransactionStore.entries.length, 1, "addLocalEntries dedupes by txId")
    }

    // ── 15. Monkey: seeded, terminal invariants always hold ─────────────

    function test_monkey_seeded_runs_never_leave_a_bad_terminal_state() {
        function mulberry32(seed) {
            return function() {
                seed |= 0; seed = (seed + 0x6D2B79F5) | 0
                var t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
                t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
                return ((t ^ (t >>> 14)) >>> 0) / 4294967296
            }
        }
        var rnd = mulberry32(20260926)

        for (var run = 0; run < 200; ++run) {
            init()
            var online = rnd() < 0.5
            AuthService.isOnline = online
            var qty = 1 + Math.floor(rnd() * 3)
            OrdersStore.orders = [_pendingOrder(qty)]
            InventoryStore.products = [_product(5)]
            StockBatchStore.batches = [_batch(5)]

            var result = "unresolved"
            dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })

            var guardIter = 0
            while (_ops().length > 0 && guardIter < dm.maxReplans + 2) {
                var key = _ops()[0].requestId
                var outcome = rnd()
                if (outcome < 0.35) {
                    _answer(key, _appliedResult([{ entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 5 - qty } }]))
                } else if (outcome < 0.55) {
                    var replay = _appliedResult([{ entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 5 - qty } }])
                    replay.idempotentReplay = true
                    _answer(key, replay)
                } else if (outcome < 0.85) {
                    _answer(key, _rejection(0, { current: Math.max(0, 5 - qty) }))
                } else {
                    // 503-shaped: non-terminal in production (retried by the
                    // outbox itself, not by DataModel's re-plan logic at all)
                    // -- here, simulate by just leaving the item queued and
                    // stopping this run's loop; DataModel must not have moved
                    // to a bad state while a non-terminal failure is pending.
                    break
                }
                guardIter++
            }

            verify(_ops().length <= 1, "run " + run + ": never more than one outstanding request for this order")
            if (_ops().length === 0) {
                verify(!dm._completingOrderIds["ORD-ATOMIC-1"], "run " + run + ": guard released once nothing is outstanding")
            }
            verify(InventoryStore.getById("SKU-1").stock >= 0, "run " + run + ": stock never negative")
        }
    }

    // ── 16. Reopen while a completion is still open (design check-in decision 3) ──

    function test_reopen_while_completion_open_clears_it_so_the_late_answer_is_a_noop() {
        var result = null
        dm._tryCompleteOrder("ORD-ATOMIC-1", function(ok) { result = ok })
        compare(result, true, "shown as completed while offline")
        verify(dm._openCompletions[_key(1)], "completion still open, awaiting the real answer")
        verify(dm._completingOrderIds["ORD-ATOMIC-1"])
        compare(InventoryStore.getById("SKU-1").stock, 4)

        // Reopened before the server ever answered -- exercises the actual
        // function DataModel's reopen path calls (onUpdateOrder's
        // completed-\u2192-non-completed edge), not the store method directly,
        // since that edge is where the fix lives.
        dm._reverseCompletedOrder(OrdersStore.getById("ORD-ATOMIC-1"))

        // creditStockNoBatch is server-confirmed (recordDelta), so local stock
        // is NOT credited synchronously -- capture it and require it unchanged.
        var stockAfterReopen = InventoryStore.getById("SKU-1").stock
        verify(!dm._openCompletions[_key(1)], "reopen must clear the open completion")
        verify(!dm._completingOrderIds["ORD-ATOMIC-1"], "and the guard, so a fresh completion isn't blocked")

        // The original request's answer finally arrives, late. Must be a
        // no-op: nothing left in _openCompletions for this key.
        _answer(_key(1), _appliedResult([
            { entity: "inventory", entityId: "SKU-1", kind: "delta", after: { stock: 3 } }
        ]))
        compare(InventoryStore.getById("SKU-1").stock, stockAfterReopen,
                "the stale answer for the superseded completion must not touch stock (it would set 3)")
    }
}
