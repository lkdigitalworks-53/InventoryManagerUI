pragma Singleton
import QtQuick

// One-shot backfill that runs once per tenant after the FIFO model lands.
// Synthesises supplier records from existing PartyStore names and stock
// batches from existing purchase/created transactions, so users who already
// had data don't see empty Analysis charts after the upgrade.
//
// Idempotency: a tenant-level flag doc lives at
// `_migrations/fifo_v1` (Firestore path resolved through tenant scoping)
// with `{ done: true, completedAt }`. We refuse to re-run when that doc
// reports done=true.
//
// Trigger: `Main.qml` calls `MigrationService.runIfNeeded()` after
// `tenantContextReady`, once the four prerequisite stores have synced.
QtObject {
    id: root

    property bool busy: false
    property bool _completed: false

    // ── Public API ─────────────────────────────────────────────────────────

    function runIfNeeded() {
        if (busy || _completed) return
        if (!AuthStore || !AuthStore.tenantId) return   // no tenant yet
        busy = true
        FirebaseService.get("_migrations/fifo_v1", function(ok, data) {
            if (ok && data && data.done) {
                _completed = true
                busy = false
                console.log("[Migration] fifo_v1 already done — skipping")
                return
            }
            _runBackfill()
        })
    }

    // ── Backfill steps ─────────────────────────────────────────────────────

    function _runBackfill() {
        // Step 1: promote every PartyStore name into a Supplier document.
        // The store dedupes by name so an idempotent re-run is safe.
        var partyNames = PartyStore.parties || []
        var nameToId = {}
        for (var i = 0; i < partyNames.length; ++i) {
            var existing = SupplierStore.findByName(partyNames[i])
            if (existing) {
                nameToId[partyNames[i]] = existing.supplierId
                continue
            }
            var s = SupplierStore.addSupplier({ name: partyNames[i] })
            if (s) nameToId[partyNames[i]] = s.supplierId
        }

        // Step 2: synthesise batches from purchase/created tx events. These
        // events already carry supplierId (newer writes) OR a supplier name
        // in `e.party` / `snapshot.party` (legacy writes). We resolve to
        // an id either way.
        //
        // Distribution rule: walk events oldest → newest per product, stamp
        // qtyReceived from the event qty. Then assign qtyRemaining so the
        // total per product equals product.stock — meaning the live stock
        // gets attributed to the most recent batches (LIFO of the stock
        // remaining), and older batches are treated as fully consumed by
        // pre-FIFO sales.
        var entries = (TransactionStore.entries || []).slice()
        // Walk oldest → newest.
        entries.sort(function(a, b) {
            return (a.timestamp || "").localeCompare(b.timestamp || "")
        })
        var batchesByProduct = {}
        for (var k = 0; k < entries.length; ++k) {
            var e = entries[k]
            if (e.kind !== "purchase" && e.kind !== "created") continue
            var pid = e.productId
            if (!pid) continue
            var supId = e.party
                    || (e.snapshot ? e.snapshot.supplierId || e.snapshot.party || "" : "")
                    || ""
            // If we got a name string, map to an id; otherwise leave as-is.
            if (supId && supId.indexOf("SUP-") !== 0) {
                supId = nameToId[supId] || ""
            }
            if (!batchesByProduct[pid]) batchesByProduct[pid] = []
            batchesByProduct[pid].push({
                supplierId: supId,
                qty: e.quantity || 0,
                unitCost: e.unitCost || 0,
                receivedDate: e.timestamp || e.date || new Date().toISOString(),
                note: "Backfilled (" + e.kind + ")"
            })
        }

        // Step 3: for each product, allocate live stock back-to-front so the
        // newest batches carry the qtyRemaining and older batches sit at 0.
        var products = InventoryStore.products || []
        for (var pi = 0; pi < products.length; ++pi) {
            var p = products[pi]
            var batches = batchesByProduct[p.productId] || []
            // No prior batches but the product has stock? Synthesise a single
            // catch-all batch so analytics has something to consume from.
            if (batches.length === 0 && (p.stock || 0) > 0) {
                StockBatchStore.addBatch(p.productId, "", p.stock, p.price || 0,
                                         "Backfilled (legacy stock)")
                continue
            }
            // Walk newest → oldest, claim qtyRemaining from `live` until the
            // remaining stock budget is exhausted.
            var live = p.stock || 0
            for (var bi = batches.length - 1; bi >= 0; --bi) {
                var b = batches[bi]
                var claim = Math.min(b.qty, live)
                b.qtyRemaining = claim
                live -= claim
            }
            // Issue the writes in oldest → newest order so receivedDate
            // ordering still gives the same FIFO behaviour going forward.
            for (var bi2 = 0; bi2 < batches.length; ++bi2) {
                var bb = batches[bi2]
                _writeBatch(p.productId, bb)
            }
        }

        // Step 4: stamp the completion flag so we never run again.
        var nowIso = new Date().toISOString()
        FirebaseService.put("_migrations/fifo_v1", { done: true, completedAt: nowIso }, function(ok) {
            if (ok) console.log("[Migration] fifo_v1 backfill complete at", nowIso)
            else console.warn("[Migration] fifo_v1 flag write failed — will retry next launch")
            _completed = ok
            busy = false
        })
    }

    // Write one synthesised batch through StockBatchStore, but using a custom
    // path so we can preserve the historical receivedDate (the public API
    // stamps `new Date()`). This keeps the FIFO order matching what actually
    // happened rather than backfill-time.
    function _writeBatch(productId, b) {
        var nowIso = new Date().toISOString()
        // We can't reach the store's private nextBatchId from here, so we
        // mint our own deterministic id keyed on the receivedDate. That
        // also makes the migration idempotent: re-running produces the same
        // batchId for the same source event.
        var stamp = (b.receivedDate || nowIso).replace(/[^0-9]/g, '').substring(0, 14)
        var batchId = "BAT-MIG-" + productId + "-" + stamp
        var doc = {
            batchId: batchId,
            productId: productId,
            supplierId: b.supplierId || "",
            qtyReceived: b.qty || 0,
            qtyRemaining: b.qtyRemaining || 0,
            unitCost: b.unitCost || 0,
            receivedDate: b.receivedDate || nowIso,
            poId: "",
            note: b.note || "",
            createdAt: nowIso,
            updatedAt: nowIso
        }
        // Write via FirebaseService directly so the date isn't bumped, and
        // append to the in-memory list so the UI sees it without a re-fetch.
        var arr = (StockBatchStore.batches || []).slice()
        arr.push(doc)
        StockBatchStore.batches = arr
        FirebaseService.put("stock_batches/" + batchId, doc, function(ok) {
            if (!ok) console.warn("[Migration] batch write failed for", batchId)
        })
    }
}
