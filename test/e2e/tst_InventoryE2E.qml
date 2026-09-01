import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

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
// Fixture loading, emulator-doc polling, and the raw-POST warm-up primitive
// now live in E2EHelpers.js (factored out 2026-08-16 when tst_OrdersE2E.qml
// needed the same logic) — see that file for the mechanics and the pragma-
// library/TestCase boundary this crosses.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt -- no network
// egress here to Firebase's emulator distribution.

TestCase {
    name: "InventoryE2E"

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"

    property var fixture: null
    // seed.js and this file both live in test/e2e/ (moved here 2026-08-14 —
    // originally this file sat under tests/e2e/, a second, similarly-named
    // directory that the qml-tests CI job's blanket "-input tests" scan
    // recursively swept in, even though it needs the Firebase Emulator
    // Suite + seeded fixture that only the dedicated e2e-tests job sets up.
    // Moving the file out of the tests/ tree entirely — rather than trying
    // to exclude a subdirectory from qmltestrunner's scan, which has no
    // documented flag for that — was the reliable fix). The "../../" below
    // still resolves to the repo root either way, since both locations are
    // the same depth from it.
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")

    function _loadFixture() {
        return E2EHelpers.loadFixture(this, fixtureUrl)
    }

    // Discovered while reviewing this file after rebasing onto
    // fix/async-write-sequencing-review-fixes: that branch added
    // Gateway.mutationConflicted(entity, entityId, current), fired when the
    // server's applyMutation() CAS check (_deepEqual(current, before)) fails
    // -- a 409 that Gateway now recognizes instead of retrying forever, but
    // that recognition is still silent from a caller's perspective (no error
    // surfaces to InventoryStore's callback). A genuine conflict shouldn't
    // happen in this test's single-writer, fresh-id-per-test flow, but if it
    // does, E2EHelpers.pollEmulatorDoc turns an opaque "doc never appeared"
    // timeout into an actual diagnostic instead of another guess.
    property var lastConflict: null

    function _onMutationConflicted(entity, entityId, current) {
        lastConflict = { entity: entity, entityId: entityId, current: current }
    }

    function _pollEmulatorDoc(docPath, entityId, predicateFn, timeoutMs, message) {
        return E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, docPath, entityId,
                                           predicateFn, timeoutMs, message)
    }

    // Shared by the initTestCase() warm-up and the diagnostic probe below —
    // both need the identical raw POST (bypassing Gateway/OutboxStore
    // entirely) with only the entityId/timeout differing.
    function _postRecordMutationDirect(entityId, timeoutMs, timeoutMessage) {
        return E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutation", {
            env: "prd", // matches FirebaseService.environment for a bare qmltestrunner run
            entity: "inventory",
            entityId: entityId,
            action: "create",
            before: null,
            after: { name: "Diagnostic Widget", sku: "SKU-DIAG-1", price: 1, stock: 1 },
            requestId: "diag-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }, timeoutMs, timeoutMessage)
    }

    // Runs exactly once, before ANY test_ function — unlike this file's own
    // declaration order, which QtQuickTest does NOT preserve. Confirmed
    // empirically from the run that surfaced this (2026-08-13, via the
    // -o -,txt CI fix + results.xml): actual execution order was
    // test_addProduct, test_deleteProduct, test_recordMutation, then
    // test_updateProduct — alphabetical, not declared order.
    // test_recordMutation_function_accepts_seeded_credentials's own old
    // comment claimed "declared first so it fails fast" — that was never
    // true, and is very likely why this bug survived four CI rounds: the
    // probe meant to catch a cold Functions emulator never actually ran
    // before the CRUD tests it was supposed to protect.
    //
    // Root cause of the actual bug (found from that same run's raw log):
    // the Cloud Functions Emulator lazily spins up a fresh Node worker on
    // the FIRST real invocation of a given function — "Loaded functions
    // definitions from source" at emulator boot is static registration
    // only, not a warm runtime. In the run that caught this, the client
    // dispatched its POST within ~0.5s of the test starting, but the
    // emulator's own log didn't show "Beginning execution" until 6.68s
    // later — 1.6s AFTER test_addProduct had already given up and failed
    // on its 5000ms poll. Every call after that first one landed in well
    // under 1s. That's the exact "first one hangs, the rest are fine"
    // pattern this bug has shown across every prior run, regardless of
    // which literal test happened to create the first product.
    //
    // Fix: pay that cold-start cost here, once, with a timeout sized for
    // "one-time emulator warm-up" rather than per-call latency — keeps the
    // real tests' 5000ms budgets meaningful instead of just inflating them
    // and hoping. Does not poll/clean up the resulting doc afterward (a
    // stray "warmup-*" inventory doc is harmless to the 4 CRUD tests below,
    // none of which assert on collection counts) — a deliberate, minimal
    // trade-off, not an oversight.
    function initTestCase() {
        fixture = _loadFixture()

        // Forces AuthService's singleton construction now, before any
        // test's init() sets AuthStore.idToken for real. Confirmed root
        // cause of the addProduct failure (2026-08-14, via the Gateway._send
        // diagnostic): AuthService is a pragma-Singleton QML type never
        // referenced anywhere in this file or in init() -- its actual FIRST
        // reference in the whole run is inside Gateway.drainNow():
        // "if (typeof AuthService !== 'undefined' && AuthService)
        // AuthService.ensureFreshToken()". Referencing a QML singleton for
        // the first time triggers its Component.onCompleted, which for
        // AuthService calls AuthStore.loadSession() -> clear() UNCONDITIONALLY
        // before checking whether there's a persisted session to restore --
        // wiping idToken/tenantId/everything back to "" regardless.
        // test_addProduct is the first test to actually call
        // Gateway.recordMutation() (the diagnostic probe and the warm-up
        // below both bypass Gateway/OutboxStore entirely, using a raw
        // XMLHttpRequest instead) -- so it's also the first thing that ever
        // references AuthService, and it does so from inside drainNow(),
        // AFTER its own init() already set AuthStore.idToken = fixture.idToken.
        // The construction-time wipe lands in between, clearing idToken
        // right before _send()'s own guard checks it. Confirmed directly,
        // not inferred: the now-removed Gateway._send() diagnostic logged
        // idTokenLength as 0 on every call across a ~5.1s span, then 469 (a
        // real token) the instant the next test's init() re-set it --
        // _send()'s guard was silently no-op-ing the whole time, and the
        // item sat queued until an unrelated later drainNow() call (the
        // next test's own create) happened to pick it up. That's the exact
        // failure this file has been chasing since the Seventh run.
        //
        // The real app almost certainly never hits this in practice --
        // something in its normal UI/bootstrap flow references AuthService
        // (to check login state) long before any real login sets
        // AuthStore.idToken, so the construction-time wipe lands on
        // already-empty state there. This test pokes AuthStore directly,
        // skipping that natural bootstrap order, so it has to force the
        // same ordering explicitly. That inference isn't traced end to end
        // against main.qml's actual bootstrap sequence -- flagged as worth
        // Taher's own quick confirmation, not re-verified here.
        AuthService.ensureFreshToken() // no-op (not authenticated yet); forces construction only

        var result = _postRecordMutationDirect(
            "warmup-" + Date.now(), 15000,
            "Cloud Functions emulator never responded to the warm-up call")
        compare(result.status, 200,
                "warm-up recordMutation call was rejected — response body: " + result.text)
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

    // Diagnostic — added after test_addProduct/update/delete all failed
    // with "doc never appeared" and no visible reason: Gateway._send()
    // logs the actual HTTP status/response via console.warn on failure but
    // never surfaces it to the caller (recordMutation is fire-and-forget by
    // design), so a rejected request looks identical to a slow/successful
    // one from this test's perspective. This bypasses Gateway/OutboxStore
    // entirely and POSTs to the same emulated recordMutation function with
    // the same payload shape _send() uses, so a failure here prints the
    // real status/response text via compare()'s own output — replacing a
    // guess with evidence. No longer relied on to run first (see
    // initTestCase() above for why that assumption was wrong) — kept as a
    // fast regression check that credentials/payload shape are still
    // accepted, now reliably fast since initTestCase() already warmed the
    // emulator up by the time this runs.
    function test_recordMutation_function_accepts_seeded_credentials() {
        var result = _postRecordMutationDirect(
            "diag-" + Date.now(), 5000, "recordMutation call never completed")
        compare(result.status, 200, "recordMutation rejected the request — response body: " + result.text)
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
        var doc = _pollEmulatorDoc(docPath, id, function(d) { return d !== null }, 5000,
                                    "product doc never appeared in the emulator")
        compare(doc.fields.name.stringValue, "E2E Widget")
        compare(Number(doc.fields.stock.integerValue), 10)
    }

    function test_updateProduct_persists_to_emulator() {
        var id = _createProduct("E2E Widget Update", "SKU-E2E-2", 5)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        _pollEmulatorDoc(docPath, id, function(d) { return d !== null }, 5000,
                          "product doc never appeared before the update")

        lastConflict = null // isolate the update's own conflict signal from the create above
        InventoryStore.updateProduct(id, { stock: 25 }, "e2e adjustment")

        var doc = _pollEmulatorDoc(docPath, id, function(d) {
            return d !== null && Number(d.fields.stock.integerValue) === 25
        }, 5000, "updated stock never reached the emulator")
        compare(Number(doc.fields.stock.integerValue), 25)
    }

    function test_deleteProduct_removes_from_emulator() {
        var id = _createProduct("E2E Widget Delete", "SKU-E2E-3", 3)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        _pollEmulatorDoc(docPath, id, function(d) { return d !== null }, 5000,
                          "product doc never appeared before the delete")

        lastConflict = null // isolate the delete's own conflict signal from the create above
        InventoryStore.deleteProduct(id)

        _pollEmulatorDoc(docPath, id, function(d) { return d === null }, 5000,
                          "product doc was never removed from the emulator")
    }

    // Converts a Firestore REST doc's typed field wrappers (stringValue,
    // integerValue, etc.) into a plain object matching what the client's
    // own before/after payloads look like -- needed to build the second
    // user's `before` accurately (it must match the CURRENT server state,
    // not the first user's now-stale local cache, or its own write would
    // itself get rejected as a conflict). Verbatim copy of
    // tst_OrdersStoreE2E.qml's helper of the same name.
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

    // Backlog item (CHECKPOINT.md, post-merge planning): QTBUG-49896 broke
    // Gateway.mutationConflicted's delivery identically for all five stores
    // connected to it (Orders/Inventory/Staff/Supplier/StockBatch) -- only
    // OrdersStore's reconciliation path had actually been proven end to end
    // by a real conflict test before now. This is Inventory's. Simpler than
    // tst_OrdersStoreE2E.qml's version: _createProduct already leaves
    // InventoryStore's own local cache holding the pre-second-write state,
    // so no extra cache manipulation is needed to engineer the staleness --
    // the natural post-create state already IS the stale copy this test
    // needs. A 10s wait (not the old investigation's 45s) since the
    // underlying mechanism is now confirmed working, not still being
    // diagnosed.
    function test_two_users_editing_the_same_product_produces_a_real_conflict() {
        var id = _createProduct("Conflict Test Widget", "SKU-CONFLICT-1", 10)
        var docPath = "tenants/" + fixture.tenantId + "/inventory/" + id
        var doc = _pollEmulatorDoc(docPath, id, function(d) { return d !== null }, 5000,
                                    "product doc never appeared before the conflict test")

        // Second identity writes to the SAME product via the real Gateway
        // path (not InventoryStore's own API, so InventoryStore's local
        // cache is left deliberately stale for the first identity's side
        // below).
        var plainProduct = _firestoreFieldsToPlain(doc.fields)
        var secondUserAfter = Object.assign({}, plainProduct, { name: "Changed By Second User" })
        var savedToken = AuthStore.idToken
        AuthStore.idToken = fixture.secondIdToken
        Gateway.recordMutation("inventory", id, "update", plainProduct, secondUserAfter)
        _pollEmulatorDoc(docPath, id, function(d) {
            return d !== null && d.fields.name.stringValue === "Changed By Second User"
        }, 5000, "second identity's write never actually changed the server's product name -- conflict setup failed")
        AuthStore.idToken = savedToken

        // First identity, still holding its stale local copy (from right
        // after _createProduct, before the write above), now tries its own
        // update via the normal InventoryStore path.
        lastConflict = null
        InventoryStore.updateProduct(id, { stock: 999 }, "e2e conflict test")

        tryVerify(function() { return lastConflict !== null }, 10000,
                  "Gateway.mutationConflicted never fired for a genuine inventory CAS conflict")
        compare(lastConflict.entity, "inventory")
        compare(lastConflict.entityId, id)
        compare(lastConflict.current.name, "Changed By Second User")
    }
}
