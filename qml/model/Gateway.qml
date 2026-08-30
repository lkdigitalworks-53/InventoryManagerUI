pragma Singleton
import QtQuick

// Compliance gateway client (P0). Single entry point for every books-of-
// account mutation in P0 scope (inventory + stock). Stores call
// `recordMutation(...)` instead of writing Firestore directly.
//
// Two modes:
//   "direct"  — Writes the working-tier doc via FirebaseService, exactly as
//               the stores did before P0. No ledger entry. Behaviour-
//               preserving fallback for when the Cloud Function/locked
//               rules aren't deployed (e.g. a fresh `dev`/`test` env).
//   "gateway" — DEFAULT since 649046d (Cloud Function + locked rules are
//               live in production). Enqueues the call in the durable
//               OutboxStore and POSTs it to the recordMutation Cloud
//               Function (Bearer idToken), which atomically writes the
//               working doc + an immutable audit_log entry. Failed/offline
//               calls stay queued and retry w/ backoff.
//
// Single-flight-per-record (Component 1, async-write-sequencing design §3):
// drainNow() marks every due item in-flight (OutboxStore.markInFlight)
// before dispatching it, and each _send*/clears it once the request
// resolves — OutboxStore uses this to stop a second enqueue() for the same
// entity+entityId from ever touching an already-dispatched item's payload,
// and to stop the same item being sent twice concurrently.
//
// recordDelta (Component 4) is the one Gateway call that ISN'T fire-and-
// forget — its callback fires with the real server outcome, since callers
// (order completion) need to branch on success vs. insufficient-quantity
// before proceeding. Everything else stays fire-and-forget by design.
QtObject {
    id: root

    // "gateway" in production (649046d). "direct" remains available as a
    // manual fallback for envs without the Cloud Function/locked rules.
    property string mode: "gateway"

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
    // InventoryStore.upsertMany. See functions/lib/batchMutationLogic.js.
    property string batchFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutationsBatch"
    // Atomic-delta endpoint (Component 4, async-write-sequencing design) —
    // NOT YET DEPLOYED, this URL is aspirational until index.js wires up
    // GatewayLogic.applyDelta and it's actually deployed. recordDelta()
    // below is safe to call before then; it'll just retry with backoff like
    // any other outbox item until the endpoint exists.
    property string deltaFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordDelta"
    // One-time fresh-start cutover endpoint (owner-only, server-side wipe).
    property string cutoverUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/runCutover"
    // Member provisioning endpoint (Admin SDK; owner/admin only). Adds a
    // teammate to the caller's tenant — creates the Auth account for a new
    // staff member, or attaches an existing account, writing both users/{uid}
    // and the member doc server-side (the client can't write another user's
    // profile under the Firestore rules).
    property string provisionMemberUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/provisionMember"

    signal cutoverFinished(bool ok, string error)

    // Component 3's client-side half (review finding C3, 2026-08-06): fired
    // when applyMutation's CAS check rejects a recordMutation because
    // someone else's write already landed for that record (`before` was
    // stale). `current` is the server's actual current document (null only
    // if the malformed/legacy edge case in _parseMutationConflict below
    // ever fires, which it shouldn't for a real conflict response). Each
    // store that calls recordMutation should connect to this and patch its
    // own local array for `entityId` from `current` — the queued write is
    // already dropped (not retried) by the time this fires, see _send.
    // `action` (2026-08-30): the original item.action ("delete"/"update"/
    // "create") that conflicted -- added so a store can word its reconcile
    // toast correctly. A rejected delete-conflict means the record still
    // legitimately exists (someone else edited it after this client's
    // stale `before`), and gets pushed back into the local array by the
    // same current-patch logic below; telling the user "your change didn't
    // save" is misleading when what they attempted was a delete. Additive
    // param -- existing 3-arg listeners still connect fine, they just
    // don't see it.
    signal mutationConflicted(string entity, string entityId, var current, string action)

    property int inFlight: 0

    // Pending recordDelta callbacks, keyed by outbox requestId — NOT
    // persisted (callbacks are JS functions, can't survive relaunch or
    // coalescing-across-restart anyway). One requestId can map to MULTIPLE
    // callbacks if OutboxStore.enqueueDelta coalesced several recordDelta
    // calls into one held item — all of them fire with that item's single
    // outcome. If the app relaunches mid-flight, any never-fired callbacks
    // are simply lost with the closure that held them — callers that care
    // about that (order completion) hold their own busy/timeout state, this
    // is not a durability mechanism the way the outbox itself is.
    property var _deltaCallbacks: ({})

    // entity → working-tier collection. Mirrors ENTITY_COLLECTIONS in
    // functions/index.js; the two MUST stay in sync.
    readonly property var _collections: ({
        "inventory": "inventory",
        "stock_batch": "stock_batches",
        "stock_movement": "stock_movements",
        "transaction": "transactions",
        "order": "orders",
        "staff": "staff",
        "supplier": "suppliers"
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

    // Atomic server-side delta (Component 4) — for quantity fields where two
    // legitimate concurrent writers should both apply, not race each other.
    // Unlike every other Gateway call, this is NOT fire-and-forget: callback
    // fires once the real outcome is known — success, or a definitive
    // rejection (insufficient-quantity) — following the same shape as
    // provisionMember's callback. Requires gateway mode; delta semantics
    // need server-side read-then-write, which "direct" mode has no way to
    // do (it's just a client-side FirebaseService.put of an absolute value).
    // If two recordDelta calls for the same record coalesce into one held
    // outbox item (OutboxStore.enqueueDelta), BOTH callbacks fire with that
    // item's single outcome — see _deltaCallbacks above.
    //
    // `floors` (field -> min value) REJECTS the whole call if any field
    // would cross it — use for "this must never silently under-apply"
    // (order completion's stock deduction: insufficient stock should fail
    // the order, not silently sell inventory that isn't there).
    // `clamps` (field -> min value) instead caps the result AT that value
    // and still succeeds — use for "always apply, just don't go negative"
    // (completeImportedOrder's deliberate "complete + report shortfall"
    // business rule — rejecting would break its designed behavior). A field
    // should only ever appear in one of the two maps, never both.
    function recordDelta(entity, entityId, deltas, floors, clamps, callback) {
        var collection = _collectionFor(entity)
        if (!collection || !entityId) {
            console.warn("[Gateway] recordDelta: bad entity/id", entity, entityId)
            if (callback) callback({ ok: false, error: "bad-request" })
            return ""
        }
        if (mode !== "gateway") {
            console.warn("[Gateway] recordDelta: requires gateway mode, got", mode)
            if (callback) callback({ ok: false, error: "delta-requires-gateway-mode" })
            return ""
        }
        var requestId = _nextRequestId()
        var item = OutboxStore.enqueueDelta({
            requestId: requestId,
            entity: entity,
            entityId: entityId,
            deltas: deltas || {},
            floors: floors || {},
            clamps: clamps || {},
            clientTimestamp: new Date().toISOString()
        })
        // item.requestId is the SURVIVING requestId — may belong to an
        // earlier call this one just coalesced into, not `requestId` above.
        if (callback) {
            var existing = _deltaCallbacks[item.requestId] || []
            existing.push(callback)
            var map = Object.assign({}, _deltaCallbacks)
            map[item.requestId] = existing
            _deltaCallbacks = map
        }
        drainNow()
        return item.requestId
    }



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
    // SAME entity, e.g. InventoryStore.upsertMany. `items` is
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
            OutboxStore.markInFlight(due[i])
            if (Array.isArray(due[i].items)) _sendBatch(due[i])
            else if (due[i].deltas) _sendDelta(due[i])
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

    // Detects a CAS-conflict response from applyMutation (Component 3),
    // pure function, no XHR — unit-testable, see tst_Gateway.qml. Review
    // finding C3 (2026-08-06): this case wasn't handled at all before —
    // _send treated a 409 conflict exactly like a timeout or a 5xx,
    // retrying forever via markFailed with the SAME stale `before`, which
    // the server would keep rejecting by construction. Deliberately
    // narrow, unlike _classifyDeltaResponse: only the specific
    // conflict:true 409 shape gets special handling here. Every OTHER
    // non-2xx (400/401/403/5xx/network error) keeps going through the
    // existing markFailed()+backoff+retry path completely unchanged —
    // those genuinely might resolve on retry (token refresh, transient
    // infra blip), so it would be WRONG to also stop retrying on them.
    // A conflict never resolves on retry: `before` is permanently stale
    // by construction, so this is the one case retrying can't fix.
    function _parseMutationConflict(status, responseText) {
        if (status !== 409) return { isConflict: false, current: null }
        var body = null
        try { body = JSON.parse(responseText) } catch (e) { return { isConflict: false, current: null } }
        if (!body || body.conflict !== true) return { isConflict: false, current: null }
        return { isConflict: true, current: body.current !== undefined ? body.current : null }
    }

    // ── QTBUG-49896 workaround (12th round, 2026-08-25) ──────────────────────
    // QML's XMLHttpRequest implementation can lose (reset to 0) xhr.status —
    // and, in this codebase's observed manifestation, responseText and
    // getAllResponseHeaders() along with it — during the readyState 3->4
    // (LOADING -> DONE) transition, for certain {method, response status}
    // combinations. Confirmed via bugreports.qt.io/browse/QTBUG-49896:
    // "XmlHttpRequest status is 'lost' (becomes 0) in readyState 3->4
    // transition for PUT requests yielding response with custom HTTP
    // status" — unresolved, no fix version, and the original report
    // reproduced with a 409, the exact status this codebase's conflict path
    // uses. status is reported correctly at readyState 2/3 and only lost by
    // DONE — this is not a server bug: see CHECKPOINT.md's twelfth round for
    // two real repros (plain Express, and the actual firebase-functions v2 +
    // functions-framework wrapper) that both send this exact response
    // cleanly, ruling the server side out with evidence.
    //
    // Workaround: snapshot status/responseText/headers the moment they're
    // non-zero (readyState HEADERS_RECEIVED or LOADING), and every call site
    // falls back to that snapshot if xhr.status reads 0 at DONE. Deliberately
    // keeps the RAW xhr.status alongside the effective one in every failure
    // log — this hasn't been run against a real emulator from this sandbox,
    // so the next real CI run is what actually confirms or refutes this,
    // not another guess declared as fixed.
    //
    // Known limitation: for a response large enough to arrive across
    // multiple LOADING events, the snapshot taken at HEADERS_RECEIVED/
    // LOADING might not have the full body yet. Not a concern for this
    // codebase's responses (single small JSON documents), but worth knowing
    // if this pattern gets reused somewhere with larger payloads.
    function _captureBeforeStatusIsLost(xhr, snapshot) {
        if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED || xhr.readyState === XMLHttpRequest.LOADING) {
            if (xhr.status !== 0) {
                snapshot.status = xhr.status
                snapshot.responseText = xhr.responseText
                try { snapshot.headers = xhr.getAllResponseHeaders() } catch (e) { /* keep previous value */ }
            }
        }
    }

    function _send(item) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            // Not signed in yet — leave queued; drain again after auth.
            OutboxStore.clearInFlight(item)
            return
        }
        inFlight++
        var xhr = new XMLHttpRequest()
        var _snap = { status: 0, responseText: "", headers: "" }
        xhr.onreadystatechange = function() {
            _captureBeforeStatusIsLost(xhr, _snap)
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            inFlight--
            var effStatus = (xhr.status !== 0) ? xhr.status : _snap.status
            var effResponseText = (xhr.status !== 0) ? xhr.responseText : _snap.responseText
            var ok = effStatus >= 200 && effStatus < 300
            if (ok) {
                OutboxStore.markSent(item.requestId)
            } else {
                var conflict = _parseMutationConflict(effStatus, effResponseText)
                if (conflict.isConflict) {
                    console.warn("[Gateway] recordMutation conflict — dropping stale write, notifying store",
                                 item.entity, item.entityId)
                    // Remove without retrying — see _parseMutationConflict's
                    // comment for why retry can never succeed here. The
                    // owning store reconciles its cache via the signal below.
                    OutboxStore.markSent(item.requestId)
                    mutationConflicted(item.entity, item.entityId, conflict.current, item.action)
                } else {
                    // 11th round (2026-08-24): two working repros this round
                    // (plain Express, and the real firebase-functions v2 +
                    // functions-framework wrapper -- as close to what the
                    // local emulator actually runs as this sandbox can get)
                    // both send this exact response shape/headers cleanly.
                    // That rules out the response construction and the
                    // framework layer with actual evidence, not just
                    // inspection -- see CHECKPOINT.md. 12th round: found
                    // QTBUG-49896 and applied the workaround above via
                    // _captureBeforeStatusIsLost -- raw-status/effective-
                    // status logged side by side below so the next real run
                    // confirms or refutes this rather than trusting it blind.
                    var headersSeen = (xhr.status !== 0) ? "" : _snap.headers
                    if (xhr.status !== 0) { try { headersSeen = xhr.getAllResponseHeaders() } catch (e) { headersSeen = "<getAllResponseHeaders threw: " + e + ">" } }
                    console.warn("[Gateway] recordMutation failed", "raw-status:", xhr.status, "effective-status:", effStatus,
                                 "statusText:", xhr.statusText, item.entity, item.entityId, effResponseText, "headers:", headersSeen)
                    OutboxStore.markFailed(item.requestId)
                }
            }
            OutboxStore.clearInFlight(item)
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

    // Detects a CAS-conflict response from applyMutationsBatch (review I1,
    // added this round now that the batch path has a CAS check at all).
    // Different response shape from _parseMutationConflict above by
    // necessity — a batch can have MULTIPLE conflicting items in one
    // response, not just one, so it's `conflicts: [{entityId, current}]`
    // rather than a single `current`. Pure function, no XHR — unit-
    // testable, see tst_Gateway.qml.
    function _parseBatchMutationConflict(status, responseText) {
        if (status !== 409) return { isConflict: false, conflicts: [] }
        var body = null
        try { body = JSON.parse(responseText) } catch (e) { return { isConflict: false, conflicts: [] } }
        if (!body || !Array.isArray(body.conflicts) || body.conflicts.length === 0)
            return { isConflict: false, conflicts: [] }
        return { isConflict: true, conflicts: body.conflicts }
    }

    // Batch counterpart of _send — one outbox item, one HTTP call, whatever
    // its `items` count. Same success/failure/backoff handling as _send.
    //
    // Conflict handling (review I1, filled in this round — see
    // _parseBatchMutationConflict's comment for the response-shape
    // difference from _send's). Same reasoning as _send: a genuine
    // conflict can never resolve on retry, so drop without retrying
    // (markSent) rather than markFailed. Fires the EXISTING
    // mutationConflicted signal once per conflicting item — every store is
    // already wired to it from the single-item C3 fix, so a batch conflict
    // reconciles through the exact same path with zero new store-side code.
    function _sendBatch(item) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            OutboxStore.clearInFlight(item)
            return
        }
        inFlight++
        var xhr = new XMLHttpRequest()
        var _snap = { status: 0, responseText: "", headers: "" }
        xhr.onreadystatechange = function() {
            _captureBeforeStatusIsLost(xhr, _snap)
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            inFlight--
            var effStatus = (xhr.status !== 0) ? xhr.status : _snap.status
            var effResponseText = (xhr.status !== 0) ? xhr.responseText : _snap.responseText
            var ok = effStatus >= 200 && effStatus < 300
            if (ok) {
                OutboxStore.markSent(item.requestId)
            } else {
                var conflict = _parseBatchMutationConflict(effStatus, effResponseText)
                if (conflict.isConflict) {
                    console.warn("[Gateway] recordMutationsBatch conflict — dropping stale batch, notifying stores",
                                 item.entity, conflict.conflicts.length, "of", item.items.length, "item(s) conflicted")
                    OutboxStore.markSent(item.requestId)
                    for (var i = 0; i < conflict.conflicts.length; ++i) {
                        mutationConflicted(item.entity, conflict.conflicts[i].entityId, conflict.conflicts[i].current)
                    }
                } else {
                    console.warn("[Gateway] recordMutationsBatch failed", "raw-status:", xhr.status, "effective-status:", effStatus,
                                 item.entity, item.items.length, effResponseText)
                    OutboxStore.markFailed(item.requestId)
                }
            }
            OutboxStore.clearInFlight(item)
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

    // Classifies a recordDelta HTTP response. Pure function, no XHR — this
    // is what actually decides terminal-vs-transient, extracted specifically
    // so it's unit-testable without a mock HTTP layer (see tst_Gateway.qml).
    //
    // Bug this fixes (found 2026-07-29, systematic-debugging session): the
    // original inline check was `(status===409||status===404) && result &&
    // result.error`, treating ANY response with a truthy `.error`-shaped
    // field as terminal. An undeployed Cloud Function's 404 has no
    // meaningful body at all — JSON.parse throws, `result` is null — so
    // that check correctly filtered it out, but landed on "transient,
    // retry forever" with no way to ever resolve, since the endpoint
    // categorically doesn't exist yet. The real fix isn't a smarter status-
    // code check; it's recognizing that a genuine decision from OUR code
    // is only ever valid JSON matching OUR response envelope (a boolean
    // `ok` field) — anything else, regardless of HTTP status, is an
    // infrastructure failure, not a business rejection, and must not be
    // presented to the caller as one.
    function _classifyDeltaResponse(status, body) {
        var isRealResponse = body !== null && typeof body === "object" && typeof body.ok === "boolean"
        if (!isRealResponse) return { terminal: false, result: null }
        if (body.ok === true) return { terminal: true, result: body }
        // A real ok:false response. A 4xx from our own code means the
        // server made a definitive decision (conflict, insufficient stock,
        // bad request) that retrying with the same data won't change —
        // terminal. A 5xx, even with a well-formed body, means something
        // went wrong on OUR side that could be transient (a Firestore
        // hiccup, say) — worth retrying rather than giving up immediately,
        // same as before this fix.
        var definitive = status >= 400 && status < 500
        return { terminal: definitive, result: definitive ? body : null }
    }

    // Delta counterpart of _send (Component 4). Distinguishes a definitive
    // server outcome (success, or a rejection the server actually decided
    // on) from an infrastructure-level failure (network error, undeployed
    // endpoint, 5xx that never reached our function code) via
    // _classifyDeltaResponse above — only the former is terminal, removed
    // from the outbox with its callback(s) fired. Anything else retries
    // with backoff like any other item, callbacks staying pending for
    // whichever attempt eventually resolves for real.
    function _sendDelta(item) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            OutboxStore.clearInFlight(item)
            return
        }
        inFlight++
        var xhr = new XMLHttpRequest()
        var _snap = { status: 0, responseText: "", headers: "" }
        xhr.onreadystatechange = function() {
            _captureBeforeStatusIsLost(xhr, _snap)
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            inFlight--
            var effStatus = (xhr.status !== 0) ? xhr.status : _snap.status
            var effResponseText = (xhr.status !== 0) ? xhr.responseText : _snap.responseText
            var body = null
            try { body = JSON.parse(effResponseText) } catch (e) { body = null }
            var classified = _classifyDeltaResponse(effStatus, body)

            if (classified.terminal) {
                OutboxStore.markSent(item.requestId)
            } else {
                console.warn("[Gateway] recordDelta failed", "raw-status:", xhr.status, "effective-status:", effStatus,
                             item.entity, item.entityId, effResponseText)
                OutboxStore.markFailed(item.requestId)
            }
            OutboxStore.clearInFlight(item)

            if (classified.terminal) {
                var callbacks = _deltaCallbacks[item.requestId] || []
                var map = Object.assign({}, _deltaCallbacks)
                delete map[item.requestId]
                _deltaCallbacks = map
                for (var i = 0; i < callbacks.length; ++i)
                    callbacks[i](classified.result)
            }
            _reschedule()
        }
        xhr.open("POST", deltaFunctionUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.send(JSON.stringify({
            env: FirebaseService.environment,
            entity: item.entity,
            entityId: item.entityId,
            deltas: item.deltas,
            floors: item.floors,
            clamps: item.clamps,
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
        var _snap = { status: 0, responseText: "", headers: "" }
        xhr.onreadystatechange = function() {
            _captureBeforeStatusIsLost(xhr, _snap)
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var effStatus = (xhr.status !== 0) ? xhr.status : _snap.status
            var effResponseText = (xhr.status !== 0) ? xhr.responseText : _snap.responseText
            var ok = effStatus >= 200 && effStatus < 300
            if (ok) {
                cutoverFinished(true, "")
            } else {
                console.warn("[Gateway] cutover failed", "raw-status:", xhr.status, "effective-status:", effStatus, effResponseText)
                cutoverFinished(false, "HTTP " + effStatus)
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
        var _snap = { status: 0, responseText: "", headers: "" }
        xhr.onreadystatechange = function() {
            _captureBeforeStatusIsLost(xhr, _snap)
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var effStatus = (xhr.status !== 0) ? xhr.status : _snap.status
            var effResponseText = (xhr.status !== 0) ? xhr.responseText : _snap.responseText
            var ok = effStatus >= 200 && effStatus < 300
            var data = null
            try { data = JSON.parse(effResponseText) } catch (e) { data = null }
            if (!ok)
                console.warn("[Gateway] provisionMember failed", "raw-status:", xhr.status, "effective-status:", effStatus, effResponseText)
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
        _deltaCallbacks = ({})
        if (_drainTimer) _drainTimer.stop()
    }
}
