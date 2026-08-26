import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// SupplierStore E2E — same backlog rationale as tst_StaffStoreE2E.qml (see
// its header comment): closes out the last-but-one of the five
// mutationConflicted-connected stores that QTBUG-49896 affected identically
// but only OrdersStore had an actual end-to-end test proving reconciliation
// works. Not a CRUD parity pass — addSupplier/_createSupplier exist only to
// support the conflict test below.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt.

TestCase {
    name: "SupplierStoreE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")

    property var fixture: null
    property var lastConflict: null

    function _loadFixture() {
        return E2EHelpers.loadFixture(this, fixtureUrl)
    }

    function _onMutationConflicted(entity, entityId, current) {
        lastConflict = { entity: entity, entityId: entityId, current: current }
    }

    function _pollEmulatorDoc(docPath, entityId, predicateFn, timeoutMs, message) {
        return E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, docPath, entityId,
                                           predicateFn, timeoutMs, message)
    }

    function initTestCase() {
        fixture = _loadFixture()
        AuthService.ensureFreshToken()

        var result = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutation", {
            env: "prd", entity: "supplier", entityId: "warmup-supplier-" + Date.now(),
            action: "create", before: null,
            after: { supplierId: "warmup-supplier-" + Date.now(), name: "Warmup Supplier" },
            requestId: "warmup-supplier-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }, 15000, "Cloud Functions emulator never responded to the recordMutation warm-up call")
        compare(result.status, 200,
                "warm-up recordMutation call was rejected — response body: " + result.text)
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        Gateway.functionUrl = emulatorFunctionsBase + "/recordMutation"
        Gateway.mode = "gateway"
        AuthStore.idToken = fixture.idToken
        AuthStore.tenantId = fixture.tenantId
        // NOT []. SupplierStore.nextSupplierId() floors its mint on the
        // highest supplierId number found in this LOCAL array (seedMax),
        // combined with a real Firestore counter -- but the counter is
        // never pre-seeded (seed.js writes SUP-001 directly, bypassing the
        // counter entirely), so an empty local array here makes
        // nextSupplierId() mint "SUP-001" again on a fresh counter,
        // colliding with seed.js's real SUP-001. First real run of this
        // file hit exactly that (results.xml, 2026-08-26): "Gateway.
        // mutationConflicted fired for supplier/SUP-001, server has:
        // {...name:'E2E Supplier'...}" -- E2E Supplier is seed.js's exact
        // SUPPLIER_NAME. Matching the convention every OTHER E2E file
        // already uses (tst_InventoryE2E.qml, tst_OrdersE2E.qml, etc.)
        // fixes it: seed the known fixture supplier so seedMax correctly
        // floors at 1.
        SupplierStore.suppliers = [{ supplierId: fixture.supplierId, name: fixture.supplierName }]
        OutboxStore.clear()
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

    function _createSupplier(name) {
        var createdDoc = null
        var done = false
        SupplierStore.addSupplier({ name: name, contact: "", leadTimeDays: 7, terms: "", notes: "" },
            function(doc) { done = true; createdDoc = doc })
        tryVerify(function() { return done }, 5000, "addSupplier callback never fired")
        verify(createdDoc !== null, "addSupplier did not return a created record")
        return createdDoc.supplierId
    }

    function test_addSupplier_creates_real_emulator_doc() {
        var id = _createSupplier("E2E Conflict Supplier Co")
        var docPath = "tenants/" + fixture.tenantId + "/suppliers/" + id
        var doc = _pollEmulatorDoc(docPath, id, function(d) { return d !== null }, 5000,
                                    "supplier doc never appeared in the emulator")
        compare(doc.fields.name.stringValue, "E2E Conflict Supplier Co")
    }

    function _firestoreFieldsToPlain(fields) {
        function convertValue(v) {
            if (v.stringValue !== undefined) return v.stringValue
            if (v.integerValue !== undefined) return Number(v.integerValue)
            if (v.doubleValue !== undefined) return v.doubleValue
            if (v.booleanValue !== undefined) return v.booleanValue
            if (v.nullValue !== undefined) return null
            if (v.timestampValue !== undefined) return v.timestampValue
            if (v.arrayValue !== undefined) {
                var arr = (v.arrayValue.values || [])
                var out = []
                for (var i = 0; i < arr.length; ++i) out.push(convertValue(arr[i]))
                return out
            }
            if (v.mapValue !== undefined) return _firestoreFieldsToPlain(v.mapValue.fields || {})
            return null
        }
        var plain = {}
        for (var key in fields) plain[key] = convertValue(fields[key])
        return plain
    }

    function test_two_users_editing_the_same_supplier_produces_a_real_conflict() {
        var id = _createSupplier("Conflict Test Supplier Co")
        var docPath = "tenants/" + fixture.tenantId + "/suppliers/" + id
        var doc = _pollEmulatorDoc(docPath, id, function(d) { return d !== null }, 5000,
                                    "supplier doc never appeared before the conflict test")

        var plainSupplier = _firestoreFieldsToPlain(doc.fields)
        var secondUserAfter = Object.assign({}, plainSupplier, { contact: "Changed By Second User" })
        var savedToken = AuthStore.idToken
        AuthStore.idToken = fixture.secondIdToken
        Gateway.recordMutation("supplier", id, "update", plainSupplier, secondUserAfter)
        _pollEmulatorDoc(docPath, id, function(d) {
            return d !== null && d.fields.contact.stringValue === "Changed By Second User"
        }, 5000, "second identity's write never actually changed the server's supplier contact -- conflict setup failed")
        AuthStore.idToken = savedToken

        lastConflict = null
        SupplierStore.updateSupplier(id, { terms: "Changed By First Identity" })

        tryVerify(function() { return lastConflict !== null }, 10000,
                  "Gateway.mutationConflicted never fired for a genuine supplier CAS conflict")
        compare(lastConflict.entity, "supplier")
        compare(lastConflict.entityId, id)
        compare(lastConflict.current.contact, "Changed By Second User")
    }
}
