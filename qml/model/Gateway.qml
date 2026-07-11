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

    // Member/staff credential provisioning needs the Admin-SDK Cloud Function
    // (provisionMember) — it CANNOT fall back to a direct client write, because
    // Firestore rules forbid a client writing another user's users/{uid} doc.
    // The function is only reachable once deployed on a Blaze plan. Until then,
    // keep this false: provisionMember() short-circuits with a clear
    // "provisioning-unavailable" code instead of firing a request that 404s and
    // surfacing a misleading hard error. Flip to true the day functions/ is
    // deployed and provisioning starts working.
    property bool provisioningAvailable: false

    // recordMutation HTTPS endpoint (Gen-2 onRequest, asia-south1).
    property string functionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"
    // Batch counterpart of recordMutation (new this session) — one atomic
    // transaction for up to MAX_BATCH_SIZE items of the same entity, e.g.
    // OrdersStore.approveAllPending. See functions/lib/batchMutationLogic.js.
    property string batchFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutationsBatch"
    // One-time fresh-start cutover endpoint (owner-only, server-side wipe).
    property string cutoverUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/runCutover"
    // Member provisioning endpoint (Admin SDK; owner/admin only). Adds a
    // teammate to the caller's tenant — creates the Auth account for a new
    // staff member, or attaches an existing account, writing both users/{uid}
    // and the member doc server-side (the client can't write another user's
    // profile under the Firestore rules).
    property string provisionMemberUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/provisionMember"

    signal cutoverFinished(bool ok, string error)

    property int inFlight: 0

    // entity → working-tier collection. Mirrors ENTITY_COLLECTIONS in
    // functions/index.js; the two MUST stay in sync.
    readonly property var _collections: ({
        "inventory": "inventory",
        "stock_batch": "stock_batches",
        "stock_movement": "stock_movements",
        "transaction": "transactions",
        "order": "orders",
        "staff": "staff"
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

    // Batch counterpart of recordMutation — one call for many items of the
    // SAME entity, e.g. OrdersStore.approveAllPending. `items` is
    // [{entityId, action, before, after}, ...]. Returns the batch requestId.
    function recordMutations(entity, items) {
        var collection = _collectionFor(entity)
        if (!collection || !items || items.length === 0) {
            console.warn("[Gateway] recordMutations: bad entity/items", entity)
            return ""
        }
        var requestId = _nextRequestId()
        var normalized = []
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            normalized.push({
                entityId: it.entityId,
                action: it.action,
                before: it.before === undefined ? null : it.before,
                after: it.after === undefined ? null : it.after
            })
        }

        if (mode === "direct") {
            _writeDirectBatch(collection, normalized)
            return requestId
        }

        OutboxStore.enqueueBatch({
            requestId: requestId,
            entity: entity,
            items: normalized,
            clientTimestamp: new Date().toISOString()
        })
        drainNow()
        return requestId
    }

    // direct-mode fallback for recordMutations — preserves today's single
    // putMany-per-batch performance for creates/updates; deletes (which
    // putMany has no form for) go one call each, same as _writeDirect.
    function _writeDirectBatch(collection, items) {
        var docsById = {}
        var deleteIds = []
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (it.action === "delete") {
                deleteIds.push(it.entityId)
            } else {
                docsById[it.entityId] = it.after || {}
            }
        }
        if (Object.keys(docsById).length > 0) {
            FirebaseService.putMany(collection, docsById, function(ok) {
                if (!ok) console.warn("[Gateway:direct] batch write failed", collection)
            })
        }
        for (var j = 0; j < deleteIds.length; ++j) {
            FirebaseService.remove(collection + "/" + deleteIds[j], function(ok) {
                if (!ok) console.warn("[Gateway:direct] batch delete failed", collection, deleteIds[j])
            })
        }
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
        for (var i = 0; i < due.length; ++i) {
            if (Array.isArray(due[i].items)) _sendBatch(due[i])
            else _send(due[i])
        }

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
            // Tells the Cloud Function which per-env Firestore database to
            // read/write (Skill 30) -- pulled fresh at send time (not stored
            // on the outbox item), since it's a build-time constant anyway.
            env: FirebaseService.environment,
            entity: item.entity,
            entityId: item.entityId,
            action: item.action,
            before: item.before,
            after: item.after,
            requestId: item.requestId,
            clientTimestamp: item.clientTimestamp
        }))
    }

    // Batch counterpart of _send — one outbox item, one HTTP call, whatever
    // its `items` count. Same success/failure/backoff handling as _send.
    function _sendBatch(item) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
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
                console.warn("[Gateway] recordMutationsBatch failed", xhr.status,
                             item.entity, item.items.length, xhr.responseText)
                OutboxStore.markFailed(item.requestId)
            }
            _reschedule()
        }
        xhr.open("POST", batchFunctionUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.send(JSON.stringify({
            env: FirebaseService.environment,
            entity: item.entity,
            requestId: item.requestId,
            items: item.items,
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
        xhr.send(JSON.stringify({
            env: FirebaseService.environment,
            confirm: "CUTOVER",
            clientTimestamp: new Date().toISOString()
        }))
    }

    // ── Member provisioning (owner/admin only) ──────────────────────────────
    // POST a provision request to the Admin-SDK function. `payload` carries
    // { email, displayName, password?, uid?, role }. `callback(ok, data)` gets
    // the parsed JSON ({ ok, uid, created, error }) so the caller can react to
    // recoverable cases (e.g. error === "password-required"). The function
    // derives the caller's tenant + role from the verified token, so we send
    // only the target details — never the tenant or actor role.
    function provisionMember(payload, callback) {
        if (!provisioningAvailable) {
            // No deployed Cloud Function (pre-Blaze). Don't fire a request that
            // 404s — report a recoverable code the caller turns into a friendly
            // "login access coming once the server is set up" notice.
            if (callback) callback(false, { ok: false, error: "provisioning-unavailable" })
            return
        }
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            if (callback) callback(false, { ok: false, error: "not-signed-in" })
            return
        }
        if (typeof AuthService !== "undefined" && AuthService)
            AuthService.ensureFreshToken()

        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var ok = xhr.status >= 200 && xhr.status < 300
            var data = null
            try { data = JSON.parse(xhr.responseText) } catch (e) { data = null }
            if (!ok)
                console.warn("[Gateway] provisionMember failed", xhr.status, xhr.responseText)
            if (callback) callback(ok, data)
        }
        xhr.open("POST", provisionMemberUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        // Merge, don't mutate -- payload is the caller's (AuthService.qml)
        // object, which it may reuse across calls.
        xhr.send(JSON.stringify(Object.assign({}, payload, { env: FirebaseService.environment })))
    }

    function clear() {
        OutboxStore.clear()
        if (_drainTimer) _drainTimer.stop()
    }
}
