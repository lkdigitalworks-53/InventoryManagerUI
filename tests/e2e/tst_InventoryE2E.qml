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
    //
    // Also checks lastConflict on every tick and fails immediately with the
    // real conflict data if one appears for this docPath's entityId, rather
    // than waiting out the full timeout to report a generic, uninformative
    // message. (tryVerify's own `message` argument is evaluated once, before
    // polling starts, so it can't reflect something that happens *during*
    // the wait — this is why that check has to live inside the predicate,
    // not be pre-built as a string.)
    // Diagnostic instrumentation (2026-08-12): added after a run where
    // test_addProduct's poll timed out with the generic "doc never
    // appeared" message despite every recordMutation call in that run's
    // Functions-emulator log finishing in <1.1s with no error logged —
    // math that doesn't support a plain "ran out of time" explanation.
    // The real gap is that fire() below collapsed EVERY non-200 response
    // (403, 500, a genuine 404-still-waiting, a malformed request, ...)
    // into the same `latest = null`, so a permissions problem and "not
    // created yet" were indistinguishable from this test's own point of
    // view. This does not change pass/fail behavior — same predicate, same
    // timeout — it only makes the CI log show what the poll actually
    // observed (status + body) instead of forcing a guess. Intended to be
    // temporary: strip it back out once the addProduct-specific failure is
    // understood and this file has been stable for a while.
    function _pollEmulatorDoc(docPath, entityId, predicateFn, timeoutMs, message) {
        var url = emulatorFirestoreHost
            + "/v1/projects/inventorymanager-48392/databases/(default)/documents/" + docPath
        var latest = null
        var inFlight = false
        var startedAt = Date.now()
        var attemptCount = 0
        var lastStatus = -1
        var lastLoggedStatus = -2
        var lastLoggedAt = 0

        function fire() {
            if (inFlight) return
            inFlight = true
            attemptCount++
            var xhr = new XMLHttpRequest()
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    lastStatus = xhr.status
                    latest = (xhr.status === 200) ? JSON.parse(xhr.responseText) : null
                    // Log on every status change, and at most once a second
                    // otherwise -- a run that just keeps 404ing still shows
                    // elapsed-time progression instead of one line total.
                    var nowMs = Date.now()
                    if (lastStatus !== lastLoggedStatus || (nowMs - lastLoggedAt) >= 1000) {
                        console.warn("[_pollEmulatorDoc]", entityId,
                                     "attempt", attemptCount,
                                     "elapsedMs", (nowMs - startedAt),
                                     "status", lastStatus,
                                     "body", (lastStatus !== 200)
                                         ? String(xhr.responseText).slice(0, 300)
                                         : "(200 OK)")
                        lastLoggedStatus = lastStatus
                        lastLoggedAt = nowMs
                    }
                    inFlight = false
                }
            }
            xhr.open("GET", url, true)
            xhr.setRequestHeader("Authorization", "Bearer " + fixture.idToken)
            xhr.send()
        }

        tryVerify(function() {
            if (lastConflict && lastConflict.entityId === entityId) {
                fail(message + " -- Gateway.mutationConflicted fired for "
                    + lastConflict.entity + "/" + lastConflict.entityId
                    + ", server has: " + JSON.stringify(lastConflict.current))
            }
            fire()
            return predicateFn(latest)
        }, timeoutMs, message + " (entityId=" + entityId + ", docPath=" + docPath + ")")

        return latest
    }

    // Discovered while reviewing this file after rebasing onto
    // fix/async-write-sequencing-review-fixes: that branch added
    // Gateway.mutationConflicted(entity, entityId, current), fired when the
    // server's applyMutation() CAS check (_deepEqual(current, before)) fails
    // -- a 409 that Gateway now recognizes instead of retrying forever, but
    // that recognition is still silent from a caller's perspective (no error
    // surfaces to InventoryStore's callback). A genuine conflict shouldn't
    // happen in this test's single-writer, fresh-id-per-test flow, but if it
    // does, this turns an opaque "doc never appeared" timeout into an actual
    // diagnostic instead of another guess.
    property var lastConflict: null

    function _onMutationConflicted(entity, entityId, current) {
        lastConflict = { entity: entity, entityId: entityId, current: current }
    }

    // Shared by the initTestCase() warm-up and the diagnostic probe below —
    // both need the identical raw POST (bypassing Gateway/OutboxStore
    // entirely) with only the entityId/timeout differing. Returns
    // {status, text} instead of asserting itself so each caller can apply
    // its own timeout/message.
    function _postRecordMutationDirect(entityId, timeoutMs, timeoutMessage) {
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
            entityId: entityId,
            action: "create",
            before: null,
            after: { name: "Diagnostic Widget", sku: "SKU-DIAG-1", price: 1, stock: 1 },
            requestId: "diag-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }))
        tryVerify(function() { return done }, timeoutMs, timeoutMessage)
        return { status: status, text: text }
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
}

