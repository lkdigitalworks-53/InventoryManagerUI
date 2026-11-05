.pragma library

// Pure geometry for one row of the order picker sheet (design 2026-11-03, slice S2). No Qt types, no
// singletons: everything with a right or wrong answer (touch targets, the stepper width, what is left for
// the pills) lives here so it is testable headless (Skill 83), and ProductPickerRow.qml only paints it.
// Tests: functions/test/pickerRowGeometry.test.js, tests/tst_PickerRowGeometry.qml.
//
// A row is a two-line card: line 1 = photo + text (name, id and SKU, category and price), line 2 = pills on
// the left and the quantity stepper on the right. Stacking the stepper under the text means the stepper
// never competes with the name for width, at any phone width and any system font size.
//
// All sizes are in "units": pass dp(1) as `unit`, or 1 for plain pixels.

var TOUCH_MIN = 48      // smallest touch target, in units (design: at least 48dp)
var GAP = 8             // space between two touch targets, in units
var PHOTO = 48          // photo or initial avatar edge
var PAD = 12            // card padding
var MIN_PILLS = 64      // narrowest the pill area may get before the pills wrap to their own line
var DIGIT = 10          // width of one digit of the quantity field at the base font size
var FIELD_PAD = 16      // horizontal padding inside the quantity field
var MAX_DIGITS = 6      // same as PickerDraft.MAX_DIGITS

function _size(v) { return (typeof v === "number" && isFinite(v) && v > 0) ? v : 0 }

// Digits of a whole quantity, 1..MAX_DIGITS (a quantity of 0 still shows one digit).
function digitsOf(maxQty) {
    var n = (typeof maxQty === "number" && isFinite(maxQty) && maxQty > 0) ? Math.floor(maxQty) : 0
    return Math.min(MAX_DIGITS, String(n).length)    // String(0) is "0": at least one digit without a guard
}

// width: the width of the row card in px; unit in px per unit; maxQty decides how wide the field must be
// (a six-digit stock needs room for six digits, a stock of 40 does not); fontScale >= 1 widens the field
// and heightens the row for large system fonts. Returns sizes in px; ok is false when the inputs are junk; fits is
// false when the stepper alone is wider than the card (a card narrower than about 212 units: no phone sheet is).
function layout(width, unit, maxQty, fontScale) {
    var w = _size(width)
    var u = _size(unit)
    var fs = Math.max(1, _size(fontScale) || 1)
    if (w <= 0 || u <= 0) {
        return { ok: false, fits: false, photo: 0, gap: 0, pad: 0, minus: 0, plus: 0, field: 0, fieldHeight: 0, stepper: 0,
                 pills: 0, pillsWrap: true, minHeight: 0 }
    }
    var gap = GAP * u
    var pad = PAD * u
    var target = TOUCH_MIN * u
    var field = Math.max(target, (digitsOf(maxQty) * DIGIT * fs + FIELD_PAD) * u)
    var stepper = target + gap + field + gap + target
    var inner = w - 2 * pad
    var pills = inner - stepper - gap
    var pillsWrap = pills < MIN_PILLS * u
    var photo = PHOTO * u
    // Line 1 holds at least the photo; line 2 holds the stepper (one touch target high). When the pills do not
    // fit beside the stepper they go on their own line above it, one more target-high line at most.
    var line1 = Math.max(photo, 3 * 16 * u * fs)
    var line2 = target + (pillsWrap ? gap + 24 * u * fs : 0)
    return {
        ok: true, fits: stepper <= inner, photo: photo, gap: gap, pad: pad,
        minus: target, plus: target, field: field, fieldHeight: target, stepper: stepper,
        pills: pillsWrap ? Math.max(0, inner) : pills,
        pillsWrap: pillsWrap,
        minHeight: pad + line1 + gap + line2 + pad
    }
}
