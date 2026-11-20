.pragma library

// Two small decisions of the product picker sheet that have a right or wrong answer (picker v2, slice S5c;
// KNOWN-ISSUES 8, 19a, 19b). Pure: no Qt types, no clock of its own (the caller passes `now`), so they are
// testable headless (Skill 83). Tests: functions/test/pickerGuards.test.js, tests/tst_PickerGuards.qml.

var BACK_REPEAT_MS = 400      // one physical Back press may reach the sheet twice (the sheet's own key handler and the app's global router)
var TOGGLE_REPEAT_MS = 250    // one accessibility activation may send both pressAction and toggleAction

// True when `now` is the second sight of the same gesture: a real earlier time, not in the future, closer than
// windowMs. A clock that went backwards, a first call (lastAt 0) or junk is never a repeat, so a gesture is
// never swallowed by a bad clock.
function isRepeat(lastAt, now, windowMs) {
    if (typeof lastAt !== "number" || typeof now !== "number" || typeof windowMs !== "number") return false
    if (!isFinite(lastAt) || !isFinite(now) || !isFinite(windowMs)) return false
    if (lastAt <= 0) return false   // a window of 0 or less needs no guard of its own: now - lastAt < windowMs is then never true
    return now >= lastAt && now - lastAt < windowMs
}

// What a Back press does for the sheet. state: { opened, busy, confirmOpen }.
//   "pass"            the sheet is not open: not ours, let the app go on.
//   "swallow"         busy (a commit is in flight): nothing, and it must NOT fall through to the dialog below.
//   "dismiss-confirm" the "Discard these items?" question is open: Back answers it with "keep editing".
//   "request-close"   otherwise: close, or ask the discard question when a draft exists (the sheet decides).
// Anything that is not exactly true counts as false, so junk state never closes a sheet by accident, except that
// a missing state is "pass" (nothing is open).
function backRoute(state) {
    var s = state || {}
    if (s.opened !== true) return "pass"
    if (s.busy === true) return "swallow"
    if (s.confirmOpen === true) return "dismiss-confirm"
    return "request-close"
}
