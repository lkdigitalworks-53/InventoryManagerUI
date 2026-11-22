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
// What a line holds now: a positive finite quantity as it is (an order line of 2.5 stays 2.5), anything else 0.
function _held(n) { return (typeof n === "number" && isFinite(n) && n > 0) ? n : 0 }
function _blankId(id) { return id === undefined || id === null || id === "" }

function _productOf(lookup, id) {
    try {
        var p = (lookup && typeof lookup.productOf === "function") ? lookup.productOf(id) : null
        return (p && typeof p === "object") ? p : null
    } catch (e) {
        return null    // a throwing lookup reads as "gone": the row is refused, never added
    }
}

// A per-build index of how many units each product holds across `rows` (picker v2, S5d, plan S5d-D1/D3). The sheet
// asks "how much of this product is already in the order" for EVERY product of the catalog on every rebuild; walking
// the whole cart each time is N x L work (83% of a 60-line rebuild, measured by scripts/bench/pickerBench.cjs). The
// dialog builds ONE index when a build starts (the sheet's beginBuild hook) and drops it when the build ends.
// `field` is the quantity key: "qty" for cart lines, "quantity" for an Edit Order's original lines. The rules are the
// scan's, line for line: a row that is not an object, a blank id, or a quantity that is not a positive finite number
// holds nothing; ids match as String(id); sums run in row order, so even a fractional total equals the scan's.
// Keys carry a "k:" prefix: a product id of "__proto__" must not reach the prototype.
// The index remembers WHICH rows and WHICH field it was made from (`rows`, `field`): indexFits trusts it only for those,
// so an index of another list or of the other quantity key (cart `qty` versus original `quantity`) can never answer for
// this one. A mismatch is not an error: the caller scans, as before S5d (PR #210 sweep, F1).
function qtyIndex(rows, field) {
    var sums = {}
    if (Array.isArray(rows))
        for (var i = 0; i < rows.length; ++i) {
            var l = rows[i]
            if (!l || typeof l !== "object" || _blankId(l.productId)) continue
            var q = l[field]
            if (typeof q !== "number" || !isFinite(q) || !(q > 0)) continue
            var k = "k:" + String(l.productId)
            sums[k] = (_has(sums, k) ? sums[k] : 0) + q
        }
    return { qtyIndex: true, field: field, rows: rows, sums: sums }
}

// True only for an index made by qtyIndex from exactly THESE rows (the same array, not an equal one) and this quantity
// key. The rows are compared by identity, so a stale index (the order changed since), an index of another list and an
// index of the other key are all refused, and the caller scans. Without this, a wrong index answered with a wrong number
// and the sheet offered MORE stock than there is (PR #210 sweep, F1).
function indexFits(index, rows, field) {
    return !!index && typeof index === "object" && index.qtyIndex === true && index.rows === rows && index.field === field
}

// The units the index holds for this product, or null when `index` is not an index made by qtyIndex (the caller then
// scans). Junk is never trusted: a string, {}, an array, or an index whose `sums` is an array, as the third argument of
// cartQty falls back to the scan. Callers check indexFits first (cartQty and heldAtCompletion do).
function qtyFromIndex(index, productId) {
    if (!index || typeof index !== "object" || index.qtyIndex !== true) return null
    if (!index.sums || typeof index.sums !== "object" || Array.isArray(index.sums)) return null
    if (_blankId(productId)) return 0
    var k = "k:" + String(productId)
    return _has(index.sums, k) ? index.sums[k] : 0
}

// Units of a product already in the cart (all lines of that product). `index` (optional, qtyIndex(lines, "qty")) answers
// without walking the cart; it is used only when it was made from these very `lines` (indexFits), any other value is
// ignored and the cart is scanned.
function cartQty(lines, productId, index) {
    var used = 0
    if (_blankId(productId)) return used
    var fast = indexFits(index, lines, "qty") ? qtyFromIndex(index, productId) : null
    if (fast !== null) return fast
    if (!Array.isArray(lines)) return used
    var id = String(productId)
    for (var i = 0; i < lines.length; ++i) {
        var l = lines[i]
        if (!l || typeof l !== "object" || _blankId(l.productId) || String(l.productId) !== id) continue
        // Only positive quantities count, as in CompletionPlan: a stray negative line must not free stock for another.
        if (typeof l.qty === "number" && isFinite(l.qty) && l.qty > 0) used += l.qty
    }
    return used
}

// The most units of this product an order may hold IN TOTAL: the whole units on hand (units leave stock only when the
// order completes). 0 for something that is not a product (a product that left the catalog holds none). This is the ONE
// stock rule of the order dialogs (picker v2, S5b): availableFor below, the cart-row steppers and Edit Order's save-time
// check all read it, so a fractional stock such as 2.5 means 2 everywhere.
function ceilingOf(product) { return (product && typeof product === "object") ? _whole(product.stock) : 0 }

// What NEW lines may still use: the ceiling minus what the cart already holds (units are not deducted until the
// order completes). Never negative, whole units, 0 for a product that is not a product.
function availableFor(product, lines, index) {
    if (!product || typeof product !== "object" || _blankId(product.productId)) return 0
    return Math.max(0, ceilingOf(product) - cartQty(lines, product.productId, index))
}

// The quantity of a New Order cart row after a tap of + (delta above 0) or - (delta below 0), the same contract as
// EditOrderPicker.stepUp. + adds at most delta, up to the ceiling (ceilingOf; `product` null or not a product has none),
// and NEVER lowers or removes a row: a row above the ceiling (stock fell) or a product that ran out keeps its quantity
// and trySubmit reports it, instead of the tap silently deleting the row and its discount (PR #202 sweep; Skill 176
// rule 3). - takes exactly delta off whatever the ceiling is; a result of 0 means the caller removes the row. A quantity
// or a step that is not a finite number is returned as the quantity.
function stepQty(qty, delta, product) {
    if (typeof qty !== "number" || !isFinite(qty) || typeof delta !== "number" || !isFinite(delta)) return qty
    if (delta < 0) return Math.max(0, qty + delta)
    return Math.max(qty, Math.min(ceilingOf(product), qty + delta))
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
    var left = availableFor({ productId: id, stock: p.stock }, out)    // a fractional line in the cart leaves a fraction: whole units only
    return left > 0 ? Math.floor(left) : 0
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
        if (at >= 0) out[at].qty = _held(out[at].qty) + take    // a line with no usable quantity counts as 0, never NaN; a fraction is kept
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
