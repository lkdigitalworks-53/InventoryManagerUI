.pragma library

// Pure bookkeeping behind Gateway's "stuck write" indicator. Design:
// docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md
//
// Gateway owns one state object and calls these functions; nothing here touches
// QML, the outbox or the network, so it has a headless test
// (tests/tst_StuckWrites.qml).
//
// A queued write is "stuck" once it has failed THRESHOLD times with a
// server-side status. Offline (status 0), 401 (token refresh) and 409 (CAS
// conflict, dropped elsewhere) never count: they resolve on their own or the
// write leaves the outbox. Retry, backoff and dropping are not decided here.

// 5 server-side failures is about 3 minutes with OutboxStore's backoff
// ([2s, 8s, 30s, 2m, 10m]): long enough to ride out a deploy blip.
var THRESHOLD = 5

// state = { failures: { requestId: count }, stuck: { requestId: true } }
function newState() { return { failures: {}, stuck: {} } }

function isStuckStatus(status) {
    return status >= 400 && status !== 401 && status !== 409
}

// Records one failed send. Returns true only for the failure that tips the item
// over THRESHOLD, so the caller can react once per item.
function noteFailure(state, requestId, status) {
    if (!isStuckStatus(status)) return false
    var n = (state.failures[requestId] || 0) + 1
    state.failures[requestId] = n
    if (n !== THRESHOLD) return false
    state.stuck[requestId] = true
    return true
}

function stuckCount(state) { return Object.keys(state.stuck).length }

// Forgets every requestId that has left the outbox (sent, dropped, coalesced,
// signed out). liveIds = { requestId: true }. Returns the new stuck count.
function prune(state, liveIds) {
    var id
    for (id in state.stuck) if (!liveIds[id]) delete state.stuck[id]
    for (id in state.failures) if (!liveIds[id]) delete state.failures[id]
    return stuckCount(state)
}
