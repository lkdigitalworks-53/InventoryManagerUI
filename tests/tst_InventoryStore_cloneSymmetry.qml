import QtQuick
import QtTest
import "../qml/model"

// Regression test for a bug found in code review of pr_taher_bug_fixes
// (2026-08-21): that branch added `supplierId` to InventoryStore._clone()'s
// field-reconstruction whitelist (needed to carry it through the bulk-
// import/overwrite path) but never added it to addProduct()'s create
// payload. Exact same failure shape tst_OrdersStore_normalization.qml
// already locks down for OrdersStore: every _clone() after creation
// silently produces a local record with a field (supplierId) the real
// Firestore document doesn't actually have, and applyMutation's CAS check
// requires an EXACT key-set match (functions/lib/gatewayLogic.js's
// _deepEqual: `aKeys.length !== bKeys.length` fails immediately) — so the
// very next update or delete on that product is rejected as a false 409
// conflict. This is what made test_updateProduct_persists_to_emulator and
// test_deleteProduct_removes_from_emulator fail against pr_taher_bug_fixes
// in the real (Qt 6.8) CI run — both create a product via addProduct, then
// touch it again, which is exactly the drift this file guards.
//
// addProduct() itself can't be driven directly in a fast/offline unit test
// — it mints id/supplier via FirebaseService, which needs a real backend —
// so InventoryStore._newProductDoc() was pulled out as the pure, already-
// resolved-arguments half of addProduct's payload-building specifically so
// this invariant is testable here without the emulator. See the comments
// on _newProductDoc() and _clone() in InventoryStore.qml for the invariant
// itself; this file locks it down directly, not just by inspection.
TestCase {
    name: "InventoryStore_cloneSymmetry"

    function init() { InventoryStore.products = [] }
    function cleanup() { InventoryStore.products = [] }

    function _doc(supplierId) {
        return InventoryStore._newProductDoc(
            "PRD-001", "Widget", "SKU-1", "General", 10, 2,
            100, 120, false, 0, "", "pc", "A widget", supplierId || "SUP-001")
    }

    function test_newProductDoc_fields_exactly_match_clone_whitelist() {
        var doc = _doc()
        InventoryStore.products = [doc]
        var cloned = InventoryStore._clone()[0]

        var docKeys = Object.keys(doc).sort()
        var cloneKeys = Object.keys(cloned).sort()
        compare(JSON.stringify(cloneKeys), JSON.stringify(docKeys),
                "_clone()'s whitelist must carry exactly the fields addProduct's " +
                "create payload sends -- no more, no less -- or the next edit's " +
                "CAS check false-conflicts (see functions/lib/gatewayLogic.js _deepEqual)")
    }

    function test_newProductDoc_sends_supplierId_at_creation() {
        var doc = _doc("SUP-042")
        compare(doc.supplierId, "SUP-042",
                "supplierId must be part of the actual create payload, not just " +
                "something _clone() defaults afterwards")
    }

    function test_clone_preserves_supplierId_across_a_second_touch() {
        // The concrete failure shape: create (products = [doc]), then
        // whatever the next mutation does reads the record back through
        // _clone() first (see updateProduct/deleteProduct in
        // InventoryStore.qml, both of which start with `var arr = _clone()`).
        InventoryStore.products = [_doc("SUP-042")]
        var cloned = InventoryStore._clone()[0]
        compare(cloned.supplierId, "SUP-042")
    }

    function test_clone_key_count_matches_created_doc_key_count() {
        // The exact mechanism of the server-side rejection: applyMutation's
        // _deepEqual bails out on `aKeys.length !== bKeys.length` before it
        // even looks at values.
        var doc = _doc()
        InventoryStore.products = [doc]
        var cloned = InventoryStore._clone()[0]
        compare(Object.keys(cloned).length, Object.keys(doc).length)
    }
}
