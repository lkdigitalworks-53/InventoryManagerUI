.pragma library
.import "OrderMath.js" as OrderMath

// Single source of truth for REALISED money aggregation over the immutable
// transaction event log. Pure — no QML/singleton deps; all inputs are passed
// in. Mirrors the BreakdownMath.js / OrderMath.js pattern so it is unit-testable
// headlessly.
//
// Revenue convention (locked, same as OrderMath): net = gross - discount; tax is
// a SEPARATE pass-through, never part of revenue. Reads STAMPED event fields
// (e.net/e.tax/e.discountShare) only — NEVER re-allocates the live parent order
// (which a later return/discount-edit may have mutated). A missing stamped `net`
// contributes 0 (fail-closed), per the fresh-data invariant.
//
// scope (all keys optional; "" / null = "all"):
//   { window: {from,to}|null, channel: "", staffId: "", category: "",
//     supplierId: "" }
// lookups (functions, injected so the lib stays singleton-free):
//   { categoryOf(productId) -> categoryString,        // "" when unknown
//     orderLookup(orderId)  -> order|null }           // for legacy price_adjust spread

function _round2(x) { return Math.round(x * 100) / 100 }

function _emptyRow() {
    return { revenue: 0, cogs: 0, profit: 0, tax: 0, discount: 0, margin: 0 }
}

// Mirror of SalesPage._passesCrossFilters: date / channel / staff / category.
// Supplier is handled per consumption-row by the caller. A category filter with
// no resolvable product excludes the row (matches production: getById(null)→null).
function _passesScope(e, scope, categoryOf) {
    if (!scope) return true
    if (scope.window) {
        var ed = OrderMath.eventDate(e)
        if (isNaN(ed.getTime())) return false
        if (ed < scope.window.from || ed >= scope.window.to) return false
    }
    if (scope.channel && (e.orderChannel || "") !== scope.channel) return false
    if (scope.staffId && (e.staffId || "") !== scope.staffId) return false
    if (scope.category) {
        var cat = categoryOf ? (categoryOf(e.productId) || "") : ""
        if (cat !== scope.category) return false
    }
    return true
}

