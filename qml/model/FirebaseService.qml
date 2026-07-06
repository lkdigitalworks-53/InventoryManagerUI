pragma Singleton
import QtQuick
import "../helper/EnvConfig.js" as EnvConfig

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
