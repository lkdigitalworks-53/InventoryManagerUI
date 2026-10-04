import QtQuick
import QtTest
import "../qml/model"

// PR #121 follow-up (Taher, Q2 + Q3): InventoryStore.updateProduct enqueues the EDIT first, and the
// ledger rows (field_change, stock_adjustment) plus the Activity "product_updated" entry wait for the
// server's ack of THAT edit. If the edit leaves the outbox unacked (discarded, conflicted, rejected
// permanently) the rows are deleted from the outbox AND from TransactionStore.entries, and the
// Activity entry is never written. Device bug it locks down: a description > 1 MiB is rejected by the
// server but its ledger row still registered.
// Harness: gateway mode, offline (no idToken): nothing is sent, ack/discard are simulated by calling
// Gateway._ackSingle / OutboxStore.markSent + Gateway._reschedule, exactly what the real send path calls.
// Direct mode is not exercised (needs FirebaseService). NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "InventoryStore_updateProductAfterAck"

    property string _prevMode: ""

    function init() {
        _prevMode = Gateway.mode
        Gateway.mode = "gateway"
        AuthStore.idToken = ""
        OutboxStore.clear()
        ActivityLog.clear()
        TransactionStore.entries = []
        TransactionStore.revision = 0
        InventoryStore._pendingUpdateActivity = ({})
        InventoryStore.products = [InventoryStore._newProductDoc(
            "PRD-001", "Widget", "SKU-1", "General", 10, 2, 100, 120, false, 0, "", "pc", "A widget", "SUP-001")]
    }
    function cleanup() { OutboxStore.clear(); ActivityLog.clear(); Gateway.mode = _prevMode }

    function _editItem() { return OutboxStore.items.filter(function(i) { return i.entity === "inventory" })[0] }
    function _txItems() { return OutboxStore.items.filter(function(i) { return i.entity === "transaction" }) }
    function _updatedActivity() { return ActivityLog.entries.filter(function(e) { return e.kind === "product_updated" }) }
    function _ack() { Gateway._ackSingle(_editItem()) }
    function _reject() { OutboxStore.markSent(_editItem().requestId); Gateway._reschedule() }

    // ── enqueue order: edit first, rows held ──────────────────────────────

    function test_edit_is_queued_and_ledger_rows_are_held_behind_it() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150, stock: 7 }, "fix")
        var edit = _editItem()
        verify(edit, "the edit is queued")
        var tx = _txItems()
        compare(tx.length, 2, "one field_change + one stock_adjustment")
        for (var i = 0; i < tx.length; ++i) compare(tx[i].dependsOn, edit.requestId)
        compare(OutboxStore.dueItems().filter(function(d) { return d.entity === "transaction" }).length, 0,
                "no ledger row is sendable before the ack")
    }
    function test_local_ledger_rows_still_show_optimistically() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.entries[0].kind, "field_change")
    }
    function test_stock_only_edit_holds_one_stock_adjustment_row() {
        InventoryStore.updateProduct("PRD-001", { stock: 4 }, "")
        compare(_txItems().length, 1)
        compare(_txItems()[0].after.kind, "stock_adjustment")
    }
    function test_no_change_edit_queues_the_edit_but_no_ledger_rows_edge() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 120 }, "")
        verify(_editItem())
        compare(_txItems().length, 0)
    }
    function test_unknown_product_queues_nothing_edge() {
        InventoryStore.updateProduct("NOPE", { sellingPrice: 1 }, "")
        compare(OutboxStore.items.length, 0)
        compare(Object.keys(InventoryStore._pendingUpdateActivity).length, 0)
    }
    function test_activity_entry_is_deferred_until_the_ack() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        compare(_updatedActivity().length, 0)
        compare(InventoryStore._pendingUpdateActivity["PRD-001"].length, 1)
    }

    // ── ack: everything lands ─────────────────────────────────────────────

    function test_ack_releases_the_ledger_rows_and_writes_the_activity_entry() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150, stock: 7 }, "fix")
        _ack()
        compare(_editItem(), undefined, "edit left the outbox")
        var tx = _txItems()
        compare(tx.length, 2)
        for (var i = 0; i < tx.length; ++i) verify(!tx[i].dependsOn, "released")
        compare(OutboxStore.dueItems().length, 2, "now sendable")
        compare(_updatedActivity().length, 1)
        compare(_updatedActivity()[0].entityId, "PRD-001")
        compare(Object.keys(InventoryStore._pendingUpdateActivity).length, 0)
    }
    function test_two_edits_merged_into_one_item_release_together_edge() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 175 }, "")
        compare(OutboxStore.items.filter(function(i) { return i.entity === "inventory" }).length, 1, "merged")
        var edit = _editItem()
        _txItems().forEach(function(t) { compare(t.dependsOn, edit.requestId) })
        _ack()
        compare(_updatedActivity().length, 2)
        compare(_txItems().filter(function(t) { return !!t.dependsOn }).length, 0)
    }
    function test_edit_while_the_first_is_in_flight_depends_on_the_second_item_edge() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        var first = _editItem()
        OutboxStore.markInFlight(first)
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 175 }, "")
        var edits = OutboxStore.items.filter(function(i) { return i.entity === "inventory" })
        compare(edits.length, 2, "second edit is a separate held item")
        var tx = _txItems()
        compare(tx[0].dependsOn, first.requestId)
        compare(tx[1].dependsOn, edits[1].requestId)
        Gateway._ackSingle(first)
        compare(_updatedActivity().length, 1, "only the first edit's entry")
        compare(_txItems().filter(function(t) { return !!t.dependsOn }).length, 1)
    }
    function test_edit_merged_into_a_queued_create_flushes_on_the_create_ack_edge() {
        OutboxStore.clear()
        OutboxStore.enqueue({ requestId: "c1", entity: "inventory", entityId: "PRD-001", action: "create",
                              before: null, after: InventoryStore.products[0] })
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        compare(_editItem().requestId, "c1", "merged into the create")
        _ack()
        compare(_updatedActivity().length, 1, "ack says create, entry still flushes")
    }

    // ── rejection: nothing registers ─────────────────────────────────────

    function test_rejected_edit_drops_held_rows_everywhere() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150, stock: 7 }, "")
        compare(TransactionStore.entries.length, 2)
        _reject()
        compare(OutboxStore.items.length, 0, "no ledger row will ever be sent")
        compare(TransactionStore.entries.length, 0, "no ghost row in the local ledger")
        compare(_updatedActivity().length, 0)
    }
    function test_over_one_MiB_description_rejected_registers_no_transaction() {
        var big = "x".repeat(1048577)
        InventoryStore.updateProduct("PRD-001", { description: big }, "")
        compare(_txItems().length, 1)
        _reject()
        compare(_txItems().length, 0)
        compare(TransactionStore.entries.length, 0)
        compare(_updatedActivity().length, 0)
    }
    function test_discard_signal_drops_that_edits_pending_activity() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        var rid = _editItem().requestId
        Gateway.parkedWriteDiscarded(rid, ["inventory"])
        compare(Object.keys(InventoryStore._pendingUpdateActivity).length, 0)
    }
    function test_discard_of_another_request_keeps_pending_activity_edge() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        Gateway.parkedWriteDiscarded("someone-else", ["inventory"])
        compare(InventoryStore._pendingUpdateActivity["PRD-001"].length, 1)
    }
    function test_conflict_drops_pending_activity_and_held_rows() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        var old = InventoryStore._newProductDoc("PRD-001", "Widget", "SKU-1", "General", 10, 2, 100, 120, false, 0, "", "pc", "A widget", "SUP-001")
        Gateway.mutationConflicted("inventory", "PRD-001", old, "update")
        OutboxStore.markSent(_editItem().requestId)
        Gateway._reschedule()
        compare(Object.keys(InventoryStore._pendingUpdateActivity).length, 0)
        compare(OutboxStore.items.length, 0)
        compare(TransactionStore.entries.length, 0)
    }
    function test_ack_after_a_discard_writes_no_stale_activity_edge() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        Gateway.parkedWriteDiscarded(_editItem().requestId, ["inventory"])
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 160 }, "")
        Gateway.writeAcked("unrelated", "inventory", "PRD-001", "update")
        compare(_updatedActivity().length, 0)
    }

    // ── other entities / actions are ignored ─────────────────────────────

    function test_ack_of_another_entity_or_a_delete_does_not_flush_edge() {
        InventoryStore.updateProduct("PRD-001", { sellingPrice: 150 }, "")
        var rid = _editItem().requestId
        Gateway.writeAcked(rid, "order", "PRD-001", "update")
        compare(_updatedActivity().length, 0)
        Gateway.writeAcked(rid, "inventory", "PRD-001", "delete")
        compare(_updatedActivity().length, 0, "a merged delete drops the entry silently")
        compare(Object.keys(InventoryStore._pendingUpdateActivity).length, 0)
    }
    function test_ack_with_nothing_pending_is_a_noop_edge() {
        Gateway.writeAcked("r", "inventory", "PRD-001", "update")
        compare(_updatedActivity().length, 0)
    }

    // ── monkey ───────────────────────────────────────────────────────────

    function test_monkey_every_edit_ends_acked_or_gone_never_half() {
        var seed = 20261005
        function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n }
        for (var step = 0; step < 40; ++step) {
            OutboxStore.clear(); ActivityLog.clear(); TransactionStore.entries = []
            InventoryStore._pendingUpdateActivity = ({})
            var edits = 1 + rnd(3)
            for (var e = 0; e < edits; ++e)
                InventoryStore.updateProduct("PRD-001", { sellingPrice: 200 + step * 10 + e, stock: 3 + rnd(5) }, "")
            var held = _txItems().length
            if (rnd(2) === 0) {
                _ack()
                compare(_txItems().filter(function(t) { return !!t.dependsOn }).length, 0, "step " + step)
                compare(_txItems().length, held, "step " + step)
                compare(_updatedActivity().length, edits, "step " + step)
            } else {
                _reject()
                compare(_txItems().length, 0, "step " + step)
                compare(TransactionStore.entries.length, 0, "step " + step)
                compare(_updatedActivity().length, 0, "step " + step)
            }
        }
    }
}
