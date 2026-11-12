.pragma library
.import "NewOrderPicker.js" as NP

// Pure rules of the Edit Order picker wiring (picker v2, slice S4; plan
// docs/superpowers/plans/2026-11-12-product-picker-v2-s4-edit-order.md). OrderDetailDialog.qml holds state and paints;
// what may be added, how much, with which tax, and whether a pending order is still small enough to complete lives HERE,
// in one tested place (Skill 83). Tests: functions/test/editOrderPicker.test.js.
//
// It reuses NewOrderPicker.applyPlan for the money invariants (add N more, never remove, never a duplicate line, never
// more than the stock, a new line needs a valid price) and adds only what Edit Order does differently:
//   1. the stock formula depends on the order's saved status (a COMPLETED order's units are already out of stock),
//   2. a new line on a COMPLETED order that was on the order at completion keeps its BOOKED tax (time of supply),
//   3. the dry run of completion applies only to pending and processing orders (a completed order's edit goes through
//      DataModel._tryAdjustOrder, which has no operation cap: KNOWN-ISSUES, picker carried item 2).
//
// Shapes. `lines` are picker lines { productId, name, qty, price, discountType, discountValue }, one per ListModel row
// in the same order (linesOf). `ctx` is { status, original }: the order's SAVED status and its original lines
// ({ productId, quantity, taxable, taxPercent }, the dialog's _originalLines). `lookup` is { productOf(id), batchesOf(id) }.

function _whole(n) { return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0 }
function _blankId(id) { return id === undefined || id === null || id === "" }
function _completed(ctx) { return !!ctx && ctx.status === "completed" }
// The picker line of a row that is not an object: it keeps the index of its row and holds nothing.
function _blankLine() { return { productId: "", name: "", qty: 0, price: 0, discountType: "flat", discountValue: 0 } }

// One picker line per row, same order, quantity renamed to qty. A row that is not an object becomes a blank line, so
// the index of every line stays the index of its row.
function linesOf(rows) {
    var out = []
    if (!Array.isArray(rows)) return out
    for (var i = 0; i < rows.length; ++i) {
        var r = rows[i]
        if (!r || typeof r !== "object") { out.push(_blankLine()); continue }
        out.push({ productId: r.productId, name: r.name, qty: r.quantity, price: r.price,
                   discountType: r.discountType === "percent" ? "percent" : "flat", discountValue: r.discountValue || 0 })
    }
    return out
}

// The line this product had when the order was completed (first match by String id), or null. `original` is the dialog's
// _originalLines. The dialog's _findOriginalLine is this function, so the stock guard, the tax forecast, the + stepper and
// the picker all match ids the same way (an order line may hold a numeric id, KNOWN-ISSUES, picker carried requirement 5).
function originalOf(original, productId) {
    if (_blankId(productId) || !Array.isArray(original)) return null
    var id = String(productId)
    for (var i = 0; i < original.length; ++i) {
        var l = original[i]
        if (l && typeof l === "object" && !_blankId(l.productId) && String(l.productId) === id) return l
    }
    return null
}
function _originalOf(ctx, productId) { return originalOf(ctx && ctx.original, productId) }

// Units of a product the order holds now (all its lines).
function cartQty(lines, productId) { return NP.cartQty(lines, productId) }

// Units NEW quantity may still use. Pending or processing: on-hand minus what the order holds (same as New Order).
// Completed: its units are already out of stock, so on-hand plus the units the order held at completion minus what it
// holds now (a removed line frees its units for a re-add, a bigger line uses them). Whole units, never negative. Any
// other status uses the stricter first formula (fail closed).
function availableFor(product, lines, ctx) {
    if (!product || typeof product !== "object" || _blankId(product.productId)) return 0
    if (!_completed(ctx)) return NP.availableFor(product, lines)
    var orig = _originalOf(ctx, product.productId)
    var origQty = orig ? _whole(orig.quantity) : 0
    var n = _whole(product.stock) + origQty - NP.cartQty(lines, product.productId)
    return n > 0 ? Math.floor(n) : 0
}

