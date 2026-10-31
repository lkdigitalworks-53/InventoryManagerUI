pragma Singleton
import QtQuick

// Client-side half of Component 2 (pessimistic record locking),
// docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md §4.
// Server half: functions/lib/lockLogic.js + index.js's acquireLock/
// releaseLock endpoints.
//
// Assumption baked into this design: at most ONE lock is held at a time
// (one edit dialog open) — this owns a single renewal timer, not a pool.
// Revisit if that assumption turns out wrong (e.g. a future multi-pane
// editing UI that could plausibly hold two locks at once).
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
// Written to convention (mirrors Gateway.qml's dynamically-created Timer
// pattern, since QtObject has no declarative Timer child support) and
// manually reviewed; needs a real device/build pass before merge, same
// status as every other client-side piece from this session.

QtObject {
    id: root

    property string acquireLockUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/acquireLock"
    property string releaseLockUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/releaseLock"

    // Renewal heartbeat cadence — well under the server's 90s TTL
    // (index.js's LOCK_TTL_MS), so a normal renewal lands with margin to
    // spare even accounting for a slow request or two before it's due.
    readonly property int renewIntervalMs: 30000

    // How long one lock request may take before it counts as "no answer" (status 0). Without a timeout a
    // request that never answers never calls back: a bulk Approve then waits on it for good, with no cancel
    // button (PR #174 sweep, D-E). 15 s is a STARTING value, not measured (like SendPolicy's 10 s / 30 s):
    // between the 10 s a waiting caller gets there and the 30 s a background send gets, and under
    // renewIntervalMs so two renewals never overlap. A cold Cloud Function start that exceeds it reads as
    // "no answer" (the user taps again and it is warm): check acquireLock latency on a device and tune.
    readonly property int requestTimeoutMs: 15000

    // The lock this device currently holds, or null. { entity, entityId, requestId }
    property var _held: null
    property var _renewTimer: null
    property int _requestSeq: 0

    function _renewTimerInstance() {
        if (!_renewTimer) {
            _renewTimer = Qt.createQmlObject(
                "import QtQuick; Timer { repeat: true }", root, "LockRenewTimer")
            _renewTimer.interval = renewIntervalMs
            _renewTimer.triggered.connect(_onRenewTick)
        }
        return _renewTimer
    }

    function _onRenewTick() {
        if (!_held) { _renewTimerInstance().stop(); return }
        var heldNow = _held
        _post(acquireLockUrl, {
            entity: heldNow.entity,
            entityId: heldNow.entityId,
            requestId: heldNow.requestId
        }, function(status, body) {
            // A renewal that gets rejected — someone else's acquire won a
            // race after ours expired, which the 3x TTL/heartbeat margin
            // makes rare but not impossible under real network jitter —
            // just stops renewing silently. This is a UX gap, not a data-
            // safety one: whatever dialog is open keeps working locally,
            // and if it tries to SAVE after this, the normal recordMutation/
            // recordDelta conflict path (Component 3's CAS backstop) is
            // still there underneath to catch it for real. Same
            // classification as acquire() for consistency — an
            // infrastructure hiccup during renewal shouldn't be treated
            // differently from a real denial here; either way we just stop
            // renewing and let the next real save attempt be the source of
            // truth.
            var classified = _classifyAcquireResponse(status, body)
            if (_renewalLost(status, body, classified)) {
                console.warn("[LockManager] renewal failed, no longer holding",
                             heldNow.entity, heldNow.entityId)
                if (_held === heldNow) _held = null
                _renewTimerInstance().stop()
            }
        })
    }

    // True when a renewal answer means the lock is gone: the server REFUSED it with an answer we can read
    // (409, 403, or a 5xx that carries `{ ok: false, ... }`). A renewal with NO answer keeps the hold and the
    // next heartbeat tries again (the TTL, 3 heartbeats, outlives one lost renewal). No answer = status 0 (the
    // request timed out or the device is offline) OR a body we cannot read (an HTML error page, or the empty /
    // partial body a timeout leaves next to a status recovered by the QTBUG-49896 snapshot). Before the request
    // timeout existed a hung renewal behaved exactly like this; keeping it so means adding the timeout does not
    // start dropping locks on a slow network (PR #174 sweep, D-E).
    function _renewalLost(status, body, classified) {
        return !classified.granted && status !== 0 && body !== null && typeof body === "object" && typeof body.ok === "boolean"
    }

    // Classifies an acquireLock HTTP response. Pure function, no XHR — same
    // fix and same reasoning as Gateway._classifyDeltaResponse (2026-07-29
    // systematic-debugging session): a genuine denial (someone else holds
    // it) is only ever a well-formed `{ok:false, holder:{...}}` from OUR
    // code. An undeployed endpoint's 404, or any other infrastructure-level
    // failure, must never be presented to the user as "someone else is
    // editing this" — that's not what happened, and saying so is actively
    // misleading (this was the reported bug: a lone tester seeing that
    // message with nobody else on the system at all).
    function _classifyAcquireResponse(status, body) {
        var isRealResponse = body !== null && typeof body === "object" && typeof body.ok === "boolean"
        if (!isRealResponse) return { granted: false, holder: null, reason: "error" }
        if (body.ok === true) return { granted: true, holder: null, reason: null }
        // A real ok:false response. acquireLock's handler only ever uses
        // 409 for an actual denial (someone else holds it, with `holder`
        // populated) — 400 (missing-fields), 401 (invalid-token), 403
        // (no-tenant-context), and 500 (lock-failed, the transaction's own
        // catch) are all well-formed ok:false bodies too, but none of them
        // mean "someone else is editing this". Treating every non-ok
        // response as "denied" was exactly the bug _classifyDeltaResponse
        // was already fixed for on the delta path (2026-07-29) — this is
        // the same fix, applied here (2026-08-06 review, finding C6).
        if (status === 409) return { granted: false, holder: body.holder || null, reason: "denied" }
        // 403 `no-tenant-context`: the server refused the caller's MEMBERSHIP (removed, suspended, invalid
        // role). Still reason "error" (not a denial, so no caller can call it "edited elsewhere"), plus
        // `noAccess` so a caller can say what happened instead of "connection issue, try again": retrying
        // can never succeed until an owner or admin restores the member (S2f-3 sweep, PR #171 device test).
        // Only this exact pair counts: any other 403 body stays a plain error.
        if (status === 403 && body.error === "no-tenant-context")
            return { granted: false, holder: null, reason: "error", noAccess: true }
        return { granted: false, holder: null, reason: "error" }
    }

    // Acquire a lock before opening an edit action (never before a plain
    // view — reads are always allowed, per the design). callback(result)
    // where result is { granted, holder, reason }. `reason` is only set
    // when granted is false: "denied" means a real holder has it (`holder`
    // carries {name, role, expiresAt}); "error" means we couldn't even get
    // a real decision (network issue, endpoint not deployed, etc.) — the
    // caller should show a different, honest message for that case, not
    // claim someone else is editing when we don't actually know that.
    // An "error" result may also carry `noAccess: true` (403 no-tenant-context: the
    // membership was refused, retrying cannot help). Callers read the four-way state
    // through FailureCause.lockState(result), never `reason` directly.
    function acquire(entity, entityId, callback) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            if (callback) callback({ granted: false, holder: null, reason: "error" })
            return
        }
        // A dialog can be opened long after sign-in, well past the token's
        // freshness window — without this, a stale token produces a 401
        // that (pre-fix, see _classifyAcquireResponse above) used to show
        // as "someone else is editing this" instead of what it actually
        // was. Matches Gateway.qml's drainNow()/_send()/_sendDelta() etc.,
        // which all do this before their own auth-sensitive requests.
        if (typeof AuthService !== "undefined" && AuthService)
            AuthService.ensureFreshToken()
        var requestId = _nextRequestId()
        _post(acquireLockUrl, {
            entity: entity,
            entityId: entityId,
            requestId: requestId
        }, function(status, body) {
            var classified = _classifyAcquireResponse(status, body)
            if (classified.granted) {
                _held = { entity: entity, entityId: entityId, requestId: requestId }
                _renewTimerInstance().restart()
            }
            if (callback) callback(classified)
        })
    }

    // Release the currently held lock, but ONLY if `entity`/`entityId`
    // match what's actually held — a stale call from a dialog that's
    // already lost its lock (e.g. to a renewal failure above) is a safe
    // no-op, not an accidental release of whatever's held now. Call on
    // dialog save-success or cancel/close.
    function release(entity, entityId) {
        if (!_held || _held.entity !== entity || _held.entityId !== entityId) return
        var releasing = _held
        _held = null
        _renewTimerInstance().stop()
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) return
        // Fire-and-forget is fine here — TTL expiry is the real safety net
        // (design doc §4), this is purely a fast-reclaim nicety for whoever
        // wants the record next.
        _post(releaseLockUrl, { entity: releasing.entity, entityId: releasing.entityId }, function() {})
    }

    // True if THIS device currently holds a lock on this record — lets a
    // dialog that's mid-edit tell the difference between "I have this
    // locked" and "nobody does" without re-deriving it from _held directly.
    function isHeldByMe(entity, entityId) {
        return !!(_held && _held.entity === entity && _held.entityId === entityId)
    }

    // Sign-out hygiene (mirrors Gateway.clear()/OutboxStore.clear(), called
    // alongside them in Main.qml). No network release attempt — the token
    // that would authorize it is about to be invalid anyway; TTL expiry
    // reclaims it for whoever's next.
    function clear() {
        _held = null
        if (_renewTimer) _renewTimer.stop()
    }

    function _nextRequestId() {
        _requestSeq++
        return "lock-" + Date.now() + "-" + _requestSeq
    }

    // QTBUG-49896 (SKILLS Skill 45/76): QML's XMLHttpRequest can reset `status` to 0 at the 3->4 transition for
    // some non-2xx answers (a 409 is the original report). Same snapshot as Gateway / PhotoQueue: keep the last
    // non-zero status and body seen at HEADERS_RECEIVED / LOADING. Without it a real 403 `no-tenant-context` or
    // 409 denial could reach _classifyAcquireResponse as status 0 and be worded as "connection issue".
    function _captureBeforeStatusIsLost(xhr, snap) {
        if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED || xhr.readyState === XMLHttpRequest.LOADING) {
            if (xhr.status !== 0) {
                snap.status = xhr.status
                snap.responseText = xhr.responseText
            }
        }
    }

    // Answers `callback(status, body)` exactly once: DONE and the timeout can both fire for one request (see
    // PhotoQueue._failUpload), and a late DONE after the timeout must not answer a second time.
    // status 0 + null body = no answer (timeout, offline); the classifier turns that into reason "error".
    function _post(url, payload, callback) {
        var xhr = new XMLHttpRequest()
        var settled = false
        var snap = { status: 0, responseText: "" }
        function _settle(status, text) {
            if (settled) return
            settled = true
            var body = null
            try { body = JSON.parse(text) } catch (e) { body = null }
            if (callback) callback(status, body)
        }
        xhr.onreadystatechange = function() {
            _captureBeforeStatusIsLost(xhr, snap)
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var lost = xhr.status === 0
            _settle(lost ? snap.status : xhr.status, lost ? snap.responseText : xhr.responseText)
        }
        xhr.ontimeout = function() { _settle(0, "") }
        xhr.open("POST", url)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.timeout = requestTimeoutMs
        var envelope = { env: FirebaseService.environment }
        for (var k in payload) envelope[k] = payload[k]
        xhr.send(JSON.stringify(envelope))
    }
}
