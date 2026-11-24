.pragma library
.import "OperationKeys.js" as Keys
.import "RestockFlow.js" as RF

// Pure decisions around the add-product wiring (atomic-ops AP3a). Design:
// docs/superpowers/specs/2026-11-16-ap3a-add-product-wire-design.md. InventoryStore.addProduct stays thin and asks this
// file; every branch here runs in Node (functions/test/addProductFlow.test.js) and in tests/tst_AddProductFlow.qml.
// Nothing here reads a store, a clock or a random source. The supplier rules, the date format and the answer
// classification are RestockFlow's, so the two flows cannot drift.

// Design D-AP-7 (decided by Taher): adding a product needs a connection. The id is minted inside the server transaction, so
// offline there is no id to show or to attach a photo to.
var OFFLINE_TEXT = "Adding a product needs an internet connection. Connect and try again"
// The answer did not come in time (slow link): the operation stays queued and the product appears when the server answers.
var QUEUED_TEXT = "Product saved. It appears in your list when it syncs"
// The server committed the add but its answer could not be read (AddProductPlan.reflect refused it). Design D-AP3-4: do NOT
// offer a plain retry (a new tap is a new key, so a SECOND product); say so and re-read the lists instead.
var UNCONFIRMED_TEXT = "The server may have saved this product, but its answer could not be read. Check the product list before adding it again"
var DISCARDED_TEXT = "This product was discarded, so nothing was added"
// Review sweep 2 of PR 203: a picked photo is attached from the LIVE answer only (D-AP-8), so a queued or unconfirmed add (or a photo that could not be queued) must say the photo
// was not attached instead of dropping it silently.
var PHOTO_QUEUED_SUFFIX = ". Add its photo from the product page"
var PHOTO_UNCONFIRMED_SUFFIX = ". Its photo was not attached"
var PHOTO_APPLIED_SUFFIX = ". Its photo could not be added. Add it from the product page"

// The key made at the tap. "" only if the nonce is not a plain token (cannot happen with addProductNonce).
function newKey(nowMs, random) {
    return Keys.addProductKey(Keys.addProductNonce(nowMs, random))
}

// Builds AddProductPlan.build's input from what the tap knows, resolving the defaults the old addProduct had:
//   sellingPrice not given (undefined or null)   = price
//   unitCost not a number                        = price (0 when price is not a number either)
//   taxable                                      = !!taxable
//   taxPercent not a number                      = 0
//   minStock undefined or null                   = 0 (anything else non-numeric is the planner's to refuse)
// `party` may be "", a supplierId, an existing supplier name, a brand-new name, or { id } / { newName } (RestockFlow.supplierFor
// decides; a new supplier is created INSIDE the operation, never before it). `now` is ONE Date: the ISO timestamp and the local
// date both come from it (R4 O4), so a tap at 23:59:59.9 cannot get two different days.
// a = { key, name, sku, category, unit, size, description, price, sellingPrice, taxable, taxPercent, stock, minStock,
//       unitCost, party, suppliers, now }
// -> { ok: true, input } | { ok: false, reason }   (reason: bad-time, bad-supplier, supplier-too-long)
function makeInput(a) {
    var x = (a && typeof a === "object") ? a : {}
    if (Object.prototype.toString.call(x.now) !== "[object Date]" || isNaN(x.now.getTime())) return { ok: false, reason: "bad-time" }
    var sup = RF.supplierFor(x.party, x.suppliers)
    if (!sup.ok) return sup
    var price = x.price
    return { ok: true, input: {
        key: x.key, name: x.name, sku: x.sku, category: x.category, unit: x.unit, size: x.size, description: x.description,
        price: price,
        sellingPrice: (x.sellingPrice !== undefined && x.sellingPrice !== null) ? x.sellingPrice : price,
        taxable: !!x.taxable,
        taxPercent: (typeof x.taxPercent === "number" && !isNaN(x.taxPercent)) ? x.taxPercent : 0,
        stock: x.stock,
        minStock: (x.minStock === undefined || x.minStock === null) ? 0 : x.minStock,
        unitCost: (typeof x.unitCost === "number" && !isNaN(x.unitCost)) ? x.unitCost : (typeof price === "number" ? price : 0),
        supplier: sup.supplier,
        now: x.now.toISOString(), date: RF.localDate(x.now)
    } }
}