// Group realised revenue/cogs/profit/tax/discount on `field`, filtered by scope.
//   field ∈ "productId" | "supplierId" | "category" | "channel" | "staffId"
// Returns { key -> {revenue, cogs, profit, tax, discount, margin} }.
function byDimension(field, entries, scope, lookups) {
    var out = {}
    entries = entries || []
    lookups = lookups || {}
    var categoryOf = lookups.categoryOf || function() { return "" }
    var orderLookup = lookups.orderLookup || function() { return null }

    for (var i = 0; i < entries.length; ++i) {
        var e = entries[i]
        if (e.kind !== "sale" && e.kind !== "return" && e.kind !== "price_adjust") continue
        if (!_passesScope(e, scope, categoryOf)) continue

        if (e.kind === "price_adjust") {
            // Under a supplier filter, attribute the adjustment via its STAMPED
            // supplierSlices (write-time lineage, return-proof) instead of
            // dropping it — only the slice matching the filtered supplier counts.
            // No match → 0 (no "Unknown" leakage). Without a supplier filter it's
            // attributed across the dimension as before (SITES 2/3).
            if (scope && scope.supplierId) {
                var paAmt = _priceAdjustSupplierAmount(e, scope.supplierId)
                if (paAmt !== 0) {
                    var paKeyF = (field === "supplierId") ? scope.supplierId
                            : (field === "category")   ? (categoryOf(e.productId) || "(uncategorised)")
                            : (field === "channel")    ? (e.orderChannel || "")
                            : (field === "staffId")    ? (e.staffId || "")
                            :                            (e.productId || "")
                    if (!out[paKeyF]) out[paKeyF] = _emptyRow()
                    out[paKeyF].revenue += paAmt
                    out[paKeyF].profit  += paAmt
                    out[paKeyF].tax     += _priceAdjustTaxShare(e, paAmt)
                    if (e.reason === "discount") out[paKeyF].discount += -paAmt
                }
            } else {
                _accumulatePriceAdjust(out, e, field, scope, categoryOf, orderLookup)
            }
            continue
        }

        // sale / return — distribute stamped net/tax/discount per consumption row.
        var c = e.consumption || []
        var rowCategory = null
        if (field === "category") rowCategory = (categoryOf(e.productId) || "(uncategorised)")
        var lineQty = 0
        for (var q = 0; q < c.length; ++q) lineQty += (c[q].qtyConsumed || 0)
        // Stamped fields only. Missing net → fail closed to 0 (SITE 4): never
        // re-allocate the live order.
        var evNet = (e.net !== undefined && e.net !== null) ? e.net : 0
        var evTax = (e.tax !== undefined && e.tax !== null) ? e.tax : 0
        var evDisc = (e.discountShare !== undefined && e.discountShare !== null) ? e.discountShare : 0

        // First pass: per-row raw split; track largest row for remainder
        // reconciliation (C) so the supplier axis is cent-exact vs the line net.
        var rows = []
        var assignedNet = 0, assignedTax = 0, assignedDisc = 0
        var largestIdx = -1, largestQty = -Infinity
        for (var ci = 0; ci < c.length; ++ci) {
            var cc = c[ci]
            var qty = cc.qtyConsumed || 0
            if (qty === 0) continue
            var supId = cc.supplierId || ""
            if (scope && scope.supplierId && supId !== scope.supplierId) continue
            var frac = lineQty !== 0 ? (qty / lineQty) : 0
            var rNet = _round2(evNet * frac)
            var rTax = _round2(evTax * frac)
            var rDisc = _round2(evDisc * frac)
            var rCogs = qty * (cc.unitCost || 0)
            assignedNet += rNet; assignedTax += rTax; assignedDisc += rDisc
            // Largest by absolute qty (returns carry negative qty).
            if (Math.abs(qty) > largestQty) { largestQty = Math.abs(qty); largestIdx = rows.length }
            var key
            if (field === "productId")      key = e.productId || ""
            else if (field === "supplierId") key = supId
            else if (field === "channel")    key = e.orderChannel || ""
            else if (field === "staffId")    key = e.staffId || ""
            else                              key = rowCategory
            rows.push({ key: key, net: rNet, tax: rTax, disc: rDisc, cogs: rCogs })
        }
        // Assign the rounding remainder to the largest in-scope row so children
        // re-sum to the stamped line totals exactly (C). lineQty == Σ qtyConsumed,
        // so the consumed fraction is 1 and the target is the rounded line total.
        // Skip under a supplier filter: only some rows are in scope, so they
        // reconcile to their own slice, not the whole line.
        if (rows.length > 0 && largestIdx >= 0 && !(scope && scope.supplierId)) {
            rows[largestIdx].net  = _round2(rows[largestIdx].net  + (_round2(evNet)  - assignedNet))
            rows[largestIdx].tax  = _round2(rows[largestIdx].tax  + (_round2(evTax)  - assignedTax))
            rows[largestIdx].disc = _round2(rows[largestIdx].disc + (_round2(evDisc) - assignedDisc))
        }
        for (var ri = 0; ri < rows.length; ++ri) {
            var r = rows[ri]
            if (!out[r.key]) out[r.key] = _emptyRow()
            out[r.key].revenue += r.net
            out[r.key].cogs    += r.cogs
            out[r.key].profit  += (r.net - r.cogs)
            out[r.key].tax     += r.tax
            out[r.key].discount += r.disc
        }
    }

    // margin% in a second pass (avoids divide-by-zero on cogs==0 rows).
    var keys = Object.keys(out)
    for (var k = 0; k < keys.length; ++k) {
        var row = out[keys[k]]
        row.margin = row.cogs > 0 ? (row.profit / row.cogs) * 100 : 0
    }
    return out
}

