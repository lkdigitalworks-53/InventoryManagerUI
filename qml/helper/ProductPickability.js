.pragma library

// Pure, single place that decides whether a product can be added to an order (design 2026-11-03,
// section 4). The dialog injects its own lookups as plain functions, so the three stock formulas
// (new order, edit pending, edit completed) stay in their dialogs and this file stays headless-testable.
//
// Fail closed: a missing or throwing `availableFor`, `hasPendingMint` or `unsyncedState` never makes a row
// addable (row disabled, reason "unavailable"). Only the two guards that may not exist yet are optional:
// `hasQueuedRestock` (before R4) and `isDeleting` (no accessor exists today: the inventory store removes a deleted
// product synchronously, and a refetched one then reads as an unsynced edit, so this hook is redundant and S3
// should drop it unless a real accessor appears).
//
// Hook contract for the dialogs (S3/S4):
//   hasPendingMint(id)   the stock-batch store's hasPendingMint(id)
//   unsyncedState(id)    the inventory store's syncStateOf(id): "" | "pending" | "parked". Anything else but ""
//                        (an object, a typo) hides the row, so a wrong hook cannot open the guard.
//   availableFor(p)      stock the NEW lines may still use, never reduced by the draft (the draft is "N more"):
//                        new order max(0, stock - cartQty); edit pending max(0, stock - used);
//                        edit completed max(0, stock + originalQty - used), 0 if the product is gone.
// Guards that stay in the dialog because they are about the ORDER, not the row: the order lock, `busy`,
// the transaction store's hasMore refusal when editing a completed order, the booked-tax rule on re-add, and
// a valid selling price (this helper does not look at prices).

var REASON = {
    pendingMint: "pending-mint", queuedRestock: "queued-restock", unsyncedEdit: "unsynced-edit",
    deleting: "deleting", outOfStock: "out-of-stock", orderFull: "order-full", unavailable: "unavailable"
}

function _isProduct(p) {
    return !!p && typeof p === "object" && typeof p.productId === "string" && p.productId.length > 0
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
        // hasPendingMint and unsyncedState are called without a typeof guard on purpose: a missing one throws
        // a TypeError, and the catch below turns that into a disabled "unavailable" row (fail closed).
        if (c.hasPendingMint(id)) return _hide(row, REASON.pendingMint)
        if (_call(c.hasQueuedRestock, id, false)) return _hide(row, REASON.queuedRestock)
        var u = c.unsyncedState(id)
        if (u !== "" && u !== undefined && u !== null) return _hide(row, REASON.unsyncedEdit)
        if (_call(c.isDeleting, id, false)) return _hide(row, REASON.deleting)
        row.inOrder = _whole(_call(c.inOrderQty, id, 0))
        row.inDraft = _whole(_call(c.inDraft, id, 0))
        row.available = _whole(_call(c.availableFor, product, 0))
        if (row.available <= 0) return _disable(row, REASON.outOfStock)
        if (!!c.lineLimitReached && row.inOrder === 0 && row.inDraft === 0)
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
