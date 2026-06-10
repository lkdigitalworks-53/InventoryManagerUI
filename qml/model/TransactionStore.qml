pragma Singleton
import QtQuick

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

    Component.onCompleted: _fetchFromFirebase()

    function _fetchFromFirebase() {
        FirebaseService.get("transactions", function(ok, data) {
            if (!ok) {
                console.warn("[TransactionStore] Firestore sync failed",
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
                return
            }
            var arr = FirebaseService.toArray(data)
            arr.sort(function(a, b) {
                return (b.timestamp || "").localeCompare(a.timestamp || "")
            })
            entries = arr
            revision++
            console.log("[TransactionStore] Synced", arr.length, "transactions")
        })
    }

    function syncFromFirebase() { _fetchFromFirebase() }

    // Drop in-memory state. Used on sign-out so the next user never briefly
    // sees the previous account's transactions before the next sync lands.
    function clear() {
        entries = []
        revision++
    }

    function _nextId(kind) {
        return "tx-" + kind + "-" + Date.now() + "-" + Math.floor(Math.random() * 1000)
    }

    function _push(doc) {
        var arr = (entries || []).slice()
        arr.unshift(doc)
        entries = arr
        revision++
        // Transactions are append-only ledger rows — route through the
        // compliance gateway so each one lands with an immutable audit_log
        // entry. In "direct" mode (pre-deploy) the gateway writes the doc
        // exactly as before.
        Gateway.recordMutation("transaction", doc.txId, "create", null, doc)
    }

    function recordPurchase(productId, quantity, unitCost, productName, party) {
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
            orderId: ""
        }
        _push(doc)
    }

    // Product-creation event. Always recorded for new products, even when
    // initial stock is 0 (qty: 0 row stays informational). Counts toward the
    // Purchased analytics bucket via bucketsFor(["purchase","created"], ...).
    function recordCreated(productId, productName, initialStockQty, unitCost, snapshot, party) {
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
        _push(doc)
    }

    // Single-field mutation. One row per changed field — keeps the product
    // history granular ("Selling: ₹100 → ₹150" stays a separate row from
    // "Description: old → new").
    function recordFieldChange(productId, productName, field, before, after) {
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
            orderId: ""
        }
        _push(doc)
    }

    // Direct stock edit through product details (distinct from restock).
    // before/after are absolute values; delta is the signed difference.
    function recordStockAdjustment(productId, productName, before, after) {
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
            orderId: ""
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
        for (var i = 0; i < order.products.length; ++i) {
            var p = order.products[i]
            var qty = p.quantity || p.qty || 0
            if (!qty) continue
            var inv = p.productId ? InventoryStore.getById(p.productId) : null
            var doc = {
                txId: _nextId("s"),
                kind: "sale",
                timestamp: iso,
                date: order.date || Qt.formatDate(new Date(), "yyyy-MM-dd"),
                productId: p.productId || "",
                productName: p.name || (inv ? inv.name : ""),
                quantity: qty,
                unitCost: inv ? (inv.price || 0) : 0,
                unitPrice: typeof p.price === "number" ? p.price : 0,
                total: qty * (typeof p.price === "number" ? p.price : 0),
                orderId: order.orderId || "",
                // Stamp channel + staff onto every sale doc so per-channel
                // and per-staff Analysis queries don't have to join back to
                // OrdersStore at read time. Empty strings indicate
                // "unspecified" — the Analysis page filters those out of
                // per-dimension breakdowns.
                orderChannel: order.orderChannel || "",
                staffId: order.staffId || "",
                consumption: Array.isArray(p.consumption) ? p.consumption.slice() : []
            }
            _push(doc)
        }
    }

    // Returns entries with timestamp (or date) inside [fromDate, toDate).
    function between(fromDate, toDate) {
        var out = []
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            var d = new Date(e.timestamp || e.date)
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
                if (!kindSet[e.kind]) continue
            } else if (kind && e.kind !== kind) {
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
            var dd = new Date(e.timestamp || e.date)
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
