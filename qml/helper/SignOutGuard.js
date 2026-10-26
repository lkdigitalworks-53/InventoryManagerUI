.pragma library
.import "DescribeItem.js" as DescribeItem
.import "StuckWrites.js" as StuckWrites

// What signing out (or leaving a workspace) would throw away: the queued writes in
// OutboxStore and the queued photo uploads in PhotoQueue, as rows and plain-language
// consequences for SignOutSheet. Design: docs/superpowers/specs/2026-10-26-signout-guard-design.md
//
// Pure: no QML, no stores. The caller passes the two item arrays and, optionally,
// two lookups it owns (opts.inFlight, opts.productName). Never throws: a malformed
// item is still counted (it would be dropped too) and shown as "Pending change";
// a lookup that throws is treated as "no answer".

var DEFAULT_MAX_ROWS = 5

var LABEL = { waiting: "Waiting", sending: "Sending", attention: "Needs attention" }

function _list(v) { return Array.isArray(v) ? v : [] }

function _ask(fn, arg) {
    if (typeof fn !== "function") return undefined
    try { return fn(arg) } catch (e) { return undefined }
}

// "attention" = parked (server said write-rejected) OR stuck (failing, still retrying);
// both are "not syncing" in the stuck-writes sheet. Read from the persisted item.
function _outboxState(item, opts) {
    if (item && typeof item === "object") {
        if (StuckWrites.isParkedItem(item) || item.stuck === true) return "attention"
        if (_ask(opts.inFlight, item.requestId) === true) return "sending"
    }
    return "waiting"
}

// PhotoQueue item.state: "enqueued" | "uploading" | "retrying" | "failed".
function _photoState(item) {
    var s = item && typeof item === "object" ? item.state : ""
    if (s === "failed") return "attention"
    if (s === "uploading") return "sending"
    return "waiting"
}

function _photoRow(item, opts) {
    var id = item && typeof item === "object" && typeof item.productId === "string" ? item.productId : ""
    var name = id.length > 0 ? _ask(opts.productName, id) : ""
    var state = _photoState(item)
    return {
        kind: "photo",
        title: "Product photo",
        detail: (typeof name === "string" && name.trim().length > 0) ? name.trim() : id,
        state: state,
        stateLabel: LABEL[state]
    }
}

function _outboxRow(item, opts) {
    var d = DescribeItem.describe(item)
    var state = _outboxState(item, opts)
    var isCompletion = !!item && Array.isArray(item.ops) && item.opType === "completeOrder"
    return {
        kind: isCompletion ? "completion" : "change",
        title: d.title,
        detail: d.detail,
        state: state,
        stateLabel: LABEL[state]
    }
}

function _summary(count) {
    if (count === 0) return "Everything has synced. Nothing will be lost."
    return count === 1 ? "1 change hasn't reached the server."
                       : count + " changes haven't reached the server."
}

// -> { count, rows: [{ kind, title, detail, state, stateLabel }] (first maxRows),
//      more, summary, consequences: [string], hasSending }
// opts (all optional): inFlight(requestId) -> bool, productName(productId) -> string,
// maxRows (default 5), leaving (true = leave-workspace wording).
function build(outboxItems, photoItems, opts) {
    var o = (opts && typeof opts === "object") ? opts : {}
    var outbox = _list(outboxItems)
    var photos = _list(photoItems)

    var all = []
    var i
    for (i = 0; i < outbox.length; ++i) all.push(_outboxRow(outbox[i], o))
    for (i = 0; i < photos.length; ++i) all.push(_photoRow(photos[i], o))

    var count = all.length
    var max = (typeof o.maxRows === "number" && isFinite(o.maxRows) && o.maxRows >= 1)
        ? Math.floor(o.maxRows) : DEFAULT_MAX_ROWS
    var rows = all.slice(0, max)

    var hasSending = false
    var kinds = { completion: false, change: false, photo: false }
    for (i = 0; i < all.length; ++i) {
        if (all[i].state === "sending") hasSending = true
        kinds[all[i].kind] = true
    }

    var consequences = []
    if (count > 0) {
        consequences.push(o.leaving === true
            ? "Leaving signs you out and discards these. They will not sync, even if you rejoin or sign back in as the same user."
            : "Signing out discards these. They will not sync when you sign back in, even as the same user.")
        if (hasSending)
            consequences.push("Changes marked Sending may or may not have been saved. Check after you sign in.")
        if (kinds.completion)
            consequences.push("A queued order completion leaves the order Pending. Complete it again after signing in.")
        if (kinds.change)
            consequences.push("Edits, additions and deletions must be entered again.")
        if (kinds.photo)
            consequences.push("Photos that were not uploaded are lost.")
        consequences.push("Data stored on this device is also cleared.")
    }

    return {
        count: count,
        rows: rows,
        more: count - rows.length,
        summary: _summary(count),
        consequences: consequences,
        hasSending: hasSending
    }
}
