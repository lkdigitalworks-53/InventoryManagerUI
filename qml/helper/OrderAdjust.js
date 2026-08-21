.pragma library

// Pure order-adjustment math for returns/exchanges/modify on a completed order.
// No QML/singleton deps so it's unit-testable. The orchestration (stock + ledger
// writes) lives in DataModel._tryAdjustOrder; this just computes deltas/plans.

// Per-line delta of the edited lines vs the order's current lines. Matches lines
// by productId. Emits one row per line that changed (qty up/down, removed, added,
// or price changed). Lines with no change are omitted.
//   → [{ productId, name, oldQty, newQty, returnedQty, addedQty, oldPrice, newPrice }]
// ASSUMPTION: order lines are unique per productId (NewOrderDialog merges a
// re-added product into its existing line), so keying by productId||name never
// drops a distinct line. A caller without that invariant would lose duplicates.
function diffLines(oldLines, newLines) {
    oldLines = oldLines || []
    newLines = newLines || []
    var byIdOld = {}
    for (var i = 0; i < oldLines.length; ++i) {
        var o = oldLines[i]
        byIdOld[o.productId || o.name] = o
    }
    var byIdNew = {}
    for (var j = 0; j < newLines.length; ++j) {
        var n = newLines[j]
        byIdNew[n.productId || n.name] = n
    }
    var out = []
    for (var k = 0; k < oldLines.length; ++k) {
        var ol = oldLines[k]
        var key = ol.productId || ol.name
        var nl = byIdNew[key]
        var oldQty = ol.quantity || 0
        var newQty = nl ? (nl.quantity || 0) : 0
        var oldPrice = ol.price || 0
        var newPrice = nl ? (nl.price || 0) : oldPrice
        var changed = (oldQty !== newQty) || (oldPrice !== newPrice)
        if (!changed) continue
        out.push({
            productId: ol.productId || "", name: ol.name,
            oldQty: oldQty, newQty: newQty,
            returnedQty: Math.max(0, oldQty - newQty),
            addedQty: Math.max(0, newQty - oldQty),
            oldPrice: oldPrice, newPrice: newPrice,
            taxable: !!ol.taxable,
            taxPercent: ol.taxPercent || 0
        })
    }
    for (var m = 0; m < newLines.length; ++m) {
        var n2 = newLines[m]
        var key2 = n2.productId || n2.name
        if (byIdOld[key2]) continue
        out.push({
            productId: n2.productId || "", name: n2.name,
            oldQty: 0, newQty: n2.quantity || 0,
            returnedQty: 0, addedQty: n2.quantity || 0,
            oldPrice: 0, newPrice: n2.price || 0,
            taxable: !!n2.taxable,
            taxPercent: n2.taxPercent || 0
        })
    }
    return out
}

// Compute which original batches a returned qty credits back to, unwinding the
// line's consumption[] most-recently-consumed first (reverse-FIFO). Returns
// [{ batchId, qty, unitCost, supplierId }]. Empty when there's no consumption
// lineage (pre-FIFO line) — caller falls back to topUpOldest.
function restorePlan(consumption, returnedQty) {
    if (!consumption || returnedQty <= 0) return []
    var plan = []
    var remaining = returnedQty
    for (var i = consumption.length - 1; i >= 0 && remaining > 0; --i) {
        var c = consumption[i]
        var avail = c.qtyConsumed || 0
        if (avail <= 0) continue
        var take = Math.min(avail, remaining)
        plan.push({
            batchId: c.batchId,
            qty: take,
            unitCost: c.unitCost || 0,
            supplierId: c.supplierId || ""
        })
        remaining -= take
    }
    return plan
}

// Given a line's consumption[] and how many units were returned, return the
// consumption that REMAINS on the surviving units. restorePlan unwinds the
// returned units newest-consumed-first; this keeps the rest (oldest-first),
// so the surviving units retain their true original batch/cost lineage. Used
// to re-stamp adjusted order lines so order-sourced Revenue-by-supplier keeps
// working. Returns [{ batchId, supplierId, qtyConsumed, unitCost }].
function survivingConsumption(consumption, returnedQty) {
    if (!consumption || consumption.length === 0) return []
    var toRemove = returnedQty > 0 ? returnedQty : 0
    // Walk newest-first removing returned units; whatever remains per entry stays.
    var remainingToRemove = toRemove
    var kept = []
    for (var i = consumption.length - 1; i >= 0; --i) {
        var c = consumption[i]
        var have = c.qtyConsumed || 0
        var removeHere = Math.min(have, remainingToRemove)
        var staying = have - removeHere
        remainingToRemove -= removeHere
        if (staying > 0) {
            kept.unshift({ batchId: c.batchId, supplierId: c.supplierId || "",
                           qtyConsumed: staying, unitCost: c.unitCost || 0 })
        }
    }
    return kept
}

// Rebuild a line array for OrdersStore.updateOrder(..., {products: ...}) so
// each surviving line keeps its ORIGINAL consumption[] (the FIFO batch
// lineage stamped at completion). Callers that rebuild lines from editable
// UI state (OrderDetailDialog._save()) never carry consumption in that
// state at all — it isn't a user-editable field — so any array they build
// and persist unconditionally would silently strip it off every line, even
// for a metadata-only edit (customer/status/channel) that never touched
// quantities. RealisedMath.byDimension/totals need a non-empty consumption[]
// on a later return event to attribute its revenue/profit; bucketsFor
// (Sold/Purchased) doesn't, since it only sums quantity — which is exactly
// why losing this field here made Revenue/Profit silently stop reflecting
// returns on any order touched again after completion, while every other
// analysis view stayed correct.
// Matches lines by productId (same invariant as diffLines). A line with no
// match in originalLines (a genuinely new line) gets consumption: [].
function reconcileConsumptionOnSave(newLines, originalLines) {
    newLines = newLines || []
    originalLines = originalLines || []
    var byIdOrig = {}
    for (var i = 0; i < originalLines.length; ++i) {
        var o = originalLines[i]
        byIdOrig[o.productId || o.name] = o
    }
    var out = []
    for (var j = 0; j < newLines.length; ++j) {
        var n = newLines[j]
        var key = n.productId || n.name
        var orig = byIdOrig[key]
        var merged = {}
        for (var k in n) merged[k] = n[k]
        merged.consumption = (orig && Array.isArray(orig.consumption)) ? orig.consumption.slice() : []
        out.push(merged)
    }
    return out
}
