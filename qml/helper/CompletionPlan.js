.pragma library
.import "OperationKeys.js" as Keys

// Pure planner for the atomic order-completion operation. Design:
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// Turns "complete this order" into the ordered list of writes the server applies in
// ONE transaction: FIFO batch deltas (and a drift-repair batch when the batches
// cannot cover a line), one stock delta per line, the order update, and one sale
// transaction doc per line. It reads no store and sends nothing; DataModel gathers
// the inputs and hands the result to Gateway.recordOperation.

// Mirrors MAX_OPS in functions/lib/operationLogic.js and Gateway.maxOperationOps.
var MAX_OPS = 200

// Same label StockBatchStore.topUpOldest has always used for drift-repair batches.
var REPAIR_NOTE = "Adjustment (drift repair)"

// input = {
//   orderId, epoch, now (ISO string), clampStock (bool),
//   lines: [ { line, productId, name, qty } ]          line = the order's own line object
//   stockByProduct: { productId: number }              local product.stock
//   batchesByProduct: { productId: [ { batchId, supplierId, qtyRemaining, unitCost } ] }  oldest first
// }
// hooks = {
//   orderUpdate(lines) -> { before, after }            the order doc before/after completion
//   saleDocs(orderAfter) -> [ doc ]                    sale docs, each with a deterministic txId
// }
// Returns { ok: true, key, opType, ops, lines, orderAfter, predicted }
//      or { ok: false, reason: "out-of-stock" | "too-many-ops", errors: [string] }
function _has(obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key)
}

function build(input, hooks) {
    var errors = []
    var demand = {}
    var i

    // 1. Validate against local stock. Demand is summed per product, so two lines of
    // the same product cannot each pass on their own and then fail together. Only
    // positive quantities count: a stray negative line must not free up stock for another.
    for (i = 0; i < input.lines.length; ++i) {
        var v = input.lines[i]
        if (!_has(input.stockByProduct, v.productId)) {
            errors.push(v.name + ": not found in inventory")
            continue
        }
        demand[v.productId] = (demand[v.productId] || 0) + (v.qty > 0 ? v.qty : 0)
        if (!input.clampStock && demand[v.productId] > input.stockByProduct[v.productId])
            errors.push(v.name + ": need " + demand[v.productId] + ", only "
                        + input.stockByProduct[v.productId] + " in stock")
    }
    if (errors.length > 0) return { ok: false, reason: "out-of-stock", errors: errors }

    // 2. FIFO per line against a working copy of each batch's remaining quantity, so
    // a second line of the same product continues where the first stopped.
    var avail = {}
    var ops = []
    var lines = []
    var predicted = { batches: {}, stock: {}, created: [] }

    for (i = 0; i < input.lines.length; ++i) {
        var L = input.lines[i]
        var out = Object.assign({}, L.line)
        out.consumption = []

        if (L.qty > 0) {
            var remaining = L.qty
            var batches = input.batchesByProduct[L.productId] || []
            for (var b = 0; b < batches.length && remaining > 0; ++b) {
                var batch = batches[b]
                var have = _has(avail, batch.batchId) ? avail[batch.batchId] : (batch.qtyRemaining || 0)
                avail[batch.batchId] = have
                if (have <= 0) continue
                var take = Math.min(have, remaining)
                ops.push({ kind: "delta", entity: "stock_batch", entityId: batch.batchId,
                           deltas: { qtyRemaining: -take }, floors: { qtyRemaining: 0 }, clamps: {} })
                avail[batch.batchId] = have - take
                predicted.batches[batch.batchId] = have - take
                out.consumption.push({ batchId: batch.batchId, supplierId: batch.supplierId || "",
                                       qtyConsumed: take, unitCost: batch.unitCost || 0 })
                remaining -= take
            }

            if (remaining > 0) {
                // Batches cannot cover this line although product.stock says they
                // should (or the sale is being force-applied): book the gap as an
                // explicit, clearly labelled batch that is already fully consumed.
                var rid = Keys.repairBatchId(input.orderId, input.epoch, i)
                var repair = { batchId: rid, productId: L.productId, supplierId: "",
                               qtyReceived: remaining, qtyRemaining: 0, unitCost: 0,
                               receivedDate: input.now, poId: "", note: REPAIR_NOTE,
                               createdAt: input.now, updatedAt: input.now }
                ops.push({ kind: "mutation", entity: "stock_batch", entityId: rid,
                           action: "create", before: null, after: repair })
                predicted.created.push(repair)
                out.consumption.push({ batchId: rid, supplierId: "", qtyConsumed: remaining, unitCost: 0 })
            }

            ops.push({ kind: "delta", entity: "inventory", entityId: L.productId,
                       deltas: { stock: -L.qty },
                       floors: input.clampStock ? {} : { stock: 0 },
                       clamps: input.clampStock ? { stock: 0 } : {} })
            var left = (_has(predicted.stock, L.productId) ? predicted.stock[L.productId] : input.stockByProduct[L.productId]) - L.qty
            predicted.stock[L.productId] = input.clampStock ? Math.max(0, left) : left
        }
        lines.push(out)
    }

    // 3. The order itself, then its sale docs.
    var upd = hooks.orderUpdate(lines)
    ops.push({ kind: "mutation", entity: "order", entityId: input.orderId,
               action: "update", before: upd.before, after: upd.after })
    var sales = hooks.saleDocs(upd.after)
    for (i = 0; i < sales.length; ++i)
        ops.push({ kind: "mutation", entity: "transaction", entityId: sales[i].txId,
                   action: "create", before: null, after: sales[i] })

    if (ops.length > MAX_OPS)
        return { ok: false, reason: "too-many-ops",
                 errors: ["This order is too large to complete in one step (" + ops.length
                          + " changes, limit " + MAX_OPS + ")"] }

    return { ok: true, key: Keys.completeOrderKey(input.orderId, input.epoch), opType: "completeOrder",
             ops: ops, lines: lines, orderAfter: upd.after, predicted: predicted }
}
