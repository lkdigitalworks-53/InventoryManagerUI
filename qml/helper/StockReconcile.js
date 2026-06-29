.pragma library

// Pure decision for reconciling a manual product.stock edit into the FIFO batch
// ledger (StockBatchStore). A stock decrease must drain batches oldest-first
// (consumeFifo); an increase must add to the newest batch (topUpOldest), so the
// batch-derived Analysis reports (Value, Potential Profit, by-supplier) stay in
// sync with product.stock. No QML/singleton deps so it's unit-testable.
//
// Returns { action: "consume" | "topup" | "none", qty: <non-negative int> }.
// Non-numeric inputs (e.g. a field edit that didn't touch stock) → "none".
function delta(oldStock, newStock) {
    var a = Number(oldStock)
    var b = Number(newStock)
    if (isNaN(a) || isNaN(b)) return { action: "none", qty: 0 }
    var diff = b - a
    if (diff === 0) return { action: "none", qty: 0 }
    if (diff < 0) return { action: "consume", qty: -diff }
    return { action: "topup", qty: diff }
}