// Person-facing text for a refusal made BEFORE anything is queued (AddProductPlan.build's reasons, plus the supplier ones
// makeInput can return). too-large is worded by the caller (InventoryStore.tooLargeMessage, the one text every
// product write already shows). An app-side reason says so and asks for a report.
function refusalText(reason) {
    switch (reason) {
    case "bad-name": return "Enter a valid product name"
    case "bad-price": return "Cost and price must be numbers of zero or more"
    case "bad-tax": return "Tax % must be a number from 0 to 100"
    case "bad-stock": return "Stock and reorder level must be numbers of zero or more"
    case "bad-cost": return "Cost is too large or not a valid amount"
    case "bad-supplier":
    case "supplier-too-long": return RF.refusalText(reason)
    }
    return "Could not add the product (" + String(reason) + "). Please report this"
}

// How a Gateway.recordOperation callback result is treated: "applied" | "queued" | "rejected" (RestockFlow.classify).
function classify(res) {
    return RF.classify(res)
}

// A queued restock or add already creates a supplier with this name (RestockFlow.queuedNewSupplierClash): a second one would
// make a second supplier, because the local supplier list learns the first only when the server answers.
function supplierPendingText(newName) {
    return "A change that adds the supplier \"" + String(newName) + "\" is still waiting to sync. Add this product after it syncs, or leave the supplier out"
}

// The toast the add sheet shows once the callback answered ok. status: "applied" | "queued" | "unconfirmed" (anything else reads as
// applied, the pre-AP3a wording). photoSkipped: a photo was picked but could not be attached from this answer.
function doneText(status, photoSkipped) {
    var skipped = photoSkipped === true
    if (status === "queued") return QUEUED_TEXT + (skipped ? PHOTO_QUEUED_SUFFIX : "")
    if (status === "unconfirmed") return UNCONFIRMED_TEXT + (skipped ? PHOTO_UNCONFIRMED_SUFFIX : "")
    return "Product added" + (skipped ? PHOTO_APPLIED_SUFFIX : "")
}

// ---------------------------------------------------------------------------------------------------------------------
// AP3b (design 2026-11-20-ap3b-add-product-dialog-design.md): everything the Add Product sheet decides BEFORE the tap reaches
// the store. The dialog reads its fields into plain text and asks fromForm; nothing here reads a control, a store or a clock.
// ---------------------------------------------------------------------------------------------------------------------

// The app's own limits (no server rule exists for them). Text limits stop a paste that would make a list row or a report column
// unreadable; money and stock limits stop a typo that is finite but absurd (a 30-digit price passes the planner).
//   MAX_MONEY = RestockFlow.MAX_UNIT_COST (one source of truth for "a price is at most 1e9 rupees").
//   MAX_STOCK = the opening stock and the reorder level; whole numbers only (D-AP3b-2).
var MAX_NAME = 100
var MAX_SKU = 40
var MAX_SIZE = 40
var MAX_DESCRIPTION = 500
var MAX_MONEY = RF.MAX_UNIT_COST
var MAX_STOCK = 1000000

// Plain decimals only: digits with an optional fraction ("5." and ".5" are fine). parseFloat read "12abc" as 12, "1,5" as 1 and
// "1e3" as 1000, so a mistyped price was stored as a different price with no refusal. No sign: a negative is refused like junk.
var _MONEY = /^(\d+\.?\d*|\.\d+)$/
var _WHOLE = /^\d+$/

