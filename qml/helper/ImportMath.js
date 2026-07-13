.pragma library

// Pure helpers for the inventory CSV import. Extracted from InventoryStore so the
// operator-precedence-sensitive bits carry a headless test.

// Unique-SKU suffix for a "rename" conflict resolution. addedCount is the number
// of rows already added in this import (0-based), so the FIRST renamed row gets
// suffix -1. Parenthesised so "+" doesn't string-concatenate the counter before
// the increment: "ABC" + "-" + (0 + 1) === "ABC-1"  (NOT "ABC-01").
function renameSku(sku, addedCount) {
    return sku + "-" + (addedCount + 1)
}

// Parses a human-typed "Taxable" export/import cell into a boolean. Accepts
// "yes"/"true"/"1" case-insensitively (matches how the app writes the column
// on export: "Yes"/"No"). Blank or unrecognized values default to false —
// there is no "reject the row" behavior for this optional column.
function parseTaxableCell(raw) {
    var s = (raw === undefined || raw === null) ? "" : String(raw).trim().toLowerCase()
    return s === "yes" || s === "true" || s === "1"
}

// Parses the "Tax %" cell. When the row isn't taxable, the rate is always 0
// regardless of what's in the cell (matches AddProductDialog/EditProductDialog's
// own behavior: the Tax % input is disabled and zeroed when "Not taxable" is
// selected). When taxable, an unparseable value also falls back to 0 rather
// than rejecting the row — Taxable/Tax % are optional columns.
function parseTaxPercentCell(raw, taxable) {
    if (!taxable) return 0
    var n = parseFloat(raw)
    return isNaN(n) ? 0 : n
}

// Finds the line for `pid` in an order's `products` array, or null if the
// order doesn't have that product yet (or `products` is null/empty — a
// brand-new order being imported). Extracted so the search has its own
// headless test: a previous inline version wrote
//   for (...) { if (match) x = line; break }
// with the `break` outside the `if`, so the loop always stopped after
// checking index 0 — any match past the first line was silently missed.
function findOrderLineByProductId(products, pid) {
    if (!products) return null
    for (var i = 0; i < products.length; ++i) {
        if (products[i].productId === pid) return products[i]
    }
    return null
}

// Decides how an order-import row's requested quantity for one product
// should be handled against current on-hand stock.
//
// Mirrors the app's completion-time stock philosophy used everywhere else
// (NewOrderDialog/_tryCompleteOrder/completeImportedOrder): a pending or
// processing order doesn't reserve stock, so only a row whose imported
// Status is "completed" needs to fit in what's currently on hand.
//
// existingLineQty: quantity already booked for this product on the order
//   being updated (from the currently-persisted order), or null when this
//   is a brand-new order or a new product line being added to one.
// currentStock: idToProduct[pid].stock at import time.
// importedQty: the quantity requested by this import row.
// isCompleting: true when this row's Status column is "completed".
//
// Returns { qty, reject, issue }:
// - reject === true means the caller should drop this line entirely (only
//   possible when existingLineQty is null — a brand-new line that can't be
//   funded from stock has nothing safe to fall back to).
// - reject === false with issue set means the line is kept, but `qty` was
//   clamped back to what's already booked — an existing order's requested
//   increase couldn't be funded, so we don't touch that line at all rather
//   than risk selling stock that isn't there.
function checkOrderLineStock(existingLineQty, currentStock, importedQty, isCompleting) {
    if (!isCompleting) return { qty: importedQty, reject: false, issue: null }

    var hasExisting = existingLineQty !== null && existingLineQty !== undefined
    if (hasExisting) {
        var delta = importedQty - existingLineQty
        if (delta > 0 && currentStock - delta < 0)
            return { qty: existingLineQty, reject: false, issue: "insufficient stock" }
        return { qty: importedQty, reject: false, issue: null }
    }

    if (currentStock - importedQty < 0)
        return { qty: importedQty, reject: true, issue: "insufficient stock" }
    return { qty: importedQty, reject: false, issue: null }
}
