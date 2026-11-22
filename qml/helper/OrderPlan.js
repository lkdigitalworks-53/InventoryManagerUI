.pragma library
.import "OperationKeys.js" as Keys
.import "AddProductPlan.js" as AP
.import "DocLimits.js" as DocLimits

// Pure planner for the atomic create-order operation (atomic-ops NO2). Designs:
// docs/superpowers/specs/2026-11-21-create-order-atomic-operation-design.md (sections 2, 3: D-NO-5b is the server rule this
// file must satisfy) and docs/superpowers/specs/2026-11-22-no2-create-order-client-plan-design.md (this slice).
//
// build() turns "save this new order" into the two ops the server applies in ONE transaction (functions/lib/operationLogic.js,
// opType createOrder): mint the order id, then create `order/{{ord}}`. The server mints the id inside the transaction, so a
// refused or repeated create burns no number. reflect() reads the server's results back.
//
// The ORDER DOC comes from OrdersStore._normalizeOrder (one function builds it at creation and at every later read, so the
// totals have one author). This planner does not recompute the discount and tax rules; it checks what must hold for ANY
// correct doc (a new order is pending, lines are whole positive quantities, items/subtotal/total add up) and refuses the rest
// before anything is queued. The server checks the structure only (D-NO-5b), so these checks are the last guard on the fields.
//
// Nothing here reads a store or sends anything. Dormant until NO3 wires OrdersStore.addOrder to it.

var ORD = "ord"
var TOK_ORD = "{{ord}}"
var _ID = /^ORD-\d{3,}$/

function _refuse(reason) { return { ok: false, reason: reason } }
function _isNum(n) { return typeof n === "number" && isFinite(n) }
function _isObj(v) { return v !== null && typeof v === "object" && !Array.isArray(v) }
function _money(x) { return Math.round(x * 100) / 100 }
// Typed text as it is stored: trimmed, then `{{` / `}}` neutralised (the server substitutes every string, KNOWN-ISSUES 75).
// A non-string is "" (the store never sends one).
function _typed(s) { return AP.neutralisePlaceholders(typeof s === "string" ? s.trim() : "") }

// One line as the store normalises it. Returns the stored line, or null when the line is not one.
function _line(lp) {
    if (!_isObj(lp)) return null
    if (typeof lp.productId !== "string" || _typed(lp.name).length === 0) return null
    if (!_isNum(lp.price) || lp.price < 0) return null
    if (!_isNum(lp.quantity) || lp.quantity < 1 || Math.floor(lp.quantity) !== lp.quantity) return null
    if (typeof lp.taxable !== "boolean" || !_isNum(lp.taxPercent) || lp.taxPercent < 0 || lp.taxPercent > 100) return null
    if (lp.discountType !== "flat" && lp.discountType !== "percent") return null
    if (!_isNum(lp.discountValue) || lp.discountValue < 0) return null
    // A new order has consumed nothing: the batches are taken by the completion operation, never by the create.
    if (lp.consumption !== undefined && !(Array.isArray(lp.consumption) && lp.consumption.length === 0)) return null
    return { productId: _typed(lp.productId), name: _typed(lp.name), price: lp.price, quantity: lp.quantity,
             taxable: lp.taxable, taxPercent: lp.taxPercent, discountType: lp.discountType, discountValue: lp.discountValue,
             consumption: [] }
}

