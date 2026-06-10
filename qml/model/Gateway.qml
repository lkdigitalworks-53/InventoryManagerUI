pragma Singleton
import QtQuick

// Compliance gateway client (P0). Single entry point for every books-of-
// account mutation in P0 scope (inventory + stock). Stores call
// `recordMutation(...)` instead of writing Firestore directly.
//
// Two modes (so the app keeps working before the Cloud Function is
// deployed):
//   "direct"  — DEFAULT. Writes the working-tier doc via FirebaseService,
//               exactly as the stores did before P0. No ledger entry. This
//               is behaviour-preserving: nothing changes until you deploy.
//   "gateway" — Enqueues the call in the durable OutboxStore and POSTs it to
//               the recordMutation Cloud Function (Bearer idToken), which
//               atomically writes the working doc + an immutable audit_log
//               entry. Failed/offline calls stay queued and retry w/ backoff.
//
// Flip `mode` to "gateway" only after `functions/` is deployed and the
// locked Firestore rules are live.
QtObject {
    id: root

    // "direct" until the Cloud Function + locked rules are deployed.
    property string mode: "direct"

    // recordMutation HTTPS endpoint (Gen-2 onRequest, asia-southeast1).
    property string functionUrl: "https://asia-southeast1-inventorymanager-48392.cloudfunctions.net/recordMutation"
    // One-time fresh-start cutover endpoint (owner-only, server-side wipe).
    property string cutoverUrl: "https://asia-southeast1-inventorymanager-48392.cloudfunctions.net/runCutover"

    signal cutoverFinished(bool ok, string error)

    property int inFlight: 0

    // entity → working-tier collection. Mirrors ENTITY_COLLECTIONS in
    // functions/index.js; the two MUST stay in sync.
    readonly property var _collections: ({
        "inventory": "inventory",
        "stock_batch": "stock_batches",
        "stock_movement": "stock_movements",
        "transaction": "transactions"
    })

    property var _drainTimer: null

    function _collectionFor(entity) { return _collections[entity] || "" }

    function _nextRequestId() {
        return "req-" + Date.now() + "-" + Math.floor(Math.random() * 1000000)
    }

    // The one call every store makes. `after` is the full post-mutation doc
    // (or null for deletes); `before` is the pre-mutation snapshot (or null
    // for creates). Returns the requestId so callers can correlate if needed.
    function recordMutation(entity, entityId, action, before, after) {
        var collection = _collectionFor(entity)
        if (!collection || !entityId) {
            console.warn("[Gateway] recordMutation: bad entity/id", entity, entityId)
            return ""
        }
        var requestId = _nextRequestId()

        if (mode === "direct") {
            _writeDirect(collection, entityId, action, after)
            return requestId
        }

        OutboxStore.enqueue({
            requestId: requestId,
            entity: entity,
            entityId: entityId,
            action: action,
            before: before === undefined ? null : before,
            after: after === undefined ? null : after,
            clientTimestamp: new Date().toISOString()
        })
        drainNow()
        return requestId
    }

    // ── direct mode (pre-deploy, behaviour-preserving) ──────────────────────

    function _writeDirect(collection, entityId, action, after) {
        var path = collection + "/" + entityId
        if (action === "delete") {
            FirebaseService.remove(path, function(ok) {
                if (!ok) console.warn("[Gateway:direct] delete failed", path)
            })
            return
        }
        FirebaseService.put(path, after || {}, function(ok) {
            if (!ok) console.warn("[Gateway:direct] write failed", path)
        })
    }

    // ── gateway mode (post-deploy) ──────────────────────────────────────────

    // Send every due outbox item, then reschedule the retry timer for the
    // next-due item. Safe to call repeatedly (start, connectivity regain,
    // timer tick, after each enqueue).
    function drainNow() {
        if (mode !== "gateway") return
        if (typeof AuthService !== "undefined" && AuthService)
            AuthService.ensureFreshToken()

        var due = OutboxStore.dueItems()
        for (var i = 0; i < due.length; ++i)
            _send(due[i])

        _reschedule()
    }

    function _reschedule() {
        if (!_drainTimer) {
            _drainTimer = Qt.createQmlObject(
                'import QtQuick; Timer { repeat: false }', root, "GatewayDrainTimer")
            _drainTimer.triggered.connect(_onDrainTick)
        }
        var due = OutboxStore.nextDueInMs()
        if (due < 0) { _drainTimer.stop(); return }
        _drainTimer.interval = Math.max(250, due)
        _drainTimer.restart()
    }

    // Retry-timer tick — re-drains due outbox items and reschedules.
    function _onDrainTick() { drainNow() }

    function _send(item) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            // Not signed in yet — leave queued; drain again after auth.
            return
        }
        inFlight++
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            inFlight--
            var ok = xhr.status >= 200 && xhr.status < 300
            if (ok) {
                OutboxStore.markSent(item.requestId)
            } else {
                console.warn("[Gateway] recordMutation failed", xhr.status,
                             item.entity, item.entityId, xhr.responseText)
                OutboxStore.markFailed(item.requestId)
            }
            _reschedule()
        }
        xhr.open("POST", functionUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.send(JSON.stringify({
            entity: item.entity,
            entityId: item.entityId,
            action: item.action,
            before: item.before,
            after: item.after,
            requestId: item.requestId,
            clientTimestamp: item.clientTimestamp
        }))
    }

    // ── Fresh-start cutover (owner-only, irreversible) ──────────────────────
    // Calls the server to wipe the ledger collections + zero product stock.
    // Emits cutoverFinished(ok, error). After success, callers should re-sync
    // the stores (InventoryStore/StockBatchStore/TransactionStore.syncFromFirebase).
    function runCutover() {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            cutoverFinished(false, qsTr("Not signed in"))
            return
        }
        if (AuthStore.role !== "owner") {
            cutoverFinished(false, qsTr("Only the workspace owner can run cutover"))
            return
        }
        if (typeof AuthService !== "undefined" && AuthService)
            AuthService.ensureFreshToken()

        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var ok = xhr.status >= 200 && xhr.status < 300
            if (ok) {
                cutoverFinished(true, "")
            } else {
                console.warn("[Gateway] cutover failed", xhr.status, xhr.responseText)
                cutoverFinished(false, "HTTP " + xhr.status)
            }
        }
        xhr.open("POST", cutoverUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.send(JSON.stringify({ confirm: "CUTOVER", clientTimestamp: new Date().toISOString() }))
    }

    function clear() {
        OutboxStore.clear()
        if (_drainTimer) _drainTimer.stop()
    }
}
