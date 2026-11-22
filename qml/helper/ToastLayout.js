.pragma library

// The numbers behind the toast pill (picker v2, slice S5e-2, KNOWN-ISSUES 26). No Qt types: the pill used to be one
// unwrapped line of a fixed 40 dp, so a message of 80 to 134 characters (stores, imports, conflicts) was cut at both
// edges. The sums live here, testable headless (Skill 83); ToastHost only binds them. Every length comes IN already
// scaled (dp), so this file knows no density.
// Tests: functions/test/toastLayout.test.js, tests/tst_ToastLayout.qml.

// Most lines the pill shows. The longest toast in the app (134 characters) takes 4 lines on a 360 dp phone at the
// normal font and 5 at 1.3x; 6 leaves room for that and still stops a runaway server text from covering the screen.
// The text is cut with an ellipsis after this, never grown without bound.
var MAX_LINES = 6
// Reading time. 5000 ms was the fixed time for one short line. A message that now wraps needs longer to read: about
// 60 ms per character on top of 2000 ms, never under the old 5000 and never over 10000 (a toast must not stay on
// screen for long; it covers the lower part of a sheet's footer while it shows, KNOWN-ISSUES).
var DISMISS_MIN_MS = 5000
var DISMISS_MAX_MS = 10000
var DISMISS_BASE_MS = 2000
var DISMISS_PER_CHAR_MS = 60

function _n(v) { return (typeof v === "number" && isFinite(v)) ? v : 0 }
function _pos(v) { return _n(v) > 0 ? _n(v) : 0 }

// Pill width: the text on one line (naturalWidth, from an unwrapped copy of it), plus the side padding, plus 1 px
// of slack so the wrapped text below is never a hair narrower than its own single line (a sum like (w + pad) - pad can
// come out a rounding error under w, and the last word would drop to a second line for no reason). Never wider than
// maxWidth (the layer minus its margins), never negative.
function pillWidth(naturalWidth, maxWidth, pad) {
    var w = Math.ceil(_pos(naturalWidth)) + 1 + _pos(pad)
    return Math.min(w, _pos(maxWidth))
}

// The width the wrapped text gets inside that pill: what is left after the side padding, never negative.
function textWidth(pillW, pad) { return Math.max(0, _pos(pillW) - _pos(pad)) }

// Pill height: the wrapped text plus the vertical padding, never under the old single-line 40 dp.
function pillHeight(contentHeight, minHeight, pad) {
    return Math.max(_pos(minHeight), _pos(contentHeight) + _pos(pad))
}

// Corner radius. The theme token is 999 ("fully round") and Qt clamps a Rectangle radius to half its height, so the one-line
// 40 dp pill is a stadium (radius 20) but a 4-line pill of about 95 dp would get radius 47 and its curve would cut into the
// first and last line (white text, so the cut part is invisible on a light sheet). Cap the radius at half the ONE-LINE height:
// identical look for one line, a 20 dp corner that stays clear of the text for any taller pill (picker S5e-2 review sweep).
function pillRadius(token, minHeight) {
    return Math.min(_pos(token), _pos(minHeight) / 2)
}

// How long the toast stays: whole milliseconds, between DISMISS_MIN_MS and DISMISS_MAX_MS, growing with the length
// of the message. A non-string counts as empty.
function dismissMs(msg) {
    var len = (typeof msg === "string") ? msg.length : 0
    var ms = DISMISS_BASE_MS + DISMISS_PER_CHAR_MS * len
    return Math.min(DISMISS_MAX_MS, Math.max(DISMISS_MIN_MS, ms))
}

// Where the pill's top edge sits. rise 0 = parked just below the layer (hidden), rise 1 = resting with its BOTTOM edge
// at the same place it always had (clearance - minHeight above the layer's bottom, i.e. 70 dp for a 110 dp clearance
// and a 40 dp single line); a taller pill therefore grows UPWARD and never down into the tab bar. The slides animate
// `rise`, and this derives y, so a layer that changes height while a toast shows (soft keyboard, rotation) moves the
// pill with it instead of leaving it where the animation last wrote (KNOWN-ISSUES, "pill y is a binding").
function pillY(layerHeight, rise, height, clearance, minHeight) {
    var r = Math.min(1, Math.max(0, _n(rise)))
    var span = _pos(clearance) - _pos(minHeight) + _pos(height)
    return _n(layerHeight) - r * span
}
