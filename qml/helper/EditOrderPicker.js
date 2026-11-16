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

// The units of this product the order held when it was completed, exactly as booked: ALL its original lines added up
// (a legacy order may hold two lines of one product), a line of 2.5 counts 2.5. A quantity that is not a positive finite
// number holds nothing. (originalOf, the first match, stays for the booked TAX; units must not be read from it: PR #202
// sweep, F1.)
function heldAtCompletion(original, productId) {
    if (_blankId(productId) || !Array.isArray(original)) return 0
    var id = String(productId)
    var total = 0
    for (var i = 0; i < original.length; ++i) {
        var l = original[i]
        if (!l || typeof l !== "object" || _blankId(l.productId) || String(l.productId) !== id) continue
        if (typeof l.quantity === "number" && isFinite(l.quantity) && l.quantity > 0) total += l.quantity
    }
    return total
}

// The most units this product may hold on the order IN TOTAL (all its lines together). Pending or processing: the whole
// units on hand (NP.ceilingOf, the one stock rule). Completed: its units are already out of stock, so the whole units on
// hand plus EVERYTHING the order held at completion, exactly as booked (heldAtCompletion), so an order saved with its
// lines unchanged or smaller never asks for stock, also with two lines of one product or a line of 2.5 (the ceiling is
// then fractional; availableFor and stepUp hand out whole units only). A product that left the catalog (`product` null)
// has no stock: a pending order can not hold any of it more, a completed order can still go back to what it held. Any
// other status uses the stricter first formula (fail closed). Never negative. The picker (availableFor), the + stepper
// (stepUp) and the save check (stockShortfalls) all read THIS, so they cannot disagree (picker v2, S5b; KNOWN-ISSUES
// 28a, 37a, 39a).
function ceilingFor(productId, product, ctx) {
    if (_blankId(productId)) return 0
    var stock = NP.ceilingOf(product)
    if (!_completed(ctx)) return stock
    return stock + heldAtCompletion(ctx.original, productId)
}

// Units NEW quantity may still use: the ceiling minus what the order holds now (a removed line frees its units for a
// re-add, a bigger line uses them). Whole units, never negative.
function availableFor(product, lines, ctx) {
    if (!product || typeof product !== "object" || _blankId(product.productId)) return 0
    if (!_completed(ctx)) return NP.availableFor(product, lines)
    var n = ceilingFor(product.productId, product, ctx) - NP.cartQty(lines, product.productId)
    return n > 0 ? Math.floor(n) : 0
}

// One tap of + on a cart row -> the row's new quantity: one more, never above what the stock leaves THIS row (the
// ceiling minus the other lines of the same product), never below what the row already holds (a ceiling that fell since
// the row was made must not pull it down on +). The cap is a whole number (a fractional ceiling never makes a fractional
// row). `product` is null when it left the catalog and `lines` are the picker lines (linesOf), the row included. A
// quantity that is not a finite number is returned as it is.
function stepUp(qty, productId, product, ctx, lines) {
    if (typeof qty !== "number" || !isFinite(qty)) return qty
    var others = NP.cartQty(lines, productId) - (qty > 0 ? qty : 0)
    var cap = Math.floor(ceilingFor(productId, product, ctx) - (others > 0 ? others : 0))
    var q = Math.min(cap, qty + 1)
    return q < qty ? qty : q
}

// The save-time stock check -> [{ productId, name, stock, need }], one entry per product (first line's name, order of
// first appearance) whose lines together hold more than its ceiling; `stock` is the whole units on hand, `need` how many
// more the order holds than it may. A product that left the catalog is skipped on purpose: the save keeps working for
// an unrelated edit and completion refuses it later (KNOWN-ISSUES 6 and 28c, decision S5b-D4). `productOf(id)` reads the
// catalog; a throwing reader reads as "gone".
function stockShortfalls(lines, ctx, productOf) {
    var out = []
    if (!Array.isArray(lines)) return out
    var seen = []
    var lookup = { productOf: productOf }
    for (var i = 0; i < lines.length; ++i) {
        var l = lines[i]
        if (!l || typeof l !== "object" || _blankId(l.productId)) continue
        var id = String(l.productId)
        if (seen.indexOf(id) >= 0) continue
        seen.push(id)
        var p = _productOf(lookup, l.productId)
        if (!p) continue
        var need = NP.cartQty(lines, id) - ceilingFor(id, p, ctx)
        if (need > 0) out.push({ productId: id, name: l.name, stock: NP.ceilingOf(p), need: need })
    }
    return out
}

// The line part of the Save payload -> { items, products }, or {} for an order that never stored a products array
// (`noLinesStored` is exactly true) and still has no rows. Such an order must send NEITHER key: OrdersStore.buildOrderUpdate
// recomputes total and items from `products` whenever that key is present, so writing [] would zero the order's total
// and items on any save, even a customer-name edit (PR #202 sweep F2; picker v2 S5b removed the seed that used to invent
// lines for it). Without the key OrdersStore keeps the stored total and items. Its subtotal, tax and discount are
// recomputed from the (missing) lines on every update anyway: KNOWN-ISSUES 48, not fixed here. Every other order sends
// both keys, as they are; anything but a real true reads as "stored".
function lineFields(noLinesStored, rowCount, items, products) {
    if (noLinesStored === true && rowCount === 0) return {}
    return { items: items, products: products }
}

// The sentence for one shortfall, as the dialog has always worded it: "Widget: only 2 in stock, need 1 more".
function shortfallText(s) { return s.name + ": only " + s.stock + " in stock, need " + s.need + " more" }

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
            // `> 0` also keeps a row whose quantity is NaN out of `sets`: NaN !== NaN would make an untouched row look changed.
            if (l.qty > 0 && l.qty !== before[i].qty) sets.push({ index: i, productId: l.productId, quantity: l.qty })
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