// input = {
//   key     from Keys.createOrderKey(...), made at the tap
//   order   the doc OrdersStore._normalizeOrder builds (its `orderId` is ignored: the server mints it). Must be: status
//           "pending", completionEpoch 0 (or absent), no adjustments, >= 1 line, a non-empty customer, a real `date`
//           ("yyyy-MM-dd") and a real `updatedAt` (Date.toISOString()), and totals that add up (see below)
// }
// Returns { ok: true, key, opType: "createOrder", ops, at: { mint: 0, create: 1 } }
//      or { ok: false, reason } with reason one of: bad-key, bad-order, bad-customer, bad-status, bad-time, bad-line (+ `index`),
//         bad-totals, too-large. Nothing is built for a refused input. The input object is never changed.
function build(input) {
    var inp = _isObj(input) ? input : {}
    if (!Keys.isCreateOrderKey(inp.key)) return _refuse("bad-key")
    var o = inp.order
    if (!_isObj(o)) return _refuse("bad-order")

    var customer = _typed(o.customer)
    if (customer.length === 0) return _refuse("bad-customer")
    // D-NO-6: an order is created pending and completed by a SECOND operation (stock is taken there). A "completed" create
    // would be a sale that never touched stock or the ledger.
    if (o.status !== "pending" || (o.completionEpoch !== undefined && o.completionEpoch !== 0)
        || (o.adjustments !== undefined && !(Array.isArray(o.adjustments) && o.adjustments.length === 0)))
        return _refuse("bad-status")
    if (!AP.isIsoDate(o.date) || !AP.isIsoInstant(o.updatedAt)) return _refuse("bad-time")

    if (!Array.isArray(o.products) || o.products.length === 0) return { ok: false, reason: "bad-line", index: -1 }
    var lines = []
    var items = 0
    var gross = 0
    for (var i = 0; i < o.products.length; ++i) {
        var ln = _line(o.products[i])
        if (ln === null) return { ok: false, reason: "bad-line", index: i }
        lines.push(ln)
        items += ln.quantity
        gross += ln.quantity * ln.price
    }

    // What holds for any correct doc, whatever the discount and tax rules are (the store owns those). Every money field of a doc the
    // store makes is a whole number of cents, so one rounding of the sum equals the store's two (a 2500-cart probe pins it).
    var subtotal = _money(gross)
    if (!_isNum(subtotal) || o.items !== items || o.subtotal !== subtotal) return _refuse("bad-totals")
    if (!_isNum(o.discount) || o.discount < 0 || o.discount > subtotal) return _refuse("bad-totals")
    if (!_isNum(o.tax) || o.tax < 0) return _refuse("bad-totals")
    if (o.total !== _money(subtotal - o.discount + o.tax)) return _refuse("bad-totals")
    if (!Array.isArray(o.taxBreakdown)) return _refuse("bad-totals")
    var breakdown = []
    for (var b = 0; b < o.taxBreakdown.length; ++b) {
        var t = o.taxBreakdown[b]
        if (!_isObj(t) || !_isNum(t.rate) || t.rate < 0 || t.rate > 100 || !_isNum(t.amount) || t.amount < 0) return _refuse("bad-totals")
        breakdown.push({ rate: t.rate, amount: t.amount })
    }

    // The keys OrdersStore._normalizeOrder returns, in its order (a drift test pins the list). Anything else on the input is
    // dropped, so an extra key can never reach the server.
    var after = {
        orderId: TOK_ORD, customer: customer, email: _typed(o.email), phone: _typed(o.phone),
        items: items, subtotal: subtotal, discount: o.discount, tax: o.tax, taxBreakdown: breakdown, total: o.total,
        status: "pending", date: o.date, updatedAt: o.updatedAt, notes: _typed(o.notes),
        orderChannel: _typed(o.orderChannel), staffId: _typed(o.staffId),
        adjustments: [], completionEpoch: 0, products: lines
    }
    // Firestore refuses a doc over 1 MiB; a rejected operation queued in the outbox would retry or park for nothing.
    if (DocLimits.exceedsDoc(after)) return _refuse("too-large")

    return { ok: true, key: inp.key, opType: "createOrder", at: { mint: 0, create: 1 }, ops: [
        { kind: "mint", counter: "order", bind: ORD },
        { kind: "mutation", entity: "order", entityId: TOK_ORD, action: "create", before: null, after: after }
    ] }
}

// Reads the server's results for a create (a live answer or a stored replay) into the stored order. It uses only what the
// results themselves say, never the plan, so it works after a relaunch when the plan is gone. Anything that is not exactly
// one create answer is refused (a half-understood result must never be applied to the local store).
// -> { ok: true, orderId, order }  |  { ok: false, reason: "malformed-results", detail }
function reflect(results) {
    function bad(detail) { return { ok: false, reason: "malformed-results", detail: detail } }
    if (!Array.isArray(results)) return bad("not-a-list")

    var id = ""
    var order = null
    var entityId = ""
    var mints = 0
    var creates = 0
    for (var i = 0; i < results.length; ++i) {
        var r = results[i]
        if (!_isObj(r)) return bad("entry-" + i)
        if (r.kind === "mint") {
            if (typeof r.id !== "string" || r.bind !== ORD) return bad("mint-id")
            id = r.id
            mints++
        } else if (r.kind === "mutation") {
            if (r.entity !== "order" || !_isObj(r.after)) return bad("mutation")
            order = r.after
            entityId = r.entityId
            creates++
        } else {
            return bad("kind-" + i)
        }
    }
    if (mints !== 1 || creates !== 1) return bad("shape")
    if (!_ID.test(id)) return bad("order-id")
    if (order.orderId !== id || entityId !== id) return bad("order-doc")
    if (order.status !== "pending" || typeof order.customer !== "string" || !Array.isArray(order.products) || order.products.length === 0)
        return bad("order-doc")
    return { ok: true, orderId: id, order: order }
}
