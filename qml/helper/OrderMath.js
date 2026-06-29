.pragma library

// Canonical per-order allocation. Splits an order into per-line (and, in a
// later step, per-FIFO-consumption) net / tax / discount / cogs, mirroring the
// pro-rata rounding in OrdersStore.computeOrderTotals so every analytics axis
// reconciles to the order. Pure — no QML/singleton deps, unit-testable.
//
// Revenue convention (locked): net = gross - discountShare; tax is a SEPARATE
// pass-through amount, never part of revenue. total = net + tax.

function _round2(x) { return Math.round(x * 100) / 100 }

// The instant a transaction event should bucket at for period/date reports.
//
// Events carry TWO dates: `date` ("yyyy-MM-dd", the BUSINESS date — the order's
// day) and `timestamp` (ISO, the WRITE instant — when the row was recorded).
// Reports must bucket on the business date: an order dated yesterday but
// recorded today belongs to yesterday's Day/Week/Month, not today's. Bucketing
// on `timestamp` made every back-dated/imported sale match the "Day = today"
// filter (the "reports ignore the date filter" bug).
//
//   • day/week/month/year membership comes from the business `date`
//   • the hourly Day view keeps the real clock time from `timestamp` ONLY when
//     timestamp lands on the same business day (a live, same-day sale); a
//     back-dated/imported event with no real intra-day time falls to local
//     midnight (00:00) of its business day.
//   • no `date` (older/odd rows) → fall back to the write instant.
//
// `date` is parsed as LOCAL midnight (+"T00:00:00") so it lines up with the
// locally-built period bounds (bare new Date("yyyy-MM-dd") is UTC midnight,
// which shifts the day east of UTC). Returns a Date.
function eventDate(e) {
    if (!e) return new Date(NaN)
    var biz = e.date ? new Date(e.date + "T00:00:00") : null   // local midnight
    var ts  = e.timestamp ? new Date(e.timestamp) : null
    if (biz && !isNaN(biz.getTime())) {
        if (ts && !isNaN(ts.getTime())
            && ts.getFullYear() === biz.getFullYear()
            && ts.getMonth()    === biz.getMonth()
            && ts.getDate()     === biz.getDate())
            return ts            // live same-day sale → keep real hour-of-day
        return biz               // back-dated / imported → its business day
    }
    return ts ? ts : new Date(NaN)   // no usable date → write instant (or NaN)
}

// Tax for ONE order line, with optional vintage split for completed orders.
//
// A line holds a single {quantity, price, discountType, discountValue, taxable,
// taxPercent}. After a mid-life product tax change a completed-order line's units
// span TWO vintages: units present at completion (the "original" qty, taxed at
// the BOOKED rate, time-of-supply) and units added during a later edit (taxed at
// the line's CURRENT rate). The order detail must show both.
//
// `opts` (optional): { originalQty, bookedRate, currentRate }
//   - omitted  → single-rate: net * (taxPercent/100) when taxable. Byte-identical
//                to computeOrderTotals' per-line tax (pending orders, new orders,
//                every existing caller — unchanged).
//   - provided → split: originalUnits = min(originalQty, qty) taxed at bookedRate;
//                the remaining addedUnits taxed at `currentRate`. Discount is
//                distributed per-unit (net/qty), so each vintage taxes its own
//                discounted net share. Both rates are PERCENTs (0 = tax-free).
//                `currentRate` lets the caller supply the product's CURRENT rate
//                for the added vintage when the line itself stores the BOOKED rate
//                (a re-added completed-order line). Omitted → falls back to the
//                line's own taxPercent (when taxable).
// Returns the (unrounded) line tax; callers sum then round once, like
// computeOrderTotals.
function lineTax(line, opts) {
    line = line || {}
    var qty = line.quantity || 0
    var price = (typeof line.price === "number") ? line.price : 0
    var gross = qty * price
    var lnType = line.discountType === "percent" ? "percent" : "flat"
    var disc
    if (lnType === "percent") {
        var pct = parseFloat(line.discountValue) || 0
        if (pct < 0) pct = 0
        if (pct > 100) pct = 100
        disc = gross * (pct / 100)
    } else {
        disc = parseFloat(line.discountValue) || 0
        if (disc < 0) disc = 0
        if (disc > gross) disc = gross
    }
    var net = gross - disc
    var curRate = (line.taxable && line.taxPercent > 0) ? line.taxPercent : 0

    if (!opts) return net * (curRate / 100)

    // Vintage split. qty 0 → no tax; guard divide-by-zero.
    if (qty <= 0) return 0
    var originalUnits = Math.min(opts.originalQty || 0, qty)
    if (originalUnits < 0) originalUnits = 0
    var addedUnits = qty - originalUnits
    var perUnitNet = net / qty
    var bookedRate = (opts.bookedRate && opts.bookedRate > 0) ? opts.bookedRate : 0
    // Added units use the explicitly-supplied current rate when given (the line
    // may store the BOOKED rate); otherwise fall back to the line's own rate.
    var addedRate = (opts.currentRate !== undefined && opts.currentRate !== null)
            ? (opts.currentRate > 0 ? opts.currentRate : 0)
            : curRate
    var originalTax = (perUnitNet * originalUnits) * (bookedRate / 100)
    var addedTax    = (perUnitNet * addedUnits)    * (addedRate / 100)
    return originalTax + addedTax
}

