pragma Singleton
import QtQuick
import "../helper/EnvConfig.js" as EnvConfig
import "../helper/PagingHelper.js" as PagingHelper

QtObject {
    id: root

    readonly property string projectId: "inventorymanager-48392"
    readonly property string apiKey: "AIzaSyAeA5Mb6ZmtKLOb3Oxw_n-dh62_qY0r4mA"

    // Build-time environment (APP_STAGE from CMake PRODUCT_STAGE). prd → the
    // existing (default) database; test/dev → named databases in the same
    // project. Single point of change — every get/put/patch/remove builds its
    // URL from databaseUrl/databaseId below, so all data access switches here.
    readonly property string environment: EnvConfig.envForStage(
        (typeof APP_STAGE !== "undefined" && APP_STAGE) ? APP_STAGE : "")
    readonly property string databaseId: EnvConfig.databaseIdForEnv(environment)
    readonly property string databaseUrl: "https://firestore.googleapis.com/v1/projects/"
                                          + projectId + "/databases/" + databaseId + "/documents"

    property bool syncing: false
    property int pendingRequests: 0
    property int lastStatusCode: 0
    property string lastRequest: ""
    property string lastError: ""

    readonly property bool tenantScopingEnabled: true
    readonly property string salesSummaryDoc: "summary"

    function _trackStart() {
        pendingRequests++
        syncing = true
    }

    function _trackDone() {
        pendingRequests--
        if (pendingRequests <= 0) {
            pendingRequests = 0
            syncing = false
        }
    }

    function _isSalesCollectionPath(path) {
        return path === "sales" || /\/sales$/.test(path)
    }

    function _resolvePath(path) {
        var clean = String(path || "").replace(/^\/+|\/+$/g, "")
        if (!clean)
            return ""

        if (_isSalesCollectionPath(clean))
            clean = clean + "/" + salesSummaryDoc

        if (!tenantScopingEnabled)
            return clean

        if (clean.indexOf("tenants/") === 0 || clean.indexOf("users/") === 0)
            return clean

        if (!AuthStore.tenantId)
            return clean

        return "tenants/" + AuthStore.tenantId + "/" + clean
    }

    function _splitPath(path) {
        var normalized = _resolvePath(path)
        if (!normalized)
            return { normalizedPath: "", isCollection: false }

        var parts = normalized.split("/")
        return {
            normalizedPath: normalized,
            isCollection: (parts.length % 2) === 1
        }
    }

    function _encodePath(path) {
        var parts = String(path || "").split("/")
        var encoded = []
        for (var i = 0; i < parts.length; ++i)
            encoded.push(encodeURIComponent(parts[i]))
        return encoded.join("/")
    }

    function _collectionUrl(collectionPath) {
        return databaseUrl + "/" + _encodePath(collectionPath)
    }

    // runQuery needs the collection split into its parent document path (or
    // "" for a root-level collection) and the bare collectionId — Firestore's
    // structured-query REST shape addresses "parent document + collectionId",
    // not a flat collection path the way get()/put() do.
    function _splitCollectionParent(normalizedPath) {
        var idx = normalizedPath.lastIndexOf("/")
        if (idx < 0)
            return { parent: "", collectionId: normalizedPath }
        return { parent: normalizedPath.substring(0, idx),
                 collectionId: normalizedPath.substring(idx + 1) }
    }

    function _docUrl(docPath) {
        return databaseUrl + "/" + _encodePath(docPath)
    }

    function _request(method, url, body, callback, authToken) {
        var urlWithKey = url + (url.indexOf("?") >= 0 ? "&" : "?") + "key=" + encodeURIComponent(apiKey)
        var xhr = new XMLHttpRequest()
        lastRequest = method + " " + urlWithKey
        _trackStart()

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            _trackDone()

            lastStatusCode = xhr.status
            var ok = xhr.status >= 200 && xhr.status < 300
            if (!ok) {
                lastError = xhr.responseText || ("HTTP " + xhr.status)
                console.warn("[Firestore]", method, "failed", urlWithKey, "status:", xhr.status, xhr.responseText)
                if (callback) callback(false, null, xhr.status, lastError)
                return
            }

            lastError = ""
            if (!callback) return

            if (!xhr.responseText || xhr.responseText.length === 0) {
                callback(true, null, xhr.status, "")
                return
            }

            try {
                callback(true, JSON.parse(xhr.responseText), xhr.status, "")
            } catch (e) {
                lastError = String(e)
                console.warn("[Firestore] Parse error for", urlWithKey, ":", e)
                callback(false, null, xhr.status, lastError)
            }
        }

        xhr.open(method, urlWithKey)
        if (body !== undefined && body !== null)
            xhr.setRequestHeader("Content-Type", "application/json")
        // Use an explicit token when provided (e.g. provisioning a staff user's
        // own users/{uid} doc with THAT staff's token); otherwise the current
        // session's token.
        var bearer = (authToken && authToken.length > 0) ? authToken : AuthStore.idToken
        if (bearer && bearer.length > 0)
            xhr.setRequestHeader("Authorization", "Bearer " + bearer)
        xhr.send(body !== undefined && body !== null ? JSON.stringify(body) : null)
    }

    function _isIntegerNumber(n) {
        return typeof n === "number" && isFinite(n) && Math.floor(n) === n
    }

    function _encodeValue(v) {
        if (v === null || v === undefined)
            return { nullValue: null }

        if (typeof v === "string")
            return { stringValue: v }

        if (typeof v === "boolean")
            return { booleanValue: v }

        if (typeof v === "number") {
            if (_isIntegerNumber(v))
                return { integerValue: String(v) }
            return { doubleValue: v }
        }

        if (Array.isArray(v)) {
            var values = []
            for (var i = 0; i < v.length; ++i)
                values.push(_encodeValue(v[i]))
            return { arrayValue: { values: values } }
        }

        if (typeof v === "object") {
            var fields = {}
            var keys = Object.keys(v)
            for (var j = 0; j < keys.length; ++j)
                fields[keys[j]] = _encodeValue(v[keys[j]])
            return { mapValue: { fields: fields } }
        }

        return { stringValue: String(v) }
    }

    function _decodeValue(v) {
        if (!v || typeof v !== "object") return null
        if (v.stringValue !== undefined) return v.stringValue
        if (v.booleanValue !== undefined) return v.booleanValue
        if (v.integerValue !== undefined) return parseInt(v.integerValue, 10)
        if (v.doubleValue !== undefined) return Number(v.doubleValue)
        if (v.nullValue !== undefined) return null

        if (v.arrayValue !== undefined) {
            var raw = v.arrayValue.values || []
            var arr = []
            for (var i = 0; i < raw.length; ++i)
                arr.push(_decodeValue(raw[i]))
            return arr
        }

        if (v.mapValue !== undefined) {
            var fields = v.mapValue.fields || {}
            var out = {}
            var keys = Object.keys(fields)
            for (var j = 0; j < keys.length; ++j)
                out[keys[j]] = _decodeValue(fields[keys[j]])
            return out
        }

        return null
    }

    function _encodeDoc(data) {
        var fields = {}
        var source = data || {}
        var keys = Object.keys(source)
        for (var i = 0; i < keys.length; ++i)
            fields[keys[i]] = _encodeValue(source[keys[i]])
        return { fields: fields }
    }

    function _decodeDoc(document) {
        if (!document || !document.fields)
            return null
        return _decodeValue({ mapValue: { fields: document.fields } })
    }

    function _buildCommitWrites(collectionPath, data) {
        var writes = []
        var keys = Object.keys(data || {})
        for (var i = 0; i < keys.length; ++i) {
            var docId = keys[i]
            var docName = "projects/" + projectId + "/databases/" + databaseId + "/documents/"
                          + collectionPath + "/" + docId
            writes.push({
                update: {
                    name: docName,
                    fields: _encodeDoc(data[docId]).fields
                }
            })
        }
        return writes
    }

    function get(path, callback) {
        var p = _splitPath(path)
        if (!p.normalizedPath) {
            if (callback) callback(false, null)
            return
        }

        if (p.isCollection) {
            var acc = []
            var baseUrl = _collectionUrl(p.normalizedPath)
            var fetchPage = function(pageToken) {
                var url = baseUrl
                if (pageToken)
                    url += "?pageToken=" + encodeURIComponent(pageToken)
                _request("GET", url, null, function(ok, data) {
                    if (!ok) {
                        if (callback) callback(false, null)
                        return
                    }
                    var docs = (data && data.documents) ? data.documents : []
                    for (var i = 0; i < docs.length; ++i) {
                        var decoded = _decodeDoc(docs[i])
                        if (decoded !== null)
                            acc.push(decoded)
                    }
                    // Firestore's List-Documents endpoint paginates internally
                    // once a collection crosses an internal response-size
                    // threshold; a truncated first page previously returned
                    // silently (no error, no warning) if nextPageToken wasn't
                    // followed. Loop until it's absent.
                    if (data && data.nextPageToken) {
                        fetchPage(data.nextPageToken)
                    } else {
                        if (callback) callback(true, acc)
                    }
                })
            }
            fetchPage(null)
            return
        }

        _request("GET", _docUrl(p.normalizedPath), null, function(ok, data) {
            if (!ok) {
                if (callback) callback(false, null)
                return
            }
            if (callback) callback(true, _decodeDoc(data))
        })
    }

    // Cursor-paginated read via Firestore's structured-query (:runQuery)
    // endpoint — the mechanism that lets us load a bounded page instead of
    // get()'s "fetch the whole collection" (which is what Phase 1 replaces
    // for the six growing collections; get() itself stays correct for
    // bounded/small collections and single documents).
    //
    // opts = { orderBy, direction ("ASCENDING"|"DESCENDING", default
    //          ASCENDING), limit (default 50), startAfter (opaque cursor
    //          value from a previous page's result, omit for the first page) }
    //
    // callback(ok, { items, nextCursor, hasMore }). nextCursor is null when
    // hasMore is false, so a caller can't accidentally page past the end.
    function query(path, opts, callback) {
        var p = _splitPath(path)
        if (!p.normalizedPath || !p.isCollection) {
            if (callback) callback(false, null)
            return
        }

        var split = _splitCollectionParent(p.normalizedPath)
        var requestedLimit = (opts && opts.limit) ? opts.limit : 50
        var orderByField = (opts && opts.orderBy) ? opts.orderBy : "__name__"
        var direction = (opts && opts.direction) ? opts.direction : "ASCENDING"

        var structuredQuery = {
            from: [{ collectionId: split.collectionId }],
            orderBy: [{ field: { fieldPath: orderByField }, direction: direction }],
            // Over-fetch by one so PagingHelper can detect hasMore exactly at
            // the page boundary instead of guessing from "got a full page".
            limit: requestedLimit + 1
        }
        if (opts && opts.startAfter !== undefined && opts.startAfter !== null) {
            // Firestore requires a __name__ cursor to be a referenceValue (the
            // document's full resource path), not a plain string value — a
            // stringValue cursor against __name__ is silently wrong/rejected.
            var cursorValue = (orderByField === "__name__")
                ? { referenceValue: opts.startAfter }
                : _encodeValue(opts.startAfter)
            structuredQuery.startAt = { values: [cursorValue], before: false }
        }

        var url = split.parent
            ? (databaseUrl + "/" + _encodePath(split.parent) + ":runQuery")
            : (databaseUrl + ":runQuery")

        _request("POST", url, { structuredQuery: structuredQuery }, function(ok, data) {
            if (!ok) {
                if (callback) callback(false, null)
                return
            }
            var rows = Array.isArray(data) ? data : []
            var decoded = []
            // Parallel to `decoded`, same indices — the raw orderBy-field
            // value per row, kept OUT of the returned items. For "__name__"
            // this is Firestore's full document resource path, which must
            // never leak into an item: if that item is later edited and PUT
            // back, "__name__" is a reserved field name and Firestore rejects
            // writing it. For a real field it's just the decoded value again.
            var rawCursorValues = []
            for (var i = 0; i < rows.length; ++i) {
                // Firestore may interleave rows with no `document` (progress
                // heartbeats on a slow query) — skip those, only real results
                // count toward the page.
                if (rows[i] && rows[i].document) {
                    var d = _decodeDoc(rows[i].document)
                    if (d !== null) {
                        decoded.push(d)
                        rawCursorValues.push(orderByField === "__name__"
                            ? rows[i].document.name
                            : d[orderByField])
                    }
                }
            }
            var merged = PagingHelper.mergePage([], decoded, requestedLimit)
            var cursor = merged.hasMore ? rawCursorValues[merged.items.length - 1] : null
            if (callback) callback(true, { items: merged.items, nextCursor: cursor, hasMore: merged.hasMore })
        })
    }

    function put(path, data, callback, authToken) {
        var p = _splitPath(path)
        if (!p.normalizedPath) {
            if (callback) callback(false)
            return
        }

        if (p.isCollection) {
            var writes = _buildCommitWrites(p.normalizedPath, data)
            if (writes.length === 0) {
                if (callback) callback(true)
                return
            }
            _request("POST", databaseUrl + ":commit", { writes: writes }, function(ok) {
                if (callback) callback(ok)
            }, authToken)
            return
        }

        _request("PATCH", _docUrl(p.normalizedPath), _encodeDoc(data), function(ok) {
            if (!ok)
                console.warn("[Firestore] PUT failed", path)
            if (callback) callback(ok)
        }, authToken)
    }

    function patch(path, data, callback) {
        put(path, data, callback)
    }

    // Bulk upsert of ONLY the docs the caller actually changed (not a
    // collection-wide overwrite). Chunks into <=500-write commits since a
    // single Firestore :commit is hard-capped at 500 writes — one unbounded
    // commit would fail outright once a caller's changed-doc set crossed that
    // line. Sequential, not parallel, to avoid a burst of concurrent commits
    // against the same collection. callback(ok, errorInfo) where errorInfo is
    // null on success or { failedAtChunk: index } on failure, so the caller
    // can retry just the docs in that chunk instead of the whole batch.
    function putMany(collectionPath, docsById, callback) {
        var p = _splitPath(collectionPath)
        if (!p.normalizedPath || !p.isCollection) {
            if (callback) callback(false, { failedAtChunk: 0 })
            return
        }

        var keys = Object.keys(docsById || {})
        if (keys.length === 0) {
            if (callback) callback(true, null)
            return
        }

        var CHUNK_SIZE = 500
        var chunks = []
        for (var i = 0; i < keys.length; i += CHUNK_SIZE) {
            var chunkKeys = keys.slice(i, i + CHUNK_SIZE)
            var chunkData = {}
            for (var j = 0; j < chunkKeys.length; ++j)
                chunkData[chunkKeys[j]] = docsById[chunkKeys[j]]
            chunks.push(chunkData)
        }

        var idx = 0
        var runNext = function() {
            if (idx >= chunks.length) {
                if (callback) callback(true, null)
                return
            }
            var writes = _buildCommitWrites(p.normalizedPath, chunks[idx])
            _request("POST", databaseUrl + ":commit", { writes: writes }, function(ok) {
                if (!ok) {
                    console.warn("[Firestore] putMany chunk failed", collectionPath, "chunk:", idx)
                    if (callback) callback(false, { failedAtChunk: idx })
                    return
                }
                idx++
                runNext()
            })
        }
        runNext()
    }

    // Atomically mints the next integer from a counter document at `path`
    // (e.g. "counters/products", tenant-scoped like every other path this
    // service handles). Returns callback(ok, mintedValue).
    //
    // Why this exists: nextProductId()/nextOrderId()/nextStaffId()/
    // nextSupplierId() used to compute max(existing id numbers) + 1 from the
    // locally-synced array. That reuses an id the moment the highest-numbered
    // record is deleted (a new record can mint the SAME id a deleted one
    // used to have, silently inheriting its orphaned transaction/batch
    // history), and two devices computing max()+1 from stale local state at
    // nearly the same moment can mint the SAME id, with the second write
    // silently clobbering the first.
    //
    // This uses Firestore's documented optimistic-concurrency pattern for
    // building a counter without a real transaction: read the counter doc
    // (to get its current value AND updateTime), then commit a write guarded
    // by a `currentDocument` precondition (updateTime must still match, or
    // — for the very first mint — the doc must not exist yet). If another
    // client's write landed in between, the precondition fails, the commit
    // is rejected, and we retry with a fresh read. Firestore itself is the
    // single source of truth serializing the race, not our client.
    //
    // `seedValue` is only used the FIRST time this counter doc is created —
    // pass the current max(existing ids) so a tenant with pre-existing data
    // doesn't restart numbering from 1. Once the doc exists, its stored
    // value is authoritative and `seedValue` is ignored on every later call.
    // Exponential backoff with jitter for mint retries — see _delayedRetry.
    // Deterministic given the same randomFn, so this piece alone is
    // Node-testable; the actual Timer-based delay execution below isn't.
    function _computeRetryDelayMs(attempt, baseMs, maxMs, randomFn) {
        var rand = randomFn || Math.random
        var exp = Math.min(maxMs, baseMs * Math.pow(2, attempt))
        return Math.round(exp * (0.5 + rand()))
    }

    // Runs fn() after a jittered exponential-backoff delay instead of
    // immediately — without this, several concurrent mint calls hitting the
    // same precondition conflict would all retry in the same instant and
    // likely collide again. Each call creates its own independent one-shot
    // Timer (not a shared/reused one), so concurrent retries for different
    // counters (e.g. "counters/products" and "counters/suppliers" minting
    // at the same time) never interfere with each other.
    function _delayedRetry(attempt, fn) {
        var delayMs = _computeRetryDelayMs(attempt, 100, 2000)
        var timer = Qt.createQmlObject(
            'import QtQuick; Timer { interval: ' + delayMs + '; running: true; repeat: false }',
            root, "mintRetryTimer")
        timer.triggered.connect(function() {
            timer.destroy()
            fn()
        })
    }

    function mintCounterValue(path, seedValue, callback, _attempt) {
        var attempt = _attempt || 0
        if (attempt >= 8) {
            console.warn("[Firestore] mintCounterValue gave up after", attempt, "attempts:", path)
            if (callback) callback(false, 0)
            return
        }

        var p = _splitPath(path)
        if (!p.normalizedPath) { if (callback) callback(false, 0); return }
        var docName = "projects/" + projectId + "/databases/" + databaseId + "/documents/" + p.normalizedPath

        _request("GET", _docUrl(p.normalizedPath), null, function(getOk, doc, status) {
            // A 404 (doc doesn't exist yet) is an expected first-run state,
            // not a failure — only bail out on OTHER errors.
            var exists = getOk && doc !== null
            if (!getOk && status !== 404) { if (callback) callback(false, 0); return }

            var current = exists ? (Number(_decodeDoc(doc).value) || 0) : (seedValue || 0)
            var next = current + 1

            var write = {
                update: { name: docName, fields: _encodeDoc({ value: next }).fields },
                currentDocument: exists ? { updateTime: doc.updateTime } : { exists: false }
            }
            _request("POST", databaseUrl + ":commit", { writes: [write] }, function(commitOk, commitData, commitStatus, commitError) {
                if (commitOk) { if (callback) callback(true, next); return }
                // 401/403 will never succeed by retrying — same credentials,
                // same result every time. Give up immediately instead of
                // burning all 8 attempts (and the latency of 8 fresh
                // GET+commit round trips) on something retrying can't fix.
                if (commitStatus === 401 || commitStatus === 403) {
                    console.warn("[Firestore] mintCounterValue non-retryable failure (status", commitStatus + "), giving up:", path, commitError)
                    if (callback) callback(false, 0)
                    return
                }
                // Anything else (400 FAILED_PRECONDITION — someone else's
                // write landed between our read and this commit — network
                // failure, quota, 5xx) is treated as potentially transient
                // and retried with a fresh read, same as before. Firestore
                // guarantees whoever committed first is reflected in it now.
                // Waits a jittered backoff first — an immediate retry is
                // exactly how several concurrent callers hitting the same
                // conflict end up colliding again on the very next attempt.
                _delayedRetry(attempt, function() {
                    mintCounterValue(path, seedValue, callback, attempt + 1)
                })
            })
        })
    }

    // Same as mintCounterValue, but atomically reserves `count` consecutive
    // values in ONE round-trip instead of one. callback(ok, startValue) —
    // the caller owns the exclusive range [startValue+1 .. startValue+count].
    // Needed by bulk import (upsertMany), which otherwise would need one
    // mintCounterValue round-trip PER new row — slow, and awkward to splice
    // into a loop that's synchronous everywhere else. Single-id minting
    // (mintCounterValue) is just this with count=1.
    function mintCounterBatch(path, seedValue, count, callback, _attempt) {
        var attempt = _attempt || 0
        if (count <= 0) { if (callback) callback(true, 0); return }
        if (attempt >= 8) {
            console.warn("[Firestore] mintCounterBatch gave up after", attempt, "attempts:", path)
            if (callback) callback(false, 0)
            return
        }

        var p = _splitPath(path)
        if (!p.normalizedPath) { if (callback) callback(false, 0); return }
        var docName = "projects/" + projectId + "/databases/" + databaseId + "/documents/" + p.normalizedPath

        _request("GET", _docUrl(p.normalizedPath), null, function(getOk, doc, status) {
            var exists = getOk && doc !== null
            if (!getOk && status !== 404) { if (callback) callback(false, 0); return }

            var current = exists ? (Number(_decodeDoc(doc).value) || 0) : (seedValue || 0)
            var reservedThrough = current + count

            var write = {
                update: { name: docName, fields: _encodeDoc({ value: reservedThrough }).fields },
                currentDocument: exists ? { updateTime: doc.updateTime } : { exists: false }
            }
            _request("POST", databaseUrl + ":commit", { writes: [write] }, function(commitOk, commitData, commitStatus, commitError) {
                if (commitOk) { if (callback) callback(true, current); return }
                if (commitStatus === 401 || commitStatus === 403) {
                    console.warn("[Firestore] mintCounterBatch non-retryable failure (status", commitStatus + "), giving up:", path, commitError)
                    if (callback) callback(false, 0)
                    return
                }
                _delayedRetry(attempt, function() {
                    mintCounterBatch(path, seedValue, count, callback, attempt + 1)
                })
            })
        })
    }

    function remove(path, callback) {
        var p = _splitPath(path)
        if (!p.normalizedPath || p.isCollection) {
            if (callback) callback(false)
            return
        }

        _request("DELETE", _docUrl(p.normalizedPath), null, function(ok) {
            if (!ok)
                console.warn("[Firestore] DELETE failed", path)
            if (callback) callback(ok)
        })
    }

    function toArray(data) {
        if (data === undefined || data === null) return []
        if (Array.isArray(data)) return data

        var keys = Object.keys(data)
        var arr = []
        for (var i = 0; i < keys.length; i++) {
            var v = data[keys[i]]
            if (v !== null && typeof v === "object") arr.push(v)
        }
        return arr
    }
}
