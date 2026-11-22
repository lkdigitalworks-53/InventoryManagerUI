.pragma library

// What a screen reader (TalkBack) says for one row of the product sheet (picker v2, slice S5e-1; test plan check 25
// asks for "name, ID, price, availability and quantity"). No Qt types: the words have a right and a wrong answer, so
// they live here, testable headless (Skill 83), and the sheet row only binds them to Accessible.name.
// Tests: functions/test/pickerSpeech.test.js, tests/tst_PickerSpeech.qml.
//
// The row passes the price already formatted (InventoryStore.formatCurrency lives in a store; this file knows none).
// Order: name, ID, price per unit, availability pill, "In this order", how many are picked, maximum, why it is off.

function _s(v) { return typeof v === "string" ? v.trim() : "" }

// A picked quantity that can be spoken: a whole number of at least one (a fraction below one floors to none).
function _picked(v) { return (typeof v === "number" && isFinite(v) && v > 0) ? Math.floor(v) : 0 }

// `r` is the row (the ListModel roles of the sheet row), `priceText` the price as shown ("Rs 120.00").
// Rules:
//  - A price is spoken only when the row's price is above zero. The model gives 0 for "no selling price" AND for a free
//    item, and 0.00 spoken for a product that has no price would be a false statement (KNOWN-ISSUES 43); the pill and
//    the reason say "No price" in words. A free item is not announced as free (KNOWN-ISSUES 94).
//  - A part that repeats an earlier one (the pill and the reason both say "Out of stock") is spoken once.
//  - The reason is spoken only when the row cannot be added.
//  - Junk (a missing row, text where a number belongs) never throws and never says "undefined" or "NaN".
function row(r, priceText) {
    var x = (r !== null && typeof r === "object") ? r : {}
    var parts = []
    var seen = {}
    function add(text) {
        var t = _s(text)
        if (t.length === 0) return
        var key = t.toLowerCase()
        if (seen[key] === true) return
        seen[key] = true
        parts.push(t)
    }
    var unit = _s(x.unit)
    var price = _s(priceText)
    add(x.name)
    add(x.productId)
    if (typeof x.price === "number" && isFinite(x.price) && x.price > 0 && price.length > 0)
        add(unit.length > 0 ? price + " per " + unit : price)
    add(x.pillLabel)
    add(x.inOrderLabel)
    var n = _picked(x.qty)
    if (n > 0) add(n + " selected")
    if (x.atMax === true) add("Maximum reached")
    if (x.canAdd !== true) add(x.reasonText)
    return parts.join(", ")
}
