.pragma library

// Pure bookkeeping behind Gateway's "stuck write" indicator. Design:
// docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md
//
// Gateway owns one state object and calls these functions; nothing here touches
// QML, the outbox or the network, so it has a headless test
// (tests/tst_StuckWrites.qml).
//
// A queued write is "stuck" once it has failed THRESHOLD times with a
// server-side status, or timed out while the device is online. Offline (status 0),
// 401 (token refresh) and 409 (CAS conflict, dropped elsewhere) never count: they
// resolve on their own or the write leaves the outbox. Retry, backoff and dropping
// are not decided here.
//
// P5 (docs/superpowers/specs/2026-09-29-gateway-park-retry-discard-plan.md): the
// state is MIRRORED onto each outbox item (metaOf -> OutboxStore.setStuckMeta) and
// rebuilt from the items on launch (hydrate), so a relaunch does not forget a stuck
// write. The outbox item is the source of truth across launches; this object is the
// in-memory working copy.

// 5 server-side failures is about 3 minutes with OutboxStore's backoff
// ([2s, 8s, 30s, 2m, 10m]): long enough to ride out a deploy blip.
var THRESHOLD = 5

// state = { failures: { requestId: count }, stuck: { requestId: true },
//           terminal: { requestId: true } }
// `terminal` = the server's LATEST answer for that write was "rejected" (see
// REJECTED); it only labels the write, it never changes retry or dropping.
function newState() { return { failures: {}, stuck: {}, terminal: {} } }

// functions/lib/writeError.js: the server answers HTTP 500 either way, so the
// body's `error` string is the only signal. Everything else (write-unavailable,
// write-failed, an unparseable body) is treated as "may still succeed".
var REJECTED = "write-rejected"

// `body` is the raw responseText or an already-parsed object. Never throws.
function errorCodeOf(body) {
    var b = body
    if (typeof b === "string") {
        try { b = JSON.parse(b) } catch (e) { return "" }
    }
    return (b && typeof b.error === "string") ? b.error : ""
}

// A request that timed out (Gateway aborted it) is reported as TIMEOUT, not as
// status 0. It counts only while the device believes it is online: a hang with
// a working network is a stuck write, a timeout while offline is expected.
var TIMEOUT = "timeout"

function isStuckStatus(status, online) {
    if (status === TIMEOUT) return online === true
    return status >= 400 && status !== 401 && status !== 409
}

// Records one failed send. Returns true only for the failure that tips the item
// over THRESHOLD, so the caller can react once per item.
function noteFailure(state, requestId, status, online, errorCode) {
    if (!isStuckStatus(status, online)) return false
    if (errorCode === REJECTED) state.terminal[requestId] = true
    else delete state.terminal[requestId]
    var n = (state.failures[requestId] || 0) + 1
    state.failures[requestId] = n
    if (n !== THRESHOLD) return false
    state.stuck[requestId] = true
    return true
}

function stuckCount(state) { return Object.keys(state.stuck).length }

function isStuck(state, requestId) { return state.stuck[requestId] === true }

// The stuck writes still in the outbox, in queue order, for the stuck-writes
// dialog. `items` is OutboxStore.items. A stuck id no longer queued (sent or
// dropped since the last prune) is skipped, so a stale dialog never shows a
// ghost row. -> [{ requestId, terminal, item }]
function rows(state, items) {
    var out = []
    var list = Array.isArray(items) ? items : []
    for (var i = 0; i < list.length; ++i) {
        var it = list[i]
        if (!it || !state.stuck[it.requestId]) continue
        out.push({
            requestId: it.requestId,
            terminal: state.terminal[it.requestId] === true,
            item: it
        })
    }
    return out
}

// Stuck writes the server has said it rejects. Always <= stuckCount.
function terminalCount(state) {
    var n = 0
    for (var id in state.stuck) if (state.terminal[id]) n++
    return n
}

// Forgets every requestId that has left the outbox (sent, dropped, coalesced,
// signed out). liveIds = { requestId: true }. Returns the new stuck count.
function prune(state, liveIds) {
    var id
    for (id in state.stuck) if (!liveIds[id]) delete state.stuck[id]
    for (id in state.failures) if (!liveIds[id]) delete state.failures[id]
    for (id in state.terminal) if (!liveIds[id]) delete state.terminal[id]
    return stuckCount(state)
}

// Persisted shape of one write's stuck state, for OutboxStore.setStuckMeta:
// { failures: n, stuck: bool, terminal: bool }. A write with no state is all zero/false.
function metaOf(state, requestId) {
    return {
        failures: state.failures[requestId] || 0,
        stuck: state.stuck[requestId] === true,
        terminal: state.terminal[requestId] === true
    }
}

// Rebuilds the state from persisted outbox items (relaunch). Never throws: a
// malformed item is skipped, a malformed field is ignored. Repairs two impossible
// combinations so a bad save can neither hide a stuck write nor toast twice:
// failures >= THRESHOLD means stuck, and stuck means failures >= THRESHOLD.
function hydrate(items) {
    var state = newState()
    var list = Array.isArray(items) ? items : []
    for (var i = 0; i < list.length; ++i) {
        var it = list[i]
        if (!it || !it.requestId) continue
        var id = it.requestId
        var n = (typeof it.failures === "number" && it.failures > 0) ? Math.floor(it.failures) : 0
        var isStuck = it.stuck === true || n >= THRESHOLD
        if (isStuck) {
            state.stuck[id] = true
            if (n < THRESHOLD) n = THRESHOLD
        }
        if (n > 0) state.failures[id] = n
        if (it.terminal === true) state.terminal[id] = true
    }
    return state
}
