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

// Codes that mean the app built a request the server's rules can never accept (never the user's doing,
// and retrying the same request cannot help). Includes the `mint` / placeholder codes of atomic-ops R2.
var _BUG_CODES = {
    "missing-fields": true, "unsupported-op-type": true, "invalid-request-id": true, "empty-operation": true,
    "unsupported-kind": true, "invalid-entity-id": true, "cascade-delete-not-allowed": true,
    "too-many-mints": true, "unknown-counter": true, "invalid-bind-name": true, "duplicate-bind-name": true,
    "unused-mint": true, "unbound-placeholder": true, "placeholder-not-allowed": true,
    "placeholder-entity-mismatch": true, "movement-qty-mismatch": true
}
function _isBugCode(code) { return Object.prototype.hasOwnProperty.call(_BUG_CODES, code) }
function _bug(code) {
    return { kind: "bug", text: "The server cannot accept this request. This is an app problem, please report it (" + code + ")" }
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
        return { kind: "limit", text: "This order has too many items to complete in one step. Move some lines, or part of a line's quantity, to a second order, then complete both" }
    case "request-id-in-use":
        return { kind: "duplicate", text: "This request was already used for a different change. Try again" }
    }
    if (_isBugCode(code)) return _bug(code)
    var safe = _safeCode(code)
    return { kind: "unknown", text: safe ? GENERIC_REJECT + " (" + safe + ")" : GENERIC_REJECT }
}

// Same as forRejection, for a rejected RESTOCK operation (atomic-ops R3). A rejection writes nothing, so every
// text here may say "nothing was added". `name` = the product name ("" when unknown).
function forRestock(rejection, name) {
    var code = (rejection && typeof rejection === "object") ? _str(rejection.error) : ""
    var who = _str(name)
    switch (code) {
    case "not-found":
        return { kind: "missing", text: (who ? who + ": " : "") + "this product is no longer on the server (probably deleted on another device). Nothing was added" }
    case "conflict":
        return { kind: "conflict", text: "Another device changed this at the same time. Nothing was added. Try again" }
    case "mint-exhausted":
        return { kind: "limit", text: "The server could not reserve a new batch number. Nothing was added. Try again in a moment; if it keeps failing, please report it (mint-exhausted)" }
    case "request-id-in-use":
        return { kind: "duplicate", text: "This request was already used for a different change. Try again" }
    case "insufficient-quantity":
    case "operation-too-large":
        return _bug(code)
    }
    return forRejection(rejection, name)
}

// The one wording for "the server refused your membership" (HTTP 403 `no-tenant-context`), shared by a
// stuck write (forWriteError) and a lock acquire (lockState below) so the two can never drift. Never
// "try again": retrying cannot help until an owner or admin restores the member.
var ACCESS_TEXT = "The server no longer accepts your access to this shop. It was most likely removed or suspended. Ask the shop owner or an admin to restore it"
function forAccess() { return { kind: "access", text: ACCESS_TEXT } }

// State name an edit dialog / bulk action keeps for a LockManager.acquire result:
// "granted" | "denied" (a real other holder) | "no-access" (membership refused, result.noAccess) |
// "error" (anything else: network, 5xx, malformed). Anything that is not clearly one of the first
// three is "error", so a junk result can never read as "someone else is editing this".
function lockState(result) {
    if (result === null || typeof result !== "object") return "error"
    if (result.granted === true) return "granted"
    if (result.noAccess === true) return "no-access"
    return result.reason === "denied" ? "denied" : "error"
}

// A failed SEND of a queued write: `code` = the 500 body's `error` string ("" when
// none), `status` = HTTP status number, or "timeout" (StuckWrites.TIMEOUT).
function forWriteError(code, status) {
    var c = _str(code)
    if (c === "write-rejected")
        return { kind: "rejected", text: "The server refused to save this. Usually a permission change, invalid data, or a record deleted elsewhere" }
    // HTTP 403 `no-tenant-context`: the gateway refused the caller's membership. Almost always the
    // member doc is gone (removed) or its status is not "active" (suspended); the same code also
    // covers an invalid role, a missing users doc and an unsafe tenant id, and the client cannot tell
    // which, so the text says "most likely" (never assert a cause the code cannot know). S2f-3.
    if (c === "no-tenant-context")
        return forAccess()
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