// What a typed amount is: { n, state } with state "ok" (n is a number in range), "large" (plain digits, above the limit: a typo the
// person can fix, so the message says so) or "invalid" (blank, junk, negative, an exponent, a comma). Review sweep 1 of PR 207:
// a too-large number used to be reported as "not a number", which sent the person looking for a typo that was not there.
function _moneyState(text) {
    var t = (typeof text === "string") ? text.trim() : ""
    if (!_MONEY.test(t)) return { n: NaN, state: "invalid" }
    var n = Number(t)
    return (n <= MAX_MONEY) ? { n: n, state: "ok" } : { n: NaN, state: "large" }   // Infinity (a 400-digit paste) is "large" too
}
function _wholeState(text) {
    var t = (typeof text === "string") ? text.trim() : ""
    if (!_WHOLE.test(t)) return { n: NaN, state: "invalid" }
    var n = Number(t)
    return (n <= MAX_STOCK) ? { n: n, state: "ok" } : { n: NaN, state: "large" }
}

// -> a number in 0..MAX_MONEY, or NaN (blank, junk, negative, an exponent, too large).
function moneyFromText(text) { return _moneyState(text).n }

// The same reading with its reason, for a caller that shows its own message (New Order's price field, NO3b): { n, state } as _moneyState.
function moneyState(text) { return _moneyState(text) }

// -> a whole number in 0..MAX_STOCK, or NaN. "2.5" is NaN, not 2: parseInt cut it silently (D-AP3b-2).
function wholeFromText(text) { return _wholeState(text).n }

// The markup mode's price: cost plus markup %, to a whole rupee (what the sheet has always shown and stored), but never below the
// cost. Review sweep 1 of PR 207: Math.round alone put 0% on a cost of 10.40 at 10, BELOW the cost, and Save then refused
// "Price < cost" for a markup the person had set to zero. Only results that were refused before change: cost 10.40 at 0% is now
// 10.40. Every other result is the same whole rupee as before.
function _markupPrice(markupPercent, cost) { return Math.max(Math.round(((markupPercent * cost) / 100) + cost), cost) }

// ONE reading of the cost and price fields, used by Save (fromForm) and by the pill (priceSummary), so they cannot disagree about
// what the person typed. markup === true: the price field holds a markup %.
// -> { cost, price, costError, priceError }   cost / price are NaN when their error is not "". An error is "" or the text to show.
// A price BELOW the cost is not an error here (the pill shows it as a negative markup; Save refuses it with "Price < cost").
function _resolvePrices(costText, priceText, markup) {
    var c = _moneyState(costText)
    var costError = c.state === "ok" ? "" : (c.state === "large" ? _tooBig("Cost", MAX_MONEY) : "Enter a valid cost")
    var v = _moneyState(priceText)
    var price = NaN
    var priceError = ""
    if (v.state === "invalid") priceError = "Enter a valid price"
    else if (v.state === "large") priceError = markup === true ? "Markup is too high. The selling price must be at most " + MAX_MONEY : _tooBig("Price", MAX_MONEY)
    else if (markup === true) {
        if (c.state !== "ok") priceError = "Enter a valid price"                  // no cost, no markup price
        else if (c.n <= 0) priceError = "A markup needs a cost above 0"
        else {
            price = _markupPrice(v.n, c.n)
            if (price > MAX_MONEY) { price = NaN; priceError = "Markup is too high. The selling price must be at most " + MAX_MONEY }
        }
    } else {
        price = v.n
        if (price <= 0) { price = NaN; priceError = "Enter a valid price" }
    }
    return { cost: c.n, price: price, costError: costError, priceError: priceError }
}

// The live pill under the price row, from the field TEXT, through the same reading Save uses, so the pill never shows a price that
// Save would then refuse as invalid or too large, or read differently. markup === true: the price field holds a markup %.
function priceSummary(costText, priceText, markup) {
    var r = _resolvePrices(costText, priceText, markup)
    if (isNaN(r.cost) || isNaN(r.price) || r.cost <= 0) return markup === true ? "Selling price \u2014" : "Markup \u2014"
    if (markup === true) return "Selling price \u20b9" + r.price + "   \u00b7   profit \u20b9" + (r.price - r.cost).toFixed(2)
    return "Markup " + Math.round(((r.price - r.cost) / r.cost) * 100) + "%   \u00b7   profit \u20b9" + (r.price - r.cost).toFixed(2)
}

