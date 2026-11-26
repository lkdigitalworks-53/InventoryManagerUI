.pragma library
.import "OperationKeys.js" as Keys
.import "RestockFlow.js" as RF
.import "AddProductFlow.js" as AP

// Pure decisions around the create-order wiring (atomic-ops NO3a). Design:
// docs/superpowers/specs/2026-11-23-no3a-create-order-wire-design.md. OrdersStore.addOrder stays thin and asks this file;
// every branch here runs in Node (functions/test/orderFlow.test.js) and in tests/tst_OrderFlow.qml. Nothing here reads a store,
// a clock or a random source. The answer classification and the date format are RestockFlow's, so the flows cannot drift.

// Decided by Taher (NO1, Q-NO-3, option A): a new order needs a connection. The id is minted inside the server transaction, so
// offline there is no number to show and nothing to complete.
var OFFLINE_TEXT = "Placing an order needs an internet connection. Connect and try again"
// The answer did not come in time (slow link): the operation stays queued and the order appears when the server answers.
var QUEUED_TEXT = "Order saved. It appears in your list when it syncs"
// The server committed the order but its answer could not be read (OrderPlan.reflect refused it). Do NOT offer a plain retry (a
// new tap is a new key, so a SECOND order); say so and re-read the list instead (same rule as AP3a D-AP3-4).
var UNCONFIRMED_TEXT = "The server may have saved this order, but its answer could not be read. Check the order list before placing it again"
var DISCARDED_TEXT = "This order was discarded, so nothing was placed"
var TOO_LARGE_TEXT = "This order is too large to save. Remove some products and try again"

// The key made at the tap. "" only if the nonce is not a plain token (cannot happen with createOrderNonce).
function newKey(nowMs, random) {
    return Keys.createOrderKey(Keys.createOrderNonce(nowMs, random))
}

// The order's local day as "yyyy-MM-dd" (the format OrderPlan.build checks), or "" when `d` is not a real Date: the planner then
// refuses it as bad-time instead of this file inventing a day.
function localDay(d) {
    return (Object.prototype.toString.call(d) === "[object Date]" && !isNaN(d.getTime())) ? RF.localDate(d) : ""
}

// How a Gateway.recordOperation callback result is treated: "applied" | "queued" | "rejected" (RestockFlow.classify).
function classify(res) {
    return RF.classify(res)
}

// Person-facing text for a refusal made BEFORE anything is queued (OrderPlan.build's reasons). `index` is build's line index
// (-1 = the cart is empty); `names` are the cart's line names in order. Only the customer and the lines are things a person can
// fix; the rest says so and asks for a report (the dialog guarantees them, so seeing one is an app bug).
function refusalText(reason, index, names) {
    switch (reason) {
    case "bad-customer": return "Enter a valid customer name"
    case "too-large": return TOO_LARGE_TEXT
    case "bad-line":
        if (typeof index !== "number" || !(index >= 0)) return "Add at least one product"
        var n = Array.isArray(names) && typeof names[index] === "string" && names[index].length > 0 ? names[index] : ""
        return "Line " + (index + 1) + (n ? " (" + n + ")" : "")
            + ": the quantity must be a whole number of 1 or more, and the price, tax and discount must be valid. A price can be at most "
            + RF.MAX_UNIT_COST
    }
    return "Could not place the order (" + String(reason) + "). Please report this"
}

// The toast text after the callback answered ok. status: "applied" | "queued" | "unconfirmed". An applied order needs no toast
// (the sheet closes and the order is in the list), so it is "".
function doneText(status) {
    if (status === "queued") return QUEUED_TEXT
    if (status === "unconfirmed") return UNCONFIRMED_TEXT
    return ""
}

// ---------------------------------------------------------------------------------------------------------------------
// NO3b (design 2026-11-24-no3b-order-price-cap-design.md): the unit-price field of a cart line. _setLinePrice used to read the
// text with replace(/[^0-9.]/g, "") + parseFloat, so "-5" became 5, "1e5" became 15, "12abc" became 12, "1.2.3" became 1.2, and
// an over-limit or blank entry was dropped with no word (KNOWN-ISSUES 114). Now ONE reading (Add Product's plain decimal, with
// the app's one limit RestockFlow.MAX_UNIT_COST) and a reason the person can read.
// ---------------------------------------------------------------------------------------------------------------------

// What the field text means for a line whose price is `current`:
//   text      what the field holds when it is committed
//   current   the line's stored price (a number)
//   shown     the text the field displays when it is NOT being edited (InventoryStore.formatCurrency(current), e.g. "₹1,200")
// -> { kind: "unchanged" }                 the text is what the field shows anyway (focus lost, nothing typed, or the formatted
//                                          display read back): nothing to commit and nothing to say
//    { kind: "set", price }                a plain decimal in 0..MAX_UNIT_COST
//    { kind: "refused", reason }           reason "blank" | "invalid" | "large": keep the old price and show priceText(reason)
// The formatted display is never parsed: "₹1,200" is not a price the person typed (the field swaps it in on focus loss, and
// which of that swap and editingFinished runs first is Qt's business, not ours).
function priceEdit(text, current, shown) {
    var t = (typeof text === "string") ? text.trim() : ""
    if (t !== "" && (t === String(current) || (typeof shown === "string" && t === shown.trim()))) return { kind: "unchanged" }
    if (t === "") return { kind: "refused", reason: "blank" }
    var m = AP.moneyState(t)
    return m.state === "ok" ? { kind: "set", price: m.n } : { kind: "refused", reason: m.state }
}

