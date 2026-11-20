.pragma library

// Pure sizes for the cart-line quantity stepper (product picker v2, slice S5c; KNOWN-ISSUES 24a, 28b). No Qt types: the
// numbers with a right or wrong answer live here so they are testable headless (Skill 83) and CartStepper.qml
// only paints them. Tests: functions/test/cartStepperGeometry.test.js, tests/tst_CartStepperGeometry.qml.
//
// A button's TOUCH area is TARGET units square, its painted frame only VISUAL units (so the look stays light and
// the 8 unit ring around it is still part of the target). All sizes are in "units": pass dp(1) as `unit`, or 1
// for plain pixels.

var TARGET = 48     // smallest touch target (the same 48 the sheet's rows use)
var VISUAL = 32     // painted frame edge, inside the target
var QTY_W = 28      // width of the quantity text between the two buttons (three digits at the base font)
var GAP = 4         // space between two controls in a row

function _size(v) { return (typeof v === "number" && isFinite(v) && v > 0) ? v : 0 }

// Sizes in px for one stepper: [-] qty [+] and, when `removable`, a third target for the remove button.
// A junk or non-positive unit gives all zeros (nothing to paint).
function layout(unit, removable) {
    var u = _size(unit)
    if (u <= 0) return { target: 0, visual: 0, qty: 0, gap: 0, inset: 0, width: 0, height: 0 }
    var target = TARGET * u
    var qty = QTY_W * u
    var gap = GAP * u
    return {
        target: target, visual: VISUAL * u, qty: qty, gap: gap,
        inset: (TARGET - VISUAL) / 2 * u,                       // room between the target edge and the frame
        width: rowWidth(u, removable, []),
        height: target
    }
}

// Width a line-controls row needs: `extras` are other fixed-width items in the same row (the price field), in
// units. Gaps are counted between every pair of items. Used to prove the row fits a narrow phone.
function rowWidth(unit, removable, extras) {
    var u = _size(unit)
    if (u <= 0) return 0
    var n = removable === true ? 3 : 2
    var items = n + 1                                           // the buttons and the quantity text
    var extra = 0
    var list = Array.isArray(extras) ? extras : []
    for (var i = 0; i < list.length; ++i) { extra += _size(list[i]) * u; items += _size(list[i]) > 0 ? 1 : 0 }
    return n * TARGET * u + QTY_W * u + extra + (items - 1) * GAP * u
}
