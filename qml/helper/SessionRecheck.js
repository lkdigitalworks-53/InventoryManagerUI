.pragma library

// Silent session re-check (L3 slice A): when an AUTOMATIC check may start, and what its answer means for
// a session that is already open. Design: docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md
// (L3-D1c, L3-D2a).
//
// Pure: no QML, no stores, never throws. "Try again" is not throttled and does not use canStart: it
// starts a new load that supersedes anything in flight (AuthService._profileSeq).

var AUTO_SPACING_MS = 60000
// FirebaseService sets no request timeout, so a read can fail to answer at all. A check still "in flight"
// after this long is treated as lost and may be replaced (the sequence number discards its late answer).
var STALE_MS = 120000

function isNum(n) { return typeof n === "number" && isFinite(n) }

// inFlight: a check is already out. lastStartMs: when the last one started (anything but a finite number
// means never). nowMs: Date.now(). A trigger that is not allowed is dropped, not queued.
// An unreadable clock fails to "run" when nothing is out: a throttle that wedges would hide an access change
// for good, and the in-flight rule still stops a storm. A clock that went backwards runs too, and the new
// start time heals it. With a check out, an unreadable clock or a backwards one keeps waiting for it.
function canStart(inFlight, lastStartMs, nowMs) {
    var known = isNum(nowMs) && isNum(lastStartMs)
    var gap = known ? nowMs - lastStartMs : 0
    if (inFlight) return gap >= STALE_MS   // gap is 0 when the clock or the start is unknown: keep waiting
    if (!known) return true
    return gap < 0 || gap >= AUTO_SPACING_MS
}

// What a silent check's answer changes. `out` is AccessState.outcome(...). prev* is what this device holds
// before the answer is applied; wasBlocked is whether the access screen is up.
//   "block"   the answer refuses (removed, suspended, role, unverified): show the access screen
//   "unblock" the screen was up and the answer lets the member in: open like a fresh sign-in
//   "first"   this session has not synced the stores yet (synced is not exactly true): open like a fresh
//             sign-in. At cold start AuthStore already holds the saved tenant and role, so without this a
//             silent check would find "nothing changed" and no store would ever sync.
//   "tenant"  another workspace
//   "role"    another role (staff scope depends on it)
//   "none"    nothing changed: touch nothing, and no store resync
// A malformed answer is "none": a check that could not decide must not lock out a member who was verified.
function changeKind(prevTenantId, prevRole, wasBlocked, tenantId, out, synced) {
    if (out === null || typeof out !== "object") return "none"
    if (out.action === "block") return "block"
    if (out.action !== "enter" || typeof out.role !== "string" || out.role.length === 0) return "none"
    if (wasBlocked === true) return "unblock"
    if (synced !== true) return "first"
    if (tenantId !== prevTenantId) return "tenant"
    if (out.role !== prevRole) return "role"
    return "none"
}