function allocate(order) {
    order = order || {}
    var lines = order.products || []
    var subtotal = 0
    for (var i = 0; i < lines.length; ++i)
        subtotal += (lines[i].quantity || 0) * (lines[i].price || 0)

    var perLine = []
    var totalTax = 0
    var totalCogs = 0
    var totalDiscount = 0
    var itemCount = 0
    for (var j = 0; j < lines.length; ++j) {
        var ln = lines[j]
        var qty = ln.quantity || 0
        var price = (typeof ln.price === "number") ? ln.price : 0
        var gross = qty * price
        // Per-line discount (replaces the old order-level pro-rata split).
        var lnType = ln.discountType === "percent" ? "percent" : "flat"
        var discShare
        if (lnType === "percent") {
            var lnPct = parseFloat(ln.discountValue) || 0
            if (lnPct < 0) lnPct = 0
            if (lnPct > 100) lnPct = 100
            discShare = gross * (lnPct / 100)
        } else {
            discShare = parseFloat(ln.discountValue) || 0
            if (discShare < 0) discShare = 0
            if (discShare > gross) discShare = gross
        }
        totalDiscount += discShare
        var net = gross - discShare
        var taxable = !!ln.taxable
        var taxPercent = (typeof ln.taxPercent === "number") ? ln.taxPercent : 0
        var tax = (taxable && taxPercent > 0) ? net * (taxPercent / 100) : 0
        totalTax += tax
        itemCount += qty
        var cons = Array.isArray(ln.consumption) ? ln.consumption : []
        var perConsumption = []
        var lineCogs = 0
        if (cons.length > 0 && qty > 0) {
            // Proportional split of net/tax/discountShare by qtyConsumed/qty.
            var assignedNet = 0, assignedTax = 0, assignedDisc = 0
            var largestIdx = 0, largestQty = -1
            for (var c = 0; c < cons.length; ++c) {
                var cq = cons[c].qtyConsumed || 0
                var frac = cq / qty
                var cNet = _round2(net * frac)
                var cTax = _round2(tax * frac)
                var cDisc = _round2(discShare * frac)
                var cCost = _round2(cq * (cons[c].unitCost || 0))
                lineCogs += cCost
                assignedNet += cNet; assignedTax += cTax; assignedDisc += cDisc
                if (cq > largestQty) { largestQty = cq; largestIdx = c }
                perConsumption.push({
                    supplierId: cons[c].supplierId || "", batchId: cons[c].batchId || "",
                    qtyConsumed: cq, unitCost: cons[c].unitCost || 0,
                    net: cNet, tax: cTax, discountShare: cDisc,
                    cogs: cCost, profit: cNet - cCost
                })
            }
            // Assign rounding remainder to the largest row so children re-sum.
            if (perConsumption.length > 0) {
                var totalQtyConsumed = 0
                for (var tc = 0; tc < cons.length; ++tc) totalQtyConsumed += (cons[tc].qtyConsumed || 0)
                var consumedFrac = qty > 0 ? (totalQtyConsumed / qty) : 0
                var rNet = _round2(net * consumedFrac) - assignedNet
                var rTax = _round2(tax * consumedFrac) - assignedTax
                var rDisc = _round2(discShare * consumedFrac) - assignedDisc
                var L = perConsumption[largestIdx]
                L.net = _round2(L.net + rNet)
                L.tax = _round2(L.tax + rTax)
                L.discountShare = _round2(L.discountShare + rDisc)
                L.profit = L.net - L.cogs
            }
        }
        totalCogs += lineCogs
        perLine.push({
            productId: ln.productId || "", name: ln.name || "",
            qty: qty, price: price,
            gross: gross, discountShare: discShare, net: net,
            taxable: taxable, taxPercent: taxPercent, tax: tax,
            cogs: lineCogs,
            perConsumption: perConsumption
        })
    }

    var roundedSubtotal = _round2(subtotal)
    var roundedDiscount = _round2(totalDiscount)
    var roundedTax = _round2(totalTax)
    var roundedNet = _round2(roundedSubtotal - roundedDiscount)
    var total = _round2(roundedNet + roundedTax)

    return {
        perLine: perLine,
        totals: {
            gross: roundedSubtotal,
            discount: roundedDiscount,
            net: roundedNet,
            tax: roundedTax,
            cogs: _round2(totalCogs),
            total: total,
            profit: _round2(roundedNet - _round2(totalCogs)),
            itemCount: itemCount
        }
    }
}

