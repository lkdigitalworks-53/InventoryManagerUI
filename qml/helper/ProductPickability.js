.pragma library

// Pure, single place that decides whether a product can be added to an order (design 2026-11-03,
// section 4). The dialog injects its own lookups as plain functions, so the three stock formulas
// (new order, edit pending, edit completed) stay in their dialogs and this file stays headless-testable.
//
// Fail closed: a missing or throwing `availableFor` never makes a row addable. A missing HIDE hook
// means "not hidden" (that guard does not exist yet, e.g. hasQueuedRestock before R4).

var REASON = {
    pendingMint: "pending-mint", queuedRestock: "queued-restock", unsyncedEdit: "unsynced-edit",
    deleting: "deleting", outOfStock: "out-of-stock", orderFull: "order-full", unavailable: "unavailable"
}

function _isProduct(p) {
    return !!p && typeof p === "object" && p.productId !== undefined && p.productId !== null
}
function _call(fn, arg, dflt) { return (typeof fn === "function") ? fn(arg) : dflt }
function _whole(n) { return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0 }

function _hide(row, reason) { row.visibility = "hidden"; row.reason = reason; row.maxQty = 0; return row }
function _disable(row, reason) { row.visibility = "disabled"; row.reason = reason; row.maxQty = 0; return row }

function classify(product, ctx) {
    var c = ctx || {}
    var row = { product: product, visibility: "enabled", reason: "", available: 0, maxQty: 0, inOrder: 0, inDraft: 0 }
    if (!_isProduct(product)) return _disable(row, REASON.unavailable)
    var id = product.productId
    try {
        if (_call(c.hasPendingMint, id, false)) return _hide(row, REASON.pendingMint)
        if (_call(c.hasQueuedRestock, id, false)) return _hide(row, REASON.queuedRestock)
        var u = _call(c.unsyncedState, id, "")
        if (u === "pending" || u === "parked") return _hide(row, REASON.unsyncedEdit)
        if (_call(c.isDeleting, id, false)) return _hide(row, REASON.deleting)
        row.inOrder = _whole(_call(c.inOrderQty, id, 0))
        row.inDraft = _whole(_call(c.inDraft, id, 0))
        row.available = _whole(_call(c.availableFor, product, 0))
        if (row.available <= 0) return _disable(row, REASON.outOfStock)
        if (c.lineLimitReached === true && row.inOrder === 0 && row.inDraft === 0)
            return _disable(row, REASON.orderFull)
        row.maxQty = row.available
    } catch (e) {
        return _disable(row, REASON.unavailable)
    }
    return row
}

// -> { rows: [classified, not hidden], hiddenCount }. opts.inStockOnly drops the out-of-stock rows only.
function summarize(products, ctx, opts) {
    var inStockOnly = !!(opts && opts.inStockOnly)
    var rows = []
    var hiddenCount = 0
    if (!Array.isArray(products)) return { rows: rows, hiddenCount: 0 }
    for (var i = 0; i < products.length; ++i) {
        var p = products[i]
        if (!_isProduct(p)) continue
        var r = classify(p, ctx)
        if (r.visibility === "hidden") { hiddenCount++; continue }
        if (inStockOnly && r.reason === REASON.outOfStock) continue
        rows.push(r)
    }
    return { rows: rows, hiddenCount: hiddenCount }
}