// Supplier-attributable portion of a price_adjust, summed from its STAMPED
// supplierSlices whose key matches `supplierId`. "" / no match → 0. Reads the
// stamped slices ONLY (no live-order re-derivation) so byDimension and bucketWalk
// compute the SAME amount under a supplier filter and totals == Σ bucketWalk
// stays exact (bucketWalk has no orderLookup to re-derive with).
function _priceAdjustSupplierAmount(e, supplierId) {
    var slices = (e && Array.isArray(e.supplierSlices)) ? e.supplierSlices : null
    if (!slices || slices.length === 0) return 0
    var amt = 0
    for (var i = 0; i < slices.length; ++i)
        if (slices[i].key === supplierId) amt += (slices[i].amount || 0)
    return amt
}

// Proportional tax share for one revenue slice of a price_adjust event.
// e.tax/e.total is a CONSTANT ratio for a given event — it equals
// (taxRate/100) exactly, by construction of TransactionStore.recordPriceAdjust
// (taxDelta = revenueDelta * taxRate/100, and every slice below is itself a
// portion of that same revenueDelta === e.total). So scaling e.tax by
// (revenueShare / e.total) recovers the EXACT tax for that slice, not an
// approximation — the same relationship byDimension already relies on for
// sale/return rows (tax split by the same fraction as net, see evTax*frac
// above). Added 2026-09-02 alongside the recordPriceAdjust fix (SKILLS Skill
// 57) — before this, price_adjust events contributed revenue/profit/discount
// to every dimension but NEVER tax, so the Analysis "Tax" column silently
// under/over-reported for any order with a post-completion discount or price
// edit on a taxable line, even though the underlying event already carried
// the correct total tax by the time this function runs.
function _priceAdjustTaxShare(e, revenueShare) {
    var total = e.total || 0
    if (total === 0) return 0
    var tax = (e.tax !== undefined && e.tax !== null) ? e.tax : 0
    return tax * (revenueShare / total)
}

// price_adjust: pure revenue correction (no qty / no COGS). Profit delta == the
// revenue delta. Carried over verbatim from InventoryStore.realisedProfitByDimension
// so the discount column and supplier attribution behave identically — now also
// gated by scope and singleton-free (category/order via injected lookups).
function _accumulatePriceAdjust(out, e, field, scope, categoryOf, orderLookup) {
    var orderWide = !e.productId
    var isDiscount = (e.reason === "discount")

    if (orderWide && (field === "productId" || field === "category" || field === "supplierId")) {
        var parentO = e.orderId ? orderLookup(e.orderId) : null
        if (!parentO) return
        var slices = OrderMath.spreadOrderDelta(parentO, (e.total || 0), field,
                        function(pid) { return categoryOf(pid) })
        for (var s = 0; s < slices.length; ++s) {
            var sk = slices[s].key
            if (!out[sk]) out[sk] = _emptyRow()
            out[sk].revenue += slices[s].amount
            out[sk].profit  += slices[s].amount
            out[sk].tax     += _priceAdjustTaxShare(e, slices[s].amount)
            if (isDiscount) out[sk].discount += -(slices[s].amount)
        }
        return
    }

    if (field === "supplierId") {
        var lineSlices = (Array.isArray(e.supplierSlices) && e.supplierSlices.length > 0)
                ? e.supplierSlices : null
        if (!lineSlices) {
            var lineParent = e.orderId ? orderLookup(e.orderId) : null
            if (lineParent) {
                var derived = e.productId
                        ? OrderMath.spreadLineDeltaBySupplier(lineParent, e.productId || "", (e.total || 0))
                        : OrderMath.spreadOrderDelta(lineParent, (e.total || 0), "supplierId", null)
                if (derived.length > 0) lineSlices = derived
            }
        }
        if (lineSlices && lineSlices.length > 0) {
            for (var ls = 0; ls < lineSlices.length; ++ls) {
                var lk = lineSlices[ls].key
                if (!out[lk]) out[lk] = _emptyRow()
                out[lk].revenue += lineSlices[ls].amount
                out[lk].profit  += lineSlices[ls].amount
                out[lk].tax     += _priceAdjustTaxShare(e, lineSlices[ls].amount)
                if (isDiscount) out[lk].discount += -(lineSlices[ls].amount)
            }
            return
        }
        // pre-FIFO / no lineage → "Unknown" bucket
        if (!out[""]) out[""] = _emptyRow()
        out[""].revenue += (e.total || 0)
        out[""].profit  += (e.total || 0)
        out[""].tax     += (e.tax || 0)
        if (isDiscount) out[""].discount += -(e.total || 0)
        return
    }

    var paKey
    if (field === "productId")      paKey = e.productId || ""
    else if (field === "channel")    paKey = e.orderChannel || ""
    else if (field === "staffId")    paKey = e.staffId || ""
    else if (field === "category")   paKey = (categoryOf(e.productId) || "(uncategorised)")
    else                              paKey = ""
    if (!out[paKey]) out[paKey] = _emptyRow()
    out[paKey].revenue += (e.total || 0)
    out[paKey].profit  += (e.total || 0)
    out[paKey].tax     += (e.tax || 0)
    if (isDiscount) out[paKey].discount += -(e.total || 0)
}