// Spread an order-wide revenue delta (e.g. a discount-edit price_adjust whose
// productId is "") across the order's lines/consumption, pro-rata, so it nets
// against the REAL products/categories/suppliers instead of dumping into one
// "(uncategorised)"/"" bucket (bug 15). Returns [{ key, amount }] where `key`
// is the dimension key for each slice and the amounts sum to `total`.
//   dim ∈ "productId" | "category" | "supplier" | "supplierId"
//   categoryOf(productId) → category string (only needed for dim "category")
// For supplier the spread is by qtyConsumed across consumption rows; for
// product/category it's by line gross. Lines/rows with no basis yield nothing.
// NOTE: callers (InventoryStore.realisedProfitByDimension) pass the field name
// "supplierId" — accept both spellings so the supplier branch actually runs
// (mismatching it silently fell through to the product branch → wrong chart).
function spreadOrderDelta(order, total, dim, categoryOf) {
    var a = allocate(order)
    var out = []
    if (dim === "supplier" || dim === "supplierId") {
        var rows = [], totQty = 0
        for (var i = 0; i < a.perLine.length; ++i)
            for (var j = 0; j < a.perLine[i].perConsumption.length; ++j) {
                var pc = a.perLine[i].perConsumption[j]
                rows.push(pc); totQty += (pc.qtyConsumed || 0)
            }
        for (var r = 0; r < rows.length; ++r)
            out.push({ key: rows[r].supplierId || "",
                       amount: totQty > 0 ? total * (rows[r].qtyConsumed / totQty) : 0 })
        return out
    }
    var totGross = 0
    for (var g = 0; g < a.perLine.length; ++g) totGross += a.perLine[g].gross
    for (var k = 0; k < a.perLine.length; ++k) {
        var pl = a.perLine[k]
        var key = (dim === "category")
                ? (categoryOf ? (categoryOf(pl.productId) || "(uncategorised)") : "(uncategorised)")
                : (pl.productId || "")
        out.push({ key: key, amount: totGross > 0 ? total * (pl.gross / totGross) : 0 })
    }
    return out
}

