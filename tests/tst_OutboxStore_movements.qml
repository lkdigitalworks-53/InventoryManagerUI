import QtQuick
import QtTest
import "../qml/model"

// P1 S2d-1: OutboxStore.enqueueDelta with explicit stock movements. The server needs
// sum(movements.qty) == the delta it applies, so explicit calls only coalesce with explicit calls
// (movements concatenate); mixed, clamped or over-cap calls queue as their own item. Derived-only
// coalescing (stock_batch, clamped imported-order deduction) is unchanged: tst_OutboxStore.qml
// still pins it. NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "OutboxStore_movements"

    function init() {
        OutboxStore.clear()
        OutboxStore._rand = function() { return 0.5 }
    }
    function cleanup() { OutboxStore.clear() }

    function _mv(kind, qty, reason) { return { kind: kind, qty: qty, reason: reason || "" } }
    function _call(id, stock, movements, extra) {
        var c = { requestId: id, entity: "inventory", entityId: "p1", deltas: { stock: stock },
                  floors: {}, clamps: {} }
        if (movements) c.movements = movements
        if (extra) for (var k in extra) c[k] = extra[k]
        return c
    }

    // ── shape ────────────────────────────────────────────────────────────
    function test_an_explicit_call_stores_its_movements() {
        var item = OutboxStore.enqueueDelta(_call("d1", 5, [_mv("receipt", 5, "box 1")]))
        compare(item.movements.length, 1)
        compare(item.movements[0].kind, "receipt")
        compare(item.movements[0].reason, "box 1")
    }
    function test_a_derived_call_has_no_movements_key() {
        var item = OutboxStore.enqueueDelta(_call("d1", 5, undefined))
        compare(item.movements, undefined)
        compare("movements" in item, false)
    }
    function test_an_empty_movements_array_is_treated_as_derived() {
        var item = OutboxStore.enqueueDelta(_call("d1", 5, []))
        compare(item.movements, undefined)
    }

    // ── explicit + explicit ──────────────────────────────────────────────
    function test_two_explicit_calls_coalesce_sum_the_delta_and_concatenate_movements() {
        OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10)]))
        var merged = OutboxStore.enqueueDelta(_call("d2", -3, [_mv("sale", -3)]))
        compare(OutboxStore.pendingCount, 1)
        compare(merged.requestId, "d1", "the surviving item is the earlier one")
        compare(merged.deltas.stock, 7)
        compare(merged.movements.length, 2)
        compare(merged.movements[0].kind, "receipt")
        compare(merged.movements[1].kind, "sale")
    }
    function test_coalesced_movements_always_sum_to_the_coalesced_delta() {
        var qtys = [4, -1, 2.5, -2.5, 6]
        for (var i = 0; i < qtys.length; ++i)
            OutboxStore.enqueueDelta(_call("d" + i, qtys[i], [_mv("adjustment", qtys[i])]))
        compare(OutboxStore.pendingCount, 1)
        var it = OutboxStore.items[0], sum = 0
        for (var j = 0; j < it.movements.length; ++j) sum += it.movements[j].qty
        compare(it.movements.length, 5)
        verify(Math.abs(sum - it.deltas.stock) < 1e-9, "sum " + sum + " vs delta " + it.deltas.stock)
    }
    function test_coalescing_does_not_mutate_the_callers_movements_array() {
        var a = [_mv("receipt", 10)], b = [_mv("sale", -3)]
        OutboxStore.enqueueDelta(_call("d1", 10, a))
        OutboxStore.enqueueDelta(_call("d2", -3, b))
        compare(a.length, 1)
        compare(b.length, 1)
    }
    function test_the_cap_is_inclusive_50_coalesce_51_does_not() {
        var fifty = [], one = [_mv("adjustment", 1)]
        for (var i = 0; i < 25; ++i) fifty.push(_mv("adjustment", 1))
        OutboxStore.enqueueDelta(_call("d1", 25, fifty))
        OutboxStore.enqueueDelta(_call("d2", 25, fifty.slice()))
        compare(OutboxStore.pendingCount, 1)
        compare(OutboxStore.items[0].movements.length, 50)
        OutboxStore.enqueueDelta(_call("d3", 1, one))
        compare(OutboxStore.pendingCount, 2, "the 51st movement queues as its own item")
        compare(OutboxStore.items[0].movements.length, 50)
        compare(OutboxStore.items[1].movements.length, 1)
    }

    // ── explicit vs derived, clamps ──────────────────────────────────────
    function test_explicit_then_derived_queue_separately() {
        OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10)]))
        OutboxStore.enqueueDelta(_call("d2", -3, undefined))
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[0].deltas.stock, 10)
        compare(OutboxStore.items[1].deltas.stock, -3)
        compare(OutboxStore.items[1].movements, undefined)
    }
    function test_derived_then_explicit_queue_separately() {
        OutboxStore.enqueueDelta(_call("d1", -3, undefined))
        OutboxStore.enqueueDelta(_call("d2", 10, [_mv("receipt", 10)]))
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[0].movements, undefined)
        compare(OutboxStore.items[1].movements.length, 1)
    }
    function test_a_clamped_derived_call_does_not_join_an_explicit_item() {
        OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10)]))
        OutboxStore.enqueueDelta(_call("d2", -3, undefined, { clamps: { stock: 0 } }))
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[1].clamps.stock, 0)
    }
    function test_explicit_calls_carrying_a_clamp_never_coalesce() {
        OutboxStore.enqueueDelta(_call("d1", 5, [_mv("receipt", 5)], { clamps: { stock: 0 } }))
        OutboxStore.enqueueDelta(_call("d2", 5, [_mv("receipt", 5)]))
        compare(OutboxStore.pendingCount, 2)
    }
    function test_derived_pairs_still_sum_exactly_as_before() {
        OutboxStore.enqueueDelta(_call("d1", -2, undefined, { clamps: { stock: 0 } }))
        var merged = OutboxStore.enqueueDelta(_call("d2", -3, undefined, { clamps: { stock: 0 } }))
        compare(OutboxStore.pendingCount, 1)
        compare(merged.deltas.stock, -5)
        compare(merged.movements, undefined)
    }
    function test_stock_batch_deltas_never_gain_movements() {
        OutboxStore.enqueueDelta({ requestId: "b1", entity: "stock_batch", entityId: "B1",
                                   deltas: { qtyRemaining: -1 }, floors: { qtyRemaining: 0 }, clamps: {} })
        var m = OutboxStore.enqueueDelta({ requestId: "b2", entity: "stock_batch", entityId: "B1",
                                           deltas: { qtyRemaining: -2 }, floors: { qtyRemaining: 0 }, clamps: {} })
        compare(m.deltas.qtyRemaining, -3)
        compare(m.movements, undefined)
    }

    // ── floors: a merged item keeps ONE floor map ────────────────────────
    function test_a_floored_sale_and_an_unfloored_restock_queue_separately() {
        OutboxStore.enqueueDelta(_call("d1", -3, [_mv("sale", -3)], { floors: { stock: 0 } }))
        OutboxStore.enqueueDelta(_call("d2", 5, [_mv("receipt", 5)]))
        compare(OutboxStore.pendingCount, 2, "merging would drop the sale's floor (stock could go negative)")
        compare(OutboxStore.items[0].floors.stock, 0)
        compare(OutboxStore.items[0].deltas.stock, -3)
        compare(OutboxStore.items[1].floors.stock, undefined)
        compare(OutboxStore.items[1].deltas.stock, 5)
    }
    function test_an_unfloored_restock_and_a_floored_sale_queue_separately() {
        OutboxStore.enqueueDelta(_call("d1", 5, [_mv("receipt", 5)]))
        OutboxStore.enqueueDelta(_call("d2", -8, [_mv("sale", -8)], { floors: { stock: 0 } }))
        compare(OutboxStore.pendingCount, 2, "merging would reject the restock together with a sale it never depended on")
        compare(OutboxStore.items[0].deltas.stock, 5)
        compare(OutboxStore.items[1].deltas.stock, -8)
        compare(OutboxStore.items[1].floors.stock, 0)
    }
    function test_two_floored_sales_still_coalesce_and_keep_the_floor() {
        OutboxStore.enqueueDelta(_call("d1", -3, [_mv("sale", -3)], { floors: { stock: 0 } }))
        var merged = OutboxStore.enqueueDelta(_call("d2", -2, [_mv("sale", -2)], { floors: { stock: 0 } }))
        compare(OutboxStore.pendingCount, 1)
        compare(merged.deltas.stock, -5)
        compare(merged.movements.length, 2)
        compare(merged.floors.stock, 0)
    }

    // ── never merge into a parked item or one that was already sent ──────
    function test_a_parked_explicit_item_is_never_a_merge_target() {
        OutboxStore.enqueueDelta(_call("d1", -3, [_mv("sale", -3)]))
        compare(OutboxStore.setStuckMeta("d1", { stuck: true, terminal: true, failures: 1 }), true)
        OutboxStore.enqueueDelta(_call("d2", -2, [_mv("sale", -2)]))
        compare(OutboxStore.pendingCount, 2, "the new change must not ride on a rejected request")
        compare(OutboxStore.items[0].requestId, "d1")
        compare(OutboxStore.items[0].deltas.stock, -3)
        compare(OutboxStore.items[0].movements.length, 1)
        compare(OutboxStore.items[1].requestId, "d2")
        compare(OutboxStore.items[1].deltas.stock, -2)
    }
    function test_a_parked_derived_item_is_never_a_merge_target() {
        OutboxStore.enqueueDelta(_call("d1", -3, undefined))
        OutboxStore.setStuckMeta("d1", { stuck: true, terminal: true, failures: 1 })
        OutboxStore.enqueueDelta(_call("d2", -2, undefined))
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[0].deltas.stock, -3)
    }
    function test_a_stuck_but_not_terminal_item_that_was_never_sent_still_merges() {
        // stuck without terminal = "may still succeed", never sent here (attempts 0): still merges
        OutboxStore.enqueueDelta(_call("d1", -3, [_mv("sale", -3)]))
        OutboxStore.setStuckMeta("d1", { stuck: true, failures: 1 })
        OutboxStore.enqueueDelta(_call("d2", -2, [_mv("sale", -2)]))
        compare(OutboxStore.pendingCount, 1)
        compare(OutboxStore.items[0].deltas.stock, -5)
    }
    function test_an_item_that_was_sent_and_failed_is_never_a_merge_target() {
        // Its reply may have been lost AFTER the server applied it. A retry carries the same
        // requestId and gets the old answer back, so anything merged in meanwhile would vanish.
        OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10)]))
        OutboxStore.markFailed("d1")
        compare(OutboxStore.items[0].attempts, 1)
        OutboxStore.enqueueDelta(_call("d2", 4, [_mv("receipt", 4)]))
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[0].requestId, "d1")
        compare(OutboxStore.items[0].deltas.stock, 10, "the already-sent payload stays byte-identical")
        compare(OutboxStore.items[0].movements.length, 1)
        compare(OutboxStore.items[1].requestId, "d2")
        compare(OutboxStore.items[1].deltas.stock, 4)
    }
    function test_a_derived_item_that_was_sent_and_failed_is_never_a_merge_target() {
        OutboxStore.enqueueDelta(_call("d1", -2, undefined, { clamps: { stock: 0 } }))
        OutboxStore.markFailed("d1")
        OutboxStore.enqueueDelta(_call("d2", -3, undefined, { clamps: { stock: 0 } }))
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[0].deltas.stock, -2)
        compare(OutboxStore.items[1].deltas.stock, -3)
    }
    function test_a_skipped_candidate_does_not_hide_a_fresh_one_behind_it() {
        OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10)]))
        OutboxStore.markFailed("d1")
        OutboxStore.enqueueDelta(_call("d2", 4, [_mv("receipt", 4)]))   // own item (d1 was sent)
        OutboxStore.enqueueDelta(_call("d3", 1, [_mv("receipt", 1)]))   // joins d2, skipping d1
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[0].deltas.stock, 10)
        compare(OutboxStore.items[1].deltas.stock, 5)
        compare(OutboxStore.items[1].movements.length, 2)
    }

    // ── isolation ────────────────────────────────────────────────────────
    function test_different_products_never_coalesce() {
        OutboxStore.enqueueDelta(_call("d1", 5, [_mv("receipt", 5)]))
        var other = _call("d2", 5, [_mv("receipt", 5)]); other.entityId = "p2"
        OutboxStore.enqueueDelta(other)
        compare(OutboxStore.pendingCount, 2)
    }
    function test_an_in_flight_explicit_item_is_never_mutated() {
        var first = OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10)]))
        OutboxStore.markInFlight(first)
        OutboxStore.enqueueDelta(_call("d2", -3, [_mv("sale", -3)]))
        compare(OutboxStore.pendingCount, 2, "the in-flight request must stay byte-identical for its retry")
        compare(OutboxStore.items[0].movements.length, 1)
        compare(OutboxStore.items[0].deltas.stock, 10)
        compare(OutboxStore.items[1].movements.length, 1)
    }
    function test_an_incompatible_first_candidate_does_not_hide_a_compatible_later_one() {
        OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10)]))           // explicit
        OutboxStore.enqueueDelta(_call("d2", -3, undefined))                      // derived, own item
        OutboxStore.enqueueDelta(_call("d3", -4, undefined))                      // joins d2, skipping d1
        compare(OutboxStore.pendingCount, 2)
        compare(OutboxStore.items[0].deltas.stock, 10)
        compare(OutboxStore.items[1].deltas.stock, -7)
    }
    function test_explicit_movements_survive_a_simulated_relaunch_and_a_replay_stays_identical() {
        OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10, "box 1")]))
        OutboxStore.enqueueDelta(_call("d2", -3, [_mv("sale", -3, "order O1")]))
        OutboxStore._load() // re-read from Settings, as if the app had just started
        compare(OutboxStore.pendingCount, 1)
        var it = OutboxStore.items[0]
        compare(it.requestId, "d1", "same requestId on replay, so the server replays from its audit entry")
        compare(it.deltas.stock, 7)
        compare(it.movements.length, 2)
        compare(it.movements[1].reason, "order O1")
    }
    function test_unsyncedByEntity_still_sees_an_explicit_item() {
        OutboxStore.enqueueDelta(_call("d1", 10, [_mv("receipt", 10)]))
        compare(OutboxStore.hasPendingForEntity("inventory", "p1"), true)
    }
}