function _rate(v) { return (typeof v === "number" && isFinite(v) && v >= 0) ? v : 0 }

// Tax flags of a NEW line. A completed order's product that was on it at completion is re-added at its BOOKED rate:
// re-taxing units already supplied would diverge from the immutable sale ledger. Everything else (a pending order, a
// product that was never on the order) takes the product's CURRENT rate.
function seedOf(product, ctx) {
    var booked = _completed(ctx) ? _originalOf(ctx, product && product.productId) : null
    if (booked) return { taxable: !!booked.taxable, taxPercent: _rate(booked.taxPercent) }
    return { taxable: !!(product && product.taxable), taxPercent: _rate(product && product.taxPercent) }
}

function _productOf(lookup, id) {
    try {
        var p = (lookup && typeof lookup.productOf === "function") ? lookup.productOf(id) : null
        return (p && typeof p === "object") ? p : null
    } catch (e) {
        return null
    }
}

// The lookup NewOrderPicker sees: the dialog's two readers, passed on only when they exist (a missing reader must reach
// NewOrderPicker.opsCheck as missing, which refuses: fail closed), plus the status-aware stock formula.
function _full(lookup, ctx) {
    var full = { availableOf: function(id, p, out) { return availableFor({ productId: id, stock: p.stock }, out, ctx) } }
    if (lookup && typeof lookup.productOf === "function") full.productOf = lookup.productOf
    if (lookup && typeof lookup.batchesOf === "function") full.batchesOf = lookup.batchesOf
    return full
}

// The plan from the sheet applied to the order's lines -> { sets, appends, skipped }:
//   sets     [{ index, productId, quantity }]  the line at `index` (a row index) gets this NEW total quantity
//   appends  [{ productId, name, price, quantity, discountType, discountValue, taxable, taxPercent }]  new rows, in order
//   skipped  what was refused or reduced (NewOrderPicker.applyPlan: invalid, gone, out-of-stock, no-price, reduced)
// The dialog applies sets with setProperty and appends with append, then recomputes ONCE. Nothing is ever removed, and no
// existing row's price, discount or tax is touched.
function applyPlan(lines, plan, ctx, lookup) {
    var before = []    // a copy in which a junk row is a blank line, so row index and line index stay the same thing
    if (Array.isArray(lines)) for (var k = 0; k < lines.length; ++k) before.push((lines[k] && typeof lines[k] === "object") ? lines[k] : _blankLine())
    var res = NP.applyPlan(before, plan, _full(lookup, ctx))
    var sets = []
    var appends = []
    var skipped = res.skipped.slice()
    for (var i = 0; i < res.lines.length; ++i) {
        var l = res.lines[i]
        if (i < before.length) {
            if (l.qty !== before[i].qty) sets.push({ index: i, productId: l.productId, quantity: l.qty })
            continue
        }
        var p = _productOf(lookup, String(l.productId))
        if (!p) { skipped.push({ productId: String(l.productId), name: l.name, reason: "gone" }); continue }   // cannot seed the tax: refuse
        var seed = seedOf(p, ctx)
        appends.push({ productId: l.productId, name: l.name, price: l.price, quantity: l.qty,
                       discountType: "flat", discountValue: 0, taxable: seed.taxable, taxPercent: seed.taxPercent })
    }
    return { sets: sets, appends: appends, skipped: skipped }
}

// The dry run (NewOrderPicker.opsCheck) for a pending or processing order; always ok for a completed one, whose edit
// has no operation cap. -> { ok, text }.
function commitCheck(lines, plan, ctx, lookup) {
    if (_completed(ctx)) return { ok: true, text: "" }
    return NP.opsCheck(Array.isArray(lines) ? lines : [], plan, _full(lookup, ctx))
}

function skippedNote(skipped) { return NP.skippedNote(skipped) }