function _trim(v) { return typeof v === "string" ? v.trim() : "" }
function _tooLong(label, n) { return label + " is too long. Use at most " + n + " characters" }
function _tooBig(label, n) { return label + " is too large. Use at most " + n }

// f = { name, sku, size, description, category, categoryIndex, unit, costText, priceText, markup, stockText, minStockText, taxable,
//       taxPercentText, pendingPartyText (the new-supplier field's text still sitting there), newSupplierName (what "Use" held),
//       partyIndex, supplierIds }
// -> { ok: true, args: { name, sku, category, description, price, unit, stock, minStock, sellingPrice, taxable, taxPercent, party,
//                        unitCost, size } }   (InventoryStore.addProduct's arguments, party as RestockFlow.partyFor says)
//  | { ok: false, errors: [text, ...] }       every problem at once, in field order; nothing is sent
// Whatever this accepts, AddProductPlan.build accepts (a test sends every accepted input through the real planner and server).
function fromForm(f) {
    var x = (f && typeof f === "object") ? f : {}
    var errs = []
    var name = _trim(x.name), sku = _trim(x.sku), size = _trim(x.size), description = _trim(x.description)

    if (name.length < 2) errs.push("Enter a valid product name")
    else if (name.length > MAX_NAME) errs.push(_tooLong("Product name", MAX_NAME))
    if (sku.length === 0) errs.push("SKU required (tap Gen)")
    else if (sku.length > MAX_SKU) errs.push(_tooLong("SKU", MAX_SKU))
    if (!(typeof x.categoryIndex === "number" && x.categoryIndex >= 0)) errs.push("Select a category")

    var rp = _resolvePrices(x.costText, x.priceText, x.markup === true)
    if (rp.costError !== "") errs.push(rp.costError)
    if (rp.priceError !== "") errs.push(rp.priceError)
    else if (!isNaN(rp.cost) && rp.price < rp.cost) errs.push("Price < cost")
    var cost = rp.cost, price = rp.price

    var st = _wholeState(x.stockText)
    var stock = st.n
    if (st.state === "large") errs.push(_tooBig("Opening stock", MAX_STOCK))
    else if (st.state === "invalid") errs.push("Enter the opening stock as a whole number (0 if none)")
    // Blank reorder level = 0 (the old behaviour); anything else must be a whole number, not silently turned into 0.
    var ms = _trim(x.minStockText) === "" ? { n: 0, state: "ok" } : _wholeState(x.minStockText)
    var minStock = ms.n
    if (ms.state === "large") errs.push(_tooBig("Reorder level", MAX_STOCK))
    else if (ms.state === "invalid") errs.push("Reorder level must be a whole number")

    var taxable = x.taxable === true
    var taxPercent = 0
    if (taxable) {
        taxPercent = moneyFromText(x.taxPercentText)
        if (isNaN(taxPercent) || taxPercent > 100) errs.push("Enter a valid tax % (0\u2013100)")
    }
    if (size.length > MAX_SIZE) errs.push(_tooLong("Size", MAX_SIZE))
    if (description.length > MAX_DESCRIPTION) errs.push(_tooLong("Description", MAX_DESCRIPTION))

    // A supplier name typed but never sent with "Use" is refused, not dropped (RestockFlow.unusedPartyText, PR #191 sweep).
    var unused = RF.unusedPartyText(x.pendingPartyText)
    if (unused !== "") errs.push(unused)
    if (errs.length > 0) return { ok: false, errors: errs }

    return { ok: true, args: {
        name: name, sku: sku, category: _trim(x.category), description: description, price: cost, unit: typeof x.unit === "string" ? x.unit : "",
        stock: stock, minStock: minStock, sellingPrice: price, taxable: taxable, taxPercent: taxPercent,
        party: RF.partyFor(x.newSupplierName, x.partyIndex, x.supplierIds), unitCost: cost, size: size
    } }
}
