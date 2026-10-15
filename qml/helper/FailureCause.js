.pragma library

// Plain-language CAUSE for a failed order completion / stuck write.
// Design: docs/superpowers/specs/2026-10-13-completion-error-cause-design.md
//
// Pure: no QML, no stores, never throws. Every function returns { text, kind }
// with a non-empty `text`, so a caller can show it without a null check.
// Wording rule: never assert a cause the code cannot know. A 500 `write-rejected`
// says "usually", because the server keeps only the CLASS of the error (Q-EC-1 A).

var GENERIC_REJECT = "The server rejected this change"
var GENERIC_WRITE = "The server returned an error"

function _str(v) { return typeof v === "string" ? v.trim() : "" }

// A code is only echoed back when it is a short, plain token, so a hostile or
// garbled body can never put arbitrary text on screen.
function _safeCode(code) {
    return (typeof code === "string" && /^[a-z0-9_-]{1,40}$/i.test(code)) ? code : ""
}

// An operation rejection body ({ error, opIndex, current, conflict }) as the
// server's recordOperation answers it. `name` = the product / record name the
// rejected op touches ("" when unknown).
function forRejection(rejection, name) {
    var code = (rejection && typeof rejection === "object") ? _str(rejection.error) : ""
    var who = _str(name)
    switch (code) {
    case "insufficient-quantity":
        return { kind: "stock", text: (who ? who + ": " : "") + "stock ran out before this order could complete" }
    case "conflict":
        return { kind: "conflict", text: "Another device changed this at the same time" }
    case "not-found":
        return { kind: "missing", text: "A record this order needs was deleted on another device" }
    case "operation-too-large":
        return { kind: "limit", text: "This order is too large to complete in one step" }
    case "request-id-in-use":
        return { kind: "duplicate", text: "This request was already used for a different change. Try again" }
    case "missing-fields":
    case "unsupported-op-type":
    case "invalid-request-id":
    case "empty-operation":
    case "unsupported-kind":
    case "invalid-entity-id":
    case "cascade-delete-not-allowed":
        return { kind: "bug", text: "The server cannot accept this request. This is an app problem, please report it (" + code + ")" }
    }
    var safe = _safeCode(code)
    return { kind: "unknown", text: safe ? GENERIC_REJECT + " (" + safe + ")" : GENERIC_REJECT }
}

// A failed SEND of a queued write: `code` = the 500 body's `error` string ("" when
// none), `status` = HTTP status number, or "timeout" (StuckWrites.TIMEOUT).
function forWriteError(code, status) {
    var c = _str(code)
    if (c === "write-rejected")
        return { kind: "rejected", text: "The server refused to save this. Usually a permission change, invalid data, or a record deleted elsewhere" }
    // HTTP 403 `no-tenant-context`: the server could not resolve this account's shop, which
    // happens when the member was deactivated or removed, or the account has no shop. The code
    // cannot tell which, so the text says "may" (never assert a cause the code cannot know).
    if (c === "no-tenant-context")
        return { kind: "access", text: "The server no longer accepts your access to this shop. Your account may have been changed or deactivated. Ask the shop owner" }
    if (c === "write-unavailable")
        return { kind: "transient", text: "The server is temporarily unavailable" }
    if (c === "write-failed")
        return { kind: "unknown", text: "The server hit an unexpected error" }
    if (status === "timeout")
        return { kind: "timeout", text: "The server did not answer in time" }
    if (typeof status === "number" && isFinite(status) && status >= 400)
        return { kind: "unknown", text: GENERIC_WRITE + " (HTTP " + Math.floor(status) + ")" }
    return { kind: "unknown", text: GENERIC_WRITE }
}
