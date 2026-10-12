import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// PH5 e2e (E01-E03 of docs/superpowers/test-plans/2026-10-08-photos-ph5-test-plan.md, section 4), against the
// real Firebase Local Emulator Suite. PH5 removed the legacy product fields `photoUrl` / `photoUpdatedAt` from
// the client. The server compares WHOLE documents on every update (`_deepEqual(current, before)`), so:
//   * a product created by the PH5 client never has the two keys, and edits + deletes keep working (E01, E02);
//   * a product doc that still stores them (a pre-PH5 tenant) 409s every client update, by decision Q-P5-3 (a)
//     "fresh tenants only" (E03). E03b is the control: the same doc WITHOUT the two keys updates fine, so the
//     409 in E03 comes from the legacy keys and from nothing else in the seeded shape.
// Real code path: InventoryStore.addProduct/updateProduct/deleteProduct -> Gateway.recordMutation ("gateway"
// mode, the production default) -> emulated recordMutation Cloud Function -> emulated Firestore, verified
// through a raw REST GET, not through the client's own optimistic state. Seeding for E03/E03b goes through the
// emulator-admin REST write in E2EHelpers.createEmulatorDoc.
//
// NOT RUN IN THIS SANDBOX -- no network egress to Firebase's emulator distribution; CI (e2e-tests job, which
// picks up every tst_*.qml in test/e2e/) is the proof.
TestCase {
    name: "ProductLegacyPhotoUrlE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"

    property var fixture: null
    property var lastConflict: null
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")

    function _loadFixture() { return E2EHelpers.loadFixture(this, fixtureUrl) }
    function _onMutationConflicted(entity, entityId, current) {
        lastConflict = { entity: entity, entityId: entityId, current: current }
    }
    function _pollDoc(docPath, entityId, predicateFn, timeoutMs, message, requireResponse) {
        return E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, docPath, entityId,
                                           predicateFn, timeoutMs, message, requireResponse)
    }
    function _docPath(productId) { return "tenants/" + fixture.tenantId + "/inventory/" + productId }
    function _num(v) { return v === undefined ? NaN : Number(v.integerValue !== undefined ? v.integerValue : v.doubleValue) }

    function initTestCase() {
        fixture = _loadFixture()
        // Same construction-order fix as tst_InventoryE2E.initTestCase(): AuthService's first reference wipes
        // AuthStore, so force it now, before any init() sets a real token.
        AuthService.ensureFreshToken()
        // Pay the recordMutation cold start once, here, not inside a test's own 5 s budget.
        var warm = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutation", {
            env: "prd", entity: "inventory", entityId: "warmup-ph5-" + Date.now(), action: "create", before: null,
            after: { name: "PH5 Warm-up", sku: "SKU-PH5-WARM", price: 1, stock: 1 },
            requestId: "warmup-ph5-req-" + Date.now(), clientTimestamp: new Date().toISOString()
        }, 15000, "Cloud Functions emulator never responded to the PH5 warm-up call")
        compare(warm.status, 200, "PH5 warm-up recordMutation was rejected -- response: " + warm.text)
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        Gateway.functionUrl = emulatorFunctionsBase + "/recordMutation"
        Gateway.mode = "gateway"
        AuthStore.idToken = fixture.idToken
        AuthStore.uid = fixture.uid
        AuthStore.tenantId = fixture.tenantId
        SupplierStore.suppliers = [{ supplierId: fixture.supplierId, name: fixture.supplierName }]
        InventoryStore.products = []
        lastConflict = null
        Gateway.mutationConflicted.connect(_onMutationConflicted)
    }

    function cleanup() {
        Gateway.mutationConflicted.disconnect(_onMutationConflicted)
        FirebaseService.emulatorHost = ""
        Gateway.functionUrl = realFunctionUrl
        AuthStore.idToken = ""
        AuthStore.tenantId = ""
    }

    function _createProduct(name, sku) {
        var createdId = "", done = false
        InventoryStore.addProduct(
            name, sku, "General", "", 100, "pc", 10, 2,
            120, false, 0, fixture.supplierName, 80, "",
            function(ok, id) { done = true; createdId = ok ? id : "" }
        )
        tryVerify(function() { return done }, 5000, "addProduct callback never fired")
        verify(createdId.length > 0, "addProduct did not return a productId")
        return createdId
    }

    // The exact key set of a client product doc (InventoryStore._clone / _newProductDoc), as the server stores it.
    function _productDoc(id, name, sku) {
        return { productId: id, name: name, sku: sku, category: "General", stock: 5, minStock: 2,
                 price: 100, sellingPrice: 120, taxable: false, taxPercent: 0, size: "", unit: "pc",
                 description: "", photoIds: [], supplierId: fixture.supplierId }
    }

    // Seeds `doc` as the emulator admin and loads it into the store the way a server read would (the product list
    // path runs the server doc through _normalizeProducts; _clone() later drops every key it does not know).
    function _seedAndLoad(doc) {
        var r = E2EHelpers.createEmulatorDoc(this, emulatorFirestoreHost, "tenants/" + fixture.tenantId + "/inventory",
                                              doc.productId, doc, 5000, "emulator admin write never completed")
        compare(r.status, 200, "seeding the raw product doc failed -- response: " + r.text)
        _pollDoc(_docPath(doc.productId), doc.productId, function(d) { return d !== null }, 5000,
                 "seeded product doc is not readable in the emulator")
        InventoryStore.products = InventoryStore._normalizeProducts([Object.assign({}, doc)])
    }

    // E01 -- HAPPY: a product created through the store and gateway on a fresh tenant has no legacy keys.
    function test_E01_a_created_product_doc_has_no_photoUrl_or_photoUpdatedAt() {
        var id = _createProduct("E2E PH5 Create", "SKU-E2E-PH5-1")
        var doc = _pollDoc(_docPath(id), id, function(d) { return d !== null }, 5000,
                           "product doc never appeared in the emulator")
        compare(doc.fields.name.stringValue, "E2E PH5 Create")
        compare(doc.fields.photoUrl, undefined, "legacy key photoUrl must not be written")
        compare(doc.fields.photoUpdatedAt, undefined, "legacy key photoUpdatedAt must not be written")
        verify(doc.fields.photoIds !== undefined, "photoIds is the only photo field a product doc carries")
    }

    // E02 -- HAPPY: update then delete on a fresh doc: both land, no CAS conflict (the removal did not break `before`).
    function test_E02_update_then_delete_of_a_fresh_product_succeeds_without_a_conflict() {
        var id = _createProduct("E2E PH5 Update Delete", "SKU-E2E-PH5-2")
        _pollDoc(_docPath(id), id, function(d) { return d !== null }, 5000, "product doc never appeared before the update")

        lastConflict = null
        InventoryStore.updateProduct(id, { price: 55 }, "e2e ph5 update")
        var updated = _pollDoc(_docPath(id), id, function(d) {
            return d !== null && _num(d.fields.price) === 55
        }, 5000, "updated price never reached the emulator")
        compare(_num(updated.fields.price), 55)
        compare(lastConflict, null, "an update of a fresh product must not conflict")

        InventoryStore.deleteProduct(id)
        _pollDoc(_docPath(id), id, function(d) { return d === null }, 5000,
                 "product doc was never removed from the emulator", true)
        compare(lastConflict, null, "a delete of a fresh product must not conflict")
    }

    // E03 -- NEGATIVE (pins Q-P5-3 a): a doc that still stores the legacy keys 409s a client update and is untouched.
    function test_E03_a_pre_PH5_doc_with_the_legacy_keys_conflicts_on_a_client_update_and_stays_unchanged() {
        var id = "e2e-ph5-legacy-" + Date.now()
        var legacy = Object.assign(_productDoc(id, "E2E PH5 Legacy", "SKU-E2E-PH5-3"), { photoUrl: "", photoUpdatedAt: "" })
        _seedAndLoad(legacy)

        lastConflict = null
        InventoryStore.updateProduct(id, { price: 55 }, "e2e ph5 legacy cas")
        tryVerify(function() { return lastConflict !== null }, 10000,
                  "Gateway.mutationConflicted never fired: the legacy keys should make `before` differ from the stored doc")
        var conflict = lastConflict
        lastConflict = null   // pollEmulatorDoc fails fast on a conflict for the same entity id
        compare(conflict.entity, "inventory")
        compare(conflict.entityId, id)
        compare(conflict.current.photoUrl, "", "the server's current doc still carries the legacy keys")
        compare(conflict.current.photoUpdatedAt, "")

        var doc = _pollDoc(_docPath(id), id, function(d) { return d !== null }, 5000, "legacy doc disappeared")
        compare(_num(doc.fields.price), 100, "a conflicting update must not change the stored price")
        compare(doc.fields.photoUrl.stringValue, "", "the stored doc keeps its legacy keys")
        compare(doc.fields.photoUpdatedAt.stringValue, "")
    }

    // E03b -- CONTROL: the same seeded shape WITHOUT the two keys updates cleanly, so E03's 409 is caused by them.
    function test_E03b_the_same_doc_without_the_legacy_keys_updates_without_a_conflict() {
        var id = "e2e-ph5-fresh-" + Date.now()
        _seedAndLoad(_productDoc(id, "E2E PH5 Fresh Seed", "SKU-E2E-PH5-3B"))

        lastConflict = null
        InventoryStore.updateProduct(id, { price: 55 }, "e2e ph5 control")
        _pollDoc(_docPath(id), id, function(d) { return d !== null && _num(d.fields.price) === 55 }, 5000,
                 "the control update never reached the emulator")
        compare(lastConflict, null, "without the legacy keys the same update must not conflict")
    }
}
