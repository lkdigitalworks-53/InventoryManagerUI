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
            if (!classified.granted) {
                console.warn("[LockManager] renewal failed, no longer holding",
                             heldNow.entity, heldNow.entityId)
                if (_held === heldNow) _held = null
                _renewTimerInstance().stop()
            }
        })
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
        return { granted: false, holder: body.holder || null, reason: "denied" }
    }

    // Acquire a lock before opening an edit action (never before a plain
    // view — reads are always allowed, per the design). callback(result)
    // where result is { granted, holder, reason }. `reason` is only set
    // when granted is false: "denied" means a real holder has it (`holder`
    // carries {name, role, expiresAt}); "error" means we couldn't even get
    // a real decision (network issue, endpoint not deployed, etc.) — the
    // caller should show a different, honest message for that case, not
    // claim someone else is editing when we don't actually know that.
    function acquire(entity, entityId, callback) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            if (callback) callback({ granted: false, holder: null, reason: "error" })
            return
        }
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

    function _post(url, payload, callback) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var body = null
            try { body = JSON.parse(xhr.responseText) } catch (e) { body = null }
            if (callback) callback(xhr.status, body)
        }
        xhr.open("POST", url)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        var envelope = { env: FirebaseService.environment }
        for (var k in payload) envelope[k] = payload[k]
        xhr.send(JSON.stringify(envelope))
    }
}
