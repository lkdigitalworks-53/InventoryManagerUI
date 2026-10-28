import QtQuick
import QtTest
import "../qml/helper/SignOutGuard.js" as SOG

// Headless tests for the sign-out guard's summary (what signing out would discard).
// Pure JS, no singletons. SignOutSheet and the Main.qml wiring cannot run here (Felgo,
// no App context): they are covered by the on-device plan.
// Design: docs/superpowers/specs/2026-10-26-signout-guard-design.md
// Test plan: docs/superpowers/test-plans/2026-10-26-signout-guard-test-plan.md
TestCase {
    name: "SignOutGuard"

    readonly property string l1SignOut: "Signing out discards these. They will not sync when you sign back in, even as the same user."
    readonly property string l1Leave: "Leaving signs you out and discards these. They will not sync, even if you rejoin or sign back in as the same user."
    readonly property string lSending: "Changes marked Sending may or may not have been saved. Check after you sign in."
    readonly property string lCompletion: "A queued order completion leaves the order Pending. Complete it again after signing in."
    readonly property string lChange: "Edits, additions and deletions must be entered again."
    readonly property string lPhoto: "Photos that were not uploaded are lost."
    readonly property string lLocal: "Data stored on this device is also cleared."

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function _edit(id, over) {
        var it = { requestId: id, entity: "inventory", entityId: "P1", action: "update",
                   before: { name: "Old" }, after: { name: "Tomato" } }
        for (var k in over) it[k] = over[k]
        return it
    }
    function _completion(id) {
        return { requestId: id, opType: "completeOrder",
                 ops: [{ entity: "order", entityId: "ORD-1", after: { customer: "Asha" } }] }
    }
    function _photo(id, state, productId) {
        return { photoId: id, requestId: id, productId: productId, state: state }
    }
    function _names(id) { return ({ P1: "Tomato", P2: "Onion" })[id] }

    // ── nothing pending ─────────────────────────────────────────────────────

    function test_empty_means_nothing_to_lose() {
        var g = SOG.build([], [])
        compare(g.count, 0)
        compare(g.rows.length, 0)
        compare(g.more, 0)
        compare(g.hasSending, false)
        compare(g.consequences.length, 0)
        compare(g.summary, "Everything has synced. Nothing will be lost.")
    }

    function test_non_array_and_missing_inputs_are_empty_data() {
        return [
            { a: null, b: null }, { a: undefined, b: undefined }, { a: "x", b: 5 },
            { a: {}, b: {} }, { a: true, b: false }
        ]
    }
    function test_non_array_and_missing_inputs_are_empty(data) {
        compare(SOG.build(data.a, data.b).count, 0)
        compare(SOG.build(data.a, data.b, null).count, 0)
        compare(SOG.build(data.a, data.b, "opts").count, 0)
    }

    // ── one outbox item ─────────────────────────────────────────────────────

    function test_one_waiting_edit() {
        var g = SOG.build([_edit("r1")], [])
        compare(g.count, 1)
        compare(g.summary, "1 change hasn't reached the server.")
        compare(g.rows.length, 1)
        compare(g.rows[0].title, "Edited product")
        compare(g.rows[0].detail, "Tomato")
        compare(g.rows[0].state, "waiting")
        compare(g.rows[0].stateLabel, "Waiting")
        compare(g.rows[0].kind, "change")
        compare(g.hasSending, false)
        compare(JSON.stringify(g.consequences), JSON.stringify([l1SignOut, lChange, lLocal]))
    }

    function test_plural_summary() {
        var g = SOG.build([_edit("r1"), _edit("r2")], [])
        compare(g.summary, "2 changes haven't reached the server.")
    }

    function test_in_flight_item_is_sending_and_adds_the_may_have_saved_line() {
        var g = SOG.build([_edit("r1")], [], { inFlight: function(id) { return id === "r1" } })
        compare(g.rows[0].state, "sending")
        compare(g.rows[0].stateLabel, "Sending")
        compare(g.hasSending, true)
        compare(JSON.stringify(g.consequences), JSON.stringify([l1SignOut, lSending, lChange, lLocal]))
    }

    function test_stuck_item_needs_attention() {
        var g = SOG.build([_edit("r1", { stuck: true, failures: 5 })], [])
        compare(g.rows[0].state, "attention")
        compare(g.rows[0].stateLabel, "Needs attention")
    }

    function test_parked_item_needs_attention() {
        var g = SOG.build([_edit("r1", { stuck: true, terminal: true, failures: 5 })], [])
        compare(g.rows[0].state, "attention")
    }

    function test_parked_by_failure_count_alone_needs_attention() {
        // StuckWrites.isParkedItem repairs failures >= THRESHOLD to stuck; a bad save cannot hide it.
        var g = SOG.build([_edit("r1", { terminal: true, failures: 5 })], [])
        compare(g.rows[0].state, "attention")
    }

    function test_terminal_without_stuck_is_not_parked_so_it_waits() {
        var g = SOG.build([_edit("r1", { terminal: true, failures: 2 })], [])
        compare(g.rows[0].state, "waiting")
    }

    function test_attention_beats_sending() {
        var g = SOG.build([_edit("r1", { stuck: true, terminal: true })], [], { inFlight: function() { return true } })
        compare(g.rows[0].state, "attention")
        compare(g.hasSending, false)
        compare(g.consequences.indexOf(lSending), -1)
    }

    function test_only_a_strict_true_from_inFlight_counts() {
        var g = SOG.build([_edit("r1")], [], { inFlight: function() { return 1 } })
        compare(g.rows[0].state, "waiting")
    }

    function test_inFlight_gets_the_request_id() {
        var seen = []
        SOG.build([_edit("r1"), _edit("r2")], [], { inFlight: function(id) { seen.push(id); return false } })
        compare(JSON.stringify(seen), JSON.stringify(["r1", "r2"]))
    }

    // ── other outbox shapes (words come from DescribeItem) ──────────────────

    function test_order_completion_row_and_line() {
        var g = SOG.build([_completion("c1")], [])
        compare(g.rows[0].title, "Order completion")
        compare(g.rows[0].detail, "Asha")
        compare(g.rows[0].kind, "completion")
        compare(JSON.stringify(g.consequences), JSON.stringify([l1SignOut, lCompletion, lLocal]))
    }

    function test_unknown_operation_type_is_a_plain_change() {
        var g = SOG.build([{ requestId: "o1", opType: "futureOp", ops: [{ entity: "inventory", entityId: "P9" }] }], [])
        compare(g.rows[0].title, "Multi-step change")
        compare(g.rows[0].kind, "change")
        compare(g.consequences.indexOf(lCompletion), -1)
        verify(g.consequences.indexOf(lChange) >= 0)
    }

    function test_batch_and_delta_rows() {
        var g = SOG.build([
            { requestId: "b1", entity: "inventory", items: [{}, {}] },
            { requestId: "d1", entity: "inventory", entityId: "P1", deltas: { stock: -1 } }
        ], [])
        compare(g.rows[0].title, "2 products changed")
        compare(g.rows[1].title, "Stock change")
        compare(g.rows[1].detail, "P1")
    }

    // ── photos ──────────────────────────────────────────────────────────────

    function test_photo_states_map_to_row_states_data() {
        return [
            { state: "enqueued", row: "waiting" },
            { state: "retrying", row: "waiting" },
            { state: "uploading", row: "sending" },
            { state: "failed", row: "attention" },
            { state: "something-new", row: "waiting" },
            { state: undefined, row: "waiting" }
        ]
    }
    function test_photo_states_map_to_row_states(data) {
        var g = SOG.build([], [_photo("ph1", data.state, "P1")])
        compare(g.rows[0].state, data.row)
        compare(g.rows[0].kind, "photo")
        compare(g.rows[0].title, "Product photo")
    }

    function test_photo_detail_uses_the_product_name_else_the_id() {
        var g = SOG.build([], [_photo("a", "enqueued", "P1"), _photo("b", "enqueued", "ZZ")], { productName: _names })
        compare(g.rows[0].detail, "Tomato")
        compare(g.rows[1].detail, "ZZ")
    }

    function test_photo_detail_without_a_lookup_is_the_id() {
        compare(SOG.build([], [_photo("a", "enqueued", "P1")]).rows[0].detail, "P1")
    }

    function test_photo_detail_survives_a_bad_lookup() {
        var throwing = SOG.build([], [_photo("a", "enqueued", "P1")], { productName: function() { throw new Error("boom") } })
        compare(throwing.rows[0].detail, "P1")
        var wrongType = SOG.build([], [_photo("a", "enqueued", "P1")], { productName: function() { return 42 } })
        compare(wrongType.rows[0].detail, "P1")
        var blank = SOG.build([], [_photo("a", "enqueued", "P1")], { productName: function() { return "   " } })
        compare(blank.rows[0].detail, "P1")
    }

    function test_photo_without_a_product_id_has_empty_detail_and_skips_the_lookup() {
        var calls = 0
        var g = SOG.build([], [{ photoId: "a", state: "enqueued" }], { productName: function() { calls++; return "x" } })
        compare(g.rows[0].detail, "")
        compare(calls, 0)
    }

    function test_photo_line_and_uploading_adds_sending_line() {
        var g = SOG.build([], [_photo("a", "uploading", "P1")])
        compare(g.hasSending, true)
        compare(JSON.stringify(g.consequences), JSON.stringify([l1SignOut, lSending, lPhoto, lLocal]))
    }

    // ── mixed, order, caps ──────────────────────────────────────────────────

    function test_mixed_kinds_give_every_line_once_in_a_fixed_order() {
        var g = SOG.build([_edit("r1"), _completion("c1"), _edit("r2")], [_photo("a", "uploading", "P1")],
                          { inFlight: function(id) { return id === "c1" } })
        compare(JSON.stringify(g.consequences),
                JSON.stringify([l1SignOut, lSending, lCompletion, lChange, lPhoto, lLocal]))
        compare(g.count, 4)
    }

    function test_outbox_rows_come_before_photo_rows_in_queue_order() {
        var g = SOG.build([_edit("r1"), _completion("c1")], [_photo("a", "enqueued", "P1")])
        compare(g.rows[0].title, "Edited product")
        compare(g.rows[1].title, "Order completion")
        compare(g.rows[2].title, "Product photo")
    }

    function test_rows_are_capped_at_five_and_the_rest_is_counted() {
        var items = []
        for (var i = 0; i < 7; ++i) items.push(_edit("r" + i))
        var g = SOG.build(items, [])
        compare(g.count, 7)
        compare(g.rows.length, 5)
        compare(g.more, 2)
    }

    function test_exactly_the_cap_has_no_more() {
        var items = []
        for (var i = 0; i < 5; ++i) items.push(_edit("r" + i))
        var g = SOG.build(items, [])
        compare(g.rows.length, 5)
        compare(g.more, 0)
    }

    function test_caps_count_outbox_and_photos_together() {
        var photos = []
        for (var i = 0; i < 4; ++i) photos.push(_photo("p" + i, "enqueued", "P1"))
        var g = SOG.build([_edit("r1"), _edit("r2"), _edit("r3")], photos)
        compare(g.count, 7)
        compare(g.rows.length, 5)
        compare(g.more, 2)
    }

    function test_maxRows_option_data() {
        return [
            { max: 2, rows: 2, more: 4 }, { max: 6, rows: 6, more: 0 }, { max: 2.9, rows: 2, more: 4 },
            { max: 0, rows: 5, more: 1 }, { max: -3, rows: 5, more: 1 }, { max: NaN, rows: 5, more: 1 },
            { max: Infinity, rows: 5, more: 1 }, { max: "3", rows: 5, more: 1 }, { max: null, rows: 5, more: 1 }
        ]
    }
    function test_maxRows_option(data) {
        var items = []
        for (var i = 0; i < 6; ++i) items.push(_edit("r" + i))
        var g = SOG.build(items, [], { maxRows: data.max })
        compare(g.rows.length, data.rows)
        compare(g.more, data.more)
    }

    // ── wording variants ────────────────────────────────────────────────────

    function test_leaving_changes_only_the_first_line() {
        var a = SOG.build([_edit("r1")], [])
        var b = SOG.build([_edit("r1")], [], { leaving: true })
        compare(b.consequences[0], l1Leave)
        compare(JSON.stringify(b.consequences.slice(1)), JSON.stringify(a.consequences.slice(1)))
        compare(b.summary, a.summary)
    }

    function test_leaving_must_be_exactly_true() {
        compare(SOG.build([_edit("r1")], [], { leaving: "yes" }).consequences[0], l1SignOut)
    }

    function test_the_local_data_line_is_always_last_when_anything_is_pending() {
        var g = SOG.build([_edit("r1")], [_photo("a", "failed", "P1")])
        compare(g.consequences[g.consequences.length - 1], lLocal)
        compare(g.consequences[0], l1SignOut)
    }

    // ── hostile and malformed input ─────────────────────────────────────────

    function test_malformed_items_are_counted_and_described_generically() {
        var g = SOG.build([null, undefined, 7, "x", {}, []], [null, 3, "x"])
        compare(g.count, 9)
        compare(g.rows[0].title, "Pending change")
        for (var i = 0; i < g.rows.length; ++i) compare(g.rows[i].state, "waiting")
    }

    function test_a_throwing_inFlight_means_not_sending() {
        var g = SOG.build([_edit("r1")], [], { inFlight: function() { throw new Error("boom") } })
        compare(g.rows[0].state, "waiting")
        compare(g.hasSending, false)
    }

    function test_inputs_are_not_mutated() {
        var out = [_edit("r1", { stuck: true }), _completion("c1")]
        var ph = [_photo("a", "failed", "P1")]
        var before = JSON.stringify([out, ph])
        SOG.build(out, ph, { inFlight: function() { return true }, productName: _names, maxRows: 1 })
        compare(JSON.stringify([out, ph]), before)
    }

    function test_the_result_does_not_alias_the_input_rows() {
        var out = [_edit("r1")]
        var g = SOG.build(out, [])
        g.rows[0].title = "changed"
        compare(SOG.build(out, []).rows[0].title, "Edited product")
    }

    function test_build_is_repeatable() {
        var out = [_edit("r1"), _completion("c1")]
        compare(JSON.stringify(SOG.build(out, [])), JSON.stringify(SOG.build(out, [])))
    }

    // ── seeded monkey: invariants hold for any mix ──────────────────────────

    function test_monkey_invariants() {
        var r = _rng(20261026)
        var junk = [null, undefined, 7, "x", {}, [], { requestId: 5 }]
        var states = ["enqueued", "uploading", "retrying", "failed", "zzz", undefined]
        var okStates = { waiting: 1, sending: 1, attention: 1 }
        for (var n = 0; n < 300; ++n) {
            var out = [], ph = []
            var no = Math.floor(r() * 9), np = Math.floor(r() * 6)
            for (var i = 0; i < no; ++i) {
                var p = r()
                if (p < 0.15) out.push(junk[Math.floor(r() * junk.length)])
                else if (p < 0.35) out.push(_completion("c" + i))
                else out.push(_edit("r" + i, { stuck: r() < 0.2, terminal: r() < 0.2, failures: Math.floor(r() * 8) }))
            }
            for (var j = 0; j < np; ++j)
                ph.push(r() < 0.1 ? junk[Math.floor(r() * junk.length)] : _photo("p" + j, states[Math.floor(r() * states.length)], r() < 0.5 ? "P1" : "P2"))
            var max = 1 + Math.floor(r() * 7)
            var inflightAll = r() < 0.5
            var g = SOG.build(out, ph, { maxRows: max, leaving: r() < 0.5, productName: _names,
                                          inFlight: function() { return inflightAll } })
            compare(g.count, no + np)
            compare(g.rows.length, Math.min(g.count, max))
            compare(g.more, g.count - g.rows.length)
            compare(g.consequences.length === 0, g.count === 0)
            compare(g.consequences.indexOf(lSending) >= 0, g.hasSending)
            for (var k = 0; k < g.rows.length; ++k) verify(okStates[g.rows[k].state] === 1)
            if (g.count > 0) compare(g.consequences[g.consequences.length - 1], lLocal)
        }
    }
}