// Spread a PER-LINE revenue delta (a price modify on one product's units —
// price_adjust with a real productId but no own consumption) across that line's
// FIFO consumption rows on the parent order, pro-rata by qtyConsumed. Returns
// [{ key: supplierId, amount }] summing to `total`. Empty when the line has no
// consumption lineage (pre-FIFO) — caller then attributes to "Unknown".
// Fixes the per-line price-modify case where the supplier axis dumped the delta
// into a bogus "Unknown" / new row instead of the real supplier's bar.
function spreadLineDeltaBySupplier(order, productId, total) {
    var a = allocate(order)
    var line = null
    for (var i = 0; i < a.perLine.length; ++i)
        if ((a.perLine[i].productId || "") === (productId || "")) { line = a.perLine[i]; break }
    if (!line) return []
    var pc = line.perConsumption || []
    var totQty = 0
    for (var c = 0; c < pc.length; ++c) totQty += (pc[c].qtyConsumed || 0)
    if (totQty <= 0) return []
    var out = []
    for (var r = 0; r < pc.length; ++r)
        out.push({ key: pc[r].supplierId || "", amount: total * (pc[r].qtyConsumed / totQty) })
    return out
}

// Profit contribution of a single STAMPED sale/return event, optionally
// restricted to one supplier. This is the ONE canonical profit formula for a
// transaction-log event — InventoryStore.realisedProfitByDimension and
// RealisedMath.bucketWalk("profit") both rely on it so the on-screen Profit hero
// and the per-dimension reports never diverge.
//
// Reads the stamped `net` field (preferred); falls back to `unitPrice*lineQty`
// ONLY when net is absent (older un-stamped events). It NEVER re-allocates the
// live parent order — that order may have been mutated by a later return or
// discount edit (OrdersStore.applyAdjustment rewrites o.products), so
// re-allocating would double-count returns and discount deltas.
//
// `e` is a transaction entry of kind "sale" or "return". Return events carry
// negative quantity/net and negative qtyConsumed; with lineQty also negative
// the per-row frac stays positive, so the result is naturally negative — a
// matching full return exactly cancels its sale. Returns a Number.
// Per-unit refund (net + tax) for returned units, read from the ORIGINAL sale
// event's stamped line-level fields. Used by DataModel._tryAdjustOrder so a 2nd
// adjustment refunds at the original-sale rate, not the live order's post-edit
// discount (SITE 6). Returns 0 when qty is missing/zero (caller falls back).
function refundPerUnit(saleEvent) {
    if (!saleEvent) return 0
    var qty = saleEvent.quantity || 0
    if (qty <= 0) return 0
    var net = (saleEvent.net !== undefined && saleEvent.net !== null) ? saleEvent.net : 0
    var tax = (saleEvent.tax !== undefined && saleEvent.tax !== null) ? saleEvent.tax : 0
    return (net + tax) / qty
}

function eventProfit(e, supplierId) {
    if (!e) return 0
    var c = (e && e.consumption) ? e.consumption : []
    // Total qty across the consumption rows (negative for return events).
    var lineQty = 0
    for (var q = 0; q < c.length; ++q) lineQty += (c[q].qtyConsumed || 0)
    // Prefer the stamped line-level net; fall back to a unitPrice approximation
    // (never re-allocate — see header).
    var evNet = (e.net !== undefined) ? e.net : (lineQty * (e.unitPrice || 0))
    var profit = 0
    for (var ci = 0; ci < c.length; ++ci) {
        var cc = c[ci]
        var qty = cc.qtyConsumed || 0
        if (qty === 0) continue
        if (supplierId && (cc.supplierId || "") !== supplierId) continue
        var frac = lineQty !== 0 ? (qty / lineQty) : 0
        var rowNet = evNet * frac
        var rowCogs = qty * (cc.unitCost || 0)
        profit += (rowNet - rowCogs)
    }
    return profit
}
