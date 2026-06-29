pragma Singleton
import QtQuick

// FIFO inventory cost ledger. Each row in `stock_batches/{batchId}` is one
// receipt of goods — typically created when the user restocks a product
// (or on initial product creation when stock > 0). Sales consume batches
// in receivedDate order (oldest first), decrementing `qtyRemaining` on
// each touched batch.
//
// Why a separate store: per-supplier qty-sold / revenue / margin reports
// require lineage from each sold unit back to the receipt event. With a
// pooled stock count this question is mathematically unanswerable — every
// industry-standard inventory system (NetSuite, Zoho, QuickBooks Enterprise,
// SAP B1, Tally) solves it by tracking lots/batches as a separate table.
//
// Document shape:
//   { batchId, productId, supplierId, qtyReceived, qtyRemaining,
//     unitCost, receivedDate, poId, note, createdAt, updatedAt }
//
// `product.stock` (on the inventory document) remains the validation source
// of truth for order-completion. If batches drift below product.stock,
// `topUpOldest` repairs the invariant rather than failing the sale.
QtObject {
    id: root

    property var batches: []
    property int revision: 0
    onBatchesChanged: revision++

    Component.onCompleted: _load()

    // ── Lifecycle ──────────────────────────────────────────────────────────

    function _load() {
        batches = []
        _fetchFromFirebase()
    }

    function _fetchFromFirebase() {
        FirebaseService.get("stock_batches", function(ok, data) {
            if (!ok) {
                console.warn("[StockBatchStore] Firestore sync failed",
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
                return
            }
            var arr = FirebaseService.toArray(data)
            for (var i = 0; i < arr.length; ++i) {
                var b = arr[i]
                if (!b.batchId) b.batchId = b.id || ""
                if (!b.productId) b.productId = ""
                if (!b.supplierId) b.supplierId = ""
                if (b.qtyReceived === undefined || b.qtyReceived === null) b.qtyReceived = 0
                if (b.qtyRemaining === undefined || b.qtyRemaining === null) b.qtyRemaining = b.qtyReceived
                if (b.unitCost === undefined || b.unitCost === null) b.unitCost = 0
                if (!b.receivedDate) b.receivedDate = b.createdAt || ""
                if (!b.poId) b.poId = ""
                if (!b.note) b.note = ""
            }
            batches = arr
            console.log("[StockBatchStore] Synced", arr.length, "batches")
        })
    }

    function syncFromFirebase() { _fetchFromFirebase() }

    function clear() {
        batches = []
        revision++
    }

    // ── Identity helpers ───────────────────────────────────────────────────

    function _nextBatchId() {
        // BAT-yyyy-NNN where NNN is monotonic across the whole year. Easier
        // to scan than a pure timestamp suffix and avoids id collisions when
        // two restocks happen within the same millisecond.
        var year = new Date().getFullYear()
        var prefix = "BAT-" + year + "-"
        var max = 0
        for (var i = 0; i < batches.length; ++i) {
            var id = String(batches[i].batchId || "")
            if (id.indexOf(prefix) !== 0) continue
            var num = parseInt(id.substring(prefix.length))
            if (!isNaN(num) && num > max) max = num
        }
        return prefix + String(max + 1).padStart(3, '0')
    }

    function getById(batchId) {
        if (!batchId) return null
        for (var i = 0; i < batches.length; ++i)
            if (batches[i].batchId === batchId) return batches[i]
        return null
    }

    // All batches for a product, oldest first. Used by the order-completion
    // FIFO walker AND the EditProductDialog history list.
    function forProduct(productId) {
        if (!productId) return []
        var out = []
        for (var i = 0; i < batches.length; ++i)
            if (batches[i].productId === productId) out.push(batches[i])
        out.sort(function(a, b) {
            return (a.receivedDate || "").localeCompare(b.receivedDate || "")
        })
        return out
    }

    // Sum of qtyRemaining across every batch for a product. Used to detect
    // drift between batches and product.stock.
    function remainingFor(productId) {
        var sum = 0
        for (var i = 0; i < batches.length; ++i)
            if (batches[i].productId === productId)
                sum += (batches[i].qtyRemaining || 0)
        return sum
    }

    // ── Mutations ──────────────────────────────────────────────────────────

    // Record a new receipt. `qty` and `unitCost` are immutable on the doc
    // (later FIFO consumption only touches `qtyRemaining`). Returns the
    // batch document including its generated id.
    function addBatch(productId, supplierId, qty, unitCost, note) {
        if (!productId || !qty || qty <= 0) return null
        var nowIso = new Date().toISOString()
        var doc = {
            batchId: _nextBatchId(),
            productId: productId,
            supplierId: supplierId || "",
            qtyReceived: qty,
            qtyRemaining: qty,
            unitCost: typeof unitCost === "number" ? unitCost : (parseFloat(unitCost) || 0),
            receivedDate: nowIso,
            poId: "",
            note: note || "",
            createdAt: nowIso,
            updatedAt: nowIso
        }
        var arr = batches.slice()
        arr.push(doc)
        batches = arr
        Gateway.recordMutation("stock_batch", doc.batchId, "create", null, doc)
        return doc
    }

    // FIFO walker. Decrements qtyRemaining on the oldest batches until the
    // requested qty is satisfied (or batches run out). Returns the list of
    // touched batches as `[{ batchId, supplierId, qtyConsumed, unitCost }]`
    // so callers can stamp the consumption onto an order line / sale event.
    //
    // Stops early when batches are exhausted — caller is expected to repair
    // the invariant via `topUpOldest` and re-call. Validation (does the
    // product even have enough total stock?) lives in DataModel; this
    // function trusts the caller and just accounts.
    function consumeFifo(productId, qty) {
        if (!productId || !qty || qty <= 0) return []
        var ordered = forProduct(productId)
        if (ordered.length === 0) return []

        var remaining = qty
        var consumption = []
        var touched = []
        var touchedBefore = []   // pre-consumption snapshot, index-aligned with `touched`
        for (var i = 0; i < ordered.length && remaining > 0; ++i) {
            var b = ordered[i]
            var avail = b.qtyRemaining || 0
            if (avail <= 0) continue
            var take = Math.min(avail, remaining)
            var updated = Object.assign({}, b, {
                qtyRemaining: avail - take,
                updatedAt: new Date().toISOString()
            })
            touched.push(updated)
            touchedBefore.push(Object.assign({}, b))
            consumption.push({
                batchId: b.batchId,
                supplierId: b.supplierId || "",
                qtyConsumed: take,
                unitCost: b.unitCost || 0
            })
            remaining -= take
        }

        // Apply touched updates back to the local array in one swap so the
        // `revision` bump fires once per call rather than per batch.
        if (touched.length > 0) {
            var touchedById = {}
            for (var t = 0; t < touched.length; ++t) touchedById[touched[t].batchId] = touched[t]
            var next = []
            for (var j = 0; j < batches.length; ++j) {
                var current = batches[j]
                next.push(touchedById[current.batchId] || current)
            }
            batches = next
            // Each FIFO decrement is an auditable update — route through the
            // gateway with before/after so the consumption is traceable.
            for (var u = 0; u < touched.length; ++u) {
                Gateway.recordMutation("stock_batch", touched[u].batchId, "update",
                                       touchedBefore[u], touched[u])
            }
        }
        return consumption
    }

    // Invariant repair. When `product.stock` says there are N units but the
    // batches sum to less, top up the most recent batch (or create a synthetic
    // one) so the next consumeFifo call can satisfy the request.
    //
    // This is deliberately permissive: we never want a sale to fail because
    // the batch ledger drifted. Manual edits to product.stock, imports, or
    // legacy data are the typical causes.
    function topUpOldest(productId, deficit) {
        if (!productId || !deficit || deficit <= 0) return
        var ordered = forProduct(productId)
        if (ordered.length === 0) {
            // No batches at all — synthesize one labelled "Adjustment".
            addBatch(productId, "", deficit, 0, "Adjustment (drift repair)")
            return
        }
        // Top up the newest batch — assumption: drift came from an unrecorded
        // restock or import, and the most recent supplier is the best guess.
        var newest = ordered[ordered.length - 1]
        var before = Object.assign({}, newest)
        var updated = Object.assign({}, newest, {
            qtyReceived: (newest.qtyReceived || 0) + deficit,
            qtyRemaining: (newest.qtyRemaining || 0) + deficit,
            updatedAt: new Date().toISOString(),
            note: (newest.note ? newest.note + " · " : "") + "drift +" + deficit
        })
        var next = []
        for (var i = 0; i < batches.length; ++i)
            next.push(batches[i].batchId === updated.batchId ? updated : batches[i])
        batches = next
        Gateway.recordMutation("stock_batch", updated.batchId, "update", before, updated)
        console.warn("[StockBatchStore] Topped up batch", updated.batchId, "by", deficit,
                     "to repair drift on product", productId)
    }

    // Inverse of consumeFifo: credit `qty` back onto a specific batch (used when
    // a completed-order line is returned and the units go back to sellable
    // stock). The batch is found by id — batches are never deleted, only zeroed,
    // so a fully-consumed batch is still present and gets its qtyRemaining
    // restored. If the batch id can't be found (rare: ledger drift), fall back to
    // topUpOldest so stock isn't silently lost.
    function restoreFifo(batchId, productId, qty) {
        if (!qty || qty <= 0) return
        var b = getById(batchId)
        if (!b) {
            if (productId) topUpOldest(productId, qty)
            return
        }
        var before = Object.assign({}, b)
        var updated = Object.assign({}, b, {
            qtyRemaining: (b.qtyRemaining || 0) + qty,
            updatedAt: new Date().toISOString()
        })
        var next = []
        for (var i = 0; i < batches.length; ++i)
            next.push(batches[i].batchId === batchId ? updated : batches[i])
        batches = next
        Gateway.recordMutation("stock_batch", batchId, "update", before, updated)
    }
}
