import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// StockBatchStore E2E — last of the four backlog conflict tests (see
// tst_StaffStoreE2E.qml's header for the shared rationale). This one is
// shaped differently from the other three, and that's deliberate, not an
// oversight — worth reading before touching this file:
//
// StockBatchStore's own numeric mutations (consumeFifo/topUpOldest/
// restoreFifo) all go through Gateway.recordDelta, NOT recordMutation —
// confirmed by reading the whole file, not assumed. recordDelta's
// server-side atomic floor/clamp semantics make a CAS conflict structurally
// impossible for those call sites: there's no "before must match current"
// check to violate. The ONLY Gateway.recordMutation call anywhere in this
// store is addBatch's "create" action. (StockBatchStore._onMutationConflicted
// does exist and is wired up — its own comment claims a "genuine two-devices
// race" can hit it via "qtyRemaining via plain recordMutation", but that
// doesn't match the current code: worth flagging to Taher as a likely-stale
// comment from before a recordDelta conversion, not fixed here since it's
// out of this backlog item's scope.)
//
// So this test exercises the one path that's actually reachable: a
// duplicate "create" collision (client A's create succeeds; client B
// attempts to create the same batchId, unaware it already exists) rather
// than an "update" collision. To make the reconciliation assertion
// meaningful (current actually differing from the second client's stale
// local cache, not just echoing back what it already expected), a direct
// Gateway "update" call changes the batch server-side in between — StockBatchStore
// itself never does this in production, but it's a legitimate way to prove
// the RECONCILIATION HANDLER works correctly when a conflict does occur,
// which is this backlog item's actual goal, independent of how rare the
// triggering scenario is in practice today.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt.

TestCase {
    name: "StockBatchStoreE2E"

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
            env: "prd", entity: "stock_batch", entityId: "warmup-batch-" + Date.now(),
            action: "create", before: null,
            after: { batchId: "warmup-batch-" + Date.now(), productId: "warmup-product", qtyReceived: 1, qtyRemaining: 1 },
            requestId: "warmup-batch-req-" + Date.now(),
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
        // NOT []. Unlike SupplierStore/StaffStore's ID minting (a local
        // scan floors a REAL Firestore counter), StockBatchStore's
        // _nextBatchId() is PURELY local -- it scans this array for the
        // highest "BAT-<year>-NNN" and has no server-side fallback at all.
        // Any product created with stock > 0 anywhere in this whole
        // qmltestrunner process (InventoryStore.addProduct()'s companion
        // "Initial stock" batch, e.g. tst_InventoryE2E.qml's very first
        // test) mints "BAT-<year>-001" against WHATEVER this array locally
        // holds at that moment -- resetting to [] here makes this file
        // blind to batches minted earlier in the SAME run, and it mints
        // the identical "next" id again, colliding for real. First run
        // hit exactly this (results.xml, 2026-08-26): "Gateway.
        // mutationConflicted fired for stock_batch/BAT-2026-001, server
        // has: {...note:'Initial stock'...}" -- that's InventoryStore's
        // companion-batch note, not this file's own. Syncing for real
        // (matching what the real app always does before minting) is the
        // only fix that's reliable regardless of what else has run before
        // this file this session -- resetting to some other hardcoded
        // guess would just move the same class of collision elsewhere.
        //
        // This is worth Taher's attention as a real, separate finding:
        // _nextBatchId()'s lack of a server-side counter (unlike Staff/
        // Supplier) is a genuine latent risk in production too, not just
        // a test artifact -- two real devices with incomplete local
        // caches could mint the same "next" batch id concurrently. Not
        // fixed here; flagged in CHECKPOINT.md rather than fixed
        // opportunistically mid-test-fix.
        StockBatchStore.syncFromFirebase()
        tryVerify(function() { return !StockBatchStore.loadingMore && !StockBatchStore.hasMore }, 5000,
                  "StockBatchStore never finished syncing from the emulator before this test's init()")
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

    function test_addBatch_creates_real_emulator_doc() {
        var doc = StockBatchStore.addBatch("prod-e2e-1", "sup-e2e-1", 10, 5, "E2E test batch")
        verify(doc !== null, "addBatch returned null")
        var docPath = "tenants/" + fixture.tenantId + "/stock_batches/" + doc.batchId
        var serverDoc = _pollEmulatorDoc(docPath, doc.batchId, function(d) { return d !== null }, 5000,
                                          "batch doc never appeared in the emulator")
        compare(Number(serverDoc.fields.qtyReceived.integerValue), 10)
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

    function test_duplicate_create_for_the_same_batch_id_produces_a_real_conflict() {
        // First identity creates the batch normally, for real.
        var doc = StockBatchStore.addBatch("prod-e2e-conflict", "sup-e2e-1", 20, 5, "Conflict test batch")
        verify(doc !== null, "addBatch returned null")
        var batchId = doc.batchId
        var docPath = "tenants/" + fixture.tenantId + "/stock_batches/" + batchId
        _pollEmulatorDoc(docPath, batchId, function(d) { return d !== null }, 5000,
                          "batch doc never appeared before the conflict test")

        // Change it server-side directly (StockBatchStore itself never
        // calls "update" for stock_batch -- see this file's header comment
        // for why that's fine for this test's purpose: it makes the
        // conflict's `current` payload genuinely differ from what
        // StockBatchStore's local cache still holds, so the reconciliation
        // assertion below is checking a real change, not an echo).
        var currentDoc = _pollEmulatorDoc(docPath, batchId, function(d) { return d !== null }, 5000,
                                           "batch doc vanished unexpectedly")
        var plainBatch = _firestoreFieldsToPlain(currentDoc.fields)
        var updatedAfter = Object.assign({}, plainBatch, { note: "Changed directly server-side" })
        Gateway.recordMutation("stock_batch", batchId, "update", plainBatch, updatedAfter)
        _pollEmulatorDoc(docPath, batchId, function(d) {
            return d !== null && d.fields.note.stringValue === "Changed directly server-side"
        }, 5000, "direct server-side update never landed -- conflict setup failed")

        // Second identity now attempts to CREATE the same batchId, unaware
        // it already exists (before: null) -- the actual reachable
        // conflict path for this entity.
        var savedToken = AuthStore.idToken
        AuthStore.idToken = fixture.secondIdToken
        lastConflict = null
        Gateway.recordMutation("stock_batch", batchId, "create", null,
            { batchId: batchId, productId: "prod-e2e-conflict", qtyReceived: 999, qtyRemaining: 999 })
        AuthStore.idToken = savedToken

        tryVerify(function() { return lastConflict !== null }, 10000,
                  "Gateway.mutationConflicted never fired for a duplicate-create stock_batch conflict")
        compare(lastConflict.entity, "stock_batch")
        compare(lastConflict.entityId, batchId)
        compare(lastConflict.current.note, "Changed directly server-side")

        // The real point of this test: StockBatchStore's own
        // _onMutationConflicted handler (connected app-wide, not just for
        // this test's own callback above) must have reconciled its local
        // cache to match the server's actual current state.
        var cached = StockBatchStore.getById(batchId)
        verify(cached !== null, "StockBatchStore's local cache lost track of the batch entirely")
        compare(cached.note, "Changed directly server-side")
    }
}