// Single filtered totals block. By construction equals Σ byDimension("category")
// so every export/hero surface reconciles to the by-dimension sections (SITE 5).
// gross = net + discount, rounded ONCE (fixes the supplier-slice ±0.01, D).
function totals(entries, scope, lookups) {
    var byCat = byDimension("category", entries, scope, lookups)
    var t = { gross: 0, discount: 0, net: 0, tax: 0, cogs: 0, profit: 0 }
    var keys = Object.keys(byCat)
    for (var i = 0; i < keys.length; ++i) {
        var r = byCat[keys[i]]
        t.net += r.revenue; t.discount += r.discount
        t.tax += r.tax; t.cogs += r.cogs; t.profit += r.profit
    }
    t.net = _round2(t.net); t.discount = _round2(t.discount)
    t.tax = _round2(t.tax); t.cogs = _round2(t.cogs); t.profit = _round2(t.profit)
    t.gross = _round2(t.net + t.discount)
    return t
}

// Per-event net contribution (revenue), optionally restricted to one supplier.
// Stamped net distributed by qtyConsumed/lineQty — mirror of eventProfit but
// revenue-only. price_adjust handled by the caller.
function _eventNet(e, supplierId) {
    var c = e.consumption || []
    var lineQty = 0
    for (var q = 0; q < c.length; ++q) lineQty += (c[q].qtyConsumed || 0)
    var evNet = (e.net !== undefined && e.net !== null) ? e.net : 0
    var net = 0
    for (var ci = 0; ci < c.length; ++ci) {
        var cc = c[ci]
        var qty = cc.qtyConsumed || 0
        if (qty === 0) continue
        if (supplierId && (cc.supplierId || "") !== supplierId) continue
        net += evNet * (lineQty !== 0 ? (qty / lineQty) : 0)
    }
    return net
}

