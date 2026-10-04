import QtQuick
import QtTest
import "../qml/model"

// PR #122 S4: OutboxStore.unsyncedByEntity(entity) -> { id: { state: "pending"|"parked", edit } }.
// Feeds the overlay (edit) and the "Not synced" / "Rejected" badge (state). Must agree with the
// sale guard (hasUnsyncedEditForEntity) and hasParkedForEntity. Pure data logic, no network.
// NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "OutboxStore_unsyncedByEntity"

    function init() { OutboxStore.clear(); OutboxStore._rand = function() { return 0.5 } }
    function cleanup() { OutboxStore.clear() }

    function _edit(id, productId, action, after) {
        return OutboxStore.enqueue({ requestId: id, entity: "inventory", entityId: productId || "P1",
                                     action: action || "update", before: { v: 0 }, after: after || { v: 1 } })
    }
    function _delta(id, productId) {
        return OutboxStore.enqueueDelta({ requestId: id, entity: "inventory", entityId: productId || "P1",
                                          deltas: { stock: -1 }, floors: { stock: 0 } })
    }
    function _park(id) { OutboxStore.setStuckMeta(id, { failures: 5, stuck: true, terminal: true }) }
    function _snap(entity) { return OutboxStore.unsyncedByEntity(entity || "inventory") }

    // ── basics ───────────────────────────────────────────────────────────

    function test_empty_outbox_gives_empty_map_edge() { compare(Object.keys(_snap()).length, 0) }

    function test_queued_update_is_pending_and_carries_the_edit() {
        _edit("e1", "P1", "update", { v: 9 })
        var s = _snap()
        compare(s.P1.state, "pending")
        compare(s.P1.edit.requestId, "e1")
        compare(s.P1.edit.after.v, 9)
    }
    function test_each_product_gets_its_own_entry() {
        _edit("e1", "P1"); _edit("e2", "P2")
        compare(Object.keys(_snap()).sort().join(), "P1,P2")
    }
    function test_other_entities_are_not_listed_edge() {
        OutboxStore.enqueue({ requestId: "o1", entity: "order", entityId: "O1", action: "update", before: {}, after: {} })
        compare(Object.keys(_snap()).length, 0)
        compare(Object.keys(_snap("order")).join(), "O1")
    }
    function test_entity_prefix_does_not_leak_between_similar_names_edge() {
        OutboxStore.enqueue({ requestId: "x1", entity: "inventory_extra", entityId: "P1", action: "update", before: {}, after: {} })
        compare(Object.keys(_snap("inventory")).length, 0, "'inventory_extra/P1' must not match prefix 'inventory/'")
    }
    function test_entity_id_containing_a_slash_is_kept_whole_edge() {
        _edit("e1", "a/b")
        compare(Object.keys(_snap()).join(), "a/b")
    }

    // ── state rules (same as the sale guard) ─────────────────────────────

    function test_in_flight_edit_is_pending() {
        _edit("e1", "P1")
        OutboxStore.markInFlight(OutboxStore.items[0])
        compare(_snap().P1.state, "pending")
        compare(_snap().P1.edit.requestId, "e1")
        OutboxStore.clearInFlight(OutboxStore.items[0])
    }
    function test_parked_edit_is_parked_and_still_carries_the_edit() {
        _edit("e1", "P1", "update", { v: 9 }); _park("e1")
        var s = _snap()
        compare(s.P1.state, "parked")
        compare(s.P1.edit.after.v, 9, "parked edits are overlaid too (Taher)")
    }
    function test_retry_flips_parked_back_to_pending() {
        _edit("e1", "P1"); _park("e1")
        OutboxStore.setStuckMeta("e1", { failures: 0 })
        compare(_snap().P1.state, "pending")
    }
    function test_stuck_but_not_terminal_is_pending_not_parked_edge() {
        _edit("e1", "P1")
        OutboxStore.setStuckMeta("e1", { failures: 5, stuck: true, terminal: false })
        compare(_snap().P1.state, "pending")
    }
    function test_a_second_edit_merges_and_the_snapshot_shows_the_net_after_edge() {
        _edit("e1", "P1", "update", { v: 1 }); _edit("e2", "P1", "update", { v: 2 })
        compare(_snap().P1.edit.requestId, "e1")
        compare(_snap().P1.edit.after.v, 2)
    }

    // ── non-edit kinds: state only, no replayable edit ───────────────────

    function test_queued_create_is_pending_without_an_edit() {
        _edit("c1", "P1", "create")
        var s = _snap()
        compare(s.P1.state, "pending")
        compare(s.P1.edit, null)
    }
    function test_queued_delete_is_pending_without_an_edit() {
        _edit("d1", "P1", "delete")
        compare(_snap().P1.state, "pending")
        compare(_snap().P1.edit, null)
    }
    function test_stock_delta_alone_is_not_an_unsynced_edit_edge() {
        _delta("d1", "P1")
        compare(Object.keys(_snap()).length, 0, "back-to-back sales must not badge the product")
    }
    function test_stock_delta_does_not_hide_a_real_edit_edge() {
        _edit("e1", "P1"); _delta("d1", "P1")
        compare(_snap().P1.state, "pending")
        compare(_snap().P1.edit.requestId, "e1")
    }
    function test_parked_delta_makes_the_product_parked_without_an_edit() {
        _delta("d1", "P1"); _park("d1")
        var s = _snap()
        compare(s.P1.state, "parked")
        compare(s.P1.edit, null)
    }
    function test_parked_delta_plus_pending_edit_is_parked_and_keeps_the_edit_edge() {
        _delta("d1", "P1"); _park("d1"); _edit("e1", "P1")
        var s = _snap()
        compare(s.P1.state, "parked")
        compare(s.P1.edit.requestId, "e1")
    }
    function test_pending_edit_then_parked_delta_is_still_parked_edge() {
        _edit("e1", "P1"); _delta("d1", "P1"); _park("d1")
        compare(_snap().P1.state, "parked")
    }
    function test_pending_batch_member_is_not_flagged_same_as_the_sale_guard_edge() {
        OutboxStore.enqueueBatch({ requestId: "b1", entity: "inventory",
                                   items: [{ entityId: "P1", action: "create" }, { entityId: "P2", action: "create" }] })
        compare(Object.keys(_snap()).length, 0, "hasUnsyncedEditForEntity skips batch members; badge must match")
        verify(!OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
    }
    function test_parked_batch_marks_every_member_parked() {
        OutboxStore.enqueueBatch({ requestId: "b1", entity: "inventory",
                                   items: [{ entityId: "P1", action: "create" }, { entityId: "P2", action: "create" }] })
        _park("b1")
        compare(_snap().P1.state, "parked"); compare(_snap().P2.state, "parked")
        compare(_snap().P1.edit, null)
    }
    function test_operation_touching_the_product_does_not_count_as_a_plain_edit_edge() {
        OutboxStore.enqueueOperation({ requestId: "op1", opType: "complete_order",
                                       ops: [{ entity: "inventory", entityId: "P1" }] })
        compare(Object.keys(_snap()).length, 0)
    }
    function test_parked_operation_makes_each_touched_product_parked() {
        OutboxStore.enqueueOperation({ requestId: "op1", opType: "complete_order",
                                       ops: [{ entity: "inventory", entityId: "P1" }, { entity: "inventory", entityId: "P2" }] })
        _park("op1")
        compare(_snap().P1.state, "parked")
        compare(_snap().P2.state, "parked")
        compare(_snap().P1.edit, null)
    }

    // ── held ledger rows ─────────────────────────────────────────────────

    function test_held_ledger_row_is_ignored_its_parent_carries_the_state() {
        _edit("e1", "P1")
        OutboxStore.enqueue({ requestId: "r-t1", entity: "transaction", entityId: "t1", action: "create",
                              before: null, after: {}, dependsOn: "e1" })
        compare(Object.keys(_snap()).join(), "P1")
        compare(Object.keys(_snap("transaction")).length, 0, "held rows are not 'unsynced edits' of their own")
    }
    function test_orphaned_held_row_is_ignored_edge() {
        OutboxStore.enqueue({ requestId: "r-t1", entity: "transaction", entityId: "t1", action: "create",
                              before: null, after: {}, dependsOn: "gone" })
        compare(Object.keys(_snap("transaction")).length, 0)
    }

    // ── agrees with the guards ───────────────────────────────────────────

    function test_state_present_iff_guard_or_parked_says_so() {
        _edit("e1", "P1"); _delta("d1", "P2"); _edit("e3", "P3"); _park("e3"); _delta("d4", "P4"); _park("d4")
        var ids = ["P1", "P2", "P3", "P4", "P5"]
        var s = _snap()
        for (var i = 0; i < ids.length; ++i) {
            var id = ids[i]
            var flagged = OutboxStore.hasUnsyncedEditForEntity("inventory", id) || OutboxStore.hasParkedForEntity("inventory", id)
            compare(!!s[id], flagged, "badge map and guards disagree for " + id)
            if (s[id] && OutboxStore.hasParkedForEntity("inventory", id)) compare(s[id].state, "parked")
        }
    }

    // ── lifecycle ────────────────────────────────────────────────────────

    function test_acked_edit_leaves_the_map() {
        _edit("e1", "P1")
        OutboxStore.markAcked("e1")
        compare(Object.keys(_snap()).length, 0)
    }
    function test_discarded_edit_leaves_the_map() {
        _edit("e1", "P1")
        OutboxStore.markSent("e1")
        compare(Object.keys(_snap()).length, 0)
    }
    function test_does_not_mutate_the_outbox_negative() {
        _edit("e1", "P1"); _park("e1")
        var before = JSON.stringify(OutboxStore.items)
        _snap(); _snap("order")
        compare(JSON.stringify(OutboxStore.items), before)
    }
    function test_unknown_entity_gives_empty_map_negative() { compare(Object.keys(_snap("nope")).length, 0) }
    function test_monkey_many_products_mixed_kinds() {
        for (var i = 0; i < 50; ++i) {
            var id = "P" + i
            if (i % 5 === 0) _delta("d" + i, id)
            else _edit("e" + i, id, i % 5 === 1 ? "create" : (i % 5 === 2 ? "delete" : "update"))
            if (i % 7 === 0) _park(i % 5 === 0 ? "d" + i : "e" + i)
        }
        var s = _snap()
        for (var j = 0; j < 50; ++j) {
            var pid = "P" + j
            var flagged = OutboxStore.hasUnsyncedEditForEntity("inventory", pid) || OutboxStore.hasParkedForEntity("inventory", pid)
            compare(!!s[pid], flagged, "mismatch at " + pid)
        }
    }
}
