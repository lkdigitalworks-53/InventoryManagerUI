.pragma library
.import "CompletionPlan.js" as CP

// Pure rules of the New Order picker wiring (picker v2, slice S3; plan
// docs/superpowers/plans/2026-11-11-product-picker-v2-s3-new-order.md). NewOrderDialog.qml holds state and paints; what
// may be added, how much, at what price, and whether the order is still small enough to complete lives HERE, in one
// tested place (Skill 83). Tests: functions/test/newOrderPicker.test.js.
//
// The sheet hands the dialog a plan { adds: [{productId, qty}], bumps: [{productId, qty}] } ("add N more", design D4).
// applyPlan is the dialog's "existing add-line code": it never removes a line, never touches a line's price or
// discount, and re-reads the product at the moment of the commit, so a drift since the last tap is clamped or
// refused (fail closed) and reported in `skipped`.
//
// `lookup` is supplied by the dialog so this file reads no store:
//   productOf(id)  -> the catalog product or null            (InventoryStore.getById)
//   batchesOf(id)  -> its FIFO batches, oldest first          (StockBatchStore.forProduct); used by opsCheck only
//   availableOf(id, product, lines) -> optional; units still addable (default: stock minus the cart). Edit Order only.
//
// Ids: plan ids are strings, a cart line may hold a numeric id (KNOWN-ISSUES, picker carried requirement 5), so
// every comparison is String(line.productId) === id.

var CANNOT_CHECK_TEXT = "Could not check the size of this order. Try again"
// The skipped note is a TOAST and the toast pill is one line that does not wrap (ToastHost, KNOWN-ISSUES 26), about 40
// characters on a phone. So the reasons are short and the note names one product.
var REASON_TEXT = {
    "invalid": "not added",
    "gone": "no longer listed",
    "out-of-stock": "out of stock",
    "no-price": "no price"
}
var NOTE_NAME_MAX = 12

function _has(o, k) { return !!o && typeof o === "object" && Object.prototype.hasOwnProperty.call(o, k) }
function _str(s) { return (typeof s === "string") ? s : ((s === undefined || s === null) ? "" : String(s)) }
function _whole(n) { return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0 }
function _isQty(q) { return typeof q === "number" && isFinite(q) && q > 0 && Math.floor(q) === q }
function _blankId(id) { return id === undefined || id === null || id === "" }

function _productOf(lookup, id) {
    try {
        var p = (lookup && typeof lookup.productOf === "function") ? lookup.productOf(id) : null
        return (p && typeof p === "object") ? p : null
    } catch (e) {
        return null    // a throwing lookup reads as "gone": the row is refused, never added
    }
}

// Units of a product already in the cart (all lines of that product).
function cartQty(lines, productId) {
    var used = 0
    if (_blankId(productId) || !Array.isArray(lines)) return used
    var id = String(productId)
    for (var i = 0; i < lines.length; ++i) {
        var l = lines[i]
        if (!l || typeof l !== "object" || _blankId(l.productId) || String(l.productId) !== id) continue
        // Only positive quantities count, as in CompletionPlan: a stray negative line must not free stock for another.
        if (typeof l.qty === "number" && isFinite(l.qty) && l.qty > 0) used += l.qty
    }
    return used
}

// What NEW lines may still use: on-hand stock minus what the cart already holds (units are not deducted until the
// order completes). Never negative, whole units, 0 for a product that is not a product.
function availableFor(product, lines) {
    if (!product || typeof product !== "object" || _blankId(product.productId)) return 0
    return Math.max(0, _whole(product.stock) - cartQty(lines, product.productId))
}

// Unit price of a NEW line: sellingPrice, else the legacy price field. null when it is not a finite number >= 0
// (0 stays allowed: a free item was always possible), so a line with no price never reaches the order.
function priceOf(product) {
    if (!product || typeof product !== "object") return null
    var v = (product.sellingPrice !== undefined && product.sellingPrice !== null) ? product.sellingPrice : product.price
    return (typeof v === "number" && isFinite(v) && v >= 0) ? v : null
}

function _copyLines(lines) {
    var out = []
    if (!Array.isArray(lines)) return out
    for (var i = 0; i < lines.length; ++i) {
        var l = lines[i]
        if (!l || typeof l !== "object") continue
        out.push({ name: l.name, qty: l.qty, price: l.price, productId: l.productId,
                   discountType: l.discountType || "flat", discountValue: l.discountValue || 0 })
    }
    return out
}

function _indexOf(lines, id) {
    for (var i = 0; i < lines.length; ++i)
        if (!_blankId(lines[i].productId) && String(lines[i].productId) === id) return i
    return -1
}

// How many units NEW quantity may still use for this product. The default is the New Order formula. Edit Order
// (picker slice S4) passes lookup.availableOf(id, product, linesBuiltSoFar) because a completed order's units are
// already out of stock; the hook is optional, so New Order is unchanged. A throwing or non-number hook gives 0:
// fail closed, the product is refused.
function _capOf(lookup, id, p, out) {
    if (lookup && typeof lookup.availableOf === "function") {
        try {
            var n = lookup.availableOf(id, p, out)
            return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0
        } catch (e) {
            return 0
        }
    }
    return availableFor({ productId: id, stock: p.stock }, out)
}

function _skip(id, name, reason) { return { productId: id, name: name, reason: reason } }

