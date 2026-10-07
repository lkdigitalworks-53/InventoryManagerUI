.pragma library

// Pure classification, backoff, circuit-breaker and queue-item reducer logic for PhotoQueue.qml.
// No Qt/network/QSettings here -- everything testable stays in this file.
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md
// A plain-Node mirror of this file lives at functions/test/testSupport/photoQueueLogicParity.js
// and runs for real under node --test in this session (23/23, including two monkey tests, run
// stably 5 times). Keep the two in sync by hand -- same convention as StuckWrites.js / Skill 67.
// tests/tst_PhotoQueueLogic.qml proves the QML copy loads and matches; CI is the proof for that one.

var BACKOFF_MS = [2000, 8000, 30000, 120000, 600000] // identical to OutboxStore._backoffMs -- do not fork
var ATTEMPT_CAP = 8
// 403 (PH4 item 1): the upload endpoint is owner/admin only, so a 403 never fixes itself by retrying -> failed
// straight away (existing Retry/Discard UI). Accepted trade-off: a reactivated suspended member's
// no-tenant-context 403 also needs one manual Retry.
var TERMINAL_STATUS = { 400: true, 413: true, 404: true, 409: true, 403: true }
var BREAKER_TRIP_AFTER = 5
var BREAKER_COOLDOWN_BASE_MS = 60000
var BREAKER_COOLDOWN_MAX_MS = 600000

function classifyError(status) {
    return TERMINAL_STATUS[status] ? 'terminal' : 'transient'
}

function nextBackoffMs(attempts) {
    var idx = Math.min(attempts - 1, BACKOFF_MS.length - 1)
    return BACKOFF_MS[Math.max(idx, 0)]
}

function reduceQueueItem(item, event) {
    if (event.type === 'sent' || event.type === 'discard') return null
    if (event.type === 'retry') {
        return Object.assign({}, item, { state: 'enqueued', attempts: 0, nextAttemptAt: 0, lastError: null })
    }
    if (event.type === 'failed') {
        // A failure report only makes sense for an item that is actually in flight. A stale or
        // duplicate report against an item that already moved on (e.g. already 'failed', or
        // reset by a 'retry' in between) is ignored rather than double-counted.
        if (item.state !== 'uploading') return item
        var attempts = item.attempts + 1
        var kind = classifyError(event.status)
        if (kind === 'terminal' || attempts >= ATTEMPT_CAP) {
            return Object.assign({}, item, { state: 'failed', attempts: attempts, lastError: event.status })
        }
        return Object.assign({}, item, {
            state: 'retrying', attempts: attempts, lastError: event.status,
            nextAttemptAt: Date.now() + nextBackoffMs(attempts)
        })
    }
    return item
}

// tripCount escalates the cooldown across repeated trips that happen without a genuine
// 'success' event in between (a successful call is the only thing that resets it). This is
// deliberately separate from consecutiveFailures/status: a caller resetting those two (e.g.
// after a cooldown window elapses and it starts allowing attempts again) does not alone re-earn
// the 60s base cooldown -- only an actual successful upload does that.
function breakerReducer(state, event) {
    var tripCount = state.tripCount || 0
    if (event.type === 'success') {
        return Object.assign({}, state, { status: 'closed', consecutiveFailures: 0, tripCount: 0 })
    }
    var failures = state.consecutiveFailures + 1
    if (failures >= BREAKER_TRIP_AFTER) {
        var cooldownMs = tripCount === 0
            ? BREAKER_COOLDOWN_BASE_MS
            : Math.min(state.cooldownMs * 2, BREAKER_COOLDOWN_MAX_MS)
        return {
            status: 'open', consecutiveFailures: failures,
            cooldownUntil: Date.now() + cooldownMs, cooldownMs: cooldownMs, tripCount: tripCount + 1
        }
    }
    return Object.assign({}, state, { consecutiveFailures: failures })
}

function isBreakerOpen(state, now) {
    var t = typeof now === 'number' ? now : Date.now()
    return state.status === 'open' && t < state.cooldownUntil
}

// PH4 item 4 (L1): ms until an open breaker closes, 0 when closed or already expired. PhotoQueue._reschedule
// waits at least this long, instead of re-arming a 250 ms timer for the whole cooldown.
function breakerWaitMs(state, now) {
    var t = typeof now === 'number' ? now : Date.now()
    return isBreakerOpen(state, t) ? state.cooldownUntil - t : 0
}

// PH4 follow-up (Taher, 2026-10-06): a 404 means the server has no such product. If the product row is
// ALSO gone locally, nothing can ever consume this photo, so discard it (and its local file) instead of
// parking an invisible `failed` item. If the row still exists locally (a first photo, a create not visible
// yet, a delete elsewhere whose snapshot is pending) keep the existing terminal 404: failed + Retry/Discard.
// Strict `=== false`: an unknown answer (undefined/null) never discards.
function shouldDiscardOnFailure(status, productExistsLocally) {
    return status === 404 && productExistsLocally === false
}
