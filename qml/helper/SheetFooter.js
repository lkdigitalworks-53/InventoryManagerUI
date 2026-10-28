.pragma library

// Footer layout math for BottomSheet. Pure, so tests/tst_SheetFooter.qml runs it headlessly.
// BottomSheet.qml cannot be instantiated under qmltestrunner (Felgo); the wiring is pinned by
// .github/scripts/__tests__/signOutGuardWiring.test.js and checked on a device.
//
// Why it exists: PrimaryButton reports no implicit label width (its Text is anchored), so in a
// two-button footer next to a long secondary label it started at its padding only and ended up
// with half of the spare room: "Stay signed in" showed as "S...". The primary button now keeps a
// floor of its own label width; the secondary button gives way first.

// TextMetrics.advanceWidth and the Text's own implicitWidth can differ by a pixel (bold, hinting).
var SLACK = 2

// The primary button may keep at most this share of the footer row, so a huge system font or a
// long translation cannot push the secondary button (or the primary itself) off the sheet.
// Past the cap the primary label ellipsizes, as it did before.
var MAX_SHARE = 0.65

// Anything that is not a positive finite number counts as 0 (NaN, Infinity, strings, null).
function _size(v) {
    return (typeof v === "number" && isFinite(v) && v > 0) ? v : 0
}

// Width the primary button must keep so its label is not ellipsized: label + padding (+ slack),
// capped at MAX_SHARE of the row. 0 when there is no label or the row has no width yet.
// labelWidth = TextMetrics.advanceWidth, padding = leftPadding + rightPadding, rowWidth = footer width.
function primaryFloor(labelWidth, padding, rowWidth) {
    var label = _size(labelWidth)
    if (label === 0) return 0
    var need = Math.ceil(label) + _size(padding) + SLACK
    return Math.min(need, _size(rowWidth) * MAX_SHARE)
}
