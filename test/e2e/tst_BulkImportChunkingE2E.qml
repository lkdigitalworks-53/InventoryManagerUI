import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// E2E coverage for the bulk-import chunking fix (2026-08-29). Real code
// path: Gateway.recordMutations("inventory", items) -> chunked into
// <=maxBatchSize OutboxStore.enqueueBatch() entries -> POST to the emulated
// recordMutationsBatch Cloud Function -> Admin SDK transaction write to the
// emulated Firestore -> response back to the client, exactly like
// tst_InventoryE2E.qml's pattern but exercising the BATCH endpoint
// specifically (a completely separate Cloud Function with its own cold
// start — see initTestCase()'s warm-up below and tst_InventoryE2E.qml's
// initTestCase() comment for why that matters here).
//
// Test 1 reproduces the ACTUAL reported bug: 250 rows, one call, verified
// against the real emulator that BOTH resulting chunks (200 + 50) actually
// landed — before this fix, the whole 250-item call was rejected outright
// and the client never even noticed. Test 2 proves the other half: a
// request the server permanently rejects (not a size issue this time — an
// invalid action, to get a REAL unsupported-action 400 from the actual
// validateBatchMutationRequest, not a simulated one) must roll back the
// optimistic local row and durably record the failure, not retry forever
// in silence while claiming success.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt — no network
// egress here to Firebase's emulator distribution, same as every other
// file in this directory.

TestCase {
    name: "BulkImportChunkingE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realBatchFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutationsBatch"

    property var fixture: null
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")
    property var lastPermanentFailure: null

    function _loadFixture() {
        return E2EHelpers.loadFixture(this, fixtureUrl)
    }

    function _pollEmulatorDoc(docPath, entityId, predicateFn, timeoutMs, message) {
        return E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, docPath, entityId,
                                           predicateFn, timeoutMs, message)
    }

    function _onBatchMutationFailedPermanently(entity, items, error) {
        lastPermanentFailure = { entity: entity, items: items, error: error }
    }

    // Same reasoning as tst_InventoryE2E.qml's initTestCase(): the emulator
    // lazily spins up a fresh Node worker on a function's FIRST real
    // invocation. recordMutationsBatch has never been called by ANY other
    // E2E file (they all use the single-item recordMutation), so it pays
    // its own separate cold-start cost here, once, rather than letting
    // test_recordMutations_over_the_cap eat it inside a tighter budget.
    function initTestCase() {
        fixture = _loadFixture()
        AuthService.ensureFreshToken() // no-op unauthenticated; forces AuthService's singleton construction before init() sets a real idToken — see tst_InventoryE2E.qml's identical comment for why this ordering matters.

        var result = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutationsBatch", {
            entity: "inventory",
            requestId: "warmup-batch-" + Date.now(),
            items: [{ entityId: "warmup-" + Date.now(), action: "create", before: null, after: { name: "Warmup", sku: "WARMUP", price: 1, stock: 1 } }]
        }, 15000, "Cloud Functions emulator never responded to the recordMutationsBatch warm-up call")
        compare(result.status, 200, "warm-up recordMutationsBatch call was rejected — response body: " + result.text)
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        Gateway.batchFunctionUrl = emulatorFunctionsBase + "/recordMutationsBatch"
        Gateway.mode = "gateway" // the real production default — see Gateway.qml
        AuthStore.idToken = fixture.idToken
        AuthStore.tenantId = fixture.tenantId
        InventoryStore.products = []
        OutboxStore.clear()
        lastPermanentFailure = null
        Gateway.batchMutationFailedPermanently.connect(_onBatchMutationFailedPermanently)
    }

    function cleanup() {
        Gateway.batchMutationFailedPermanently.disconnect(_onBatchMutationFailedPermanently)
        FirebaseService.emulatorHost = ""
        Gateway.batchFunctionUrl = realBatchFunctionUrl
        AuthStore.idToken = ""
        AuthStore.tenantId = ""
    }

    // ── The actual reported bug, reproduced and proven fixed ────────────────

    function test_recordMutations_over_the_cap_lands_every_row_via_chunked_batches() {
        var runId = Date.now()
        var items = []
        for (var i = 0; i < 250; ++i) {
            items.push({
                entityId: "e2e-chunk-" + runId + "-" + i,
                action: "create", before: null,
                after: { name: "Chunk Widget " + i, sku: "SKU-CHUNK-" + i, price: 1, stock: 1 }
            })
        }

        Gateway.recordMutations("inventory", items)

        // Before this fix: the entire 250-item call was rejected by the real
        // server's MAX_BATCH_SIZE check and NONE of these landed, forever,
        // silently. Checking the two chunk boundaries (last of chunk 1,
        // first of chunk 2) plus the very first and very last row is enough
        // to prove BOTH chunks actually committed, not just one.
        var checkIndices = [0, 199, 200, 249]
        for (var c = 0; c < checkIndices.length; ++c) {
            var idx = checkIndices[c]
            var entityId = "e2e-chunk-" + runId + "-" + idx
            var docPath = "tenants/" + fixture.tenantId + "/inventory/" + entityId
            var doc = _pollEmulatorDoc(docPath, entityId, function(d) { return d !== null }, 8000,
                                        "row at index " + idx + " never reached Firestore — chunking regression")
            compare(doc.fields.name.stringValue, "Chunk Widget " + idx)
        }
    }

    // ── A genuine permanent rejection must roll back and notify, not retry
    // forever while claiming success ─────────────────────────────────────────

    function test_permanently_rejected_item_rolls_back_and_is_not_reported_as_success() {
        var badId = "e2e-bad-" + Date.now()
        // Seed the optimistic local row exactly the way InventoryStore.
        // upsertMany would have (products committed before the remote
        // outcome is known) — this is what proves ROLLBACK happened, not
        // just that the request failed.
        InventoryStore.products = [{
            productId: badId, name: "Should Roll Back", sku: "BAD-1", category: "General",
            stock: 1, minStock: 1, price: 1, sellingPrice: 1, taxable: false, taxPercent: 0,
            size: "", unit: "pc", description: "", supplierId: ""
        }]

        // An invalid action, not an oversized batch — proves the OTHER
        // definitive validation errors this fix also protects against
        // (see _classifyBatchMutationFailure's allowlist), not just the one
        // the bug report named.
        Gateway.recordMutations("inventory", [{
            entityId: badId, action: "not-a-real-action", before: null,
            after: { name: "Should Roll Back", sku: "BAD-1", price: 1, stock: 1 }
        }])

        tryVerify(function() { return InventoryStore.products.length === 0 },
                  8000, "InventoryStore never rolled back the permanently-rejected row")

        // Belt-and-suspenders against the REAL server, not just the client's
        // own bookkeeping: confirm it genuinely never got written either.
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + badId
        _pollEmulatorDoc(docPath, badId, function(d) { return d === null }, 5000,
                          "a row the client rolled back must never have reached Firestore")

        verify(lastPermanentFailure !== null, "batchMutationFailedPermanently must have fired from a real server rejection")
        compare(lastPermanentFailure.error, "unsupported-action")

        var recordedInLog = false
        for (var i = 0; i < ActivityLog.entries.length; ++i) {
            if (ActivityLog.entries[i].kind === "import_error") { recordedInLog = true; break }
        }
        verify(recordedInLog, "the failure must be durably recorded (ActivityLog), not just reconciled silently in memory")
    }
}
