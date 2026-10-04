import QtQuick
import QtTest
import "../qml/model"

// PR #121 follow-up (Taher, Q2 = outbox dependsOn): a ledger row (transaction create) is HELD in
// the outbox until the edit it belongs to is ACKED by the server, and deleted if that edit leaves
// the outbox any other way (discard, conflict, permanent drop). Covers every new OutboxStore piece:
// enqueue({dependsOn}), dueItems/nextDueInMs skipping held items, markAcked (atomic release),
// pruneOrphans (+ the load-time prune), hasUnsyncedEditForEntity (the sale guard's query).
// Pure data-structure logic, no network. NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "OutboxStore_dependsOn"

    function init() { OutboxStore.clear(); OutboxStore._rand = function() { return 0.5 } }
    function cleanup() { OutboxStore.clear() }

    function _edit(id, productId, action) {
        return OutboxStore.enqueue({ requestId: id, entity: "inventory", entityId: productId || "P1",
                                     action: action || "update", before: { v: 0 }, after: { v: 1 } })
    }
    function _tx(id, parentId) {
        return OutboxStore.enqueue({ requestId: "r-" + id, entity: "transaction", entityId: id,
                                     action: "create", before: null, after: { txId: id }, dependsOn: parentId })
    }
    function _ids(arr) { return arr.map(function(i) { return i.requestId }) }
    function _persisted() { return JSON.parse(OutboxStore._settings.itemsJson) }

    // ── enqueue ──────────────────────────────────────────────────────────

    function test_enqueue_stores_dependsOn_on_the_item() {
        _edit("e1")
        var tx = _tx("t1", "e1")
        compare(tx.dependsOn, "e1")
        compare(OutboxStore.items.length, 2)
    }
    function test_enqueue_without_dependsOn_has_no_dependsOn_key_edge() {
        var it = _edit("e1")
        verify(!Object.prototype.hasOwnProperty.call(it, "dependsOn"), "old items stay byte-identical")
    }
    function test_enqueue_empty_string_dependsOn_is_not_held_edge() {
        var tx = OutboxStore.enqueue({ requestId: "r1", entity: "transaction", entityId: "t1",
                                       action: "create", after: {}, dependsOn: "" })
        verify(!Object.prototype.hasOwnProperty.call(tx, "dependsOn"))
        compare(OutboxStore.dueItems().length, 1)
    }
    function test_dependent_call_is_never_merged_into_a_queued_item_edge() {
        _edit("e1", "t1") // same entity? no: different entity, but same entityId string
        var tx = _tx("t1", "e1")
        compare(OutboxStore.items.length, 2)
        compare(tx.entity, "transaction")
    }
    function test_two_edits_merge_but_the_stored_item_keeps_the_first_requestId() {
        var a = _edit("e1")
        var b = OutboxStore.enqueue({ requestId: "e2", entity: "inventory", entityId: "P1",
                                      action: "update", before: { v: 1 }, after: { v: 2 } })
        compare(b.requestId, "e1", "recordEdit must hang dependents off THIS id, not the call's")
        compare(OutboxStore.items.length, 1)
    }

    // ── held items are not due ───────────────────────────────────────────

    function test_held_item_is_not_due_while_parent_is_queued() {
        _edit("e1"); _tx("t1", "e1")
        compare(_ids(OutboxStore.dueItems()).join(), "e1")
    }
    function test_held_item_is_not_due_even_when_orphaned_until_pruned_edge() {
        _tx("t1", "gone")
        compare(OutboxStore.dueItems().length, 0, "an orphan must never be sent")
    }
    function test_nextDueInMs_ignores_held_items_so_the_drain_timer_does_not_spin() {
        _edit("e1"); _tx("t1", "e1")
        OutboxStore.markFailed("e1") // parent backs off 2000 ms
        var ms = OutboxStore.nextDueInMs()
        verify(ms > 1000, "timer must follow the parent's backoff, not the held row's now-due slot: " + ms)
    }
    function test_nextDueInMs_is_minus_one_when_only_held_items_remain_edge() {
        _tx("t1", "gone")
        compare(OutboxStore.nextDueInMs(), -1)
    }
    function test_held_item_waits_while_parent_is_in_flight() {
        var e = _edit("e1"); _tx("t1", "e1")
        OutboxStore.markInFlight(e)
        compare(OutboxStore.dueItems().length, 0)
    }
    function test_parked_parent_keeps_dependents_held_edge() {
        _edit("e1"); _tx("t1", "e1")
        OutboxStore.setStuckMeta("e1", { failures: 5, stuck: true, terminal: true })
        compare(OutboxStore.dueItems().length, 0)
        compare(OutboxStore.items.length, 2, "held row stays queued behind the parked edit")
    }

    // ── markAcked ────────────────────────────────────────────────────────

    function test_markAcked_removes_parent_and_releases_dependents() {
        _edit("e1"); _tx("t1", "e1"); _tx("t2", "e1")
        OutboxStore.markAcked("e1")
        compare(_ids(OutboxStore.items).join(), "r-t1,r-t2")
        compare(OutboxStore.items[0].dependsOn, undefined)
        compare(_ids(OutboxStore.dueItems()).join(), "r-t1,r-t2")
    }
    function test_markAcked_is_one_persisted_state_atomic() {
        _edit("e1"); _tx("t1", "e1")
        OutboxStore.markAcked("e1")
        var saved = _persisted()
        compare(saved.length, 1)
        compare(saved[0].requestId, "r-t1")
        verify(!saved[0].dependsOn, "parent removal and release are in the same save")
    }
    function test_markAcked_leaves_other_parents_dependents_held() {
        _edit("e1", "P1"); _edit("e2", "P2"); _tx("t1", "e1"); _tx("t2", "e2")
        OutboxStore.markAcked("e1")
        compare(OutboxStore.items.filter(function(i) { return i.dependsOn === "e2" }).length, 1)
        compare(_ids(OutboxStore.dueItems()).sort().join(), "e2,r-t1")
    }
    function test_markAcked_unknown_id_changes_nothing_edge() {
        _edit("e1"); _tx("t1", "e1")
        OutboxStore.markAcked("nope")
        compare(OutboxStore.items.length, 2)
        compare(OutboxStore.items[1].dependsOn, "e1")
    }
    function test_markAcked_on_a_dependent_with_no_children_just_removes_it_edge() {
        _edit("e1"); _tx("t1", "e1"); OutboxStore.markAcked("e1")
        OutboxStore.markAcked("r-t1")
        compare(OutboxStore.items.length, 0)
    }

    // ── pruneOrphans ─────────────────────────────────────────────────────

    function test_markSent_parent_then_prune_drops_dependents() {
        _edit("e1"); _tx("t1", "e1"); _tx("t2", "e1")
        OutboxStore.markSent("e1") // discard / conflict / permanent drop
        var dropped = OutboxStore.pruneOrphans()
        compare(_ids(dropped).join(), "r-t1,r-t2")
        compare(OutboxStore.items.length, 0)
        compare(_persisted().length, 0)
    }
    function test_prune_keeps_live_dependents_and_unrelated_items() {
        _edit("e1", "P1"); _edit("e2", "P2"); _tx("t1", "e1"); _tx("t2", "e2")
        OutboxStore.markSent("e1")
        var dropped = OutboxStore.pruneOrphans()
        compare(_ids(dropped).join(), "r-t1")
        compare(_ids(OutboxStore.items).join(), "e2,r-t2")
    }
    function test_prune_with_nothing_to_drop_returns_empty_and_does_not_save_edge() {
        _edit("e1"); _tx("t1", "e1")
        var revBefore = OutboxStore.revision
        compare(OutboxStore.pruneOrphans().length, 0)
        compare(OutboxStore.revision, revBefore, "no save, no refresh")
    }
    function test_prune_on_empty_outbox_edge() { compare(OutboxStore.pruneOrphans().length, 0) }
    function test_load_prunes_orphans_left_by_a_crash_edge() {
        _edit("e1"); _tx("t1", "e1")
        OutboxStore.markSent("e1")           // parent gone, dependent still persisted
        OutboxStore.items = []               // simulate a relaunch: reload from the persisted JSON
        OutboxStore._load()
        compare(OutboxStore.items.length, 0, "dangling dependents are dropped at load")
    }
    function test_load_keeps_held_items_with_a_live_parent() {
        _edit("e1"); _tx("t1", "e1")
        OutboxStore.items = []
        OutboxStore._load()
        compare(OutboxStore.items.length, 2)
        compare(_ids(OutboxStore.dueItems()).join(), "e1")
    }

    // ── hasUnsyncedEditForEntity ─────────────────────────────────────────

    function test_unsynced_true_for_a_queued_update() {
        _edit("e1"); verify(OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
    }
    function test_unsynced_true_for_a_queued_create_and_delete_edge() {
        _edit("e1", "P1", "create"); _edit("e2", "P2", "delete")
        verify(OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
        verify(OutboxStore.hasUnsyncedEditForEntity("inventory", "P2"))
    }
    function test_unsynced_true_when_in_flight_and_when_parked_edge() {
        var e = _edit("e1"); OutboxStore.markInFlight(e)
        verify(OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
        OutboxStore.clearInFlight(e)
        OutboxStore.setStuckMeta("e1", { failures: 5, stuck: true, terminal: true })
        verify(OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
    }
    function test_unsynced_false_for_stock_deltas_only() {
        OutboxStore.enqueueDelta({ requestId: "d1", entity: "inventory", entityId: "P1", deltas: { stock: -1 }, floors: { stock: 0 } })
        verify(!OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"), "back-to-back sales must not block each other")
    }
    function test_unsynced_false_for_a_held_ledger_row_edge() {
        _tx("t1", "gone")
        verify(!OutboxStore.hasUnsyncedEditForEntity("transaction", "t1"))
    }
    function test_unsynced_false_for_batches_and_operations_edge() {
        OutboxStore.enqueueBatch({ requestId: "b1", entity: "inventory", items: [{ entityId: "P1", action: "create", before: null, after: {} }] })
        OutboxStore.enqueueOperation({ requestId: "o1", opType: "x", ops: [{ entity: "inventory", entityId: "P1" }] })
        verify(!OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
    }
    function test_unsynced_false_for_other_product_other_entity_and_empty_outbox() {
        verify(!OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
        _edit("e1", "P2")
        verify(!OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
        verify(!OutboxStore.hasUnsyncedEditForEntity("order", "P2"))
    }
    function test_unsynced_false_after_ack() {
        _edit("e1"); OutboxStore.markAcked("e1")
        verify(!OutboxStore.hasUnsyncedEditForEntity("inventory", "P1"))
    }

    // ── monkey ───────────────────────────────────────────────────────────

    function test_monkey_held_items_are_never_due_and_never_dangle_after_prune() {
        var seed = 20261005
        function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n }
        var n = 0
        for (var step = 0; step < 120; ++step) {
            var act = rnd(5)
            var pid = "P" + rnd(3)
            if (act === 0) _edit("e" + (++n), pid)
            else if (act === 1) { var parents = OutboxStore.items.filter(function(i) { return !i.dependsOn && i.entity === "inventory" })
                if (parents.length) _tx("t" + (++n), parents[rnd(parents.length)].requestId) }
            else if (act === 2) { var ps = OutboxStore.items.filter(function(i) { return i.entity === "inventory" })
                if (ps.length) OutboxStore.markAcked(ps[rnd(ps.length)].requestId) }
            else if (act === 3) { var qs = OutboxStore.items.filter(function(i) { return i.entity === "inventory" })
                if (qs.length) OutboxStore.markSent(qs[rnd(qs.length)].requestId); OutboxStore.pruneOrphans() }
            else { OutboxStore.items = []; OutboxStore._load() }
            var due = OutboxStore.dueItems()
            for (var d = 0; d < due.length; ++d) verify(!due[d].dependsOn, "step " + step + ": a held item was handed out")
            OutboxStore.pruneOrphans()
            var live = {}
            OutboxStore.items.forEach(function(i) { live[i.requestId] = true })
            OutboxStore.items.forEach(function(i) { if (i.dependsOn) verify(live[i.dependsOn], "step " + step + ": dangling dependsOn") })
        }
    }
}
