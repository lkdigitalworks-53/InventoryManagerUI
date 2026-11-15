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