// Person-facing text for a refused price. "" for a reason this file does not know (priceEdit gives only the three below).
function priceText(reason) {
    switch (reason) {
    case "blank": return "Enter the price of one unit, 0 or more"
    case "invalid": return "Price must be a plain number, like 120 or 99.5"
    case "large": return "Price is too large. Enter the price of ONE unit, up to " + RF.MAX_UNIT_COST
    }
    return ""
}

// The Place order refusal for a line whose typed price was refused: the cart still holds `shownPrice`.
function priceBlockedText(name, shownPrice) {
    return (name ? name : "An item") + ": the new price was not accepted, so it is still " + shownPrice
        + ". Tap its price field to keep or change it"
}

// The refusals by product id. -> a NEW object (so QML sees the change) with `message` for `id`, or without `id` when it is "".
function withPriceError(errors, id, message) {
    var out = Object.assign({}, errors)
    if (message) out[id] = message
    else delete out[id]
    return out
}

// Only the refusals of lines that are still in the cart.
function prunePriceErrors(errors, lines) {
    var out = {}
    var list = Array.isArray(lines) ? lines : []
    for (var i = 0; i < list.length; ++i) {
        var id = list[i] ? list[i].productId : undefined
        if (errors && Object.prototype.hasOwnProperty.call(errors, id)) out[id] = errors[id]
    }
    return out
}

// ---------------------------------------------------------------------------------------------------------------------
// NO3c (design 2026-11-26-no3c-edit-order-money-fields-design.md): the discount fields of both order sheets had the old lenient
// reading ("-5" stored 5, "1e2" stored 12), and a flat 500 switched to "%" was clamped by the totals to 100%: a free line with
// no word (KNOWN-ISSUES 151, 154, 158). The error maps above (withPriceError, prunePriceErrors) are field-agnostic: New Order
// keeps a second one for discounts.
// ---------------------------------------------------------------------------------------------------------------------

// True when `i` is a row of a list of `n` rows (a row can vanish while its field commits).
function isRow(i, n) {
    return typeof i === "number" && i >= 0 && i < n && Math.floor(i) === i
}

// True when a discount of `value` is whole on a line worth `gross` (price x quantity): the totals would not clamp it.
// 0 always fits. The tolerance is for float noise (0.7 x 3 is 2.0999999999999996, and 2.1 off it is not "too much").
function discountFits(value, type, gross) {
    if (typeof value !== "number" || !(value >= 0)) return false
    if (value === 0) return true
    if (type === "percent") return value <= 100
    return typeof gross === "number" && isFinite(gross) && value <= gross + 1e-6
}

function _discountFromText(t, type, gross) {
    if (t === "") return { kind: "set", value: 0 }   // a blank discount is no discount
    var m = AP.moneyState(t)
    if (m.state === "invalid") return { kind: "refused", reason: "invalid" }
    if (m.state === "ok" && discountFits(m.n, type, gross)) return { kind: "set", value: m.n }
    return { kind: "refused", reason: type === "percent" ? "percent" : "amount" }
}

// What the discount field text means for a line whose discount is `current` (the field shows String(current || 0)):
// -> { kind: "unchanged" } | { kind: "set", value } | { kind: "refused", reason: "invalid" | "percent" | "amount" }
function discountEdit(text, current, type, gross) {
    var t = (typeof text === "string") ? text.trim() : ""
    if (t !== "" && t === String(current || 0)) return { kind: "unchanged" }
    return _discountFromText(t, type, gross)
}

// Person-facing text for a refused discount; `shownGross` is the formatted line amount. "" for an unknown reason.
function discountText(reason, shownGross) {
    switch (reason) {
    case "invalid": return "Discount must be a plain number, like 50 or 7.5"
    case "percent": return "A percentage discount can be at most 100"
    case "amount": return "The discount cannot be more than the line amount, " + shownGross
    }
    return ""
}

// The ₹ / % pill. `typed` is the text of this row's discount field when the person is still in it, else null. The number is read
// under the NEW type; if it does not fit, the discount becomes 0 and the row says why. -> { value, message }.
function discountSwitch(typed, current, type, gross, shownGross) {
    var t = (typeof typed === "string") ? typed.trim() : String(current || 0)
    var r = _discountFromText(t, type, gross)
    if (r.kind === "set") return { value: r.value, message: "" }
    return { value: 0, message: discountText(r.reason, shownGross) + ". It is now 0" }
}

function _sameLine(a, b) {
    return !!b && String(a.productId || a.name) === String(b.productId || b.name) && a.price === b.price
        && a.quantity === b.quantity && (a.discountType === "percent") === (b.discountType === "percent")
        && (a.discountValue || 0) === (b.discountValue || 0)
}

// Why Save / Place order must not send this line yet (empty = fine). `line`: { productId, name, price, quantity, discountType,
// discountValue }. `errors`: { price, discount }, the unread refusals of its fields. `money`: number -> formatted text.
// `saved` (Edit Order): the lines as stored; a line identical to one of them is not checked for fit, so an old order with an odd
// discount can still be saved for its customer name or status.
function lineProblems(line, errors, money, saved) {
    var out = []
    var name = line.name ? line.name : "An item"
    var percent = line.discountType === "percent"
    var value = line.discountValue || 0
    var gross = line.price * line.quantity
    if (errors && errors.price) out.push(priceBlockedText(line.name, money(line.price)))
    if (errors && errors.discount) {
        out.push(name + ": check the discount, it is " + (percent ? value + "%" : money(value))
            + ". Tap its discount field to keep or change it")
    } else if (!discountFits(value, line.discountType, gross)
               && !(Array.isArray(saved) && saved.some(function(s) { return _sameLine(line, s) }))) {
        out.push(name + ": the discount must be from 0 to " + (percent ? "100%" : "the line amount, " + money(gross))
            + ". Change the discount")
    }
    return out
}
