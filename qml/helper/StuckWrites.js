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
// REJECTED). S2b: a stuck write whose latest answer is "rejected" is PARKED
// (see isParkedItem): no auto-retry until the user taps Retry. Parked is derived
// (stuck && terminal), not a stored flag, so it cannot drift from its inputs.
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

// S2b park rule (Taher, Q-S2b-1 A): parked = stuck AND the server's latest answer
// was "rejected". True for a persisted outbox item too: same stuck repair as
// hydrate (failures >= THRESHOLD means stuck), so a bad save cannot unpark it.
function isParkedItem(it) {
    if (!it || it.terminal !== true) return false
    return it.stuck === true || (typeof it.failures === "number" && it.failures >= THRESHOLD)
}

function isParked(state, requestId) {
    return state.stuck[requestId] === true && state.terminal[requestId] === true
}

// S3: the distinct entity names one queued write touches (single, batch and delta
// items have one; an operation item has one per op). Used by Discard to know which
// stores to re-read. Never throws; malformed or unnamed parts are skipped.
function entitiesOf(item) {
    var out = []
    var seen = {}
    function add(e) {
        if (typeof e !== "string" || e.length === 0 || seen[e] === true) return
        seen[e] = true
        out.push(e)
    }
    if (!item || typeof item !== "object") return out
    if (Array.isArray(item.ops)) {
        for (var i = 0; i < item.ops.length; ++i) add(item.ops[i] && item.ops[i].entity)
    } else {
        add(item.entity)
    }
    return out
}

// Retry on a parked write forgets "rejected" so it is due and sendable once. If
// the server rejects it again noteFailure sets terminal and it re-parks after that
// ONE attempt; a transient answer leaves it stuck and auto-retrying.
function clearTerminal(state, requestId) { delete state.terminal[requestId] }

// Stuck writes the server has said it rejects (= the parked ones). Always <= stuckCount.
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