// Period-bucket the event log for the on-screen chart and the export By-period
// section. metric ∈ "net" | "profit". `now` is injected (tests pass a fixed
// date). Canonical period bucketing for both the Revenue and Profit heroes;
// Profit now walk events (SITE 5). A supplier filter excludes price_adjust rows
// (no supplier lineage), matching the existing profit walk.
function bucketWalk(metric, periodIdx, entries, scope, now, lookups) {
    var supplierId = (scope && scope.supplierId) ? scope.supplierId : ""
    lookups = lookups || {}
    var categoryOf = lookups.categoryOf || function() { return "" }
    var bins = [], labels = [], bucket
    if (periodIdx === 0) {
        for (var i = 0; i < 24; ++i) { bins.push(0); labels.push((i % 6 === 0) ? (i + "h") : "") }
        bucket = function(d) {
            if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()
                && d.getDate() === now.getDate()) return d.getHours()
            return -1
        }
    } else if (periodIdx === 1) {
        var dl = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
        for (var w = 0; w < 7; ++w) { bins.push(0); labels.push(dl[w]) }
        var monday = new Date(now); var dow = (monday.getDay() + 6) % 7
        monday.setDate(monday.getDate() - dow); monday.setHours(0,0,0,0)
        var nextMonday = new Date(monday); nextMonday.setDate(monday.getDate() + 7)
        bucket = function(d) {
            if (d >= monday && d < nextMonday) return (d.getDay() + 6) % 7
            return -1
        }
    } else if (periodIdx === 2) {
        for (var m = 0; m < 4; ++m) { bins.push(0); labels.push("W" + (m+1)) }
        var startMonth = new Date(now.getFullYear(), now.getMonth(), 1)
        var endMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1)
        bucket = function(d) {
            if (d >= startMonth && d < endMonth) return Math.min(3, Math.floor((d.getDate() - 1) / 7))
            return -1
        }
    } else {
        var ml = ["J","F","M","A","M","J","J","A","S","O","N","D"]
        for (var y = 0; y < 12; ++y) { bins.push(0); labels.push(ml[y]) }
        bucket = function(d) {
            if (d.getFullYear() === now.getFullYear()) return d.getMonth()
            return -1
        }
    }

    entries = entries || []
    for (var k = 0; k < entries.length; ++k) {
        var e = entries[k]
        if (e.kind !== "sale" && e.kind !== "return" && e.kind !== "price_adjust") continue
        if (!_passesScope(e, scope, categoryOf)) continue
        var dd = OrderMath.eventDate(e)
        if (isNaN(dd.getTime())) continue
        var idx = bucket(dd)
        if (idx < 0) continue
        if (e.kind === "price_adjust") {
            // Supplier filter → only the matched stamped slice; else the whole
            // delta. Same _priceAdjustSupplierAmount as byDimension, so
            // totals == Σ bucketWalk holds under a filter too.
            bins[idx] += supplierId ? _priceAdjustSupplierAmount(e, supplierId)
                                    : (e.total || 0)   // net and profit both move by the delta
            continue
        }
        bins[idx] += (metric === "net") ? _eventNet(e, supplierId)
                                        : OrderMath.eventProfit(e, supplierId)
    }
    var arr = []
    for (var b = 0; b < bins.length; ++b) arr.push({ label: labels[b], value: bins[b] })
    return arr
}

// { id -> row } -> { name -> row } merge. `nameOf(key)` resolves the display
// name; `fallback` is used for an empty key (e.g. "Unknown"/"(unassigned)").
// Sums rows that resolve to the same name and recomputes margin. Extracted from
// SalesPage._namedSupplierMap/_namedStaffMap/_namedProductMap (closes X1 gap).
function nameMerge(rows, nameOf, fallback) {
    var out = {}
    var keys = Object.keys(rows || {})
    for (var i = 0; i < keys.length; ++i) {
        var k = keys[i]
        var name = k ? (nameOf ? (nameOf(k) || "(removed)") : k) : (fallback || "Unknown")
        if (!out[name]) out[name] = _emptyRow()
        out[name].revenue += rows[k].revenue || 0
        out[name].cogs += rows[k].cogs || 0
        out[name].profit += rows[k].profit || 0
        out[name].tax += rows[k].tax || 0
        out[name].discount += rows[k].discount || 0
    }
    var nks = Object.keys(out)
    for (var n = 0; n < nks.length; ++n) {
        var r = out[nks[n]]
        r.margin = r.cogs > 0 ? (r.profit / r.cogs) * 100 : 0
    }
    return out
}
