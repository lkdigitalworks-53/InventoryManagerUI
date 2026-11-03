.pragma library

// L4a non-blanking data refresh: WHEN one may start, WHEN its result may replace the lists on screen, and how
// long a wish to refresh stays alive. Design: docs/superpowers/specs/2026-11-02-l4a-resume-refresh-design.md
// (decisions L4-D1..D8).
//
// Pure: no QML, no stores, never throws. DataModel.qml reads the live state into a `snap` object and asks.
//
//   snap = { online, sessionOpen, accessBlock, checking, outboxPending, gatewayInFlight, lockHeld,
//            photoPending, storeBusy, refreshing }
//
// Why the gate is strict: a refresh replaces whole lists with what the server holds. A write that is
// queued, in flight, or acknowledged DURING the fetch makes the server copy older or newer than this device
// in a way the swap cannot tell, so any outbox activity means "do not swap, keep what is on screen" (the
// next trigger tries again). Dropping a fetched copy costs reads, never data.

var STALE_MS = 300000       // a resume/reconnect refresh only runs when the lists are at least this old (cost: every refresh re-reads every document of six collections)
var SPACING_MS = 15000      // no two refreshes START closer than this, whatever the trigger (stops a pull-to-refresh storm)
var WANT_TTL_MS = 120000    // a refresh that had to wait (writes queued, check running) is forgotten after this
var POLL_MS = 5000          // how often a waiting refresh looks at the gate again
var RUN_TTL_MS = 180000     // FirebaseService sets no request timeout: a run that has not answered after this long is treated as lost and cancelled

var TRIGGERS = ["resume", "reconnect", "manual"]

function isNum(n) { return typeof n === "number" && isFinite(n) }
function isTrigger(t) { return TRIGGERS.indexOf(t) !== -1 }

// Hard blockers: nothing to wait for, the trigger is dropped. A block ends with a full sign-in style load
// (AuthService), which syncs the stores itself.
function hardBlock(snap) {
    if (snap === null || typeof snap !== "object") return "no-state"
    if (snap.online !== true) return "offline"
    if (snap.sessionOpen !== true) return "no-session"
    if (typeof snap.accessBlock !== "string" || snap.accessBlock.length > 0) return "blocked"
    return ""
}

// Soft blockers: something is in progress that will pass; the trigger waits.
function softBlock(snap) {
    if (snap.checking !== false) return "checking"           // the silent access check decides first
    if (snap.refreshing !== false) return "refreshing"
    if (snap.storeBusy !== false) return "store-loading"
    if (!(snap.outboxPending === 0)) return "outbox"          // anything queued, in flight or parked
    if (!(snap.gatewayInFlight === 0)) return "in-flight"
    if (snap.lockHeld !== false) return "lock"                // someone is mid-edit on a locked record
    if (!(snap.photoPending === 0)) return "photos"
    return ""
}

// -> { action: "run" | "wait" | "drop", reason }
//   trigger    "resume" | "reconnect" | "manual" (anything else is dropped)
//   lastSyncMs when the lists were last known complete and current (0 / unknown = never)
//   lastStartMs when the last refresh started (0 / unknown = never)
// A clock that is unreadable or went backwards never wedges the throttle: it runs, and the new start heals it.
function decide(trigger, snap, nowMs, lastSyncMs, lastStartMs) {
    if (!isTrigger(trigger)) return { action: "drop", reason: "bad-trigger" }
    var hard = hardBlock(snap)
    if (hard.length > 0) return { action: "drop", reason: hard }
    if (trigger !== "manual" && isNum(nowMs) && isNum(lastSyncMs) && lastSyncMs > 0) {
        var age = nowMs - lastSyncMs
        if (age >= 0 && age < STALE_MS) return { action: "drop", reason: "fresh" }
    }
    if (isNum(nowMs) && isNum(lastStartMs) && lastStartMs > 0) {
        var gap = nowMs - lastStartMs
        if (gap >= 0 && gap < SPACING_MS) return { action: "drop", reason: "too-soon" }
    }
    var soft = softBlock(snap)
    if (soft.length > 0) return { action: "wait", reason: soft }
    return { action: "run", reason: "" }
}

// A waiting refresh looks again every POLL_MS and gives up after WANT_TTL_MS (an unreadable clock gives up at
// once: waiting forever on a broken clock is the worse failure).
function wantExpired(wantSinceMs, nowMs) {
    if (!isNum(wantSinceMs) || !isNum(nowMs)) return true
    var age = nowMs - wantSinceMs
    return age < 0 || age >= WANT_TTL_MS
}

// May the fetched copy REPLACE the live list? Same gate as the start, plus: the outbox revision must be the
// one seen at the start (any enqueue, ack or failure in between means the server copy may be older or newer
// than what this device did). Unknown revisions never swap.
function swapOk(startRevision, snap) {
    if (hardBlock(snap).length > 0) return false
    if (!isNum(startRevision) || !isNum(snap.outboxRevision) || snap.outboxRevision !== startRevision) return false
    if (!(snap.outboxPending === 0) || !(snap.gatewayInFlight === 0)) return false
    if (snap.lockHeld !== false || !(snap.photoPending === 0)) return false
    return true
}

// The refresh counts as "lists are current" (resets the staleness clock) only when EVERY store committed.
// results: array of "committed" | "discarded" | "failed" | "superseded", one per store asked.
function allCommitted(results) {
    if (!Array.isArray(results) || results.length === 0) return false
    for (var i = 0; i < results.length; ++i) if (results[i] !== "committed") return false
    return true
}

// A run that never answered (a hung read) would keep every later refresh waiting on "refreshing" for good. After
// RUN_TTL_MS it counts as lost; an unreadable or backwards clock counts as lost too (cancelling costs one re-run).
function runLost(startMs, nowMs) {
    if (!isNum(startMs) || !isNum(nowMs)) return true
    var age = nowMs - startMs
    return age < 0 || age >= RUN_TTL_MS
}