// -> { lines, skipped }. `lines` is a NEW array of NEW objects (the input is never changed); `skipped` lists what was
// refused or reduced: { productId, name, reason, [added, asked] } with reason one of invalid, gone, out-of-stock,
// no-price, reduced. Bumps are applied first, then adds, each entry against the lines built so far: a plan made from a
// stale order still never makes a duplicate line (an "add" for a product now on the order is a bump, a "bump" for one
// that is not is an add) and two entries for one product can never exceed the stock together.
function applyPlan(lines, plan, lookup) {
    var out = _copyLines(lines)
    var skipped = []
    var entries = []
    if (plan && Array.isArray(plan.bumps)) entries = entries.concat(plan.bumps)
    if (plan && Array.isArray(plan.adds)) entries = entries.concat(plan.adds)
    for (var i = 0; i < entries.length; ++i) {
        var e = entries[i]
        var id = (e && typeof e === "object" && typeof e.productId === "string") ? e.productId : ""
        if (id === "" || !_isQty(e.qty)) { skipped.push(_skip(id, id, "invalid")); continue }
        var p = _productOf(lookup, id)
        if (!p) { skipped.push(_skip(id, id, "gone")); continue }
        var name = _str(p.name).length > 0 ? _str(p.name) : id
        var cap = _capOf(lookup, id, p, out)
        if (cap <= 0) { skipped.push(_skip(id, name, "out-of-stock")); continue }
        var at = _indexOf(out, id)
        var price = priceOf(p)
        if (at < 0 && price === null) { skipped.push(_skip(id, name, "no-price")); continue }
        var take = Math.min(e.qty, cap)
        if (take < e.qty) skipped.push({ productId: id, name: name, reason: "reduced", added: take, asked: e.qty })
        if (at >= 0) out[at].qty = _whole(out[at].qty) + take    // a line with no usable quantity counts as 0, never NaN
        else out.push({ name: name, qty: take, price: price, productId: id, discountType: "flat", discountValue: 0 })
    }
    return { lines: out, skipped: skipped }
}

// The product name as the toast shows it: at most NOTE_NAME_MAX characters, never cutting an emoji in half.
function _shortName(name) {
    if (name.length <= NOTE_NAME_MAX) return name
    var end = NOTE_NAME_MAX - 1
    var c = name.charCodeAt(end - 1)
    if (c >= 0xD800 && c <= 0xDBFF) end--
    return name.slice(0, end).replace(/\s+$/, "") + "\u2026"
}

// The toast text, "" when nothing was skipped: the first skipped product and why, then "(+N more)". Short on purpose,
// see REASON_TEXT. Nothing is lost: the order sheet shows what was added.
function skippedNote(skipped) {
    if (!Array.isArray(skipped)) return ""
    var first = ""
    var count = 0
    for (var i = 0; i < skipped.length; ++i) {
        var s = skipped[i]
        if (!s || typeof s !== "object") continue
        if (++count > 1) continue
        var why = "not added"
        if (s.reason === "reduced") why = "only " + _whole(s.added) + " of " + _whole(s.asked) + " added"
        else if (_has(REASON_TEXT, s.reason)) why = REASON_TEXT[s.reason]
        var who = _str(s.name).length > 0 ? _str(s.name) : (_str(s.productId).length > 0 ? _str(s.productId) : "A product")
        first = _shortName(who) + ": " + why
    }
    return count === 0 ? "" : first + (count > 1 ? " (+" + (count - 1) + " more)" : "")
}

// The CompletionPlan hooks of a dry run: same number of changes as the real ones (the order itself, and one sale
// document per line that has a quantity: TransactionStore.buildSaleDocs, pinned by NOW-11), without building them.
var DRY_HOOKS = {
    orderUpdate: function(lines) { return { before: {}, after: { products: lines } } },
    saleDocs: function(after) {
        var docs = []
        var ls = after.products
        for (var i = 0; i < ls.length; ++i) if (ls[i].qty > 0) docs.push({ txId: "dry-" + i })
        return docs
    }
}

// Dry run of the order's completion (carried requirement 1): would the order, after this plan, still fit in one
// atomic operation (CompletionPlan.MAX_OPS changes)? A line that spans several FIFO batches costs more than the
// early stop of PickerDraft.MAX_LINES assumes. -> { ok, text }. Only the SIZE is judged here: a stock shortfall
// (clampStock) and a line whose product is gone are the submit check's job, and CompletionPlan at approval stays the
// final authority (batches change between now and then). Fails closed: a missing or throwing lookup refuses.
function opsCheck(lines, plan, lookup) {
    try {
        if (!lookup || typeof lookup.productOf !== "function" || typeof lookup.batchesOf !== "function")
            return { ok: false, text: CANNOT_CHECK_TEXT }
        var applied = applyPlan(lines, plan, lookup).lines
        var rows = []
        var stock = {}
        var batches = {}
        for (var i = 0; i < applied.length; ++i) {
            var l = applied[i]
            var id = String(l.productId)
            var p = _productOf(lookup, id)
            if (!p) continue
            stock[id] = _whole(p.stock)
            if (!_has(batches, id)) {
                var b = lookup.batchesOf(id)
                if (!Array.isArray(b)) throw new Error("batches of " + id + " are not a list")    // caught below: fail closed
                batches[id] = b
            }
            rows.push({ line: l, productId: id, name: l.name, qty: l.qty })
        }
        var r = CP.build({ orderId: "dry-run", epoch: 0, now: "", clampStock: true, lines: rows,
                           stockByProduct: stock, batchesByProduct: batches }, DRY_HOOKS)
        if (r.ok) return { ok: true, text: "" }
        if (r.reason === "too-many-ops") return { ok: false, text: _str(r.errors && r.errors[0]) || CANNOT_CHECK_TEXT }
        return { ok: true, text: "" }
    } catch (e) {
        return { ok: false, text: CANNOT_CHECK_TEXT }
    }
}
