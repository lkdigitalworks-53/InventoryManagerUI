.pragma library

// Pure draft for the order picker (design 2026-11-03). The draft maps productId -> whole quantity and
// is keyed by product, never by visible rows, so filtering never loses a quantity. Every function
// returns a NEW object. "Add N more" only: commitPlan never removes or reduces a line.
//
// MAX_LINES is conservative: a completed line costs at least 3 server changes (batch, stock, sale
// record) plus 1 for the order, and the server refuses more than MAX_OPS (functions/lib/operationLogic.js,
// qml/helper/CompletionPlan.js). A product that spans many batches costs more, so this is an early stop,
// not a guarantee; CompletionPlan stays the final check. functions/test/pickerDraft.test.js (DRFT-26)
// fails if 3 * MAX_LINES + 1 ever exceeds MAX_OPS.
//
// KNOWN LIMIT (carried to S3/S4, see KNOWN-ISSUES): a line that spans two FIFO batches costs 4 ops, so 50
// such lines already give 201 > 200 and the planner refuses with too-many-ops. The dialogs must therefore
// also run CompletionPlan.build as a dry run before enabling "Add to order". Completed-order edits do not go
// through CompletionPlan at all, so there this cap is only an early stop.
//
// Ids: draft keys and commitPlan ids are always strings. Order lines may carry a numeric productId; they are
// matched by "k:" + id, so the consumer must match plan entries to lines with String(line.productId) ===
// entry.productId, never with ===.

var MAX_LINES = 60
var MAX_DIGITS = 6

function empty() { return {} }

function _has(o, k) { return Object.prototype.hasOwnProperty.call(o, k) }
function _whole(n) { return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0 }
function _validId(id) { return typeof id === "string" && id.length > 0 && id !== "__proto__" }
function _isQty(q) { return typeof q === "number" && isFinite(q) && q > 0 && Math.floor(q) === q }

function _clone(d) {
    var out = {}
    if (d && typeof d === "object")
        for (var k in d) if (_has(d, k) && k !== "__proto__") out[k] = d[k]
    return out
}

// Typed or stepped value -> { ok, qty }. Digits only, at most MAX_DIGITS; anything else is refused.
function parseQty(raw) {
    var s = ""
    if (typeof raw === "number") s = String(raw)
    else if (typeof raw === "string") s = raw.trim()
    if (!/^[0-9]+$/.test(s) || s.length > MAX_DIGITS) return { ok: false, qty: 0 }
    return { ok: true, qty: parseInt(s, 10) }
}

function _put(draft, id, qty, maxQty) {
    var out = _clone(draft)
    if (!_validId(id)) return out
    var q = Math.min(qty, _whole(maxQty))
    if (q > 0) out[id] = q
    else delete out[id]
    return out
}

function setQty(draft, productId, raw, maxQty) {
    var p = parseQty(raw)
    if (!p.ok) return _clone(draft)
    return _put(draft, productId, p.qty, maxQty)
}

function step(draft, productId, delta, maxQty) {
    if (typeof delta !== "number" || !isFinite(delta) || Math.floor(delta) !== delta) return _clone(draft)
    var cur = (draft && _has(draft, productId) && _isQty(draft[productId])) ? draft[productId] : 0
    return _put(draft, productId, cur + delta, maxQty)    // _put refuses a bad id and drops a result <= 0
}

function totals(draft, priceOf) {
    var d = _clone(draft)
    var items = 0, lines = 0, amount = 0
    for (var id in d) {
        if (!_isQty(d[id])) continue
        items += d[id]
        lines++
        var price = 0
        try { price = priceOf(id) } catch (e) { price = 0 }    // a missing priceOf throws here: price 0
        if (typeof price === "number" && isFinite(price) && price > 0) amount += price * d[id]
    }
    return { items: items, lines: lines, amount: Math.round(amount * 100) / 100 }
}

// Lines on the order: `set` = lines with a product id, `unkeyed` = legacy lines without one (OrderDetail seeds
// them with ""). Each unkeyed line counts on its own so the line cap is never undercounted.
function _existing(orderLines) {
    var set = {}
    var unkeyed = 0
    if (Array.isArray(orderLines))
        for (var i = 0; i < orderLines.length; ++i) {
            var l = orderLines[i]
            if (!l || typeof l !== "object" || Array.isArray(l)) continue
            if (l.productId === undefined || l.productId === null || l.productId === "") unkeyed++
            else set["k:" + l.productId] = true
        }
    return { set: set, unkeyed: unkeyed }
}

// -> { adds, bumps }: adds = product not yet on the order, bumps = add to an existing line. Sorted by id.
function commitPlan(draft, orderLines) {
    var d = _clone(draft)
    var ex = _existing(orderLines).set
    var ids = Object.keys(d).sort()
    var adds = [], bumps = []
    for (var i = 0; i < ids.length; ++i) {
        var q = d[ids[i]]
        if (!_isQty(q)) continue
        var entry = { productId: ids[i], qty: q }
        if (_has(ex, "k:" + ids[i])) bumps.push(entry)
        else adds.push(entry)
    }
    return { adds: adds, bumps: bumps }
}

function lineCountAfter(orderLines, plan) {
    var ex = _existing(orderLines)
    return Object.keys(ex.set).length + ex.unkeyed + ((plan && Array.isArray(plan.adds)) ? plan.adds.length : 0)
}

// True when the order plus the draft's new lines already holds MAX_LINES distinct lines.
function lineLimitReached(orderLines, draft) {
    return lineCountAfter(orderLines, commitPlan(draft, orderLines)) >= MAX_LINES
}

// The gate to run right before the dialog commits (the cap in classify uses a ctx from an earlier moment, and
// step/setQty/commitPlan do not enforce it). -> { ok, reason }: "empty" when the draft holds nothing valid,
// "too-many-lines" when the order would end above MAX_LINES lines.
function canCommit(orderLines, draft) {
    var plan = commitPlan(draft, orderLines)
    if (plan.adds.length + plan.bumps.length === 0) return { ok: false, reason: "empty" }
    if (lineCountAfter(orderLines, plan) > MAX_LINES) return { ok: false, reason: "too-many-lines" }
    return { ok: true, reason: "" }
}

// After a live refresh: clamp each quantity to the product's current maxQty, drop what reached 0.
// A missing maxQtyOf drops everything, a throwing one drops that product (fail closed).
function reconcile(draft, maxQtyOf) {
    var d = _clone(draft)
    var out = {}
    for (var id in d) {
        if (!_isQty(d[id])) continue
        var m = 0
        try { m = _whole(maxQtyOf(id)) } catch (e) { m = 0 }    // a missing maxQtyOf throws here: dropped
        var q = Math.min(d[id], m)
        if (q > 0) out[id] = q
    }
    return out
}
