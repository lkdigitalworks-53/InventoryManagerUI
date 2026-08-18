.pragma library

// Shared helpers for test/e2e/*.qml, factored out of tst_InventoryE2E.qml
// (the Phase 1 pilot) when tst_OrdersE2E.qml needed the same fixture-
// loading, emulator-polling, and raw-POST warm-up logic.
//
// Every function here takes the calling TestCase instance explicitly as
// `tc` and calls tc.tryVerify/tc.fail/tc.compare/tc.verify and reads
// tc.fixture/tc.lastConflict through it. `.pragma library` scripts run in
// an isolated JS context with no access to the QML component scope a bare
// `tryVerify(...)` call resolves against inside a TestCase file itself --
// every QtTest primitive and TestCase property this code needs has to come
// in as an explicit call/read on the passed-in instance instead of an
// unqualified reference. Property reads (tc.fixture, tc.lastConflict) are
// the same QML object-reference access any external JS uses to read a QML
// item's properties, so those are on solid ground. Calling tc.tryVerify(...)
// itself -- a TestCase-provided function, not a plain property -- through
// an object reference from inside pragma-library code is a new pattern for
// this codebase (BreakdownMath.js/OrderMath.js/ImportMath.js are pure math,
// no TestCase involved) and hasn't been run anywhere with a real Qt
// toolchain; flagged as unverified beyond static review, same as every
// other file in this suite before its first CI attempt.

function loadFixture(tc, fixtureUrl) {
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
    tc.tryVerify(function() { return done }, 5000, "timed out reading .fixture.json")
    // status is documented to be unreliable for file:// reads (often 0
    // regardless of success or failure) — an empty body is the trustworthy
    // signal that the read actually failed.
    if (!text || text.length === 0) {
        tc.fail("could not read .fixture.json from " + fixtureUrl + " (status " + status
             + ", empty body) — run test/e2e/seed.js against a running emulator first")
    }
    return JSON.parse(text)
}

// Polls a raw REST GET against the Firestore emulator, independent of
// FirebaseService — asserting via the same client code that wrote the data
// would only prove the client's local cache is self-consistent, not that
// anything real reached the server. Re-fires a fresh async GET on every
// tryVerify tick until predicateFn(doc) is true or it times out; doc is
// null while missing/not-yet-caught-up.
//
// Also checks tc.lastConflict on every tick and fails immediately with the
// real conflict data if one appears for this docPath's entityId, rather
// than waiting out the full timeout to report a generic message.
function pollEmulatorDoc(tc, emulatorFirestoreHost, docPath, entityId, predicateFn, timeoutMs, message) {
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
                    console.warn("[pollEmulatorDoc]", entityId,
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
        xhr.setRequestHeader("Authorization", "Bearer " + tc.fixture.idToken)
        xhr.send()
    }

    tc.tryVerify(function() {
        if (tc.lastConflict && tc.lastConflict.entityId === entityId) {
            tc.fail(message + " -- Gateway.mutationConflicted fired for "
                + tc.lastConflict.entity + "/" + tc.lastConflict.entityId
                + ", server has: " + JSON.stringify(tc.lastConflict.current))
        }
        fire()
        return predicateFn(latest)
    }, timeoutMs, message + " (entityId=" + entityId + ", docPath=" + docPath + ")")

    return latest
}

// Raw POST bypassing Gateway/OutboxStore entirely — used for both warm-up
// calls (paying a Cloud Functions emulator's per-function cold-start once,
// deliberately, in initTestCase(), rather than letting the first real test
// eat it — see tst_InventoryE2E.qml's initTestCase() comment for the full
// story of why that ordering matters) and diagnostic probes. Returns
// {status, text} instead of asserting itself so each caller applies its own
// expected status/timeout — a delta warm-up expects 404 on a nonexistent
// doc, a mutation warm-up expects 200 on a real create, and those aren't
// interchangeable.
function postDirect(tc, url, payload, timeoutMs, timeoutMessage) {
    var status = -1, text = "", done = false
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
        if (xhr.readyState === XMLHttpRequest.DONE) {
            status = xhr.status
            text = xhr.responseText
            done = true
        }
    }
    xhr.open("POST", url, true)
    xhr.setRequestHeader("Content-Type", "application/json")
    xhr.setRequestHeader("Authorization", "Bearer " + tc.fixture.idToken)
    xhr.send(JSON.stringify(payload))
    tc.tryVerify(function() { return done }, timeoutMs, timeoutMessage)
    return { status: status, text: text }
}
