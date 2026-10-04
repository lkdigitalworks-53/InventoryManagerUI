import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// PR #122 S4 + 1 MiB cap, store level:
//  - InventoryStore.syncStates (badge) tracks the outbox: pending, parked, back to "" after ack /
//    discard / drop, and does not re-publish when nothing changed.
//  - InventoryStore._overlayUnsynced lays queued (pending AND parked) edits over a server page,
//    the same code path _fetchFromFirebase uses, so a relaunch inside the retry window keeps the
//    edit (PR #121 device obs 3) without resurrecting stale stock.
//  - updateRefusal / updateProduct / addProduct refuse a doc over 1 MiB BEFORE anything is queued
//    (PR #121 device obs 1), and DataModel surfaces the refusal and skips its side effects.
// Harness: gateway mode, offline. NOT RUN IN THIS SANDBOX: CI runs it.
TestCase {
    name: "InventoryStore_overlayAndCap"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }
    SignalSpy { id: errSpy; target: testLogic; signalName: "errorOccurred" }
    SignalSpy { id: updSpy; target: testLogic; signalName: "productUpdated" }
    SignalSpy { id: statesSpy; target: InventoryStore; signalName: "syncStatesChanged" }

    property string _prevMode: ""
    property string _prevRole: ""

    function _rep(ch, n) { var s = ""; for (var i = 0; i < n; ++i) s += ch; return s }
    function _doc(id, price, stock) {
        return InventoryStore._newProductDoc(id, "Widget " + id, "SKU-" + id, "General", stock === undefined ? 10 : stock,
                                             2, 100, price === undefined ? 25 : price, false, 0, "", "pc", "d", "SUP-001")
    }
    function _editItem(id) {
        return OutboxStore.items.filter(function(i) { return i.entity === "inventory" && i.entityId === (id || "P1") })[0]
    }
    function _park(id) { OutboxStore.setStuckMeta(id, { failures: 5, stuck: true, terminal: true }) }
    // what the server would return after a relaunch: the OLD copy, normalized like a real page
    function _serverPage(price, stock) { return InventoryStore._normalizeProducts([_doc("P1", price, stock)]) }

    function init() {
        _prevMode = Gateway.mode
        _prevRole = AuthStore.role
        Gateway.mode = "gateway"
        AuthStore.idToken = ""
        AuthStore.role = "owner"
        OutboxStore.clear()
        ActivityLog.clear()
        TransactionStore.entries = []
        TransactionStore.revision = 0
        InventoryStore._pendingUpdateActivity = ({})
        InventoryStore.products = [_doc("P1"), _doc("P2")]
        InventoryStore.syncStates = ({})
        StockBatchStore.batches = []
        errSpy.clear(); updSpy.clear(); statesSpy.clear()
    }
    function cleanup() { OutboxStore.clear(); ActivityLog.clear(); Gateway.mode = _prevMode; AuthStore.role = _prevRole }

    // ── syncStates / badge ───────────────────────────────────────────────

    function test_no_edit_no_state_edge() {
        compare(InventoryStore.syncStateOf("P1"), "")
        compare(Object.keys(InventoryStore.syncStates).length, 0)
    }
    function test_edit_makes_the_product_pending_and_only_that_product() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        compare(InventoryStore.syncStateOf("P1"), "pending")
        compare(InventoryStore.syncStateOf("P2"), "")
    }
    function test_parked_edit_shows_parked() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        _park(_editItem().requestId)
        compare(InventoryStore.syncStateOf("P1"), "parked")
    }
    function test_retry_flips_parked_back_to_pending() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        var id = _editItem().requestId
        _park(id)
        OutboxStore.setStuckMeta(id, { failures: 0 })
        compare(InventoryStore.syncStateOf("P1"), "pending")
    }
    function test_ack_clears_the_state() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        Gateway._ackSingle(_editItem())
        compare(InventoryStore.syncStateOf("P1"), "")
    }
    function test_discard_clears_the_state() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        OutboxStore.markSent(_editItem().requestId); Gateway._reschedule()
        compare(InventoryStore.syncStateOf("P1"), "")
    }
    function test_ledger_rows_held_behind_the_edit_do_not_show_a_state_of_their_own_edge() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30, stock: 4 }, "")
        compare(Object.keys(InventoryStore.syncStates).join(), "P1")
    }
    function test_stock_delta_alone_does_not_badge_edge() {
        Gateway.recordDelta("inventory", "P1", { stock: -1 }, { stock: 0 })
        compare(InventoryStore.syncStateOf("P1"), "")
    }
    function test_syncStates_is_not_republished_when_nothing_changed_edge() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        statesSpy.clear()
        Gateway.recordDelta("inventory", "P2", { stock: -1 }, { stock: 0 })   // outbox changed, states did not
        compare(statesSpy.count, 0, "bindings on syncStates must not re-evaluate on every sale delta")
    }
    function test_unknown_product_state_is_empty_negative() {
        compare(InventoryStore.syncStateOf("NOPE"), "")
        compare(InventoryStore.syncStateOf(""), "")
        compare(InventoryStore.syncStateOf(undefined), "")
    }
    function test_two_products_two_states() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        InventoryStore.updateProduct("P2", { sellingPrice: 31 }, "")
        _park(_editItem("P2").requestId)
        compare(InventoryStore.syncStateOf("P1"), "pending")
        compare(InventoryStore.syncStateOf("P2"), "parked")
    }

    // ── overlay on a server read ─────────────────────────────────────────

    function test_overlay_keeps_the_local_edit_after_a_relaunch_device_obs_3() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")      // local 25 -> 30, queued
        var page = InventoryStore._overlayUnsynced(_serverPage(25))       // server still says 25
        compare(page[0].sellingPrice, 30)
    }
    function test_overlay_applies_to_a_parked_edit_too() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        _park(_editItem().requestId)
        compare(InventoryStore._overlayUnsynced(_serverPage(25))[0].sellingPrice, 30)
    }
    function test_overlay_does_not_resurrect_stale_stock() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")      // edit made at stock 10
        var page = InventoryStore._overlayUnsynced(_serverPage(25, 7))    // server stock is 7 now
        compare(page[0].stock, 7)
        compare(page[0].sellingPrice, 30)
    }
    function test_overlay_replays_a_stock_edit_the_user_made() {
        InventoryStore.updateProduct("P1", { stock: 4 }, "")
        compare(InventoryStore._overlayUnsynced(_serverPage(25, 10))[0].stock, 4)
    }
    function test_overlay_net_of_two_merged_edits() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        InventoryStore.updateProduct("P1", { sellingPrice: 40, name: "Renamed" }, "")
        var p = InventoryStore._overlayUnsynced(_serverPage(25))[0]
        compare(p.sellingPrice, 40)
        compare(p.name, "Renamed")
    }
    function test_overlay_stops_after_ack() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        Gateway._ackSingle(_editItem())
        compare(InventoryStore._overlayUnsynced(_serverPage(30))[0].sellingPrice, 30)
        compare(InventoryStore._overlayUnsynced(_serverPage(99))[0].sellingPrice, 99, "server value wins once acked")
    }
    function test_overlay_stops_after_discard_shows_the_server_value() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        OutboxStore.markSent(_editItem().requestId); Gateway._reschedule()
        compare(InventoryStore._overlayUnsynced(_serverPage(25))[0].sellingPrice, 25)
    }
    function test_overlay_leaves_other_products_alone() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        var page = InventoryStore._normalizeProducts([_doc("P1", 25), _doc("P2", 55)])
        var out = InventoryStore._overlayUnsynced(page)
        compare(out[0].sellingPrice, 30)
        compare(out[1].sellingPrice, 55)
    }
    function test_overlay_covers_each_page_of_a_paged_read_edge() {
        InventoryStore.updateProduct("P2", { sellingPrice: 31 }, "")
        var p1 = InventoryStore._overlayUnsynced(InventoryStore._normalizeProducts([_doc("P1", 25)]))
        var p2 = InventoryStore._overlayUnsynced(InventoryStore._normalizeProducts([_doc("P2", 25)]))
        compare(p1[0].sellingPrice, 25)
        compare(p2[0].sellingPrice, 31)
    }
    function test_overlay_with_empty_outbox_changes_nothing_edge() {
        compare(InventoryStore._overlayUnsynced(_serverPage(25))[0].sellingPrice, 25)
    }
    function test_overlay_empty_page_edge() { compare(InventoryStore._overlayUnsynced([]).length, 0) }
    function test_overlay_of_a_product_deleted_on_the_server_is_ignored_edge() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        var out = InventoryStore._overlayUnsynced(InventoryStore._normalizeProducts([_doc("P2", 25)]))
        compare(out.length, 1)
        compare(out[0].productId, "P2")
    }
    function test_overlay_does_not_touch_the_live_products_array() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        var live = JSON.stringify(InventoryStore.products)
        InventoryStore._overlayUnsynced(_serverPage(25))
        compare(JSON.stringify(InventoryStore.products), live)
    }
    function test_overlay_queued_create_is_not_replayed_roadmap_edge() {
        OutboxStore.enqueue({ requestId: "c1", entity: "inventory", entityId: "PNEW", action: "create",
                              before: null, after: _doc("PNEW") })
        compare(InventoryStore._overlayUnsynced(_serverPage(25)).length, 1, "a queued create is NOT injected into the read (roadmap)")
        compare(InventoryStore.syncStateOf("PNEW"), "pending")
    }

    // ── 1 MiB cap ────────────────────────────────────────────────────────

    function test_updateRefusal_small_edit_fits() { compare(InventoryStore.updateRefusal("P1", { description: "short" }), "") }
    function test_updateRefusal_over_one_mib_description_is_refused() {
        compare(InventoryStore.updateRefusal("P1", { description: _rep("a", 1100000) }), InventoryStore.tooLargeMessage)
    }
    function test_updateRefusal_exactly_one_mib_description_is_refused_edge() {
        compare(InventoryStore.updateRefusal("P1", { description: _rep("a", 1048576) }), InventoryStore.tooLargeMessage)
    }
    function test_updateRefusal_uses_bytes_not_characters_edge() {
        compare(InventoryStore.updateRefusal("P1", { description: _rep("क", 400000) }), InventoryStore.tooLargeMessage)
    }
    function test_updateRefusal_unknown_product_is_empty_negative() {
        compare(InventoryStore.updateRefusal("NOPE", { description: _rep("a", 1100000) }), "")
    }
    function test_updateRefusal_undefined_fields_edge() { compare(InventoryStore.updateRefusal("P1", undefined), "") }
    function test_updateRefusal_does_not_mutate_the_product() {
        InventoryStore.updateRefusal("P1", { description: _rep("a", 1100000) })
        compare(InventoryStore.getById("P1").description, "d")
    }
    function test_oversize_product_can_still_be_edited_down_edge() {
        // a doc that is already big (e.g. legacy) but the NEW value fits must be allowed
        InventoryStore.products = [Object.assign(_doc("P1"), { description: _rep("a", 1100000) })]
        compare(InventoryStore.updateRefusal("P1", { description: "short" }), "")
    }

    function test_updateProduct_refuses_oversize_and_changes_nothing_device_obs_1() {
        var msg = InventoryStore.updateProduct("P1", { description: _rep("a", 1100000), sellingPrice: 99 }, "why")
        compare(msg, InventoryStore.tooLargeMessage)
        compare(InventoryStore.getById("P1").sellingPrice, 25, "no optimistic local change")
        compare(InventoryStore.getById("P1").description, "d")
        compare(OutboxStore.items.length, 0, "nothing queued: no edit, no held ledger row")
        compare(TransactionStore.entries.length, 0)
        compare(ActivityLog.entries.filter(function(e) { return e.kind === "product_updated" }).length, 0)
        compare(Object.keys(InventoryStore._pendingUpdateActivity).length, 0)
        compare(InventoryStore.syncStateOf("P1"), "")
    }
    function test_updateProduct_returns_undefined_when_accepted() {
        compare(InventoryStore.updateProduct("P1", { sellingPrice: 30 }, ""), undefined)
        verify(_editItem())
    }
    function test_updateProduct_refusal_is_per_edit_not_sticky_edge() {
        InventoryStore.updateProduct("P1", { description: _rep("a", 1100000) }, "")
        compare(InventoryStore.updateProduct("P1", { sellingPrice: 30 }, ""), undefined)
        compare(InventoryStore.getById("P1").sellingPrice, 30)
    }
    function test_updateProduct_refusal_leaves_an_earlier_queued_edit_intact_edge() {
        InventoryStore.updateProduct("P1", { sellingPrice: 30 }, "")
        InventoryStore.updateProduct("P1", { description: _rep("a", 1100000) }, "")
        compare(OutboxStore.items.filter(function(i) { return i.entity === "inventory" }).length, 1)
        compare(_editItem().after.sellingPrice, 30)
        compare(_editItem().after.description, "d")
    }

    function test_addProduct_refuses_oversize_before_minting_anything() {
        var got = null
        InventoryStore.addProduct("Big", "SKU-B", "General", _rep("a", 1100000), 10, "pc", 1, 0, 12, false, 0,
                                  undefined, undefined, "", function(ok, id, refusal) { got = { ok: ok, id: id, refusal: refusal } })
        verify(got !== null, "refused synchronously: no counter mint, no supplier call")
        compare(got.ok, false)
        compare(got.id, "")
        compare(got.refusal, InventoryStore.tooLargeMessage)
        compare(OutboxStore.items.length, 0)
        compare(InventoryStore.products.length, 2)
    }
    function test_addProduct_oversize_without_callback_does_not_throw_edge() {
        InventoryStore.addProduct("Big", "SKU-B", "General", _rep("a", 1100000), 10, "pc", 1, 0, 12, false, 0)
        compare(InventoryStore.products.length, 2)
    }

    // ── DataModel route ──────────────────────────────────────────────────

    function test_dataModel_update_oversize_reports_and_skips_side_effects() {
        testLogic.updateProduct("P1", { description: _rep("a", 1100000), stock: 3 }, "")
        compare(errSpy.count, 1)
        compare(errSpy.signalArguments[0][0], "inventory")
        compare(errSpy.signalArguments[0][1], InventoryStore.tooLargeMessage)
        compare(updSpy.count, 0, "no productUpdated for a refused edit")
        compare(OutboxStore.items.length, 0)
        compare(StockBatchStore.batches.filter(function(b) { return b.productId === "P1" }).length, 0, "no batch reconcile")
    }
    function test_dataModel_update_ok_emits_productUpdated_and_no_error() {
        testLogic.updateProduct("P1", { sellingPrice: 30 }, "")
        compare(errSpy.count, 0)
        compare(updSpy.count, 1)
        verify(_editItem())
    }
    function test_dataModel_update_oversize_as_staff_is_still_an_auth_error_negative() {
        AuthStore.role = "staff"
        testLogic.updateProduct("P1", { description: _rep("a", 1100000) }, "")
        compare(errSpy.count, 1)
        compare(errSpy.signalArguments[0][0], "auth")
    }
    function test_dataModel_add_oversize_reports_the_refusal_not_a_network_error() {
        testLogic.addProduct("Big", "SKU-B", "General", _rep("a", 1100000), 10, "pc", 1, 0, 12, false, 0)
        compare(errSpy.count, 1)
        compare(errSpy.signalArguments[0][0], "inventory")
        compare(errSpy.signalArguments[0][1], InventoryStore.tooLargeMessage)
    }

    // ── monkey ───────────────────────────────────────────────────────────

    function test_monkey_random_edits_park_ack_discard_keep_state_consistent() {
        var seed = 7
        function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n }
        for (var step = 0; step < 80; ++step) {
            var id = rnd(2) === 0 ? "P1" : "P2"
            var op = rnd(5)
            var item = _editItem(id)
            if (op === 0) InventoryStore.updateProduct(id, { sellingPrice: 20 + rnd(50) }, "")
            else if (op === 1 && item) _park(item.requestId)
            else if (op === 2 && item) OutboxStore.setStuckMeta(item.requestId, { failures: 0 })
            else if (op === 3 && item) Gateway._ackSingle(item)
            else if (op === 4 && item) { OutboxStore.markSent(item.requestId); Gateway._reschedule() }
            var snap = OutboxStore.unsyncedByEntity("inventory")
            var ids = ["P1", "P2"]
            for (var i = 0; i < ids.length; ++i) {
                var want = snap[ids[i]] ? snap[ids[i]].state : ""
                compare(InventoryStore.syncStateOf(ids[i]), want, "badge out of step with outbox at step " + step)
                compare(!!snap[ids[i]], OutboxStore.hasUnsyncedEditForEntity("inventory", ids[i]) || OutboxStore.hasParkedForEntity("inventory", ids[i]))
            }
        }
    }
}
