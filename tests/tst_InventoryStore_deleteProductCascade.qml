import QtQuick
import QtTest
import "../qml/model"

// Coverage for the Tier C design
// (docs/superpowers/specs/2026-09-02-cleanup-batches-photo-on-product-delete.md):
// deleteProduct() now cascades to remove every batch for the deleted product
// (all of them, not just open ones), routes each through the same
// Gateway.recordMutation("stock_batch", ..., "delete", ...) audit pattern
// StockBatchStore already uses, and (as of the 2026-09-21 photos feature)
// calls StorageService.removeProductPhoto once per remaining photoId, or
// falls back to a direct native cleanup for a never-migrated product's
// legacy photoUrl -- guarded in a try/catch since a native-context-property
// call (ImageProcessor) is reachable from this path and this test
// environment doesn't have it registered (same failure class as the
// DataModel logic/dispatcher bug, Skill 58).
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

    function init() {
        InventoryStore.products = []
        StockBatchStore.batches = []
        PhotoQueue.clear()
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
        // As of the 2026-09-21 photos feature this specific fixture (no photoIds, no photoUrl)
        // no longer actually throws anywhere in the cascade -- every native-context-property call
        // reachable from it (PhotoQueue.discard's ImageProcessor calls, and this function's own
        // legacy-photoUrl ImageProcessor.removeLocalCopy call) is now guarded with
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
        // Exercises the actual 2026-09-21 multi-photo cascade loop (one removeProductPhoto call
        // per id) rather than the no-photos fixture above. Can't spy on
        // StorageService.removeProductPhoto to assert it was called per id -- QML `function`
        // members aren't reassignable (see this file's 2026-09-14 correction note above, same
        // constraint, same reason) -- so this proves the same thing the Gateway.recordMutation
        // cases already do: the real call completes and doesn't block the delete.
        var p = _product("SKU-1")
        p.photoIds = ["photo-1", "photo-2"]
        InventoryStore.products = [p]
        StockBatchStore.batches = []

        InventoryStore.deleteProduct("SKU-1")

        compare(InventoryStore.products.length, 0)
    }

    function test_deleteProduct_with_a_legacy_photoUrl_and_no_photoIds_still_completes() {
        // A never-migrated product: photoIds is empty, photoUrl is set -- the cascade's other
        // branch (direct ImageProcessor.removeLocalCopy(productId) for the legacy local file).
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

        compare(_queuedIds().join(","), "b1", "only the other product's photo survives")
        compare(PhotoQueue.pendingCount, 1)
    }

    function test_deleteProduct_discards_queued_photos_in_every_state() {
        InventoryStore.products = [_product("SKU-1")]
        var states = ["enqueued", "uploading", "retrying", "failed"]
        for (var i = 0; i < states.length; ++i) _queued("p" + i, "SKU-1", states[i])

        InventoryStore.deleteProduct("SKU-1")

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
        compare(PhotoQueue.pendingCount, 0)
    }

    function test_deleteProduct_with_no_queued_photos_leaves_the_queue_alone() {
        InventoryStore.products = [_product("SKU-1"), _product("SKU-2")]
        _queued("b1", "SKU-2")

        InventoryStore.deleteProduct("SKU-1")

        compare(_queuedIds().join(","), "b1")
    }

    function test_deleteProduct_of_an_unknown_id_does_not_touch_the_queue() {
        InventoryStore.products = [_product("SKU-1")]
        _queued("a1", "SKU-GHOST")

        InventoryStore.deleteProduct("SKU-GHOST")

        compare(PhotoQueue.pendingCount, 1, "unknown product: early return, nothing purged")
    }

    function test_deleteProduct_with_an_empty_queue_does_not_throw() {
        InventoryStore.products = [_product("SKU-1")]
        InventoryStore.deleteProduct("SKU-1")
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
        compare(_queuedIds().join(","), expectKeep.sort().join(","))
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
