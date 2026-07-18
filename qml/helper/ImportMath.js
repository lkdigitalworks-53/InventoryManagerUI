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
    if (!products || !pid) return null
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

// Cross-order-batch-aware wrapper around checkOrderLineStock. A single import
// file can contain several orders that all draw from the same product's
// stock — checkOrderLineStock alone has no way to know that, since it only
// ever sees one row's numbers. This wraps it: the accept/reject/clamp
// decision is made against remainingStock (a running per-product tally the
// caller decrements across every row in the batch, in the same order
// completeImportedOrder will actually process them), while crossOrder tells
// the caller *why* a failure happened — crossOrder: false means the product
// genuinely doesn't have enough stock (same message as a single-row check);
// crossOrder: true means this row would have fit against the product's real,
// undiminished stock, and only failed because earlier rows in this same
// import already claimed it — the caller should say so in the warning rather
// than imply the product itself is short.
//
// netNew is the actual new draw this row makes on the shared pool, for the
// caller to subtract from remainingStock: 0 for anything
// rejected/clamped-back/non-completing, the full qty for an accepted new
// line, and just the delta (which can be negative, freeing up the pool) for
// an existing line's change.
function checkOrderLineStockAcrossBatch(existingLineQty, fullStock, remainingStock, importedQty, isCompleting) {
    var hasExisting = existingLineQty !== null && existingLineQty !== undefined
    var remainingResult = checkOrderLineStock(existingLineQty, remainingStock, importedQty, isCompleting)

    var netNew
    if (!isCompleting) {
        netNew = 0
    } else if (!hasExisting) {
        netNew = remainingResult.reject ? 0 : remainingResult.qty
    } else {
        netNew = remainingResult.qty - existingLineQty
    }

    var crossOrder = false
    if (remainingResult.issue) {
        var fullResult = checkOrderLineStock(existingLineQty, fullStock, importedQty, isCompleting)
        crossOrder = !fullResult.reject && (!hasExisting || fullResult.qty === importedQty)
    }

    return {
        qty: remainingResult.qty,
        reject: remainingResult.reject,
        issue: remainingResult.issue,
        crossOrder: crossOrder,
        netNew: netNew
    }
}

// Scans `records` (each with a `.productId` and a `.row` for messaging) for
// rows sharing the same explicit, non-empty productId within ONE import
// file. Blank-productId rows (continuation lines) are never grouped with
// each other — only an explicit repeated id counts.
//
// For each group of 2+ rows sharing a productId:
//  - if every field in `compareFields` matches across the whole group, it's
//    a harmless duplicate (e.g. a copy-pasted row) — safe to silently keep
//    just the first and drop the rest.
//  - if any field differs (e.g. a different price), the rows disagree and
//    there's no safe way to pick a winner — reported as a conflict instead
//    of silently letting the last one clobber the others.
//
// Returns { dropIndexes: [index,...], conflicts: [{productId, rows:[row,...]}] }
// `dropIndexes` are indexes into `records` to remove (redundant duplicates).
// `conflicts` describes groups the caller should reject entirely as issues.
function findDuplicateProductRows(records, compareFields) {
    var byId = {}
    var order = []
    for (var i = 0; i < records.length; ++i) {
        var pid = records[i].productId
        if (!pid) continue
        if (!byId[pid]) { byId[pid] = []; order.push(pid) }
        byId[pid].push(i)
    }

    var dropIndexes = []
    var conflicts = []
    for (var g = 0; g < order.length; ++g) {
        var idxs = byId[order[g]]
        if (idxs.length < 2) continue

        var first = records[idxs[0]]
        var identical = true
        for (var j = 1; j < idxs.length; ++j) {
            var r = records[idxs[j]]
            for (var f = 0; f < compareFields.length; ++f) {
                if (first[compareFields[f]] !== r[compareFields[f]]) { identical = false; break }
            }
            if (!identical) break
        }

        if (identical) {
            for (var k = 1; k < idxs.length; ++k) dropIndexes.push(idxs[k])
        } else {
            var rows = []
            for (var m = 0; m < idxs.length; ++m) rows.push(records[idxs[m]].row)
            conflicts.push({ productId: order[g], rows: rows })
        }
    }
    return { dropIndexes: dropIndexes, conflicts: conflicts }
}

// Merges the line items for ONE imported order (multiple file rows can
// reference the same product). Enforces the same invariant
// NewOrderDialog/OrderDetailDialog's interactive "add product" flow already
// enforces (merge a re-added product into its existing line) — required
// because OrderAdjust.diffLines and every productId-keyed lookup in
// OrderDetailDialog explicitly assume order lines are unique per productId;
// violating that at import time doesn't fail loudly there, it silently
// corrupts totals/history the next time the order is edited.
//
// Lines with the same productId AND identical price/taxable/taxPercent/
// discountType/discountValue are merged by SUMMING quantity — mathematically
// equivalent to keeping them as separate lines, and removes the duplicate
// safely. Lines with the same productId but differing price/tax/discount
// can't be merged without guessing which is correct, so they're reported.
//
// Returns { lines: [...]|null, conflict: string|null }. When `conflict` is
// set, `lines` is null and the caller should reject the whole order (same
// as how an unresolved/unknown product already rejects the whole group).
function mergeOrderLines(rawLines) {
    var byPid = {}
    var order = []
    for (var i = 0; i < rawLines.length; ++i) {
        var ln = rawLines[i]
        var key = ln.productId
        if (!byPid[key]) {
            byPid[key] = { productId: ln.productId, name: ln.name, quantity: ln.quantity,
                           price: ln.price, taxable: ln.taxable, taxPercent: ln.taxPercent,
                           discountType: ln.discountType, discountValue: ln.discountValue }
            order.push(key)
            continue
        }
        var existing = byPid[key]
        var sameTerms = existing.price === ln.price
            && existing.taxable === ln.taxable
            && existing.taxPercent === ln.taxPercent
            && existing.discountType === ln.discountType
            && existing.discountValue === ln.discountValue
        if (!sameTerms) {
            return { lines: null, conflict: "Product " + key + " appears more than once in "
                + "this order with different price/tax/discount — resolve in the source file" }
        }
        existing.quantity = (existing.quantity || 0) + (ln.quantity || 0)
    }

    var merged = []
    for (var g = 0; g < order.length; ++g) merged.push(byPid[order[g]])
    return { lines: merged, conflict: null }
}
