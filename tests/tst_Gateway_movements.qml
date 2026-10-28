import QtQuick
import QtTest
import "../qml/model"

// P1 S2d-1: Gateway.recordDelta's optional 7th argument `movements` (explicit stock ledger kinds).
// A bad call is refused BEFORE anything is queued (the server's rejection of a queued write is
// terminal, so a client bug must not reach the queue). Nothing here touches the network:
// AuthStore.idToken stays empty so _sendDelta's guard closes (see tst_Gateway.qml header).
// NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "Gateway_movements"

    function init() {
        OutboxStore.clear()
        Gateway.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
        AuthStore.isAuthenticated = false
        AuthService.isOnline = true
    }
    function cleanup() { OutboxStore.clear() }

    function _mv(kind, qty, reason) { return { kind: kind, qty: qty, reason: reason || "" } }
    function _refused(deltas, clamps, movements, entity) {
        var out = { calls: 0, result: null }
        var id = Gateway.recordDelta(entity || "inventory", "p1", deltas, {}, clamps || {},
                                     function(r) { out.calls++; out.result = r }, movements)
        out.id = id
        return out
    }

    // ── accepted ─────────────────────────────────────────────────────────
    function test_an_explicit_delta_is_queued_with_its_movements() {
        var id = Gateway.recordDelta("inventory", "p1", { stock: 5 }, {}, {}, null, [_mv("receipt", 5, "box")])
        verify(id.length > 0)
        compare(OutboxStore.pendingCount, 1)
        var it = OutboxStore.items[0]
        compare(it.deltas.stock, 5)
        compare(it.movements.length, 1)
        compare(it.movements[0].kind, "receipt")
        compare(it.movements[0].reason, "box")
    }
    function test_without_movements_the_item_is_exactly_as_before() {
        Gateway.recordDelta("inventory", "p1", { stock: 5 }, {}, {}, null)
        var it = OutboxStore.items[0]
        compare(it.movements, undefined)
        compare("movements" in it, false)
    }
    function test_explicit_delta_callback_waits_for_the_server() {
        var calls = 0
        Gateway.recordDelta("inventory", "p1", { stock: 5 }, {}, {}, function(r) { calls++ }, [_mv("receipt", 5)])
        compare(calls, 0, "no server answer yet, the callback must not fire")
    }
    function test_two_explicit_calls_with_equal_floors_coalesce_and_both_callbacks_join_the_survivor() {
        var a = 0, b = 0
        var id1 = Gateway.recordDelta("inventory", "p1", { stock: -3 }, { stock: 0 }, {}, function(r) { a++ }, [_mv("sale", -3)])
        var id2 = Gateway.recordDelta("inventory", "p1", { stock: -2 }, { stock: 0 }, {}, function(r) { b++ }, [_mv("sale", -2)])
        compare(id2, id1, "the second call coalesced into the first item")
        compare(OutboxStore.pendingCount, 1)
        compare(OutboxStore.items[0].deltas.stock, -5)
        compare(OutboxStore.items[0].floors.stock, 0)
        compare(OutboxStore.items[0].movements.length, 2)
        Gateway._answerDeltaCallbacks(id1, { ok: true, after: { stock: 7 } })
        compare(a, 1); compare(b, 1)
    }
    function test_explicit_calls_with_different_floors_queue_separately_and_answer_separately() {
        var a = 0, b = 0
        var id1 = Gateway.recordDelta("inventory", "p1", { stock: 10 }, {}, {}, function(r) { a++ }, [_mv("receipt", 10)])
        var id2 = Gateway.recordDelta("inventory", "p1", { stock: -3 }, { stock: 0 }, {}, function(r) { b++ }, [_mv("sale", -3)])
        verify(id2 !== id1, "a floored sale must not share an item with an unfloored restock")
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[0].deltas.stock, 10)
        compare(OutboxStore.items[1].deltas.stock, -3)
        compare(OutboxStore.items[1].floors.stock, 0)
        Gateway._answerDeltaCallbacks(id1, { ok: true, after: { stock: 10 } })
        compare(a, 1); compare(b, 0, "the sale callback waits for its own answer")
        Gateway._answerDeltaCallbacks(id2, { ok: false, error: "insufficient-quantity" })
        compare(a, 1); compare(b, 1)
    }
    function test_a_floor_next_to_explicit_movements_is_allowed() {
        var id = Gateway.recordDelta("inventory", "p1", { stock: -2 }, { stock: 0 }, {}, null, [_mv("sale", -2)])
        verify(id.length > 0)
        compare(OutboxStore.items[0].floors.stock, 0)
    }

    // ── refused before queueing ──────────────────────────────────────────
    function _assertRefused(r, code) {
        compare(r.id, "")
        compare(r.calls, 1, "the callback fires once, immediately")
        compare(r.result.ok, false)
        compare(r.result.error, "bad-request")
        compare(r.result.detail, code)
        compare(OutboxStore.pendingCount, 0, "nothing may be queued for a refused call")
    }
    function test_a_sum_that_does_not_match_the_delta_is_refused() {
        _assertRefused(_refused({ stock: 6 }, {}, [_mv("receipt", 5)]), "movement-qty-mismatch")
    }
    function test_a_wrong_direction_is_refused() {
        _assertRefused(_refused({ stock: 5 }, {}, [_mv("sale", 5)]), "invalid-movement-qty")
    }
    function test_an_unknown_kind_is_refused() {
        _assertRefused(_refused({ stock: 5 }, {}, [_mv("bogus", 5)]), "invalid-movement-kind")
    }
    function test_explicit_movements_with_a_clamp_are_refused() {
        _assertRefused(_refused({ stock: -5 }, { stock: 0 }, [_mv("sale", -5)]), "movements-with-clamps")
    }
    function test_movements_on_a_non_inventory_entity_are_refused() {
        _assertRefused(_refused({ qtyRemaining: -1 }, {}, [_mv("sale", -1)], "stock_batch"), "movements-require-inventory")
    }
    function test_movements_without_a_stock_delta_are_refused() {
        _assertRefused(_refused({ qty: 5 }, {}, [_mv("receipt", 5)]), "movements-require-stock-delta")
    }
    function test_an_empty_movements_array_is_refused() {
        _assertRefused(_refused({ stock: 5 }, {}, []), "invalid-movements")
    }
    function test_too_many_movements_are_refused() {
        var many = []
        for (var i = 0; i < 51; ++i) many.push(_mv("adjustment", 1))
        _assertRefused(_refused({ stock: 51 }, {}, many), "too-many-movements")
    }
    function test_a_refused_call_with_no_callback_is_silent_and_queues_nothing() {
        var id = Gateway.recordDelta("inventory", "p1", { stock: 6 }, {}, {}, null, [_mv("receipt", 5)])
        compare(id, "")
        compare(OutboxStore.pendingCount, 0)
    }
    function test_the_bad_entity_check_still_answers_without_a_detail() {
        var out = { r: null }
        compare(Gateway.recordDelta("widget", "w1", { qty: 1 }, {}, {}, function(r) { out.r = r }, [_mv("receipt", 1)]), "")
        compare(out.r.error, "bad-request")
        compare(out.r.detail, undefined)
    }
}
