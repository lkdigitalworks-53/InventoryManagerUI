pragma Singleton
import QtQuick
import "../helper/OrderMath.js" as OrderMath

// Persistent transaction log. One entry per product-affecting event:
//   kind="created"          — product first added to inventory (initial stock)
//   kind="purchase"         — restock from supplier (positive stock delta)
//   kind="sale"             — completed-order line item (negative stock delta)
//   kind="field_change"     — non-stock field edited (price, sku, ...)
//   kind="stock_adjustment" — stock edited directly via product details (not a restock)
//   kind="photo_change"     — product photo added / replaced / removed
// Entries are written per-doc to a Firestore "transactions" collection so
// the Analysis page can aggregate purchased / sold stock by day/week/month
// and the product details dialog can show a chronological audit trail.
QtObject {
    id: root

    property var entries: []
    property int revision: 0

    // Bounded-for-now collection (per design spec SS3.1 — full local data is
    // kept, since RealisedMath/BreakdownMath on the live Analysis page read
    // this array directly today, not just after Phase 2's server-side
    // compute lands). Fetches happen in <=_pageSize chunks via
    // FirebaseService.query() instead of one unbounded FirebaseService.get().
    // Ordered by __name__, not `timestamp` -- the existing sort's
    // "(b.timestamp || \"\")" fallback is evidence some entries lack it, and
    // Firestore's orderBy silently EXCLUDES documents missing the ordered
    // field from query results. The final in-memory sort below (by
    // timestamp descending) restores display order regardless of fetch
    // order, so this doesn't change what the UI shows.
    readonly property int _pageSize: 50
    property bool hasMore: true
    property bool loadingMore: false
    property var _cursor: null

    // Only fetch here if tenant context is ALREADY known (lazy/warm
    // creation). On cold start with a persisted session this singleton could
    // otherwise be created before AuthStore.loadSession() has run, hitting
    // Firestore with an unscoped path and 403. Main.qml's
    // onTenantContextReady already re-syncs every store once tenant context
    // resolves — defer to that.
    Component.onCompleted: {
        if (AuthStore.tenantId.length > 0)
            _resetAndFetch()
    }

    function _resetAndFetch() {
        entries = []
        hasMore = true
        _cursor = null
        _fetchFromFirebase()
    }

    function _fetchFromFirebase() {
        if (loadingMore) return
        loadingMore = true
        FirebaseService.query("transactions", { limit: _pageSize, startAfter: _cursor }, function(ok, result) {
            loadingMore = false
            if (!ok || !result) {
                console.warn("[TransactionStore] Firestore sync failed",
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
                return
            }
            var arr = entries.concat(result.items)
            arr.sort(function(a, b) {
                return (b.timestamp || "").localeCompare(a.timestamp || "")
            })
            entries = arr
            revision++
            hasMore = result.hasMore
            _cursor = result.nextCursor
            if (hasMore) {
                // Keep paging until Firestore reports no more pages, so
                // `entries` ends up complete either way -- just fetched in
                // bounded chunks instead of one unbounded request.
                _fetchFromFirebase()
            } else {
                console.log("[TransactionStore] Synced", entries.length, "transactions (all pages)")
            }
        })
    }

    function syncFromFirebase() { _resetAndFetch() }

    // Drop in-memory state. Used on sign-out so the next user never briefly
    // sees the previous account's transactions before the next sync lands.
    function clear() {
        entries = []
        revision++
    }

    function _nextId(kind) {
        return "tx-" + kind + "-" + Date.now() + "-" + Math.floor(Math.random() * 1000)
    }

    // deferWrite: when true, skips the individual Gateway.recordMutation
    // call but still performs the local `entries` update synchronously —
    // the caller collects the returned doc and passes it to a *Many()
    // batch companion once the whole set is built. See addBatch's identical
    // pattern in StockBatchStore.qml for why (bulk import otherwise fires
    // one individual write per row).
    function _push(doc, deferWrite) {
        var arr = (entries || []).slice()
        arr.unshift(doc)
        entries = arr
        revision++
        // Transactions are append-only ledger rows — route through the
        // compliance gateway so each one lands with an immutable audit_log
        // entry. In "direct" mode (pre-deploy) the gateway writes the doc
        // exactly as before.
        if (!deferWrite) Gateway.recordMutation("transaction", doc.txId, "create", null, doc)
        return doc
    }

    function recordPurchase(productId, quantity, unitCost, productName, party, reason) {
        if (!productId || !quantity || quantity <= 0) return
        var doc = {
            txId: _nextId("p"),
            kind: "purchase",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || (InventoryStore.getById(productId) || {}).name || "",
            party: party || "",
            quantity: quantity,
            unitCost: typeof unitCost === "number" ? unitCost : 0,
            unitPrice: 0,
            total: quantity * (typeof unitCost === "number" ? unitCost : 0),
            orderId: "",
            reason: reason || ""
        }
        _push(doc)
    }

    // Product-creation event. Always recorded for new products, even when
    // initial stock is 0 (qty: 0 row stays informational). Counts toward the
    // Purchased analytics bucket via bucketsFor(["purchase","created"], ...).
    // deferWrite: see _push() — used by bulk import via recordCreatedMany.
    function recordCreated(productId, productName, initialStockQty, unitCost, snapshot, party, deferWrite) {
        if (!productId) return
        var qty = parseInt(initialStockQty) || 0
        var cost = typeof unitCost === "number" ? unitCost : 0
        var snap = snapshot || {}
        // Mirror the party into the snapshot so older readers that only
        // inspect snapshot still surface it.
        if (party && !snap.party) snap.party = party
        var doc = {
            txId: _nextId("c"),
            kind: "created",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || "",
            party: party || "",
            quantity: qty,
            unitCost: cost,
            unitPrice: 0,
            total: qty * cost,
            orderId: "",
            snapshot: snap
        }
        return _push(doc, deferWrite)
    }

    // Companion to recordCreated(..., true) — fires ONE
    // Gateway.recordMutations() call for every doc collected across a
    // bulk-import loop, instead of one recordMutation() per row.
    function recordCreatedMany(docs) {
        if (!docs || docs.length === 0) return
        var mutationItems = []
        for (var i = 0; i < docs.length; ++i) {
            mutationItems.push({ entityId: docs[i].txId, action: "create", before: null, after: docs[i] })
        }
        Gateway.recordMutations("transaction", mutationItems)
    }

    // Single-field mutation. One row per changed field — keeps the product
    // history granular ("Selling: ₹100 → ₹150" stays a separate row from
    // "Description: old → new").
    function recordFieldChange(productId, productName, field, before, after, reason) {
        if (!productId || !field) return
        var doc = {
            txId: _nextId("f"),
            kind: "field_change",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || "",
            field: field,
            before: before === undefined ? "" : before,
            after: after === undefined ? "" : after,
            quantity: 0,
            unitCost: 0,
            unitPrice: 0,
            total: 0,
            orderId: "",
            reason: reason || ""
        }
        _push(doc)
    }

    // Direct stock edit through product details (distinct from restock).
    // before/after are absolute values; delta is the signed difference.
    function recordStockAdjustment(productId, productName, before, after, reason) {
        if (!productId) return
        var b = parseInt(before) || 0
        var a = parseInt(after) || 0
        if (a === b) return
        var doc = {
            txId: _nextId("a"),
            kind: "stock_adjustment",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || "",
            before: b,
            after: a,
            delta: a - b,
            quantity: 0,
            unitCost: 0,
            unitPrice: 0,
            total: 0,
            orderId: "",
            reason: reason || ""
        }
        _push(doc)
    }

    // Photo lifecycle event — beforeUrl/afterUrl can be empty strings.
    function recordPhotoChange(productId, productName, beforeUrl, afterUrl) {
        if (!productId) return
        var b = beforeUrl || ""
        var a = afterUrl || ""
        if (b === a) return
        var doc = {
            txId: _nextId("ph"),
            kind: "photo_change",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: productId,
            productName: productName || "",
            before: b,
            after: a,
            quantity: 0,
            unitCost: 0,
            unitPrice: 0,
            total: 0,
            orderId: ""
        }
        _push(doc)
    }

    // Returns entries for a single product, newest first.
    function forProduct(productId) {
        var out = []
        for (var i = 0; i < entries.length; ++i)
            if (entries[i].productId === productId) out.push(entries[i])
        return out
    }

    // Returns all sell-cycle entries for one order, newest first — the order's
    // timeline: the original sale lines, plus any returns / exchanges (added
    // sale lines) / price modifies / discount adjustments / reopen reversals.
    // Powers the OrderDetailDialog history section (bug 18). Includes all
    // price_adjust rows (discount edits are now per-line carrying real productId).
    function forOrder(orderId) {
        if (!orderId) return []
        var out = []
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            if (e.orderId !== orderId) continue
            if (e.kind === "sale" || e.kind === "return" || e.kind === "price_adjust")
                out.push(e)
        }
        return out
    }

    // Most recent supplier id for a product (purchase/created events).
    // Used by EditProductDialog's "current supplier" banner. Analytics
    // should walk the FIFO consumption arrays instead — `lastSupplierFor`
    // is a UI convenience, not a reporting source.
    function lastSupplierFor(productId) {
        if (!productId) return ""
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            if (e.productId !== productId) continue
            if (e.kind !== "purchase" && e.kind !== "created") continue
            return e.party || (e.snapshot ? e.snapshot.supplierId || e.snapshot.party || "" : "")
        }
        return ""
    }

    // Legacy alias preserved for transitional callers — the historical
    // signature returned a free-text "party" string. Keep the name working
    // for code paths I haven't migrated yet.
    function lastPartyFor(productId) {
        if (!productId) return ""
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            if (e.productId !== productId) continue
            if (e.kind !== "purchase" && e.kind !== "created") continue
            return e.party || (e.snapshot ? e.snapshot.party || "" : "")
        }
        return ""
    }

    // The FIRST original sale event for a product on an order — used by
    // DataModel._tryAdjustOrder to refund returned units at the ORIGINAL-sale
    // per-unit rate (net+tax)/qty, immune to a later adjustment's discount edit
    // (SITE 6). Returns null when no such sale event exists (pre-event legacy).
    function firstSaleEvent(orderId, productId) {
        if (!orderId) return null
        var arr = entries || []
        for (var i = 0; i < arr.length; ++i) {
            var e = arr[i]
            if (e.kind === "sale" && e.orderId === orderId
                    && (e.productId || "") === (productId || ""))
                return e
        }
        return null
    }

    // Authoritative booked { net, tax, total } for one order, summed from the
    // STAMPED event log — the same fields and convention the Analysis reports
    // sum, so a completed order's total reconciles with the reports by
    // construction. Used by OrdersStore.applyAdjustment for completed orders,
    // whose lines (single tax rate each) can't represent mixed-vintage tax.
    //   tax  = Σ e.tax  over sale + return (returns carry negative tax → netted).
    //          price_adjust has NO tax field → contributes 0 (revenue-only).
    //   net  = Σ e.net  over sale + return  +  Σ e.total over price_adjust (the
    //          signed revenue delta of a price/discount edit folds into net).
    //   total = net + tax, rounded once.
    function totalsForOrder(orderId) {
        var net = 0, tax = 0
        if (!orderId) return { net: 0, tax: 0, total: 0 }
        var arr = entries || []
        for (var i = 0; i < arr.length; ++i) {
            var e = arr[i]
            if (e.orderId !== orderId) continue
            if (e.kind === "sale" || e.kind === "return") {
                net += (e.net !== undefined && e.net !== null) ? e.net : 0
                tax += (e.tax !== undefined && e.tax !== null) ? e.tax : 0
            } else if (e.kind === "price_adjust") {
                net += (e.total || 0)
            }
        }
        net = Math.round(net * 100) / 100
        tax = Math.round(tax * 100) / 100
        return { net: net, tax: tax, total: Math.round((net + tax) * 100) / 100 }
    }

    // Persists one `sale` doc per line item. The optional `consumption` field
    // on each line is a list of FIFO batches that were consumed (each entry:
    // `{ batchId, supplierId, qtyConsumed, unitCost }`). All per-supplier
    // qty-sold / revenue / margin reports read from this field — without it,
    // sales become un-attributable. Lines created before FIFO existed simply
    // omit `consumption`, and the analytics layer handles them as
    // "Pre-FIFO" data so the totals still match.
    function recordSaleFromOrder(order) {
        if (!order || !order.products) return
        var iso = new Date().toISOString()
        var alloc = OrderMath.allocate(order)
        // productId → allocated perLine (line-level net/tax/discount).
        var allocByProduct = {}
        for (var ai = 0; ai < alloc.perLine.length; ++ai)
            allocByProduct[alloc.perLine[ai].productId] = alloc.perLine[ai]
        for (var i = 0; i < order.products.length; ++i) {
            var p = order.products[i]
            var qty = p.quantity || p.qty || 0
            if (!qty) continue
            var inv = p.productId ? InventoryStore.getById(p.productId) : null
            var al = allocByProduct[p.productId || ""] || { net: qty * (p.price || 0), tax: 0, discountShare: 0 }
            var doc = {
                txId: _nextId("s"),
                kind: "sale",
                timestamp: iso,
                date: order.date || Qt.formatDate(new Date(), "yyyy-MM-dd"),
                productId: p.productId || "",
                productName: p.name || (inv ? inv.name : ""),
                quantity: qty,
                unitPrice: typeof p.price === "number" ? p.price : 0,
                net: al.net,
                tax: al.tax,
                discountShare: al.discountShare,
                total: qty * (typeof p.price === "number" ? p.price : 0),
                orderId: order.orderId || "",
                orderChannel: order.orderChannel || "",
                staffId: order.staffId || "",
                consumption: Array.isArray(p.consumption) ? p.consumption.slice() : []
            }
            _push(doc)
        }
    }

    // Append an immutable return event for one returned line. Negative quantity
    // and total so the existing sale-summing analytics net it down. Carries the
    // REVERSED consumption[] (negative qtyConsumed at the original unitCost) so
    // per-supplier/profit queries unwind the exact margin originally booked.
    //   reversedConsumption: [{ batchId, supplierId, qtyConsumed (negative), unitCost }]
    function recordReturn(order, line, returnedQty, reversedConsumption, reason, condition, note) {
        if (!returnedQty || returnedQty <= 0) return
        var unitPrice = typeof line.price === "number" ? line.price : 0
        // Allocate the parent order and scale the returned line's net/tax/discount
        // to the returned qty (negative, mirroring the negative quantity/total).
        var rNet = 0, rTax = 0, rDisc = 0
        var parent = (typeof OrdersStore !== "undefined" && order && order.orderId)
                ? OrdersStore.getById(order.orderId) : null
        var src = parent || order
        if (src) {
            var ra = OrderMath.allocate(src)
            for (var ri = 0; ri < ra.perLine.length; ++ri) {
                var rl = ra.perLine[ri]
                if (rl.productId === (line.productId || "") && rl.qty > 0) {
                    var f = returnedQty / rl.qty
                    rNet = -(rl.net * f); rTax = -(rl.tax * f); rDisc = -(rl.discountShare * f)
                    break
                }
            }
        }
        var doc = {
            txId: _nextId("r"),
            kind: "return",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: line.productId || "",
            productName: line.name || "",
            quantity: -returnedQty,
            unitCost: 0,
            unitPrice: unitPrice,
            net: rNet,
            tax: rTax,
            discountShare: rDisc,
            total: -(returnedQty * unitPrice),
            orderId: order.orderId || "",
            orderChannel: order.orderChannel || "",
            staffId: order.staffId || "",
            consumption: Array.isArray(reversedConsumption) ? reversedConsumption.slice() : [],
            reason: reason || "",
            condition: condition || "",
            note: note || ""
        }
        _push(doc)
    }

    // Record a price-only correction on already-sold units (a "modify" that
    // changed unit price, not quantity). quantity:0 so Units Sold is unaffected;
    // total carries the signed revenue delta; consumption is empty (the delta has
    // no unit/cost basis — it's a pure price correction on already-counted units),
    // so the analysis layer nets `total` straight into Revenue AND Profit (COGS is
    // unchanged, so the profit delta equals the revenue delta).
    //   revenueDelta: signed (negative when price dropped → revenue down)
    //   perUnitDelta: oldPrice - newPrice (so unitPrice on the event reads the delta)
    function recordPriceAdjust(order, line, survivingQty, perUnitDelta, reason, note) {
        if (!survivingQty || survivingQty <= 0 || !perUnitDelta) return
        var revenueDelta = -(survivingQty * perUnitDelta)   // price drop (delta>0) → negative revenue
        // Stamp the per-supplier split of this delta AT WRITE TIME, while the
        // parent order still carries its FIFO consumption lineage. Reading it
        // back from the live order at report time is unsafe: a later full return
        // empties the line's consumption, so the supplier axis would lose the
        // lineage and dump the delta into an "Unknown" bucket (residue bug).
        // Order-wide adjustments (no productId) spread across all lines; per-line
        // adjustments spread across that one line's consumption.
        var supplierSlices = []
        if (line.productId)
            supplierSlices = OrderMath.spreadLineDeltaBySupplier(order, line.productId, revenueDelta)
        else
            supplierSlices = OrderMath.spreadOrderDelta(order, revenueDelta, "supplierId", null)
        var doc = {
            txId: _nextId("pa"),
            kind: "price_adjust",
            timestamp: new Date().toISOString(),
            date: Qt.formatDate(new Date(), "yyyy-MM-dd"),
            productId: line.productId || "",
            productName: line.name || "",
            quantity: 0,
            unitCost: 0,
            unitPrice: -perUnitDelta,
            total: revenueDelta,
            orderId: order.orderId || "",
            orderChannel: order.orderChannel || "",
            staffId: order.staffId || "",
            consumption: [],
            supplierSlices: supplierSlices,   // [{ key: supplierId, amount }] — immutable, return-proof
            revenueDelta: revenueDelta,
            reason: reason || "modify",
            note: note || ""
        }
        _push(doc)
    }

    // Returns entries with timestamp (or date) inside [fromDate, toDate).
    function between(fromDate, toDate) {
        var out = []
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            var d = OrderMath.eventDate(e)
            if (isNaN(d.getTime())) continue
            if (d >= fromDate && d < toDate) out.push(e)
        }
        return out
    }

    // Aggregate qty totals into period buckets matching SalesPage's layout.
    // `kind` may be a single string OR an array of strings (e.g. for
    // "Purchased" we want both "purchase" and "created").
    // periodIdx: 0=Day(24 hourly), 1=Week(7 daily), 2=Month(4 weekly), 3=Year(12 monthly).
    function bucketsFor(kind, periodIdx) {
        return bucketsForFiltered(kind, periodIdx, null)
    }

    // Same shape as bucketsFor but applies an extra per-entry predicate. Used
    // by SalesPage to filter sold/purchased totals by party (or any other
    // arbitrary slice) without forking the bucketing math. Pass `null` /
    // `undefined` as predicate to disable filtering.
    function bucketsForFiltered(kind, periodIdx, predicate) {
        var kindSet = null
        if (Array.isArray(kind)) {
            kindSet = {}
            for (var ki = 0; ki < kind.length; ++ki) kindSet[kind[ki]] = true
        }
        var now = new Date()
        var bins = []; var labels = []
        var bucket

        if (periodIdx === 0) {
            for (var i = 0; i < 24; ++i) { bins.push(0); labels.push((i % 6 === 0) ? (i + "h") : "") }
            bucket = function(d) {
                if (d.getFullYear() === now.getFullYear()
                    && d.getMonth() === now.getMonth()
                    && d.getDate() === now.getDate()) return d.getHours()
                return -1
            }
        } else if (periodIdx === 1) {
            var dayLabels = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
            for (var w = 0; w < 7; ++w) { bins.push(0); labels.push(dayLabels[w]) }
            var monday = new Date(now)
            var dow = (monday.getDay() + 6) % 7
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
                if (d >= startMonth && d < endMonth)
                    return Math.min(3, Math.floor((d.getDate() - 1) / 7))
                return -1
            }
        } else {
            var monthLabels = ["J","F","M","A","M","J","J","A","S","O","N","D"]
            for (var y = 0; y < 12; ++y) { bins.push(0); labels.push(monthLabels[y]) }
            bucket = function(d) {
                if (d.getFullYear() === now.getFullYear()) return d.getMonth()
                return -1
            }
        }

        for (var k = 0; k < entries.length; ++k) {
            var e = entries[k]
            if (kindSet) {
                // A "sale" request also nets "return" rows (signed quantity).
                if (!kindSet[e.kind] && !(kindSet["sale"] && e.kind === "return")) continue
            } else if (kind && e.kind !== kind && !(kind === "sale" && e.kind === "return")) {
                // Legacy/back-compat: an existing "purchase" doc with the
                // old note "Initial stock" is logically a creation event —
                // include it when the caller asks for "created".
                if (kind === "created"
                    && e.kind === "purchase"
                    && e.note === "Initial stock") {
                    // accepted
                } else {
                    continue
                }
            }
            if (predicate && !predicate(e)) continue
            var dd = OrderMath.eventDate(e)
            if (isNaN(dd.getTime())) continue
            var idx = bucket(dd)
            if (idx >= 0) bins[idx] += (e.quantity || 0)
        }

        var arr = []
        for (var b = 0; b < bins.length; ++b)
            arr.push({ label: labels[b], value: bins[b] })
        return arr
    }
}
