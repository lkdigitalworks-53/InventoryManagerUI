pragma Singleton
import QtQuick
import QtCore

import "../helper/SettingsPath.js" as SettingsPath
import "../helper/PhotoQueueLogic.js" as PQL

// Durable queue for product-photo uploads (2026-09-21 photos feature). Deliberately a SIBLING to
// Gateway/OutboxStore, not an addition to either -- Gateway retries forever with no request
// timeout (DELETE-FEATURE-ROADMAP item 1); photos need bounded retry, a give-up state with
// user-facing Retry/Discard, and per-item local-file cleanup, which is different enough lifecycle
// to keep separate.
// Design: docs/superpowers/specs/2026-09-21-product-photos-firebase-storage-design.md
// Plan:   docs/superpowers/plans/2026-09-21-product-photos-firebase-storage.md Task 10
//
// Queue item shape (persisted):
//   { photoId, requestId (=photoId), productId, uid, tenantId,
//     mainFilePath, thumbFilePath,   // already-PERSISTED local copies (ImageProcessor.persistLocalCopy
//                                    // output, NOT compressForUpload's cache-dir output -- the cache
//                                    // dir can be cleared by the OS between launches, this queue must
//                                    // never reference it)
//     state,                         // "enqueued" | "uploading" | "retrying" | "failed"
//     attempts, nextAttemptAt, lastError }
//
// TESTABILITY NOTE (read before adding a test): NativeFile and ImageProcessor are root CONTEXT
// PROPERTIES set in main.cpp (setContextProperty), not QML singletons -- they do not exist at all
// under qmltestrunner (same reason StorageService.qml, the only other file that references them,
// has zero tests; Gateway._send's real XHR is likewise untested at this level, per tst_Gateway.qml's
// own comment). So: drainCandidates() is deliberately a separate, side-effect-free function from
// _upload() -- it decides WHICH items would be attempted (identity match, OutboxStore gate) without
// touching Storage, the network, or a native file read, and IS unit-testable (tests/tst_PhotoQueue.qml).
// _upload() itself (native file read + XHR) is not exercised under qmltestrunner, consistent with
// Gateway._send's existing precedent -- CI's e2e suite (plan Task 13) is the real proof for that path.
// The two ImageProcessor calls in discard() are guarded with `typeof ImageProcessor !== "undefined"`
// so discard()'s queue-array removal (the part that matters for correctness and IS tested) stays
// callable under qmltestrunner; the guard is a no-op difference on-device, where ImageProcessor is
// always defined.
QtObject {
    id: root

    property var items: []
    property int pendingCount: 0
    property int revision: 0

    // Circuit breaker for the upload endpoint specifically -- independent of any Gateway breaker.
    // Not persisted: a fresh app launch reasonably gets a fresh chance to find the endpoint healthy.
    property var _breaker: ({ status: "closed", consecutiveFailures: 0, cooldownUntil: 0, cooldownMs: 60000 })

    // Emitted after a successful upload so InventoryStore can update its local photoIds cache
    // immediately rather than waiting for the next Firestore snapshot (design spec, flow step 3).
    signal photoUploaded(string productId, string photoId, var photoIds)
    signal photoUploadFailed(string productId, string photoId, int status)

    // Overridable, matching Gateway.functionUrl's exact convention (plain property, no leading
    // underscore -- signals "external callers, e2e tests included, may point this at the
    // emulator or another environment"). Found missing this during the e2e test write-up: as
    // readonly with a leading underscore, no e2e test could ever have redirected it.
    property string uploadUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/uploadProductPhoto"

    property Settings _settings: Settings {
        category: "PhotoQueue"
        // See qml/helper/SettingsPath.js -- same technique OutboxStore uses so durability is
        // actually exercised under qmltestrunner instead of silently no-op-ing.
        location: SettingsPath.settingsLocationOverride(
                      Application.organization,
                      StandardPaths.writableLocation(StandardPaths.TempLocation))
        property string itemsJson: ""
    }

    property var _drainTimer: null

    Component.onCompleted: _load()

    function _load() {
        if (_settings.itemsJson && _settings.itemsJson.length > 2) {
            try {
                var arr = JSON.parse(_settings.itemsJson)
                if (Array.isArray(arr)) items = arr
            } catch (e) {
                items = []
            }
        }
        _refresh()
        // Real bug found in review: without this, any item persisted from a previous session
        // just sits loaded-but-frozen forever unless something ELSE happens to call
        // _reschedule() first (a fresh enqueue, or AuthService.isOnline transitioning
        // false->true -- which never fires if the app opens already online). This is exactly
        // the "survive app close" requirement (design spec) silently not holding. enqueue()
        // itself already calls _reschedule() for the item it just added -- app start needs the
        // same call for whatever was already there.
        _reschedule()
    }

    function _save() {
        _settings.itemsJson = JSON.stringify(items)
        _refresh()
    }

    function _refresh() {
        pendingCount = items.length
        revision++
    }

    // Enqueue a new photo. photoId is the caller-supplied random id -- also the idempotency
    // requestId sent to uploadProductPhoto. mainFilePath/thumbFilePath must already be persisted
    // (see the shape comment above); this function does no file I/O itself.
    function enqueue(call) {
        var item = {
            photoId: call.photoId, requestId: call.photoId,
            productId: call.productId, uid: call.uid, tenantId: call.tenantId,
            mainFilePath: call.mainFilePath, thumbFilePath: call.thumbFilePath,
            state: "enqueued", attempts: 0, nextAttemptAt: 0, lastError: null
        }
        var arr = items.slice()
        arr.push(item)
        items = arr
        _save()
        _reschedule()
        return item
    }

    // Re-open a failed item for another attempt, ignoring backoff (PQL.reduceQueueItem's "retry"
    // transition resets attempts/nextAttemptAt/lastError and moves it back to "enqueued").
    function retry(photoId) {
        var arr = items.slice()
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].photoId !== photoId) continue
            arr[i] = PQL.reduceQueueItem(arr[i], { type: "retry" })
            break
        }
        items = arr
        _save()
        _reschedule()
    }

    // Remove a queue item and delete both its persisted local files. Nothing is ever written
    // server-side for a queued-but-not-yet-successful item, whatever its state, so this never
    // needs to talk to the network (design spec, flow step 4).
    function discard(photoId) {
        var arr = []
        var removed = null
        for (var i = 0; i < items.length; ++i) {
            if (items[i].photoId === photoId) { removed = items[i]; continue }
            arr.push(items[i])
        }
        items = arr
        _save()
        if (removed && typeof ImageProcessor !== "undefined") {
            ImageProcessor.removeLocalCopy(removed.photoId)
            ImageProcessor.removeLocalCopy(removed.photoId + "_t")
        }
    }

    // Items a drain pass would actually attempt right now: due, matching the CURRENTLY signed-in
    // identity (Trap 2 in the design spec -- a queue item is bound to the uid/tenantId active when
    // it was enqueued and only drains under that same identity), and whose product has no pending
    // OutboxStore mutation (Trap 1 -- a photo for a product created offline must wait for that
    // product's own create mutation to land, or the server 404s). Pure read, no I/O -- see the
    // TESTABILITY NOTE above for why this is deliberately separate from _upload().
    function drainCandidates(nowMs) {
        var now = typeof nowMs === "number" ? nowMs : Date.now()
        var out = []
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (it.state !== "enqueued" && it.state !== "retrying") continue
            if ((it.nextAttemptAt || 0) > now) continue
            if (it.uid !== AuthStore.uid || it.tenantId !== AuthStore.tenantId) continue
            if (OutboxStore.hasPendingForEntity("inventory", it.productId)) continue
            out.push(it)
        }
        return out
    }

    function drainNow() {
        if (PQL.isBreakerOpen(_breaker, Date.now())) { _reschedule(); return }
        // Kick off a token refresh if one's needed, once per drain pass (not per item) -- same
        // placement as Gateway.drainNow(). Without this, an item stuck on a stale/missing idToken
        // (the "not signed in / token not ready yet" branch in _upload() below) would only ever
        // get unstuck by something ELSE happening to refresh AuthStore.idToken first; this is a
        // real gap the design said would exist ("mirrors Gateway._send's ... idToken-not-ready
        // guard") but the first draft of this function never actually called it.
        if (typeof AuthService !== "undefined" && AuthService)
            AuthService.ensureFreshToken()
        var candidates = drainCandidates(Date.now())
        for (var i = 0; i < candidates.length; ++i) _upload(candidates[i])
    }

    function _replaceItem(photoId, next) {
        if (next === null) {
            var arr = []
            for (var i = 0; i < items.length; ++i) if (items[i].photoId !== photoId) arr.push(items[i])
            items = arr
        } else {
            var arr2 = items.slice()
            for (var j = 0; j < arr2.length; ++j) if (arr2[j].photoId === photoId) { arr2[j] = next; break }
            items = arr2
        }
        _save()
    }

    function _reschedule() {
        if (!_drainTimer) {
            _drainTimer = Qt.createQmlObject(
                'import QtQuick; Timer { repeat: false }', root, "PhotoQueueDrainTimer")
            _drainTimer.triggered.connect(drainNow)
        }
        var due = -1
        var now = Date.now()
        for (var i = 0; i < items.length; ++i) {
            var it = items[i]
            if (it.state !== "enqueued" && it.state !== "retrying") continue
            var wait = Math.max(0, (it.nextAttemptAt || 0) - now)
            if (due < 0 || wait < due) due = wait
        }
        if (due < 0) { _drainTimer.stop(); return }
        _drainTimer.interval = Math.max(250, due)
        _drainTimer.restart()
    }

    // Not unit-tested under qmltestrunner -- see the TESTABILITY NOTE at the top of this file.
    // Mirrors Gateway._send's structure deliberately (the QTBUG-49896 status-loss workaround,
    // 45s timeout, the auth-header/idToken-not-ready guard) so this doesn't invent a second style.
    function _upload(item) {
        // Mark uploading first so a concurrent drainNow() (e.g. the backoff timer firing right as
        // AuthService.onIsOnlineChanged also fires) can't double-send the same item.
        var uploading = Object.assign({}, item, { state: "uploading" })
        _replaceItem(item.photoId, uploading)

        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            // Not signed in / token not ready yet -- same as Gateway._send -- leave it queued,
            // not a failure, and try again on the next drain.
            _replaceItem(item.photoId, item)
            return
        }

        var mainB64 = (typeof NativeFile !== "undefined") ? NativeFile.readFileBase64(item.mainFilePath) : ""
        var thumbB64 = (typeof NativeFile !== "undefined") ? NativeFile.readFileBase64(item.thumbFilePath) : ""
        if (!mainB64 || !thumbB64) {
            // The persisted file is gone. Only discard() removes it (and it also removes the
            // queue item), so this should never happen in practice -- terminal, since retrying
            // into a missing file can never succeed.
            var missing = PQL.reduceQueueItem(uploading, { type: "failed", status: 400 })
            _replaceItem(item.photoId, missing)
            _breaker = PQL.breakerReducer(_breaker, { type: "failure" })
            photoUploadFailed(item.productId, item.photoId, 400)
            _reschedule()
            return
        }

        var xhr = new XMLHttpRequest()
        var _snap = { status: 0, responseText: "" }
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED || xhr.readyState === XMLHttpRequest.LOADING) {
                if (xhr.status !== 0) { _snap.status = xhr.status; _snap.responseText = xhr.responseText }
            }
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var effStatus = (xhr.status !== 0) ? xhr.status : _snap.status
            var effResponseText = (xhr.status !== 0) ? xhr.responseText : _snap.responseText
            var ok = effStatus >= 200 && effStatus < 300
            if (ok) {
                var parsed = {}
                try { parsed = JSON.parse(effResponseText) } catch (e) { /* keep {} */ }
                _replaceItem(item.photoId, null)
                _breaker = PQL.breakerReducer(_breaker, { type: "success" })
                photoUploaded(item.productId, item.photoId, parsed.photoIds || [])
            } else {
                var next = PQL.reduceQueueItem(uploading, { type: "failed", status: effStatus })
                _replaceItem(item.photoId, next)
                _breaker = PQL.breakerReducer(_breaker, { type: "failure" })
                if (next && next.state === "failed") photoUploadFailed(item.productId, item.photoId, effStatus)
            }
            _reschedule()
        }
        xhr.ontimeout = function() {
            var next = PQL.reduceQueueItem(uploading, { type: "failed", status: 0 })
            _replaceItem(item.photoId, next)
            _breaker = PQL.breakerReducer(_breaker, { type: "failure" })
            if (next && next.state === "failed") photoUploadFailed(item.productId, item.photoId, 0)
            _reschedule()
        }
        xhr.open("POST", uploadUrl)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        xhr.timeout = 45000
        xhr.send(JSON.stringify({
            env: FirebaseService.environment,
            productId: item.productId, photoId: item.photoId, requestId: item.photoId,
            imageBase64: mainB64, thumbBase64: thumbB64
        }))
    }

    // Drain triggers (design spec, "Flow" step 3): app start (_load -> _reschedule if items
    // exist), AuthService.isOnline flipping true, and the backoff timer itself (_reschedule).
    // Property-binding watcher, NOT Connections{} -- Connections{} inside a pragma Singleton
    // QtObject root crashes the entire singleton chain at runtime (SKILLS.md Skill 20).
    property bool _onlineWatcher: AuthService.isOnline
    on_OnlineWatcherChanged: { if (_onlineWatcher) drainNow() }

    // Drop the whole queue and its files. Used on sign-out, same reasoning as
    // OutboxStore.clear() -- a pending photo must never replay under the next account.
    function clear() {
        for (var i = 0; i < items.length; ++i) {
            if (typeof ImageProcessor !== "undefined") {
                ImageProcessor.removeLocalCopy(items[i].photoId)
                ImageProcessor.removeLocalCopy(items[i].photoId + "_t")
            }
        }
        items = []
        _settings.itemsJson = ""
        _refresh()
    }
}
