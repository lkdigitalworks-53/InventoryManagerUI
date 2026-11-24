import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// Atomic-ops NO3a: OrdersStore.addOrder sends ONE recordOperation("createOrder", ..., { awaitServer: true }) and settles through
// Gateway.operationApplied/operationRejected (DataModel routes them, and starts auto-approve AFTER the answer). The waiting caller and
// the late signal must never apply the same answer twice. The same cases run in Node against the REAL function bodies and the REAL
// server code in functions/test/orderWire.test.js; this file is the qmltestrunner copy for the QML-engine glue (Gateway waiters,
// signals, DataModel Connections, the store's real list bookkeeping).
// Design: docs/superpowers/specs/2026-11-23-no3a-create-order-wire-design.md
// NOT RUN IN THIS SANDBOX: no Qt/qmltestrunner toolchain here. CI is the oracle.
TestCase {
    name: "OrdersStore_addOrder"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }
    SignalSpy { id: errSpy; target: testLogic; signalName: "errorOccurred" }
    SignalSpy { id: addedSpy; target: testLogic; signalName: "orderAdded" }
    SignalSpy { id: deferredSpy; target: testLogic; signalName: "orderCreationDeferred" }
    SignalSpy { id: failedSpy; target: testLogic; signalName: "orderCreationFailed" }
    SignalSpy { id: compFailSpy; target: testLogic; signalName: "orderCompletionFailed" }

    readonly property var line: ({ productId: "", name: "Tomato", qty: 3, price: 20, discountType: "flat", discountValue: 0 })

    function init() {
        OutboxStore.clear()
        Gateway.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        AuthStore.isAuthenticated = false
        AuthStore.role = "owner"
        AuthService.isOnline = true
        OrdersStore.autoApproveEnabled = false
        OrdersStore.orders = []
        OrdersStore._createSettled = ({})
        OrdersStore._createNames = ({})
        InventoryStore.products = []
        errSpy.clear(); addedSpy.clear(); deferredSpy.clear(); failedSpy.clear(); compFailSpy.clear()
    }
    function cleanup() { OutboxStore.clear(); OrdersStore.autoApproveEnabled = false }

    function _items() { return OutboxStore.items.filter(function(i) { return i.opType === "createOrder" }) }
    function _tap(over) {
        var out = { calls: [] }
        var a = Object.assign({ customer: " Asha ", date: new Date(2026, 5, 15), email: "", phone: "", products: [line], channel: "Online", staff: "S-1" }, over || {})
        OrdersStore.addOrder(a.customer, a.date, a.email, a.phone, a.products, a.channel, a.staff, function(ok, id, refusal, status) {
            out.calls.push({ ok: ok, id: id, refusal: refusal, status: status }) })
        return out
    }
    // The answer the server gives: the mint, then the order the plan carried with the minted id.
    function _answer(item, id) {
        var after = JSON.parse(JSON.stringify(item.ops[1].after))
        after.orderId = id
        return [{ kind: "mint", bind: "ord", counter: "order", id: id },
                { kind: "mutation", entity: "order", entityId: id, action: "create", after: after }]
    }

    // ── refusals ──────────────────────────────────────────────────────────
    function test_offline_is_refused_at_once_and_queues_nothing() {
        AuthService.isOnline = false
        var t = _tap()
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, false)
        compare(t.calls[0].refusal, OrdersStore.createOfflineMessage)
        compare(OutboxStore.items.length, 0)
    }
    function test_a_bad_value_gets_its_own_text_even_offline() {
        AuthService.isOnline = false
        var t = _tap({ products: [] })
        compare(t.calls[0].refusal, "Add at least one product")
        t = _tap({ customer: "  " })
        compare(t.calls[0].refusal, "Enter a valid customer name")
        t = _tap({ products: [Object.assign({}, line, { price: 2e9 })] })
        verify(t.calls[0].refusal.indexOf("Line 1 (Tomato): ") === 0)
        compare(OutboxStore.items.length, 0)
    }
    function test_no_callback_does_not_throw() {
        OrdersStore.addOrder("A", new Date(), "", "", [line], "", "")
        AuthService.isOnline = false
        OrdersStore.addOrder("A", new Date(), "", "", [line], "", "")
        compare(errSpy.count, 0)
    }

    // ── answered while the caller waits ───────────────────────────────────
    function test_live_answer_applies_once_even_though_the_signal_follows() {
        var t = _tap()
        compare(t.calls.length, 0, "an awaiting caller is not answered before the server")
        compare(_items().length, 1)
        compare(OrdersStore.orders.length, 0, "no optimistic order")
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(_items()[0], "ORD-001"), idempotentReplay: false })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, true)
        compare(t.calls[0].id, "ORD-001")
        compare(t.calls[0].status, "applied")
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].customer, "Asha")
        compare(OrdersStore.orders[0].status, "pending")
        compare(errSpy.count, 0)
    }
    function test_live_rejection_answers_the_caller_and_says_nothing_more() {
        var t = _tap()
        Gateway._finishOperation(_items()[0], { ok: false, error: "conflict", conflict: true })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, false)
        verify(t.calls[0].refusal.indexOf("Asha: ") === 0)
        compare(errSpy.count, 0)
        compare(OrdersStore.orders.length, 0)
    }
    function test_replayed_answer_adds_nothing_locally() {
        var t = _tap()
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(_items()[0], "ORD-001"), idempotentReplay: true })
        compare(t.calls[0].status, "replayed")
        compare(t.calls[0].id, "ORD-001")
        compare(OrdersStore.orders.length, 0)
    }
    function test_unreadable_answer_is_unconfirmed() {
        var t = _tap()
        Gateway._finishOperation(_items()[0], { ok: true, results: [], idempotentReplay: false })
        compare(t.calls.length, 1)
        compare(t.calls[0].ok, true)
        compare(t.calls[0].id, "")
        compare(t.calls[0].status, "unconfirmed")
        compare(OrdersStore.orders.length, 0)
    }

    // ── answered after the caller left ────────────────────────────────────
    function test_a_slow_answer_is_queued_then_applied_once_by_the_signal() {
        var saved = Gateway.awaitTimeoutMs
        Gateway.awaitTimeoutMs = 20
        var t = _tap()
        tryCompare(t.calls, "length", 1, 2000)
        Gateway.awaitTimeoutMs = saved
        compare(t.calls[0].status, "queued")
        compare(OrdersStore.orders.length, 0)
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(_items()[0], "ORD-001"), idempotentReplay: false })
        compare(t.calls.length, 1, "the caller is not called twice")
        compare(OrdersStore.orders.length, 1)
        compare(OrdersStore.orders[0].orderId, "ORD-001")
    }
    function test_a_late_rejection_is_announced_once_with_the_customer() {
        var saved = Gateway.awaitTimeoutMs
        Gateway.awaitTimeoutMs = 20
        var t = _tap()
        tryCompare(t.calls, "length", 1, 2000)
        Gateway.awaitTimeoutMs = saved
        Gateway._finishOperation(_items()[0], { ok: false, error: "conflict", conflict: true })
        compare(errSpy.count, 1)
        verify(String(errSpy.signalArguments[0][1]).indexOf("A queued order was not placed. Asha: ") === 0)
    }

    // ── the DataModel route ───────────────────────────────────────────────
    function test_dataModel_live_apply_emits_orderAdded_and_no_auto_approve_when_off() {
        testLogic.addOrder("Asha", new Date(2026, 5, 15), "", "", [line], "Online", "S-1")
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(_items()[0], "ORD-001"), idempotentReplay: false })
        compare(addedSpy.count, 1)
        compare(addedSpy.signalArguments[0][0], "ORD-001")
        compare(OutboxStore.items.filter(function(i) { return i.opType === "completeOrder" }).length, 0)
    }
    function test_dataModel_offline_emits_orderCreationFailed_with_the_text() {
        AuthService.isOnline = false
        testLogic.addOrder("Asha", new Date(), "", "", [line], "", "")
        compare(failedSpy.count, 1)
        compare(failedSpy.signalArguments[0][0], OrdersStore.createOfflineMessage)
    }
    function test_dataModel_unconfirmed_emits_orderCreationDeferred() {
        testLogic.addOrder("Asha", new Date(), "", "", [line], "", "")
        Gateway._finishOperation(_items()[0], { ok: true, results: [], idempotentReplay: false })
        compare(deferredSpy.count, 1)
        compare(deferredSpy.signalArguments[0][0], "unconfirmed")
        compare(addedSpy.count, 0)
    }
    function test_dataModel_auto_approve_starts_only_after_the_answer() {
        OrdersStore.autoApproveEnabled = true
        testLogic.addOrder("Asha", new Date(), "", "", [line], "", "")
        compare(OutboxStore.items.filter(function(i) { return i.opType === "completeOrder" }).length, 0, "nothing is completed before the server answered")
        Gateway._finishOperation(_items()[0], { ok: true, results: _answer(_items()[0], "ORD-001"), idempotentReplay: false })
        var completionQueued = OutboxStore.items.filter(function(i) { return i.opType === "completeOrder" }).length > 0
        verify(completionQueued || compFailSpy.count === 1, "an attempt was made after the answer (queued, or refused with a text)")
        compare(OrdersStore.orders.length, 1)
    }
    // A replay never auto-approves, also when a sync already put the order in the list (the case that used to depend on a race).
    function test_dataModel_live_replay_never_auto_approves_even_when_the_order_is_already_listed() {
        OrdersStore.autoApproveEnabled = true
        testLogic.addOrder("Asha", new Date(), "", "", [line], "", "")
        var answer = _answer(_items()[0], "ORD-001")
        OrdersStore._addLocalOrder(answer[1].after)
        compare(OrdersStore.orders.length, 1, "a sync landed the order first")
        Gateway._finishOperation(_items()[0], { ok: true, results: answer, idempotentReplay: true })
        compare(addedSpy.count, 1, "the sheet still closes")
        compare(addedSpy.signalArguments[0][0], "ORD-001")
        compare(OutboxStore.items.filter(function(i) { return i.opType === "completeOrder" }).length, 0, "no completion for a replay")
        compare(compFailSpy.count, 0)
    }
}
