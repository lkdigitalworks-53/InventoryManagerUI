import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// StaffStore E2E — added specifically to close a backlog item, not as a full
// CRUD parity pass: QTBUG-49896 (see docs/superpowers/specs/2026-08-25-
// e2e-testing-phase2-followup-CHECKPOINT.md, SKILLS.md Skill 45) broke
// Gateway.mutationConflicted's delivery identically for every store
// connected to it -- Orders/Inventory/Staff/Supplier/StockBatch. Only
// OrdersStore's reconciliation path had an actual end-to-end test proving it
// works before now. This file's real purpose is
// test_two_users_editing_the_same_staff_record_produces_a_real_conflict
// below; addStaff/_createStaff exist only to support that test, not as
// their own coverage goal (no update/delete CRUD tests here — deliberately
// out of scope for this backlog item, not an oversight).
//
// Structure mirrors tst_InventoryE2E.qml closely (same emulator/fixture
// wiring, same warm-up rationale, same _pollEmulatorDoc/_firestoreFieldsToPlain
// helpers) rather than inventing a new pattern.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt -- no network
// egress here to Firebase's emulator distribution, same as every other file
// in this suite.

TestCase {
    name: "StaffStoreE2E"

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

    // Same rationale as tst_InventoryE2E.qml's initTestCase(): forces
    // AuthService's singleton construction (and its unconditional
    // AuthStore.clear()) before any test's own init() sets a real token,
    // and pays the Cloud Functions emulator's one-time cold-start cost with
    // a timeout sized for that rather than inflating every real test's own
    // budget.
    function initTestCase() {
        fixture = _loadFixture()
        AuthService.ensureFreshToken()

        var result = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutation", {
            env: "prd", entity: "staff", entityId: "warmup-staff-" + Date.now(),
            action: "create", before: null,
            after: { staffId: "warmup-staff-" + Date.now(), name: "Warmup", role: "staff" },
            requestId: "warmup-staff-req-" + Date.now(),
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
        StaffStore.staff = []
        OutboxStore.clear() // see tst_OrdersStoreE2E.qml's init() -- shared singleton across the
                             // whole test/e2e process, same reasoning
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

    function _createStaff(name) {
        var createdId = ""
        var done = false
        StaffStore.addStaff(name, name.toLowerCase().replace(/\s+/g, ".") + "@example.com",
            "555-0100", "staff", "General", new Date(), "active", 0,
            function(ok, id) { done = true; createdId = ok ? id : "" })
        tryVerify(function() { return done }, 5000, "addStaff callback never fired")
        verify(createdId.length > 0, "addStaff did not return a staffId")
        return createdId
    }

    function test_addStaff_creates_real_emulator_doc() {
        var id = _createStaff("E2E Staff Member")
        var docPath = "tenants/" + fixture.tenantId + "/staff/" + id
        var doc = _pollEmulatorDoc(docPath, id, function(d) { return d !== null }, 5000,
                                    "staff doc never appeared in the emulator")
        compare(doc.fields.name.stringValue, "E2E Staff Member")
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

    // See tst_InventoryE2E.qml's test of the same shape for the full
    // rationale. _createStaff already leaves StaffStore's own local cache
    // holding the pre-second-write state, so the first identity's side
    // needs no extra cache manipulation to be genuinely stale.
    function test_two_users_editing_the_same_staff_record_produces_a_real_conflict() {
        var id = _createStaff("Conflict Test Staff")
        var docPath = "tenants/" + fixture.tenantId + "/staff/" + id
        var doc = _pollEmulatorDoc(docPath, id, function(d) { return d !== null }, 5000,
                                    "staff doc never appeared before the conflict test")

        var plainStaff = _firestoreFieldsToPlain(doc.fields)
        var secondUserAfter = Object.assign({}, plainStaff, { role: "Changed By Second User" })
        var savedToken = AuthStore.idToken
        AuthStore.idToken = fixture.secondIdToken
        Gateway.recordMutation("staff", id, "update", plainStaff, secondUserAfter)
        _pollEmulatorDoc(docPath, id, function(d) {
            return d !== null && d.fields.role.stringValue === "Changed By Second User"
        }, 5000, "second identity's write never actually changed the server's staff role -- conflict setup failed")
        AuthStore.idToken = savedToken

        lastConflict = null
        StaffStore.updateStaff(id, { department: "Changed By First Identity" })

        tryVerify(function() { return lastConflict !== null }, 10000,
                  "Gateway.mutationConflicted never fired for a genuine staff CAS conflict")
        compare(lastConflict.entity, "staff")
        compare(lastConflict.entityId, id)
        compare(lastConflict.current.role, "Changed By Second User")
    }
}
