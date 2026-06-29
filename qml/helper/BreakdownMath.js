.pragma library
.import "OrderMath.js" as OrderMath

// Pure breakdown math for the Analysis page. No QML imports, no singletons,
// no dp()/sp() — everything needed is passed in. Keeps the heavy grouping
// logic out of SalesPage.qml and makes it unit-testable via qmltestrunner.

// [from, to) window for a period index relative to `now`.
//   0=Day(today)  1=Week(Mon–Sun)  2=Month  3=Year
function periodWindow(periodIdx, now) {
    if (periodIdx === 0) {
        var d0 = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        return { from: d0, to: new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1) }
    } else if (periodIdx === 1) {
        var monday = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        var dow = (monday.getDay() + 6) % 7 // 0=Mon..6=Sun
        monday.setDate(monday.getDate() - dow)
        var next = new Date(monday); next.setDate(monday.getDate() + 7)
        return { from: monday, to: next }
    } else if (periodIdx === 2) {
        return { from: new Date(now.getFullYear(), now.getMonth(), 1),
                 to:   new Date(now.getFullYear(), now.getMonth() + 1, 1) }
    }
    return { from: new Date(now.getFullYear(), 0, 1),
             to:   new Date(now.getFullYear() + 1, 0, 1) }
}

// Intersect two [from,to) windows. null = unbounded. Returns null only when
// both are null. An empty result (from >= to) filters everything out.
function intersect(a, b) {
    if (!a && !b) return null
    if (!a) return b
    if (!b) return a
    var from = a.from.getTime() >= b.from.getTime() ? a.from : b.from
    var to   = a.to.getTime()   <= b.to.getTime()   ? a.to   : b.to
    return { from: from, to: to }
}

function _inWindow(win, dateObj) {
    if (!win) return true
    var t = dateObj.getTime()
    if (isNaN(t)) return false
    return t >= win.from.getTime() && t < win.to.getTime()
}

function _categoryKey(productCategory, productId) {
    var c = productCategory[productId]
    return (c && c.length) ? c : "(uncategorised)"
}

function _supplierKey(supplierName, supplierId) {
    if (!supplierId) return "Unknown"
    return supplierName[supplierId] || "(removed)"
}

function _add(out, key, value) {
    if (value === 0) return
    out[key] = (out[key] || 0) + value
}

// Group + sum a metric by a dimension. Returns { key -> number }.
// opts = {
//   metric: "revenue"|"sold"|"purchased",
//   dim:    "category"|"supplier",
//   orders: [],            // revenue
//   entries: [],           // sold / purchased
//   window: {from,to}|null,// period ∩ date-filter (already intersected)
//   channel: "",           // "" = all (order/sale level)
//   staffId: "",           // "" = all (resolved id, not name)
//   category: "",          // "" = all (cross-filter, product category)
//   supplierId: "",        // "" = all (supplier filter, resolved id)
//   productCategory: {},   // productId -> category string
//   supplierName: {}       // supplierId -> display name
// }
function breakdown(opts) {
    if (opts.metric === "revenue" || opts.metric === "tax" || opts.metric === "discount")
        return _revenue(opts)
    if (opts.metric === "sold")      return _sold(opts)
    if (opts.metric === "purchased") return _purchased(opts)
    return {}
}

// NOTE on reconciliation: the "category" dimension always sums to the same
// total as the hero (it counts each row's full qty / line value). The
// "supplier" dimension attributes via each sale's consumption[] (FIFO
// lineage), so it can UNDERCOUNT the hero for rows that have no consumption[]
// — pre-FIFO sales and lines sold against unresolved inventory. That gap is a
// data limitation (those units have no supplier to attribute to), not a bug;
// the page surfaces it with the "No supplier data for this period" empty-state
// and a best-effort supplier breakdown. Category is the safe reconciling axis.

function _revenue(o) {
    // metricField: which per-consumption / per-line number to sum.
    var field = (o.metric === "tax") ? "tax"
              : (o.metric === "discount") ? "discountShare"
              : "net"
    var out = {}
    var orders = o.orders || []
    var alloc = o.allocate
    for (var i = 0; i < orders.length; ++i) {
        var ord = orders[i]
        if (ord.status !== "completed") continue
        var d = new Date(ord.date)
        if (!_inWindow(o.window, d)) continue
        if (o.channel && (ord.orderChannel || "") !== o.channel) continue
        if (o.staffId && (ord.staffId || "") !== o.staffId) continue
        var a = alloc(ord)
        for (var li = 0; li < a.perLine.length; ++li) {
            var pl = a.perLine[li]
            var lineCat = _categoryKey(o.productCategory, pl.productId)
            if (o.category && lineCat !== o.category) continue
            if (o.dim === "supplier") {
                var pc = pl.perConsumption || []
                for (var ci = 0; ci < pc.length; ++ci) {
                    if (o.supplierId && pc[ci].supplierId !== o.supplierId) continue
                    _add(out, _supplierKey(o.supplierName, pc[ci].supplierId), pc[ci][field] || 0)
                }
            } else { // category
                if (o.supplierId) {
                    var matched = 0
                    var pc2 = pl.perConsumption || []
                    for (var cj = 0; cj < pc2.length; ++cj)
                        if (pc2[cj].supplierId === o.supplierId) matched += (pc2[cj][field] || 0)
                    _add(out, lineCat, matched)
                } else {
                    _add(out, lineCat, pl[field] || 0)
                }
            }
        }
    }
    return out
}

function _sold(o) {
    var out = {}
    var entries = o.entries || []
    for (var i = 0; i < entries.length; ++i) {
        var e = entries[i]
        // Returns (kind:"return") carry negative quantity/qtyConsumed, so
        // including them nets the Sold breakdown down — consistent with the hero.
        if (e.kind !== "sale" && e.kind !== "return") continue
        var d = OrderMath.eventDate(e)
        if (!_inWindow(o.window, d)) continue
        if (o.channel && (e.orderChannel || "") !== o.channel) continue
        if (o.staffId && (e.staffId || "") !== o.staffId) continue
        var cat = _categoryKey(o.productCategory, e.productId)
        if (o.category && cat !== o.category) continue
        var cons = e.consumption || []
        if (o.dim === "supplier") {
            for (var ci = 0; ci < cons.length; ++ci) {
                var c = cons[ci]
                if (o.supplierId && c.supplierId !== o.supplierId) continue
                _add(out, _supplierKey(o.supplierName, c.supplierId), c.qtyConsumed || 0)
            }
        } else { // category
            if (o.supplierId) {
                var matched = 0
                for (var cj = 0; cj < cons.length; ++cj)
                    if (cons[cj].supplierId === o.supplierId) matched += (cons[cj].qtyConsumed || 0)
                _add(out, cat, matched)
            } else {
                _add(out, cat, e.quantity || 0)
            }
        }
    }
    return out
}

function _purchased(o) {
    var out = {}
    var entries = o.entries || []
    for (var i = 0; i < entries.length; ++i) {
        var e = entries[i]
        if (e.kind !== "purchase" && e.kind !== "created") continue
        var d = OrderMath.eventDate(e)
        if (!_inWindow(o.window, d)) continue
        var pid = e.party || (e.snapshot ? (e.snapshot.supplierId || e.snapshot.party || "") : "")
        if (o.supplierId && pid !== o.supplierId) continue
        var cat = _categoryKey(o.productCategory, e.productId)
        if (o.category && cat !== o.category) continue
        var qty = e.quantity || 0
        if (o.dim === "supplier") _add(out, _supplierKey(o.supplierName, pid), qty)
        else                      _add(out, cat, qty)
    }
    return out
}
