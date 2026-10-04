.pragma library

// Client-side guard for the Firestore 1 MiB document limit (PR #121 device obs 1: a product
// edit with a > 1 MiB description was accepted into the outbox, the server rejected it, and
// the write retried / parked for no reason). Refuse BEFORE anything is queued.
//
// This is an ESTIMATE of Firestore's stored size (field name bytes + 1, string bytes + 1,
// number 8, boolean/null 1, + 32 per doc), not the exact figure: the server stays the
// authority. RESERVE_BYTES leaves room for the document name and the fields the server adds,
// so a doc this file accepts is very unlikely to be rejected for size.

var MAX_DOC_BYTES = 1048576   // 1 MiB, the Firestore hard limit
var RESERVE_BYTES = 4096      // document name + server-added fields (decision, see test plan)
var LIMIT_BYTES = MAX_DOC_BYTES - RESERVE_BYTES

// UTF-8 byte length without TextEncoder (not available in QML's JS engine). Lone surrogates
// count as 3 bytes (U+FFFD), a valid pair as 4.
function utf8Bytes(s) {
    if (s === undefined || s === null) return 0
    var str = String(s)
    var n = 0
    for (var i = 0; i < str.length; ++i) {
        var c = str.charCodeAt(i)
        if (c < 0x80) n += 1
        else if (c < 0x800) n += 2
        else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length
                 && str.charCodeAt(i + 1) >= 0xDC00 && str.charCodeAt(i + 1) <= 0xDFFF) { n += 4; ++i }
        else n += 3
    }
    return n
}

function valueBytes(v) {
    if (v === undefined || v === null) return 1
    var t = typeof v
    if (t === "boolean") return 1
    if (t === "number") return 8
    if (t === "string") return utf8Bytes(v) + 1
    if (Array.isArray(v)) {
        var a = 0
        for (var i = 0; i < v.length; ++i) a += valueBytes(v[i])
        return a
    }
    if (t === "object") {
        var m = 0
        var keys = Object.keys(v)
        for (var k = 0; k < keys.length; ++k) {
            if (v[keys[k]] === undefined) continue // never sent
            m += utf8Bytes(keys[k]) + 1 + valueBytes(v[keys[k]])
        }
        return m
    }
    return 0
}

function docBytes(doc) { return valueBytes(doc) + 32 }

// true = too big to send. A non-object (null/undefined) is never "too big".
function exceedsDoc(doc) {
    if (doc === undefined || doc === null || typeof doc !== "object") return false
    return docBytes(doc) > LIMIT_BYTES
}
