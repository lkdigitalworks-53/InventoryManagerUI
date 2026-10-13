import QtQuick
import QtTest
import "../qml/model"

// Coverage for the Tier C design
// (docs/superpowers/specs/2026-09-02-cleanup-batches-photo-on-product-delete.md):
// deleteProduct() now cascades to remove every batch for the deleted product
// (all of them, not just open ones), routes each through the same
// Gateway.recordMutation("stock_batch", ..., "delete", ...) audit pattern
// StockBatchStore already uses, and (as of the 2026-09-21 photos feature)
// purges the product's queued photos (PhotoQueue.discard, native ImageProcessor
// guarded in a try/catch -- same failure class as the DataModel logic/dispatcher
// bug, Skill 58). Confirmed photos are NOT removed client-side any more (PH4 item 3,
// 2026-10-04): the server sweeps them after a committed delete. The 409 case is pinned
// in test/e2e/tst_ProductPhotosE2E.qml (test_stale_delete_409_keeps_the_product_and_every_photo).
//
// Also covers _activeBatches(), the shared filter introduced in the same
// change to replace four duplicated inline guards (one per bug fix) with
// one place to get it right — see tst_InventoryStore_valueOrphanedBatch.qml
// and tst_InventoryStore_potentialProfitOrphanedBatch.qml, both of which
// exercise the *external* behavior of the functions refactored to use it
// and should still pass unmodified, proving the refactor didn't change
// what those functions return.
//
// CORRECTED 2026-09-14 after a real CI failure: this file originally tried
// to spy on Gateway.recordMutation by reassigning it
// (`Gateway.recordMutation = function(...) {}`) to verify audit routing.
// That throws "Cannot assign to read-only property" -- a QML `function`
// member isn't a reassignable JS property like a plain object's. Removed
// the spy and the one test that needed it; the real (non-mocked)
// deleteProduct() -> Gateway.recordMutation path is exercised directly
// instead, which is safe -- tst_DataModel_deleteGuards.qml already does
// the same for the pre-cascade version of this function and passes on CI.
TestCase {
    name: "InventoryStore_deleteProductCascade"

    property string _prevMode: ""

    function init() {
        _prevMode = Gateway.mode
        Gateway.mode = "gateway"      // recordMutation enqueues (no network without an idToken)
        OutboxStore.clear()
        ActivityLog.clear()
        InventoryStore._pendingDeletes = ({})
        InventoryStore.products = []
        StockBatchStore.batches = []
        PhotoQueue.clear()
    }

    function cleanup() {
        OutboxStore.clear()
        Gateway.mode = _prevMode
    }

    // The server's 2xx for the product delete (Gateway fires this from _ackSingle).
    function _ack(id, action) { Gateway.mutationApplied("inventory", id, action === undefined ? "delete" : action) }

    function _entries(kind) {
        return ActivityLog.entries.filter(function(e) { return e.kind === kind })
    }

    function _queued(photoId, productId, state) {
        var it = PhotoQueue.enqueue({ photoId: photoId, productId: productId, uid: "u-none", tenantId: "t-none",
                                      mainFilePath: "/d/" + photoId + ".jpg", thumbFilePath: "/d/" + photoId + "_t.jpg" })
        if (state && state !== "enqueued") {
            PhotoQueue.items = PhotoQueue.items.map(function(x) {
                return x.photoId === photoId ? Object.assign({}, x, { state: state }) : x })
        }
        return it
    }

    function _queuedIds() {
        return PhotoQueue.items.map(function(x) { return x.photoId }).sort()
    }

    function _product(id) {
        return { productId: id, name: "Widget " + id, category: "Widgets", sku: "",
                 unit: "pc", price: 100, sellingPrice: 100, stock: 5, minStock: 0 }
    }

    function _batch(id, productId, qtyRemaining, unitCost) {
        return { batchId: id, productId: productId, supplierId: "", qtyReceived: qtyRemaining,
                 qtyRemaining: qtyRemaining, unitCost: unitCost, receivedDate: "2026-08-01" }
    }

    function test_deleteProduct_removes_every_batch_for_that_product_open_and_exhausted() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        StockBatchStore.batches = [
            _batch("B-1", "SKU-1", 10, 20),   // open
            _batch("B-2", "SKU-1", 0, 20),    // already exhausted -- must still be removed
            _batch("B-3", "SKU-2", 5, 10)     // different product -- must survive
        ]

        InventoryStore.deleteProduct("SKU-1")

        var remaining = StockBatchStore.batches
        compare(remaining.length, 1)
        compare(remaining[0].batchId, "B-3")
    }

    // Audit routing itself (does Gateway.recordMutation actually get called
    // with entity="stock_batch") is deliberately NOT verified by a spy here.
    // QML `function` members are read-only at the JS binding layer --
    // `Gateway.recordMutation = function(...) {}` throws "Cannot assign to
    // read-only property" (found via a real CI failure, not assumed).
    // Calling the real function is safe -- tst_DataModel_deleteGuards.qml
    // already exercises the real deleteProduct() -> Gateway.recordMutation
    // path and passes on CI -- but verifying *what it was called with*
    // without a working spy technique would need inspecting OutboxStore's
    // internal queue, unproven territory. Same call this codebase already
    // makes for Gateway's actual network dispatch (see tst_Gateway.qml):
    // not independently unit-tested. The batch-removal tests below cover
    // the part that matters observably -- that every batch for the
    // deleted product is actually gone from local state.

    function test_deleteProduct_with_no_batches_at_all_does_not_throw() {
        InventoryStore.products = [_product("SKU-1")]
        StockBatchStore.batches = []

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0)
    }

    function test_deleteProduct_completes_despite_photo_cleanup_throwing() {
        // As of the 2026-09-21 photos feature this specific fixture (no photoIds)
        // no longer actually throws anywhere in the cascade -- every native-context-property call
        // reachable from it (PhotoQueue.discard's ImageProcessor calls, and the old legacy
        // ImageProcessor.removeLocalCopy call, removed since) is now guarded with
        // `typeof ImageProcessor !== "undefined"`, and StorageService.removeProductPhoto's XHR
        // branch returns via callback rather than throwing when AuthStore.idToken is unset (the
        // default in this test environment). The try/catch stays in deleteProduct() as cheap
        // insurance against a future edit reintroducing an unguarded native call -- this test's
        // job now is the same as the others below: prove delete still completes either way.
        InventoryStore.products = [_product("SKU-1")]
        StockBatchStore.batches = [_batch("B-1", "SKU-1", 10, 20)]

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0, "product delete must complete")
        compare(StockBatchStore.batches.length, 0, "batch cascade must complete")
    }

    function test_deleteProduct_with_multiple_photoIds_still_completes() {
        // A product with confirmed photoIds deletes cleanly. The client no longer calls
        // removeProductPhoto per id (it ran before the server ack and destroyed photos of a
        // product whose delete was 409-rejected); the e2e test pins that no photo is touched.
        var p = _product("SKU-1")
        p.photoIds = ["photo-1", "photo-2"]
        InventoryStore.products = [p]
        StockBatchStore.batches = []

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0)
    }

    function test_D1_deleteProduct_with_a_stray_legacy_photoUrl_key_still_completes() {
        // PH5 removed the legacy product photoUrl from the client entirely. A row that still
        // carries the key (loaded from a pre-PH5 doc) must delete without error.
        var p = _product("SKU-1")
        p.photoUrl = "file:///tmp/SKU-1.jpg"
        InventoryStore.products = [p]
        StockBatchStore.batches = []

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0)
    }

    // ── F2 (PR #84 final sweep): queued/failed photos of a deleted product must go with it ─────
    // deleteProduct only walked the CONFIRMED photoIds. A queued photo later 404s (terminal), sits
    // as a "failed" item with no UI (its product is gone), and its local files are never removed.
    // (uid/tenantId "u-none" keeps these items out of any drain pass in this environment.)

    function test_deleteProduct_discards_the_products_queued_photos() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        _queued("a1", "SKU-1"); _queued("a2", "SKU-1"); _queued("b1", "SKU-2")

        InventoryStore.deleteProduct("SKU-1")
        compare(PhotoQueue.pendingCount, 3, "BC2 (Q-BC-4): nothing is purged before the ack")
        _ack("SKU-1")

        compare(_queuedIds().join(","), "b1", "only the other product's photo survives")
        compare(PhotoQueue.pendingCount, 1)
    }

    function test_deleteProduct_discards_queued_photos_in_every_state() {
        InventoryStore.products = [_product("SKU-1")]
        var states = ["enqueued", "uploading", "retrying", "failed"]
        for (var i = 0; i < states.length; ++i) _queued("p" + i, "SKU-1", states[i])

        InventoryStore.deleteProduct("SKU-1")
        _ack("SKU-1")

        compare(PhotoQueue.pendingCount, 0, "a failed or in-flight item must not outlive its product")
    }

    function test_deleteProduct_purges_queue_and_still_completes_the_rest_of_the_cascade() {
        var p = _product("SKU-1")
        p.photoIds = ["c1", "c2"]
        InventoryStore.products = [p]
        StockBatchStore.batches = [_batch("B-1", "SKU-1", 10, 20)]
        _queued("q1", "SKU-1")

        InventoryStore.deleteProduct("SKU-1")
        compare(InventoryStore.products.length, 0)
        compare(StockBatchStore.batches.length, 0)
        compare(PhotoQueue.pendingCount, 1, "queued photo waits for the ack")
        _ack("SKU-1")

        compare(PhotoQueue.pendingCount, 0)
    }

    function test_deleteProduct_with_no_queued_photos_leaves_the_queue_alone() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        _queued("b1", "SKU-2")

        InventoryStore.deleteProduct("SKU-1")
        _ack("SKU-1")

        compare(_queuedIds().join(","), "b1")
    }

    function test_deleteProduct_of_an_unknown_id_does_not_touch_the_queue() {
        InventoryStore.products = [_product("SKU-1")]
        _queued("a1", "SKU-GHOST")

        InventoryStore.deleteProduct("SKU-GHOST")
        _ack("SKU-GHOST")

        compare(PhotoQueue.pendingCount, 1, "unknown product: early return, nothing remembered, nothing purged")
        compare(Object.keys(InventoryStore._pendingDeletes).length, 0)
        compare(OutboxStore.pendingCount, 0, "unknown product: nothing sent")
    }

    function test_deleteProduct_with_an_empty_queue_does_not_throw() {
        InventoryStore.products = [_product("SKU-1")]
        InventoryStore.deleteProduct("SKU-1")
        _ack("SKU-1")
        compare(PhotoQueue.pendingCount, 0)
        compare(InventoryStore.products.length, 0)
    }

    function test_deleteProduct_queue_purge_monkey() {
        // Deterministic LCG, 40 items over 3 products, delete one, the rest must be exactly intact.
        // a*m < 2^53 so every product is exact in a double (the old 1103515245 multiplier was not:
        // its low bits vanished and rnd(4) was 0 forever, i.e. only "enqueued" was ever tested).
        var seed = 12345
        function rnd(n) { seed = (seed * 1664525 + 1013904223) % 4294967296; return Math.floor(seed / 65536) % n }
        var states = ["enqueued", "uploading", "retrying", "failed"]
        InventoryStore.products = [_product("P0"), _product("P1"), _product("P2")]
        var expectKeep = []
        var seenStates = {}
        var deleted = 0
        for (var i = 0; i < 40; ++i) {
            var pid = "P" + rnd(3)
            var st = states[rnd(4)]
            seenStates[st] = true
            _queued("m" + i, pid, st)
            if (pid !== "P1") expectKeep.push("m" + i); else ++deleted
        }
        compare(Object.keys(seenStates).length, 4, "the generator must reach every queue state")
        verify(deleted > 0 && expectKeep.length > 0, "both a purged and a surviving group must exist")
        InventoryStore.deleteProduct("P1")
        compare(PhotoQueue.pendingCount, 40, "nothing purged before the ack")
        _ack("P1")
        compare(_queuedIds().join(","), expectKeep.sort().join(","))
    }

    // ── BC2 (design 2026-10-04-product-delete-batch-cascade, Q-BC-3 A / Q-BC-4) ─────────────
    // deleteProduct sends ONLY the product delete. Batches are hidden locally, removed by the
    // server sweep (BC1); the Activity entry and the queued-photo purge wait for the ack.

    function test_BC2_deleteProduct_queues_exactly_one_inventory_delete_and_no_stock_batch_write() {
        InventoryStore.products = [_product("SKU-1")]
        StockBatchStore.batches = [_batch("B-1", "SKU-1", 10, 20), _batch("B-2", "SKU-1", 0, 20), _batch("B-3", "SKU-1", 3, 5)]

        InventoryStore.deleteProduct("SKU-1")

        compare(OutboxStore.items.length, 1)
        compare(OutboxStore.items[0].entity, "inventory")
        compare(OutboxStore.items[0].action, "delete")
        compare(OutboxStore.items.filter(function(i) { return i.entity === "stock_batch" }).length, 0)
        compare(StockBatchStore.batches.length, 0, "still hidden locally, open and exhausted alike")
    }

    function test_BC2_other_products_batches_are_neither_hidden_nor_sent() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        StockBatchStore.batches = [_batch("B-1", "SKU-1", 10, 20), _batch("B-2", "SKU-2", 4, 7)]
        InventoryStore.deleteProduct("SKU-1")
        compare(StockBatchStore.batches.length, 1)
        compare(StockBatchStore.batches[0].batchId, "B-2")
    }

    function test_BC2_no_activity_entry_at_click_time() {
        InventoryStore.products = [_product("SKU-1")]
        InventoryStore.deleteProduct("SKU-1")
        compare(ActivityLog.entries.length, 0)
    }

    function test_BC2_ack_writes_exactly_one_activity_entry_with_name_sku_and_stock() {
        var p = _product("SKU-1"); p.sku = "W-1"; p.stock = 7
        InventoryStore.products = [p]
        InventoryStore.deleteProduct("SKU-1")

        _ack("SKU-1")

        var es = _entries("product_deleted")
        compare(es.length, 1)
        compare(es[0].title, "Product deleted: Widget SKU-1")
        compare(es[0].subtitle, "W-1 · stock 7")
        compare(es[0].entityId, "SKU-1")
    }

    function test_BC2_activity_subtitle_without_a_sku_is_just_the_stock() {
        var p = _product("SKU-1"); p.sku = ""; p.stock = 0
        InventoryStore.products = [p]
        InventoryStore.deleteProduct("SKU-1")
        _ack("SKU-1")
        compare(_entries("product_deleted")[0].subtitle, "stock 0")
    }

    function test_BC2_a_second_ack_for_the_same_delete_logs_nothing_more() {
        InventoryStore.products = [_product("SKU-1")]
        InventoryStore.deleteProduct("SKU-1")
        _ack("SKU-1"); _ack("SKU-1")
        compare(_entries("product_deleted").length, 1, "an idempotent replay ack must not double-log")
        compare(Object.keys(InventoryStore._pendingDeletes).length, 0)
    }

    function test_BC2_acks_for_other_entities_actions_or_ids_are_ignored() {
        InventoryStore.products = [_product("SKU-1")]
        _queued("a1", "SKU-1")
        InventoryStore.deleteProduct("SKU-1")

        Gateway.mutationApplied("order", "SKU-1", "delete")
        Gateway.mutationApplied("stock_batch", "SKU-1", "delete")
        _ack("SKU-1", "update")
        _ack("SKU-1", "create")
        _ack("SKU-1", "")
        _ack("SKU-OTHER")
        _ack("")

        compare(ActivityLog.entries.length, 0)
        compare(PhotoQueue.pendingCount, 1)
        compare(Object.keys(InventoryStore._pendingDeletes).join(","), "SKU-1", "still waiting for ITS ack")
    }

    function test_BC2_a_rejected_delete_forgets_it_so_a_late_ack_logs_and_purges_nothing() {
        InventoryStore.products = [_product("SKU-1")]
        _queued("a1", "SKU-1")
        InventoryStore.deleteProduct("SKU-1")

        InventoryStore._onMutationConflicted("inventory", "SKU-1",
            { productId: "SKU-1", name: "Widget SKU-1", stock: 9, minStock: 0, price: 100, sellingPrice: 100, unit: "pc", category: "Widgets", sku: "" }, "delete")
        _ack("SKU-1")

        compare(ActivityLog.entries.length, 0, "a delete that never committed is never logged")
        compare(PhotoQueue.pendingCount, 1, "its queued photo survives")
        compare(InventoryStore.products.length, 1, "the product came back")
    }

    function test_BC2_a_rejected_update_does_not_forget_a_pending_delete() {
        InventoryStore.products = [_product("SKU-1")]
        InventoryStore.deleteProduct("SKU-1")
        InventoryStore._onMutationConflicted("inventory", "SKU-1", null, "update")
        _ack("SKU-1")
        compare(_entries("product_deleted").length, 1)
    }

    function test_BC2_delete_again_after_a_rejected_delete_logs_once() {
        InventoryStore.products = [_product("SKU-1")]
        InventoryStore.deleteProduct("SKU-1")
        InventoryStore._onMutationConflicted("inventory", "SKU-1",
            { productId: "SKU-1", name: "Widget SKU-1", stock: 5, minStock: 0, price: 100, sellingPrice: 100, unit: "pc", category: "Widgets", sku: "" }, "delete")
        InventoryStore.deleteProduct("SKU-1")
        _ack("SKU-1")
        compare(_entries("product_deleted").length, 1)
    }

    function test_BC2_after_a_relaunch_the_ack_skips_activity_and_purge_by_design() {
        // Design R7 (accepted): the pending map is in memory only. The server audit entry exists.
        InventoryStore.products = [_product("SKU-1")]
        _queued("a1", "SKU-1")
        InventoryStore.deleteProduct("SKU-1")
        InventoryStore._pendingDeletes = ({})   // what a relaunch does

        _ack("SKU-1")

        compare(ActivityLog.entries.length, 0)
        compare(PhotoQueue.pendingCount, 1)
    }

    function test_BC2_two_pending_deletes_are_acked_independently() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        _queued("a1", "SKU-1"); _queued("b1", "SKU-2")
        InventoryStore.deleteProduct("SKU-1"); InventoryStore.deleteProduct("SKU-2")

        _ack("SKU-2")
        compare(_queuedIds().join(","), "a1")
        compare(_entries("product_deleted").length, 1)
        compare(_entries("product_deleted")[0].entityId, "SKU-2")

        _ack("SKU-1")
        compare(PhotoQueue.pendingCount, 0)
        compare(_entries("product_deleted").length, 2)
    }

    function test_BC2_prototype_named_ids_cannot_confuse_the_pending_map() {
        InventoryStore.products = [_product("constructor")]
        InventoryStore.deleteProduct("constructor")
        _ack("toString"); _ack("hasOwnProperty"); _ack("__proto__")
        compare(ActivityLog.entries.length, 0)
        _ack("constructor")
        compare(_entries("product_deleted").length, 1)
        // and an id that was never deleted must not find anything on the prototype
        _ack("constructor")
        compare(_entries("product_deleted").length, 1)
    }

    function test_BC2_a_throwing_photo_purge_never_blocks_the_activity_entry_or_the_cleanup() {
        InventoryStore.products = [_product("SKU-1")]
        InventoryStore.deleteProduct("SKU-1")
        PhotoQueue.items = null   // PhotoQueue.items.filter throws inside the purge

        _ack("SKU-1")

        compare(_entries("product_deleted").length, 1)
        compare(Object.keys(InventoryStore._pendingDeletes).length, 0)
        PhotoQueue.items = []
    }

    function test_BC2_the_real_gateway_ack_path_reaches_the_store() {
        // Through Gateway._ackSingle (what _send calls on a 2xx), not a hand-fired signal.
        InventoryStore.products = [_product("SKU-1")]
        _queued("a1", "SKU-1")
        InventoryStore.deleteProduct("SKU-1")
        var item = OutboxStore.items[0]

        Gateway._ackSingle(item)

        compare(OutboxStore.pendingCount, 0)
        compare(_entries("product_deleted").length, 1)
        compare(PhotoQueue.pendingCount, 0)
    }

    function test_BC2_monkey_random_delete_ack_conflict_sequences() {
        var s = 777
        function rnd(n) { s = (s * 1664525 + 1013904223) % 4294967296; return Math.floor(s / 65536) % n }
        var ids = ["P0", "P1", "P2", "P3"]
        var logged = {}, pending = {}, applied = 0
        for (var step = 0; step < 150; ++step) {
            var id = ids[rnd(4)], roll = rnd(3)
            if (roll === 0) {
                InventoryStore.products = InventoryStore.products.concat([_product(id)].filter(function() {
                    return !InventoryStore.getById(id) }))
                var existed = !!InventoryStore.getById(id)
                InventoryStore.deleteProduct(id)
                if (existed) pending[id] = true
            } else if (roll === 1) {
                _ack(id)
                if (pending[id]) { applied++; delete pending[id] }
            } else {
                InventoryStore._onMutationConflicted("inventory", id, null, "delete")
                delete pending[id]
            }
            compare(_entries("product_deleted").length, applied, "step " + step)
            compare(Object.keys(InventoryStore._pendingDeletes).sort().join(","), Object.keys(pending).sort().join(","), "step " + step)
        }
    }

    function test_late_upload_confirmation_for_a_deleted_product_is_a_noop() {
        // An in-flight upload can still confirm after its product is deleted; Main.qml's
        // onPhotoUploaded then calls applyPhotoIds. It must neither throw nor resurrect anything.
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        InventoryStore.deleteProduct("SKU-1")
        InventoryStore.applyPhotoIds("SKU-1", ["late"], "late", "add")
        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].productId, "SKU-2")
    }

    function test_deleteProduct_still_removes_the_product_itself_unchanged_regression() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        StockBatchStore.batches = []

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 1)
        compare(InventoryStore.products[0].productId, "SKU-2")
    }

    function test_activeBatches_excludes_a_batch_whose_product_was_deleted() {
        InventoryStore.products = [_product("SKU-LIVE")]
        StockBatchStore.batches = [
            _batch("B-1", "SKU-LIVE", 10, 20),
            _batch("B-2", "SKU-ORPHAN", 5, 10)
        ]

        var active = InventoryStore._activeBatches()

        compare(active.length, 1)
        compare(active[0].batchId, "B-1")
    }

    function test_activeBatches_returns_empty_array_when_no_batches_exist() {
        InventoryStore.products = [_product("SKU-LIVE")]
        StockBatchStore.batches = []

        compare(InventoryStore._activeBatches().length, 0)
    }
}
