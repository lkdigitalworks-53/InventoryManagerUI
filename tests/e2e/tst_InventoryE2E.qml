import QtQuick
import QtTest
import "../../qml/model"

// Phase 1 E2E pilot — Inventory CRUD driven service-level (no UI) against
// the real Firebase Local Emulator Suite (Firestore + Auth + Functions).
// Real code path: InventoryStore.addProduct/updateProduct/deleteProduct ->
// Gateway.recordMutation ("gateway" mode, the real production default) ->
// POST to the emulated recordMutation Cloud Function -> Admin SDK write to
// the emulated Firestore -> response back to the client. Verified
// independently via a raw REST GET against the Firestore emulator, not
// just the client's own optimistic in-memory state.
//
// NOT RUN IN THIS SANDBOX — no network egress here to Firebase's emulator
// distribution. Requires test/e2e/.fixture.json (written by
// test/e2e/seed.js) and a running emulator suite. Run locally with:
//   firebase emulators:exec --only firestore,auth,functions \
//     "node test/e2e/seed.js && qmltestrunner -input tests/e2e -platform offscreen"

TestCase {
    name: "InventoryE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"

    property var fixture: null

    function _loadFixture() {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", Qt.resolvedUrl("./.fixture.json"), false) // synchronous local read
        xhr.send()
        if (xhr.status !== 200 && xhr.status !== 0) { // status 0 is file:// success on some Qt builds
            fail("could not read .fixture.json (status " + xhr.status
                 + ") — run test/e2e/seed.js against a running emulator first")
        }
        return JSON.parse(xhr.responseText)
    }

    // Raw REST read against the emulator, independent of FirebaseService —
    // asserting via the same client code that wrote the data would only
    // prove the client's local cache is self-consistent, not that anything
    // real reached the server.
    function _getEmulatorDoc(docPath) {
        var url = emulatorFirestoreHost
            + "/v1/projects/inventorymanager-48392/databases/(default)/documents/" + docPath
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url, false)
        xhr.setRequestHeader("Authorization", "Bearer " + fixture.idToken)
        xhr.send()
        if (xhr.status !== 200) return null
        return JSON.parse(xhr.responseText)
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        Gateway.functionUrl = emulatorFunctionsBase + "/recordMutation"
        Gateway.mode = "gateway" // the real production default — see Gateway.qml
        AuthStore.idToken = fixture.idToken
        AuthStore.tenantId = fixture.tenantId
        SupplierStore.suppliers = [{ supplierId: fixture.supplierId, name: fixture.supplierName }]
        InventoryStore.products = []
    }

    function cleanup() {
        FirebaseService.emulatorHost = ""
        Gateway.functionUrl = realFunctionUrl
        AuthStore.idToken = ""
        AuthStore.tenantId = ""
    }

    function _createProduct(name, sku, stock) {
        var createdId = ""
        var done = false
        InventoryStore.addProduct(
            name, sku, "General", "", 100, "pc", stock, 2,
            120, false, 0, fixture.supplierName, 80, "",
            function(ok, id) { done = true; createdId = ok ? id : "" }
        )
        tryVerify(function() { return done }, 5000, "addProduct callback never fired")
        verify(createdId.length > 0, "addProduct did not return a productId")
        return createdId
    }

    function test_addProduct_creates_real_emulator_doc() {
        var id = _createProduct("E2E Widget", "SKU-E2E-1", 10)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        var doc = null
        tryVerify(function() { doc = _getEmulatorDoc(docPath); return doc !== null }, 5000,
                  "product doc never appeared in the emulator")
        compare(doc.fields.name.stringValue, "E2E Widget")
        compare(Number(doc.fields.stock.integerValue), 10)
    }

    function test_updateProduct_persists_to_emulator() {
        var id = _createProduct("E2E Widget Update", "SKU-E2E-2", 5)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        tryVerify(function() { return _getEmulatorDoc(docPath) !== null }, 5000,
                  "product doc never appeared before the update")

        InventoryStore.updateProduct(id, { stock: 25 }, "e2e adjustment")

        var doc = null
        tryVerify(function() {
            doc = _getEmulatorDoc(docPath)
            return doc !== null && Number(doc.fields.stock.integerValue) === 25
        }, 5000, "updated stock never reached the emulator")
        compare(Number(doc.fields.stock.integerValue), 25)
    }

    function test_deleteProduct_removes_from_emulator() {
        var id = _createProduct("E2E Widget Delete", "SKU-E2E-3", 3)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        tryVerify(function() { return _getEmulatorDoc(docPath) !== null }, 5000,
                  "product doc never appeared before the delete")

        InventoryStore.deleteProduct(id)

        tryVerify(function() { return _getEmulatorDoc(docPath) === null }, 5000,
                  "product doc was never removed from the emulator")
    }
}
