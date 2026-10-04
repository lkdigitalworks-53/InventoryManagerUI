import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// S3: a discarded parked write makes DataModel re-read the stores it touched
// (docs/superpowers/specs/2026-09-30-s3-discard-resync-design.md, decision P2).
//
// Network-free: each store's `_resetAndFetch()` returns early with
// `_resetPending = true` while `loadingMore` is true, so setting `loadingMore` first
// lets us observe "this store was asked to resync" without any FirebaseService call.
//
// NOT RUN IN THIS SANDBOX: no Qt toolchain; CI is the first run.
TestCase {
    name: "DataModel_discardResync"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }

    readonly property var stores: ({
        "inventory": InventoryStore, "stock_batch": StockBatchStore, "order": OrdersStore,
        "staff": StaffStore, "supplier": SupplierStore, "transaction": TransactionStore
    })

    function init() {
        for (var k in stores) { stores[k].loadingMore = true; stores[k]._resetPending = false }
    }

    function cleanup() {
        for (var k in stores) { stores[k].loadingMore = false; stores[k]._resetPending = false }
    }

    function _pending() {
        var out = []
        for (var k in stores) if (stores[k]._resetPending) out.push(k)
        return out.sort()
    }

    // ── the pure mapping ─────────────────────────────────────────────────────

    function test_each_entity_maps_to_its_store() {
        compare(dm._storesToResync(["inventory"]), ["inventory"])
        compare(dm._storesToResync(["stock_batch"]), ["stock_batch"])
        compare(dm._storesToResync(["order"]), ["order"])
        compare(dm._storesToResync(["staff"]), ["staff"])
        compare(dm._storesToResync(["removed_staff"]), ["staff"])
        compare(dm._storesToResync(["supplier"]), ["supplier"])
        compare(dm._storesToResync(["transaction"]), ["transaction"])
    }

    function test_staff_and_removed_staff_resync_the_staff_store_once() {
        compare(dm._storesToResync(["staff", "removed_staff", "staff"]), ["staff"])
    }

    function test_stock_movement_and_unknown_entities_are_ignored() {
        compare(dm._storesToResync(["stock_movement"]), [])
        compare(dm._storesToResync(["nope", "", "constructor", "toString", "__proto__"]), [])
    }

    function test_several_entities_keep_first_seen_order_without_repeats() {
        compare(dm._storesToResync(["order", "inventory", "order", "transaction"]), ["order", "inventory", "transaction"])
    }

    function test_junk_input_gives_nothing() {
        var junk = [null, undefined, 0, "x", {}, true]
        for (var i = 0; i < junk.length; ++i) compare(dm._storesToResync(junk[i]), [], String(i))
        compare(dm._storesToResync([]), [])
        compare(dm._storesToResync([null, 5, {}]), [])
    }

    // Keeps DataModel in step with Gateway: a new entity must be mapped or knowingly ignored.
    function test_every_gateway_entity_is_mapped_or_explicitly_ignored() {
        var ignored = { "stock_movement": true }
        for (var entity in Gateway._collections) {
            if (ignored[entity]) continue
            verify(dm._storesToResync([entity]).length === 1, "unmapped Gateway entity: " + entity)
        }
    }

    // ── the effect ───────────────────────────────────────────────────────────

    function test_resync_asks_only_the_affected_stores() {
        dm._resyncForDiscard(["inventory", "order"])
        compare(_pending(), ["inventory", "order"])
    }

    function test_each_store_really_is_resynced() {
        for (var entity in stores) {
            cleanup(); init()
            dm._resyncForDiscard([entity])
            compare(_pending(), [entity], entity)
        }
    }

    function test_removed_staff_resyncs_the_staff_store() {
        dm._resyncForDiscard(["removed_staff"])
        compare(_pending(), ["staff"])
    }

    function test_unmapped_entities_resync_nothing() {
        dm._resyncForDiscard(["stock_movement", "nope"])
        compare(_pending(), [])
    }

    function test_empty_and_junk_resync_nothing() {
        dm._resyncForDiscard([]); dm._resyncForDiscard(null); dm._resyncForDiscard(undefined)
        compare(_pending(), [])
    }

    // ── the wiring: Gateway's signal reaches the handler ─────────────────────

    function test_the_gateway_signal_triggers_the_resync() {
        Gateway.parkedWriteDiscarded("r1", ["supplier", "transaction"])
        compare(_pending(), ["supplier", "transaction"])
    }

    function test_the_gateway_signal_with_no_entities_does_nothing() {
        Gateway.parkedWriteDiscarded("r1", [])
        compare(_pending(), [])
    }

    // Monkey: random entity lists never throw and always resync exactly the mapped stores.
    function test_monkey_random_entity_lists() {
        var s = 31
        function rnd() { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296 }
        var names = ["inventory", "stock_batch", "order", "staff", "removed_staff", "supplier", "transaction", "stock_movement", "zzz", "", null]
        for (var step = 0; step < 200; ++step) {
            cleanup(); init()
            var list = []
            var n = Math.floor(rnd() * 6)
            for (var i = 0; i < n; ++i) list.push(names[Math.floor(rnd() * names.length)])
            dm._resyncForDiscard(list)
            compare(_pending(), dm._storesToResync(list).slice().sort(), "step " + step)
        }
    }
}
