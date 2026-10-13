import QtQuick
import QtTest
import "../qml/model"

// PR #84 device-test bug 2 (2026-09-28): EditProductDialog copied a product's photoIds once, when
// it opened, so a photo confirmed afterwards (PhotoQueue -> Main.qml -> applyPhotoIds) never
// appeared in the open dialog. The dialog now re-reads InventoryStore.photoIdsFor() on every
// InventoryStore.revision change. The dialog itself imports Felgo and cannot load under
// qmltestrunner, so this file locks down the two store functions that wiring stands on:
//   * applyPhotoIds must REPLACE the list with the server's authoritative one and bump revision
//     (revision is the only signal the dialog and InventoryPage listen to);
//   * photoIdsFor must be a safe, fresh-copy read for any product/doc shape.
// NOT RUN IN THIS SANDBOX (no Qt toolchain, standing instruction) -- CI is the proof.
TestCase {
    name: "InventoryStore_photoIds"

    function init() {
        TransactionStore.entries = []
        TransactionStore.revision = 0
        InventoryStore.products = []
        Gateway.mode = "gateway"
        OutboxStore.clear()
        AuthStore.idToken = ""
        AuthStore._settings.sessionJson = ""
    }
    function cleanup() { InventoryStore.products = [] }

    function _p(id, photoIds) {
        return { productId: id, name: "Widget " + id, sku: "S-" + id, category: "General",
                 stock: 5, minStock: 1, price: 10, sellingPrice: 12, taxable: false, taxPercent: 0,
                 size: "", unit: "pcs", description: "",
                 photoIds: photoIds, supplierId: "" }
    }

    // ── photoIdsFor ──────────────────────────────────────────────────────
    function test_photoIdsFor_returns_the_products_ids_in_order() {
        InventoryStore.products = [_p("P1", ["a", "b", "c"])]
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["a","b","c"]')
    }

    function test_photoIdsFor_returns_a_fresh_copy() {
        InventoryStore.products = [_p("P1", ["a"])]
        var got = InventoryStore.photoIdsFor("P1")
        got.push("zzz")
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["a"]', "mutating the result must not touch the store")
    }

    function test_photoIdsFor_unknown_product_is_empty() {
        InventoryStore.products = [_p("P1", ["a"])]
        compare(InventoryStore.photoIdsFor("NOPE").length, 0)
    }

    function test_photoIdsFor_empty_store_is_empty() {
        compare(InventoryStore.photoIdsFor("P1").length, 0)
    }

    function test_photoIdsFor_doc_without_photoIds_is_empty() {
        InventoryStore.products = [{ productId: "P1", name: "Legacy" }]
        compare(InventoryStore.photoIdsFor("P1").length, 0)
    }

    function test_photoIdsFor_non_array_photoIds_is_empty() {
        InventoryStore.products = [{ productId: "P1", photoIds: "not-an-array" }]
        compare(InventoryStore.photoIdsFor("P1").length, 0)
        InventoryStore.products = [{ productId: "P1", photoIds: null }]
        compare(InventoryStore.photoIdsFor("P1").length, 0)
    }

    function test_photoIdsFor_monkey_ids_never_throw() {
        InventoryStore.products = [_p("P1", ["a"])]
        var junk = [undefined, null, "", 0, 42, {}, [], "P1 ", "p1"]
        for (var i = 0; i < junk.length; ++i) {
            var r = InventoryStore.photoIdsFor(junk[i])
            verify(Array.isArray(r), "always an array for input #" + i)
            compare(r.length, 0)
        }
    }

    // ── applyPhotoIds ────────────────────────────────────────────────────
    function test_applyPhotoIds_sets_the_list() {
        InventoryStore.products = [_p("P1", [])]
        InventoryStore.applyPhotoIds("P1", ["a"], "a", "add")
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["a"]')
    }

    function test_applyPhotoIds_second_upload_keeps_the_first_photo() {
        // The user-visible bug-2 sequence: add photo A, then photo B while the dialog stays open.
        InventoryStore.products = [_p("P1", [])]
        InventoryStore.applyPhotoIds("P1", ["a"], "a", "add")
        InventoryStore.applyPhotoIds("P1", ["a", "b"], "b", "add")
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["a","b"]')
    }

    function test_applyPhotoIds_replaces_rather_than_appends() {
        // The server's list is authoritative (uploadProductPhoto returns the full array).
        InventoryStore.products = [_p("P1", ["a", "b"])]
        InventoryStore.applyPhotoIds("P1", ["b"], "a", "remove")
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["b"]')
    }

    function test_applyPhotoIds_bumps_revision() {
        InventoryStore.products = [_p("P1", [])]
        var before = InventoryStore.revision
        InventoryStore.applyPhotoIds("P1", ["a"], "a", "add")
        verify(InventoryStore.revision > before, "dialog + InventoryPage refresh off this signal")
    }

    function test_applyPhotoIds_unknown_product_is_a_noop() {
        InventoryStore.products = [_p("P1", ["a"])]
        var rev = InventoryStore.revision
        InventoryStore.applyPhotoIds("NOPE", ["x"], "x", "add")
        compare(InventoryStore.revision, rev)
        compare(TransactionStore.entries.length, 0, "no ledger row for a product we don't have")
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["a"]')
    }

    function test_applyPhotoIds_leaves_other_products_alone() {
        InventoryStore.products = [_p("P1", ["a"]), _p("P2", ["z"])]
        InventoryStore.applyPhotoIds("P1", ["a", "b"], "b", "add")
        compare(JSON.stringify(InventoryStore.photoIdsFor("P2")), '["z"]')
    }

    function test_applyPhotoIds_non_array_becomes_empty() {
        InventoryStore.products = [_p("P1", ["a"])]
        InventoryStore.applyPhotoIds("P1", "garbage", "", "")
        compare(InventoryStore.photoIdsFor("P1").length, 0)
    }

    function test_applyPhotoIds_copies_its_input() {
        InventoryStore.products = [_p("P1", [])]
        var ids = ["a"]
        InventoryStore.applyPhotoIds("P1", ids, "a", "add")
        ids.push("mutated-later")
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["a"]')
    }

    function test_applyPhotoIds_add_logs_one_photo_change_row() {
        InventoryStore.products = [_p("P1", [])]
        InventoryStore.applyPhotoIds("P1", ["a"], "a", "add")
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.entries[0].kind, "photo_change")
        compare(TransactionStore.entries[0].before, "")
        compare(TransactionStore.entries[0].after, "a")
    }

    function test_applyPhotoIds_remove_logs_one_photo_change_row() {
        InventoryStore.products = [_p("P1", ["a"])]
        InventoryStore.applyPhotoIds("P1", [], "a", "remove")
        compare(TransactionStore.entries.length, 1)
        compare(TransactionStore.entries[0].before, "a")
        compare(TransactionStore.entries[0].after, "")
    }

    function test_applyPhotoIds_without_changedPhotoId_logs_nothing() {
        InventoryStore.products = [_p("P1", [])]
        InventoryStore.applyPhotoIds("P1", ["a"], "", "add")
        compare(TransactionStore.entries.length, 0)
        InventoryStore.applyPhotoIds("P1", ["a"], undefined, "add")
        compare(TransactionStore.entries.length, 0)
    }

    function test_applyPhotoIds_unknown_changeKind_logs_nothing() {
        InventoryStore.products = [_p("P1", [])]
        InventoryStore.applyPhotoIds("P1", ["a"], "a", "sideways")
        compare(TransactionStore.entries.length, 0)
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["a"]', "list still applied")
    }

    function test_applyPhotoIds_never_enqueues_an_inventory_mutation() {
        // Server already wrote photoIds; an inventory mutation would CAS-conflict against it.
        // The only thing an "add" may enqueue is the photo_change LEDGER row (entity "transaction",
        // TransactionStore.recordPhotoChange -> Gateway.recordMutation) -- so pendingCount is 1, not 0.
        InventoryStore.products = [_p("P1", [])]
        InventoryStore.applyPhotoIds("P1", ["a"], "a", "add")
        verify(!OutboxStore.hasPendingForEntity("inventory", "P1"), "no inventory mutation queued")
        compare(OutboxStore.pendingCount, 1, "exactly one ledger row")
    }

    function test_applyPhotoIds_without_changed_id_enqueues_nothing() {
        InventoryStore.products = [_p("P1", [])]
        InventoryStore.applyPhotoIds("P1", ["a"], "", "")
        compare(OutboxStore.pendingCount, 0)
    }

    function test_applyPhotoIds_ten_photos_max_list_roundtrips() {
        var ids = []
        for (var i = 0; i < 10; ++i) ids.push("p" + i)
        InventoryStore.products = [_p("P1", [])]
        InventoryStore.applyPhotoIds("P1", ids, "p9", "add")
        compare(InventoryStore.photoIdsFor("P1").length, 10)
    }

    function test_monkey_random_apply_and_read_stay_consistent() {
        InventoryStore.products = [_p("P1", []), _p("P2", [])]
        var expected = { P1: [], P2: [] }
        for (var i = 0; i < 200; ++i) {
            var pid = (i % 3 === 0) ? "P2" : "P1"
            var n = (i * 7) % 11
            var ids = []
            for (var k = 0; k < n; ++k) ids.push("id" + ((i + k) % 13))
            InventoryStore.applyPhotoIds(pid, ids, "", "")
            expected[pid] = ids
            compare(JSON.stringify(InventoryStore.photoIdsFor(pid)), JSON.stringify(ids))
        }
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), JSON.stringify(expected.P1))
        compare(JSON.stringify(InventoryStore.photoIdsFor("P2")), JSON.stringify(expected.P2))
    }

    // ── PH5 (2026-10-08): legacy product photoUrl / photoUpdatedAt are gone ─────────────────
    // Design: docs/superpowers/specs/2026-10-08-photos-ph5-legacy-removal-design.md. Server CAS
    // compares whole documents, so a doc that already carries the two keys 409s once the client
    // stops sending them (pinned server-side by functions F42); fresh tenants never get them.

    function _hasLegacy(o) { return o.hasOwnProperty("photoUrl") || o.hasOwnProperty("photoUpdatedAt") }

    function test_S01_normalize_does_not_create_the_legacy_keys() {
        var arr = [{ productId: "P1" }, { product_id: "P2", currentStock: 3 }]
        InventoryStore._normalizeProducts(arr)
        for (var i = 0; i < arr.length; ++i) verify(!_hasLegacy(arr[i]), "doc #" + i)
        verify(Array.isArray(arr[0].photoIds), "photoIds default still applied")
    }

    function test_S02_doc_carrying_the_legacy_keys_loads_and_clone_drops_them() {
        var doc = _p("P1", ["a"])
        doc.photoUrl = "file:///x.jpg"
        doc.photoUpdatedAt = "2026-01-01T00:00:00Z"
        var arr = [doc]
        InventoryStore._normalizeProducts(arr)          // must not throw
        InventoryStore.products = arr
        var c = InventoryStore._clone()
        compare(c.length, 1)
        verify(!_hasLegacy(c[0]), "clone must not propagate the legacy keys")
        compare(JSON.stringify(c[0].photoIds), '["a"]')
    }

    function test_S03_new_product_doc_and_clone_have_no_legacy_keys() {
        var d = InventoryStore._newProductDoc("P9", "N", "S9", "General", 1, 1, 10, 12, false, 0, "", "pcs", "", "")
        verify(!_hasLegacy(d), "new product doc")
        InventoryStore.products = [d]
        verify(!_hasLegacy(InventoryStore._clone()[0]), "clone of a new product doc")
    }

    function test_S11_legacy_functions_are_gone() {
        compare(typeof InventoryStore.setPhoto, "undefined")
        compare(typeof InventoryStore.clearLegacyPhotoUrl, "undefined")
    }

    function test_S13_import_new_row_with_a_stray_photoUrl_stores_no_legacy_key() {
        InventoryStore.products = []
        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [{ productId: "", _conflictPolicy: "skip", name: "Imported", sku: "IMP-1",
                         category: "General", unit: "pcs", stock: 0, minStock: 1, price: 5,
                         sellingPrice: 8, taxable: false, taxPercent: 0, size: "", supplierId: "",
                         photoUrl: "http://example.com/a.jpg" }]
        InventoryStore._upsertManySync(records, function() { return "PRD-777" }, function(r) { return "" },
                                       function() { return "BAT-2026-901" }, counts)
        compare(counts.added, 1)
        compare(InventoryStore.products.length, 1)
        verify(!_hasLegacy(InventoryStore.products[0]), "imported doc must not carry a legacy key")
    }

    function test_S14_regression_overwrite_never_touches_photoIds_or_legacy_keys() {
        InventoryStore.products = [_p("P1", ["a", "b"])]
        var counts = { added: 0, updated: 0, skipped: 0, updatedProducts: [] }
        var records = [{ productId: "P1", _conflictPolicy: "overwrite", name: "Renamed", sku: "S-P1",
                         category: "General", unit: "pcs", stock: 7, minStock: 1, price: 10,
                         sellingPrice: 12, taxable: false, taxPercent: 0, size: "", supplierId: "",
                         photoUrl: "http://example.com/b.jpg" }]
        InventoryStore._upsertManySync(records, function() { return "PRD-778" }, function(r) { return "" },
                                       function() { return "BAT-2026-902" }, counts)
        compare(counts.updated, 1)
        var f = counts.updatedProducts[0].fields
        compare(f.name, "Renamed")
        compare(f.stock, 7)
        verify(!f.hasOwnProperty("photoIds"), "overwrite must not write photoIds")
        verify(!_hasLegacy(f), "overwrite must not write legacy keys")
        compare(JSON.stringify(InventoryStore.photoIdsFor("P1")), '["a","b"]')
    }
}
