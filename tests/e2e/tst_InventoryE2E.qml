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
// QML's XMLHttpRequest does not support synchronous mode (open(..., false))
// at all -- it throws, which is what the first real CI run of this file hit
// ("Uncaught exception: Invalid state"). Every request below is
// asynchronous, with tryVerify()'s event-loop-pumping poll used to wait for
// completion -- the only pattern Qt's own docs demonstrate for QML XHR.
// Reading test/e2e/.fixture.json via file:// additionally requires
// QML_XHR_ALLOW_FILE_READ=1 in the environment (set in the e2e-tests CI job)
// -- local file reads are disabled by default, separately from the sync/
// async issue.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt -- no network
// egress here to Firebase's emulator distribution.

TestCase {
    name: "InventoryE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"

    property var fixture: null
    // seed.js (test/e2e/seed.js, singular "test" — matches the existing
    // Node-test convention alongside test/firestore.rules.test.js) writes
    // .fixture.json into that directory, not this file's own tests/e2e/
    // directory. Two similarly-named directories was an avoidable mix-up
    // from planning; fixed by pointing the read at the right one rather
    // than moving seed.js's output.
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")

    function _loadFixture() {
        var status = -1, text = "", done = false
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                status = xhr.status
                text = xhr.responseText
                done = true
            }
        }
        xhr.open("GET", fixtureUrl, true)
        xhr.send()
        tryVerify(function() { return done }, 5000, "timed out reading .fixture.json")
        // status is documented to be unreliable for file:// reads (often 0
        // regardless of success or failure) — an empty body is the
        // trustworthy signal that the read actually failed.
        if (!text || text.length === 0) {
            fail("could not read .fixture.json from " + fixtureUrl + " (status " + status
                 + ", empty body) — run test/e2e/seed.js against a running emulator first")
        }
        return JSON.parse(text)
    }

    // Polls a raw REST GET against the Firestore emulator, independent of
    // FirebaseService — asserting via the same client code that wrote the
    // data would only prove the client's local cache is self-consistent,
    // not that anything real reached the server. Re-fires a fresh async GET
    // on every tryVerify tick until predicateFn(doc) is true or it times
    // out; doc is null while missing/not-yet-caught-up.
    function _pollEmulatorDoc(docPath, predicateFn, timeoutMs, message) {
        var url = emulatorFirestoreHost
            + "/v1/projects/inventorymanager-48392/databases/(default)/documents/" + docPath
        var latest = null
        var inFlight = false

        function fire() {
            if (inFlight) return
            inFlight = true
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    latest = (xhr.status === 200) ? JSON.parse(xhr.responseText) : null
                    inFlight = false
                }
            }
            xhr.open("GET", url, true)
            xhr.setRequestHeader("Authorization", "Bearer " + fixture.idToken)
            xhr.send()
        }

        tryVerify(function() {
            fire()
            return predicateFn(latest)
        }, timeoutMs, message)

        return latest
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

    // Diagnostic — added after test_addProduct/update/delete all failed
    // with "doc never appeared" and no visible reason: Gateway._send()
    // logs the actual HTTP status/response via console.warn on failure but
    // never surfaces it to the caller (recordMutation is fire-and-forget by
    // design), so a rejected request looks identical to a slow/successful
    // one from this test's perspective. This bypasses Gateway/OutboxStore
    // entirely and POSTs to the same emulated recordMutation function with
    // the same payload shape _send() uses, so a failure here prints the
    // real status/response text via compare()'s own output — replacing a
    // guess with evidence. Runs first (declared first) so it fails fast,
    // before the slower CRUD tests even attempt anything.
    function test_recordMutation_function_accepts_seeded_credentials() {
        var status = -1, text = "", done = false
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                status = xhr.status
                text = xhr.responseText
                done = true
            }
        }
        xhr.open("POST", emulatorFunctionsBase + "/recordMutation", true)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + fixture.idToken)
        xhr.send(JSON.stringify({
            env: "prd", // matches FirebaseService.environment for a bare qmltestrunner run
            entity: "inventory",
            entityId: "diag-" + Date.now(),
            action: "create",
            before: null,
            after: { name: "Diagnostic Widget", sku: "SKU-DIAG-1", price: 1, stock: 1 },
            requestId: "diag-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }))
        tryVerify(function() { return done }, 5000, "recordMutation call never completed")
        compare(status, 200, "recordMutation rejected the request — response body: " + text)
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
        var doc = _pollEmulatorDoc(docPath, function(d) { return d !== null }, 5000,
                                    "product doc never appeared in the emulator")
        compare(doc.fields.name.stringValue, "E2E Widget")
        compare(Number(doc.fields.stock.integerValue), 10)
    }

    function test_updateProduct_persists_to_emulator() {
        var id = _createProduct("E2E Widget Update", "SKU-E2E-2", 5)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        _pollEmulatorDoc(docPath, function(d) { return d !== null }, 5000,
                          "product doc never appeared before the update")

        InventoryStore.updateProduct(id, { stock: 25 }, "e2e adjustment")

        var doc = _pollEmulatorDoc(docPath, function(d) {
            return d !== null && Number(d.fields.stock.integerValue) === 25
        }, 5000, "updated stock never reached the emulator")
        compare(Number(doc.fields.stock.integerValue), 25)
    }

    function test_deleteProduct_removes_from_emulator() {
        var id = _createProduct("E2E Widget Delete", "SKU-E2E-3", 3)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        _pollEmulatorDoc(docPath, function(d) { return d !== null }, 5000,
                          "product doc never appeared before the delete")

        InventoryStore.deleteProduct(id)

        _pollEmulatorDoc(docPath, function(d) { return d === null }, 5000,
                          "product doc was never removed from the emulator")
    }
}

