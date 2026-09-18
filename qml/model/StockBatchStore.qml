pragma Singleton
import QtQuick
import QtCore

import "../helper/SettingsPath.js" as SettingsPath

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

    // Bounded-for-now collection (per design spec SS3.1 — full local data is
    // kept, since FIFO consumption/stock-value logic assumes the complete
    // set today). Fetches happen in <=_pageSize chunks via
    // FirebaseService.query() instead of one unbounded FirebaseService.get().
    // Ordered by __name__, not `receivedDate` -- the "!b.receivedDate"
    // fallback below is evidence some batches lack it, and Firestore's
    // orderBy silently EXCLUDES documents missing the ordered field from
    // query results. FIFO correctness doesn't depend on fetch order anyway:
    // forProduct() independently sorts by receivedDate on every call.
    readonly property int _pageSize: 50
    property bool hasMore: true
    property bool loadingMore: false

    // Set instead of the reset being silently dropped when _resetAndFetch()
    // arrives while a fetch is already in flight (see the guard below) --
    // e.g. a genuine account switch mid-sync. Consumed by _fetchFromFirebase's
    // callback the moment loadingMore goes back to false: that in-flight
    // fetch chain is abandoned (its result is for the stale tenant/account)
    // and a fresh _resetAndFetch() runs immediately instead. Design: SKILLS.md
    // Skill 39's "residual trade-off" note.
    property bool _resetPending: false
    property var _cursor: null

    // Only fetch here if tenant context is ALREADY known (lazy/warm
    // creation). On cold start with a persisted session this singleton could
    // otherwise be created before AuthStore.loadSession() has run, hitting
    // Firestore with an unscoped path and 403. Main.qml's
    // onTenantContextReady already re-syncs every store once tenant context
    // resolves — defer to that.
    Component.onCompleted: {
        if (AuthStore.tenantId.length > 0)
            _load()
        Gateway.mutationConflicted.connect(_onMutationConflicted)
        _loadPendingMints()
        AuthService.isOnlineChanged.connect(_onIsOnlineChanged)
        if (AuthService.isOnline) retryPendingMints()
    }

    // Component 3's client-side half (review finding C3, 2026-08-06) — see
    // OrdersStore._onMutationConflicted for the full explanation. Correction
    // (2026-08-26, backlog follow-up): this comment previously claimed
    // consumeFifo/topUpOldest/restoreFifo could hit this via "plain
    // recordMutation" on qtyRemaining — that no longer matches the code
    // (confirmed by reading the whole file): all three go through
    // Gateway.recordDelta now, whose atomic server-side floor/clamp makes a
    // CAS conflict structurally impossible there. The only recordMutation
    // call in this store is addBatch's "create" action — a genuine conflict
    // here means a duplicate-create attempt (e.g. two devices, or a retry
    // after a dropped response, minting the same batchId — see
    // tst_StockBatchStoreE2E.qml and CHECKPOINT.md for the concrete
    // scenario this was verified against). Reuses _normalizeBatches (same
    // as _load()).
    function _onMutationConflicted(entity, entityId, current) {
        if (entity !== "stock_batch") return
        var arr = batches.slice()
        var idx = -1
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].batchId === entityId) { idx = i; break }
        }
        if (current) {
            var normalized = _normalizeBatches([current])[0]
            if (idx >= 0) arr[idx] = normalized
            else arr.push(normalized)
        } else if (idx >= 0) {
            arr.splice(idx, 1)
        }
        batches = arr
        // Deliberately no Toast here, unlike the other four stores: batch
        // writes are an internal accounting side effect of an order/restock
        // action the user already got feedback on (or, for restoreFifo, of
        // a rollback that's itself invisible to begin with) — surfacing a
        // second, separate toast about the ledger row underneath that
        // action would be confusing rather than helpful. The cache still
        // gets reconciled; the user just isn't told about this specific
        // layer of it.
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    function _load() {
        _resetAndFetch()
    }

    function _resetAndFetch() {
        if (loadingMore) { _resetPending = true; return }
        batches = []
        hasMore = true
        _cursor = null
        _fetchFromFirebase()
    }

    // Legacy-data defaults for docs predating these fields — same "not a
    // reshaping risk" note as SupplierStore's _normalizeSuppliers: every
    // update function here builds before/after via Object.assign({}, b,
    // ...) off the raw `batches` array, not a whitelisting clone(). Keep
    // it that way (see OrdersStore's 2026-07-30 note for why it matters).
    function _normalizeBatches(arr) {
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
        return arr
    }

    function _fetchFromFirebase() {
        if (loadingMore) return
        loadingMore = true
        FirebaseService.query("stock_batches", { limit: _pageSize, startAfter: _cursor }, function(ok, result) {
            loadingMore = false
            if (_resetPending) {
                _resetPending = false
                _resetAndFetch()
                return
            }
            if (!ok || !result) {
                console.warn("[StockBatchStore] Firestore sync failed",
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
                return
            }
            batches = batches.concat(_normalizeBatches(result.items))
            hasMore = result.hasMore
            _cursor = result.nextCursor
            if (hasMore) {
                // Keep paging until Firestore reports no more pages, so
                // `batches` ends up complete either way -- just fetched in
                // bounded chunks instead of one unbounded request.
                _fetchFromFirebase()
            } else {
                console.log("[StockBatchStore] Synced", batches.length, "batches (all pages)")
            }
        })
    }

    function syncFromFirebase() { _resetAndFetch() }

    function clear() {
        batches = []
        revision++
    }

    // ── Identity helpers ───────────────────────────────────────────────────

    function _batchIdPrefixForYear(year) {
        return "BAT-" + year + "-"
    }

    function _seedBatchMaxForPrefix(prefix) {
        var max = 0
        for (var i = 0; i < batches.length; ++i) {
            var id = String(batches[i].batchId || "")
            if (id.indexOf(prefix) !== 0) continue
            var num = parseInt(id.substring(prefix.length))
            if (!isNaN(num) && num > max) max = num
        }
        return max
    }

    // Async — see FirebaseService.mintCounterValue for why max(existing)+1
    // isn't safe (id reuse after delete, concurrent-restock collisions --
    // this is exactly the gap docs/superpowers/E2E-TESTING-ROADMAP.md's
    // "no server-side counter" entry flagged). Mirrors
    // SupplierStore.nextSupplierId()/StaffStore.nextStaffId() exactly,
    // except the counter doc is keyed PER YEAR
    // ("counters/stockBatches-<year>"), not a single global counter --
    // BAT-<year>-NNN numbering resets every year by existing design (see
    // the id-format contract this preserves), and a single global counter
    // would silently break that. seedMax still floors the mint against
    // this year's highest LOCAL id, same purpose as nextSupplierId's seed:
    // covers the counter doc not existing yet (first deploy of this
    // feature, or first batch of a new year) without reissuing an id
    // that's already in local use.
    // 2026-09-14, on-device (Taher): with no timeout anywhere in
    // FirebaseService's underlying request path, a mint attempt that starts
    // right as connectivity drops can hang indefinitely rather than failing
    // -- which meant addBatch()'s failure branch (queue for retry, see
    // above) never even ran, because nothing ever called it back. Confirmed:
    // over a minute with the app left open, no batch, no retry -- not a
    // slow retry cycle, a genuine hang. Root cause is app-wide (no request
    // in this codebase has a timeout; see the roadmap's own item on this),
    // but fixing that broadly is out of scope for this session -- this is a
    // narrow, bounded safety net scoped to just the one call item 1's whole
    // retry-on-reconnect promise depends on, using the exact same pattern
    // AuthService._postJson already established for this same problem
    // elsewhere ("20s timeout fallback so a hung request never leaves the
    // UI silent"). Does NOT abort the underlying request (FirebaseService's
    // _request encapsulates its own XHR, not exposed here to abort) -- if it
    // eventually does resolve after this fires, `settled` just discards it.
    function nextBatchId(callback) {
        var year = new Date().getFullYear()
        var prefix = _batchIdPrefixForYear(year)
        var seedMax = _seedBatchMaxForPrefix(prefix)
        var settled = false
        var timeoutTimer = Qt.createQmlObject(
            'import QtQuick; Timer { interval: 15000; running: true; repeat: false }',
            root, "StockBatchStoreMintTimeoutTimer")
        timeoutTimer.triggered.connect(function() {
            if (settled) return
            settled = true
            timeoutTimer.destroy()
            console.warn("[StockBatchStore] batch-id mint timed out after 15s -- treating as failed")
            callback("")
        })
        FirebaseService.mintCounterValue("counters/stockBatches-" + year, seedMax, function(ok, value) {
            if (settled) return
            settled = true
            timeoutTimer.stop()
            timeoutTimer.destroy()
            callback(ok ? (prefix + String(value).padStart(3, '0')) : "")
        })
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

    // Shared doc shape for addBatch/addBatchWithId — `id` is always
    // ALREADY minted by the caller (addBatch mints its own via
    // nextBatchId; addBatchWithId is handed a pre-reserved one).
    function _buildBatchDoc(id, productId, supplierId, qty, unitCost, note) {
        var nowIso = new Date().toISOString()
        return {
            batchId: id,
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
    }

    // Record a new receipt, minting its own id (async — see nextBatchId).
    // callback (optional) fires with the created doc, or null if the input
    // was invalid or minting failed. `qty` and `unitCost` are immutable on
    // the doc (later FIFO consumption only touches `qtyRemaining`).
    //
    // deferWrite: when true, skips the individual Gateway.recordMutation
    // call but still performs the local `batches` update. NOT used by the
    // bulk-import loop any more (that needs ids reserved synchronously up
    // front, before the loop runs — see addBatchWithId); kept for callers
    // that mint their own id but want to batch the write with siblings via
    // addBatchMany (none currently do, preserved for parity with
    // addBatchWithId's identical parameter).
    function addBatch(productId, supplierId, qty, unitCost, note, deferWrite, callback) {
        if (!productId || !qty || qty <= 0) { if (callback) callback(null); return }
        nextBatchId(function(id) {
            if (!id) {
                // No error/warning surfaced beyond this log -- by design (see
                // docs/superpowers/E2E-TESTING-ROADMAP.md item 1, Decision 1).
                // Queued for automatic retry on reconnect instead of lost:
                // the product's own stock delta already landed by the time
                // this mint could fail, so silently dropping the batch here
                // would leave that stock permanently unbacked in the FIFO
                // ledger. hasPendingMint() lets order-entry screens hide this
                // product from the picker until the retry actually lands.
                console.warn("[StockBatchStore] could not mint a batchId — queued for retry on reconnect")
                _queuePendingMint(productId, supplierId, qty, unitCost, note)
                if (callback) callback(null)
                return
            }
            var doc = _buildBatchDoc(id, productId, supplierId, qty, unitCost, note)
            var arr = batches.slice()
            arr.push(doc)
            batches = arr
            if (!deferWrite) Gateway.recordMutation("stock_batch", doc.batchId, "create", null, doc)
            if (callback) callback(doc)
        })
    }

    // Creates a batch record with an ALREADY-MINTED id (skips nextBatchId's
    // network round-trip). Used by InventoryStore.upsertMany's bulk-import
    // loop, which reserves a whole range of batch ids in ONE round-trip up
    // front via FirebaseService.mintCounterBatch — exact mirror of
    // SupplierStore.addSupplierWithId. deferWrite: see addBatch's identical
    // parameter; the bulk-import loop passes true and collects the
    // returned docs for one addBatchMany() call instead of one write per
    // row.
    function addBatchWithId(id, productId, supplierId, qty, unitCost, note, deferWrite) {
        if (!id || !productId || !qty || qty <= 0) return null
        var doc = _buildBatchDoc(id, productId, supplierId, qty, unitCost, note)
        var arr = batches.slice()
        arr.push(doc)
        batches = arr
        if (!deferWrite) Gateway.recordMutation("stock_batch", doc.batchId, "create", null, doc)
        return doc
    }

    // ── Pending batch-id-mint retry queue ───────────────────────────────────
    // Durable (Settings-backed, survives a relaunch) record of addBatch()
    // calls whose nextBatchId() mint failed -- see addBatch() above. Design:
    // docs/superpowers/E2E-TESTING-ROADMAP.md item 1, Decision 1 (2026-09-14):
    // retry automatically on reconnect, no error/warning surfaced to the
    // user, but the affected product is hidden from order-entry pickers
    // (via hasPendingMint()) until the retry actually lands -- selling
    // against stock with no batch backing it is exactly the drift that Decision
    // 2's topUpOldest fix exists to make safe, but avoiding it in the first
    // place is strictly better than relying on that safety net.
    property var _pendingMints: []
    property var _pendingMintsInFlight: ({})

    property Settings _pendingMintSettings: Settings {
        category: "StockBatchStorePendingMints"
        // Same pattern as OutboxStore.qml's _settings -- see its comment for
        // why an explicit temp-file path is used under qmltestrunner.
        location: SettingsPath.settingsLocationOverride(
                      Application.organization,
                      StandardPaths.writableLocation(StandardPaths.TempLocation))
        property string pendingJson: ""
    }

    function _loadPendingMints() {
        if (_pendingMintSettings.pendingJson && _pendingMintSettings.pendingJson.length > 2) {
            try {
                var arr = JSON.parse(_pendingMintSettings.pendingJson)
                if (Array.isArray(arr)) _pendingMints = arr
            } catch (e) {
                _pendingMints = []
            }
        }
    }

    function _savePendingMints() {
        _pendingMintSettings.pendingJson = JSON.stringify(_pendingMints)
    }

    function _queuePendingMint(productId, supplierId, qty, unitCost, note) {
        var arr = _pendingMints.slice()
        arr.push({
            id: Date.now() + "_" + Math.floor(Math.random() * 1000000),
            productId: productId,
            supplierId: supplierId || "",
            qty: qty,
            unitCost: unitCost,
            note: note || ""
        })
        _pendingMints = arr
        _savePendingMints()
    }

    // Used by order-entry pickers (NewOrderDialog, OrderDetailDialog) to hide
    // a product until its pending batch actually lands -- see the header
    // comment above.
    function hasPendingMint(productId) {
        for (var i = 0; i < _pendingMints.length; ++i)
            if (_pendingMints[i].productId === productId) return true
        return false
    }

    // Called on reconnect (AuthService.isOnlineChanged, see
    // Component.onCompleted below) and defensively at startup in case the app
    // was relaunched while already online with items left over from a prior
    // session. Snapshots the list so an item added mid-retry (a fresh mint
    // failure arriving while this is running) isn't double-processed in the
    // same pass, and skips anything already in flight so overlapping
    // triggers (isOnline flapping true/false/true) can't retry the same item
    // twice concurrently.
    function retryPendingMints() {
        var snapshot = _pendingMints.slice()
        for (var i = 0; i < snapshot.length; ++i) {
            var item = snapshot[i]
            if (_pendingMintsInFlight[item.id]) continue
            _pendingMintsInFlight[item.id] = true
            _retryOnePendingMint(item)
        }
    }

    function _retryOnePendingMint(item) {
        nextBatchId(function(id) {
            delete _pendingMintsInFlight[item.id]
            if (!id) return   // still failing -- stays queued for next reconnect
            var doc = _buildBatchDoc(id, item.productId, item.supplierId, item.qty, item.unitCost, item.note)
            var arr = batches.slice()
            arr.push(doc)
            batches = arr
            Gateway.recordMutation("stock_batch", doc.batchId, "create", null, doc)
            // Remove by id, not index -- _pendingMints may have changed
            // (new failures queued, or a concurrent retry already removed a
            // different item) since this item's snapshot was taken.
            var next = []
            for (var j = 0; j < _pendingMints.length; ++j)
                if (_pendingMints[j].id !== item.id) next.push(_pendingMints[j])
            _pendingMints = next
            _savePendingMints()
        })
    }

    function _onIsOnlineChanged() {
        if (AuthService.isOnline) retryPendingMints()
    }

    // Companion to addBatchWithId(..., true) — fires ONE
    // Gateway.recordMutations() call for every doc collected across a
    // bulk-import loop, instead of one recordMutation() per row.
    function addBatchMany(docs) {
        if (!docs || docs.length === 0) return
        var mutationItems = []
        for (var i = 0; i < docs.length; ++i) {
            mutationItems.push({ entityId: docs[i].batchId, action: "create", before: null, after: docs[i] })
        }
        Gateway.recordMutations("stock_batch", mutationItems)
    }

    // FIFO walker — full async rewrite (review round 2, chosen over the
    // smaller mechanical-swap alternative specifically to close the
    // per-batch attribution race under concurrency, not just the CAS-clobber
    // risk). Selection stays client-side (walking local batches[] oldest-
    // first, deciding a take-per-batch plan) — that's business logic, not
    // something to push into the Cloud Function. Persistence per touched
    // batch is now Gateway.recordDelta with floors:{qtyRemaining:0}, NOT
    // clamps — floors reject the delta ENTIRELY if it would go negative
    // (ok:false, zero applied), where clamps would partially apply it. The
    // floor choice is deliberate: it means every successful delta took
    // EXACTLY `take` units, no ambiguity, so the consumption[] this returns
    // is always an exact record of what actually happened server-side, not
    // a locally-planned guess that might not match reality under a race.
    //
    // Processes batches ONE AT A TIME (not fired in parallel) so that if
    // batch[i]'s delta is rejected (someone else drained it since our last
    // read), we can extend further into the FIFO-ordered list to cover the
    // shortfall from batch[i+1] onward — a plan built once, up front, from a
    // single local snapshot can't do that. Real added latency for a multi-
    // batch consumption, accepted: a single order-line's FIFO span is
    // normally 1-2 batches, and this runs inside an already-async, already-
    // spinner-gated order-completion flow, not a hot loop.
    //
    // Calls back with { consumption, shortfall } — shortfall > 0 means
    // batches ran out (locally known ones exhausted, or drained faster than
    // planned) before qty was satisfied. Same contract as the old
    // synchronous "stops early" behavior, callers still repair via
    // topUpOldest + re-call, just from inside the callback now instead of
    // immediately after a synchronous return.
    function consumeFifo(productId, qty, callback) {
        if (!productId || !qty || qty <= 0) { callback({ consumption: [], shortfall: 0 }); return }
        var ordered = forProduct(productId)
        if (ordered.length === 0) { callback({ consumption: [], shortfall: qty }); return }

        var remaining = qty
        var consumption = []
        var idx = 0

        function _tryNext() {
            if (remaining <= 0 || idx >= ordered.length) {
                callback({ consumption: consumption, shortfall: remaining })
                return
            }
            var b = ordered[idx]
            idx++
            var avail = b.qtyRemaining || 0
            if (avail <= 0) { _tryNext(); return }
            var take = Math.min(avail, remaining)

            Gateway.recordDelta("stock_batch", b.batchId, { qtyRemaining: -take }, { qtyRemaining: 0 }, {},
                function(result) {
                    if (result && result.ok) {
                        var updated = Object.assign({}, b, {
                            qtyRemaining: result.after.qtyRemaining,
                            updatedAt: new Date().toISOString()
                        })
                        var arr = []
                        for (var k = 0; k < batches.length; ++k)
                            arr.push(batches[k].batchId === b.batchId ? updated : batches[k])
                        batches = arr
                        consumption.push({
                            batchId: b.batchId,
                            supplierId: b.supplierId || "",
                            qtyConsumed: take,
                            unitCost: b.unitCost || 0
                        })
                        remaining -= take
                    } else if (result && result.current !== undefined) {
                        // Rejected — floor would've gone negative, someone
                        // else drained this batch since our last read. Zero
                        // units taken from here. Reconcile the stale local
                        // copy with the server's answer so a subsequent
                        // consumeFifo call isn't planning off the same
                        // stale number, then move on to the next batch for
                        // the shortfall.
                        var reconciled = Object.assign({}, b, { qtyRemaining: result.current })
                        var arr2 = []
                        for (var k2 = 0; k2 < batches.length; ++k2)
                            arr2.push(batches[k2].batchId === b.batchId ? reconciled : batches[k2])
                        batches = arr2
                    }
                    // Any other failure (network, non-insufficient-quantity
                    // error) also falls through to "zero taken, try next" —
                    // matches this module's own stated design goal (see
                    // topUpOldest's doc comment): a sale should never fail
                    // because the batch ledger had trouble, only because
                    // there genuinely isn't enough stock.
                    _tryNext()
                })
        }
        _tryNext()
    }

    // Invariant repair. When `product.stock` says there are N units but the
    // batches sum to less, top up the most recent batch (or create a synthetic
    // one) so the next consumeFifo call can satisfy the request.
    //
    // This is deliberately permissive: we never want a sale to fail because
    // the batch ledger drifted. Manual edits to product.stock, imports, or
    // legacy data are the typical causes -- now also a batch-id mint that
    // failed and hasn't retried yet (Decision 1, same roadmap entry).
    //
    // callback is optional — fires once the top-up is confirmed (or
    // immediately, synchronously, for the create-a-synthetic-batch path,
    // which goes through addBatch's existing fire-and-forget create — a
    // create has no CAS/attribution concern the way an existing-doc delta
    // does, so it wasn't part of this round's async rewrite).
    //
    // 2026-09-14: ALWAYS synthesizes a new, clearly-labeled batch now --
    // previously this only happened when zero batches existed; when at least
    // one did, the code instead applied an additive delta directly onto the
    // newest existing batch's qtyReceived/qtyRemaining, silently rewriting
    // its received history. Confirmed on-device (see
    // docs/superpowers/E2E-TESTING-ROADMAP.md item 1): the topped-up units
    // inherited that batch's unitCost/supplierId instead of reflecting an
    // unknown/unrecorded source honestly -- a restock at a different price
    // or supplier would silently corrupt COGS/attribution for those units.
    // A new synthetic batch costs nothing extra to create (addBatch is the
    // same call either way) and never touches another batch's own history.
    function topUpOldest(productId, deficit, callback) {
        if (!productId || !deficit || deficit <= 0) { if (callback) callback(); return }
        // addBatch is async now (mints its own id) — chain callback() off
        // ITS callback rather than firing immediately, so a caller waiting
        // on topUpOldest's callback doesn't get told "done" before the
        // synthetic batch's id-mint round-trip finishes.
        addBatch(productId, "", deficit, 0, "Adjustment (drift repair)", false, function(doc) {
            if (callback) callback()
        })
    }

    // Inverse of consumeFifo: credit `qty` back onto a specific batch (used when
    // a completed-order line is returned and the units go back to sellable
    // stock). The batch is found by id — batches are never deleted, only zeroed,
    // so a fully-consumed batch is still present and gets its qtyRemaining
    // restored. If the batch id can't be found (rare: ledger drift), fall back to
    // topUpOldest so stock isn't silently lost.
    //
    // callback is optional. Every existing call site (C5's order-completion
    // rollback, the partial-multi-line-completion fix, the returns flow) is a
    // fire-and-forget best-effort repair that doesn't gate a user-facing
    // decision the way consumeFifo's forward path does — no floor risk
    // either (a restore is purely additive), so there's no correctness
    // reason to make every rollback loop await each call before firing the
    // next. Kept firing all N "in parallel" (immediately, one after another
    // without waiting), same as before this round's rewrite.
    function restoreFifo(batchId, productId, qty, callback) {
        if (!qty || qty <= 0) { if (callback) callback(); return }
        var b = getById(batchId)
        if (!b) {
            if (productId) topUpOldest(productId, qty, callback)
            else if (callback) callback()
            return
        }
        Gateway.recordDelta("stock_batch", batchId, { qtyRemaining: qty }, {}, {},
            function(result) {
                if (result && result.ok) {
                    var updated = Object.assign({}, b, {
                        qtyRemaining: result.after.qtyRemaining,
                        updatedAt: new Date().toISOString()
                    })
                    var next = []
                    for (var i = 0; i < batches.length; ++i)
                        next.push(batches[i].batchId === batchId ? updated : batches[i])
                    batches = next
                }
                if (callback) callback()
            })
    }
}
