.pragma library
.import "OperationKeys.js" as Keys
.import "StockMovements.js" as SM
.import "DocLimits.js" as DocLimits

// Pure planner for the atomic restock operation (atomic-ops R3). Designs:
// docs/superpowers/specs/2026-10-16-restock-atomic-operation-design.md (section 4) and
// docs/superpowers/specs/2026-11-01-r3-restock-plan-design.md (this slice).
//
// build() turns "restock this product" into the ordered op list the server applies in ONE
// transaction (functions/lib/operationLogic.js): the server mints the supplier id (only for a new
// supplier name) and the batch id inside the transaction, so a rejected or repeated restock burns
// and duplicates nothing. reflect() reads the server's results back into plain docs.
//
// Nothing here reads a store or sends anything. Dormant until R4 wires InventoryStore.restock to it.

// Bind names and the tokens the server replaces (design M6: `entityId` strictly, `after` strings
// leniently). Both mints come first, so every token is declared before any op that uses it.
var SUP = "sup"
var BAT = "batch"
var TOK_SUP = "{{sup}}"
var TOK_BAT = "{{batch}}"

var _DATE = /^\d{4}-\d{2}-\d{2}$/

function _refuse(reason) { return { ok: false, reason: reason } }
function _isNum(n) { return typeof n === "number" && isFinite(n) }
function _text(v) { return typeof v === "string" ? v : "" }
function _hasToken(s) { return typeof s === "string" && (s.indexOf(TOK_SUP) >= 0 || s.indexOf(TOK_BAT) >= 0) }

function _create(entity, entityId, after) {
    return { kind: "mutation", entity: entity, entityId: entityId, action: "create", before: null, after: after }
}

// input = {
//   key            from Keys.restockKey(...), made at the tap
//   productId, productName, category
//   qty            finite number > 0
//   unitCost       finite number >= 0 (the caller resolves the default first)
//   reason         free text, trimmed here
//   now            ISO timestamp, date "yyyy-MM-dd" (the caller formats the local date)
//   supplier       null (no supplier) | { id } (a known supplier) | { newName } (create one)
// }
// Returns { ok: true, key, opType: "restock", ops, at }  (`at` = index of each op, -1 when absent)
//      or { ok: false, reason } with reason one of: bad-key, bad-product, bad-quantity, bad-cost,
//         bad-supplier, bad-time, reserved-text, too-large. Nothing is built for a refused input.
function build(input) {
    var inp = (input && typeof input === "object") ? input : {}
    if (!Keys.isRestockKey(inp.key)) return _refuse("bad-key")
    if (typeof inp.productId !== "string" || inp.productId.length === 0) return _refuse("bad-product")
    if (!_isNum(inp.qty) || inp.qty <= 0) return _refuse("bad-quantity")
    if (!_isNum(inp.unitCost) || inp.unitCost < 0) return _refuse("bad-cost")
    // Each factor is finite but the product can overflow (1e308 * 5): JSON turns Infinity into null, so
    // the stored purchase would carry total = null and every sum over the ledger would break. Whichever
    // factor is the huge one, it is a cost problem (design T12).
    if (!_isNum(inp.qty * inp.unitCost)) return _refuse("bad-cost")
    if (typeof inp.now !== "string" || inp.now.length === 0 || typeof inp.date !== "string" || !_DATE.test(inp.date))
        return _refuse("bad-time")

    var reason = _text(inp.reason).trim()
    var movements = [SM.make("receipt", inp.qty, reason)]
    // The same check Gateway.recordDelta makes: a movement the server would refuse is refused here,
    // before anything is queued (a terminal rejection of a queued write drops the stock change).
    if (SM.validate("inventory", { stock: inp.qty }, {}, movements) !== "") return _refuse("bad-quantity")

    var sup = inp.supplier
    var supplierId = ""          // what the batch and the purchase carry
    var newName = ""
    if (sup !== null && sup !== undefined) {
        if (typeof sup !== "object") return _refuse("bad-supplier")
        if (typeof sup.newName === "string") {
            newName = sup.newName.trim()
            if (newName.length === 0) return _refuse("bad-supplier")
            supplierId = TOK_SUP
        } else if (typeof sup.id === "string" && sup.id.length > 0) {
            supplierId = sup.id
        } else {
            return _refuse("bad-supplier")
        }
    }

    // The server replaces a bound token anywhere in an `after` string (design M6). Text the person
    // typed that equals a token would be silently rewritten into an id inside a stored record, so
    // it is refused instead (design T7). Practically unreachable; the cost of the check is six lines.
    var typed = [inp.productName, inp.category, reason, newName, sup ? sup.id : ""]
    for (var t = 0; t < typed.length; ++t)
        if (_hasToken(typed[t])) return _refuse("reserved-text")

    var productName = _text(inp.productName)
    var category = _text(inp.category)
    var ops = []
    var at = { supplierMint: -1, batchMint: -1, supplierCreate: -1, batchCreate: -1, delta: -1, purchase: -1 }

    if (newName.length > 0) { at.supplierMint = ops.length; ops.push({ kind: "mint", counter: "supplier", bind: SUP }) }
    at.batchMint = ops.length
    ops.push({ kind: "mint", counter: "stock_batch", bind: BAT })

    if (newName.length > 0) {
        at.supplierCreate = ops.length
        ops.push(_create("supplier", TOK_SUP, {
            supplierId: TOK_SUP, name: newName, contact: "", leadTimeDays: 0,
            terms: "", notes: "", createdAt: inp.now, updatedAt: inp.now
        }))
    }

    at.batchCreate = ops.length
    ops.push(_create("stock_batch", TOK_BAT, {
        batchId: TOK_BAT, productId: inp.productId, supplierId: supplierId,
        qtyReceived: inp.qty, qtyRemaining: inp.qty, unitCost: inp.unitCost,
        receivedDate: inp.now, poId: "", note: reason, createdAt: inp.now, updatedAt: inp.now
    }))

    at.delta = ops.length
    ops.push({ kind: "delta", entity: "inventory", entityId: inp.productId, deltas: { stock: inp.qty },
               floors: {}, clamps: {}, movements: movements })

    at.purchase = ops.length
    ops.push(_create("transaction", Keys.purchaseTxId(TOK_BAT), {
        txId: Keys.purchaseTxId(TOK_BAT), kind: "purchase", timestamp: inp.now, date: inp.date,
        productId: inp.productId, productName: productName, category: category, party: supplierId,
        quantity: inp.qty, unitCost: inp.unitCost, unitPrice: 0, total: inp.qty * inp.unitCost,
        orderId: "", reason: reason
    }))

    // Firestore refuses a doc over 1 MiB, and a rejected operation queued in the outbox would retry or
    // park for nothing. The free-text reason sits in three docs, so a pasted wall of text is the real
    // risk. Refuse before anything is queued (design T11); the server stays the authority.
    for (var d = 0; d < ops.length; ++d)
        if (ops[d].kind === "mutation" && DocLimits.exceedsDoc(ops[d].after)) return _refuse("too-large")

    return { ok: true, key: inp.key, opType: "restock", ops: ops, at: at }
}

