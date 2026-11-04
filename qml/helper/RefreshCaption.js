.pragma library

// L4b refresh row: what the row on a page says, whether it can be tapped, and what a tap or an unfinished
// refresh tells the user. Design: docs/superpowers/specs/2026-11-04-l4b-refresh-row-design.md (B-D3..B-D6).
//
// Pure: no QML, no stores, no clock reads (the caller passes `nowMs`), never throws. Plain English like
// FailureCause.js; the row and Main.qml only display what comes back.

var MIN_MS = 60000
var HOUR_MS = 3600000
var DAY_MS = 86400000

var OFFLINE_TOAST = "You are offline. Connect to the internet and try again"   // same sentence Main.qml already uses

function isNum(n) { return typeof n === "number" && isFinite(n) }

// "just now" | "N min ago" | "N h ago" | "N d ago" | "" (never synced or an unreadable time).
// A clock that went backwards (age < 0) reads "just now": never a time in the future.
function ageText(lastSyncMs, nowMs) {
    if (!isNum(lastSyncMs) || !isNum(nowMs) || lastSyncMs <= 0) return ""
    var age = nowMs - lastSyncMs
    if (age < MIN_MS) return "just now"
    if (age < HOUR_MS) return Math.floor(age / MIN_MS) + " min ago"
    if (age < DAY_MS) return Math.floor(age / HOUR_MS) + " h ago"
    return Math.floor(age / DAY_MS) + " d ago"
}

// snap = { online, state: "idle" | "waiting" | "running", lastSyncMs, nowMs }
// -> { text, busy, enabled }.   Offline beats everything, then running, then waiting, then idle.
// Anything unreadable is a disabled "Refresh": a row that cannot tell its state must not start a refresh.
function view(snap) {
    if (snap === null || typeof snap !== "object") return { text: "Refresh", busy: false, enabled: false }
    var age = ageText(snap.lastSyncMs, snap.nowMs)
    if (snap.online !== true) return { text: age.length > 0 ? "Offline · Updated " + age : "Offline", busy: false, enabled: false }
    if (snap.state === "running") return { text: "Refreshing…", busy: true, enabled: false }
    if (snap.state === "waiting") return { text: "Waiting to refresh…", busy: true, enabled: false }
    if (snap.state !== "idle") return { text: "Refresh", busy: false, enabled: false }
    return { text: age.length > 0 ? "Updated " + age : "Tap to refresh", busy: false, enabled: true }
}

// The name a screen reader speaks: the visible text, plus the action when the row can be tapped.
function accessibleName(v) {
    if (v === null || typeof v !== "object" || typeof v.text !== "string") return "Refresh"
    return v.enabled === true ? v.text + ". Tap to refresh." : v.text
}

// What a tap answers. d = { action: "run" | "wait" | "drop", reason } from DataModel.manualRefresh().
// "" means: say nothing (a run is its own feedback: the row flips to "Refreshing…").
function requestMessage(d) {
    if (d === null || typeof d !== "object") return ""
    if (d.action === "run") return ""
    if (d.action === "wait") {
        if (d.reason === "outbox" || d.reason === "in-flight" || d.reason === "photos")
            return "Sending your changes first. The refresh follows."
        if (d.reason === "lock" || d.reason === "edit-dialog")
            return "Finish editing first. The refresh follows."
        if (d.reason === "refreshing") return "Already refreshing."
        return "Busy for a moment. Refreshing as soon as it is free."
    }
    if (d.action === "drop") {
        if (d.reason === "offline") return OFFLINE_TOAST
        if (d.reason === "too-soon") return "Just refreshed. Try again in a few seconds."
        return "Can't refresh right now."
    }
    return ""
}

// A manual refresh that ended without the lists being updated. why: "gave-up" (waited its 2 minutes, or the
// phone went offline / the account was blocked while it waited) | "partial" (some lists were not updated).
function unfinishedMessage(why) {
    if (why === "gave-up") return "Couldn't refresh. Tap the refresh row to try again."
    if (why === "partial") return "Some lists could not be updated. Tap the refresh row to try again."
    return ""
}