// Reads the server's results for a restock (a live answer or a stored replay) into plain docs. It
// uses only what the results themselves say, never the plan, so it works after a relaunch when the
// plan is gone. Anything that is not exactly one restock answer is refused (a half-understood result
// must never be applied to the local stores).
// -> { ok: true, productId, stock, batchId, supplierId, batch, supplier (doc or null), purchase }
//  | { ok: false, reason: "malformed-results", detail }
function reflect(results) {
    function bad(detail) { return { ok: false, reason: "malformed-results", detail: detail } }
    if (!Array.isArray(results)) return bad("not-a-list")

    var batchId = ""
    var mintedSupplier = ""
    var deltas = 0
    var productId = ""
    var stock = NaN
    var batch = null
    var supplier = null
    var purchase = null
    var creates = { stock_batch: 0, supplier: 0, transaction: 0 }

    for (var i = 0; i < results.length; ++i) {
        var r = results[i]
        if (!r || typeof r !== "object") return bad("entry-" + i)
        if (r.kind === "mint") {
            if (typeof r.id !== "string" || r.id.length === 0) return bad("mint-id")
            if (r.bind === BAT) batchId = r.id
            else if (r.bind === SUP) mintedSupplier = r.id
        } else if (r.kind === "delta") {
            if (r.entity !== "inventory" || !r.after || !_isNum(r.after.stock)) return bad("delta")
            deltas++
            productId = String(r.entityId)
            stock = r.after.stock
        } else if (r.kind === "mutation") {
            if (!r.after || typeof r.after !== "object" || !Object.prototype.hasOwnProperty.call(creates, r.entity))
                return bad("mutation")
            creates[r.entity]++
            if (r.entity === "stock_batch") batch = r.after
            else if (r.entity === "supplier") supplier = r.after
            else purchase = r.after
        } else {
            return bad("kind-" + i)
        }
    }

    if (batchId === "") return bad("no-batch-mint")
    if (deltas !== 1 || creates.stock_batch !== 1 || creates.transaction !== 1) return bad("shape")
    if (batch.batchId !== batchId || batch.productId !== productId) return bad("batch-doc")
    if (purchase.txId !== Keys.purchaseTxId(batchId)) return bad("purchase-doc")
    if (mintedSupplier !== "") {
        if (creates.supplier !== 1 || supplier.supplierId !== mintedSupplier || batch.supplierId !== mintedSupplier)
            return bad("supplier-doc")
    } else if (creates.supplier !== 0) {
        return bad("supplier-without-mint")
    }

    return { ok: true, productId: productId, stock: stock, batchId: batchId,
             supplierId: mintedSupplier !== "" ? mintedSupplier : _text(batch.supplierId),
             batch: batch, supplier: supplier, purchase: purchase }
}
