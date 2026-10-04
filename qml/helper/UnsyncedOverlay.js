.pragma library

// PR #122 S4 (Taher, Q1 = Z): a product edit that is still queued (retrying, in flight or
// PARKED) must survive a re-read from the server, otherwise a relaunch inside the retry window
// shows the old value while the edit is still queued (PR #121 device obs 3).
//
// Pure helpers, no QML/outbox/network: headless test tests/tst_UnsyncedOverlay.qml.
//
// Only the fields the user actually CHANGED are replayed (diff of the queued item's `before`
// vs `after`), never the whole `after` doc: `after` also carries stock/price values as of
// edit time, and replaying those would undo a server-side change made since (a sale on
// another device). A merged queued edit keeps the earliest `before` and the latest `after`,
// so the diff is the net change.

function _same(a, b) {
    if (a === b) return true
    return JSON.stringify(a) === JSON.stringify(b)
}

// -> { field: afterValue } for every field whose value differs. `before` null/non-object
// (no snapshot stored) = every field of `after` counts as changed. `productId` is identity,
// never replayed. Never throws.
function changedFields(before, after) {
    var out = {}
    if (!after || typeof after !== "object") return out
    var hasBefore = before && typeof before === "object"
    var keys = Object.keys(after)
    for (var i = 0; i < keys.length; ++i) {
        var k = keys[i]
        if (k === "productId" || after[k] === undefined) continue
        if (!hasBefore || !_same(before[k], after[k])) out[k] = after[k]
    }
    return out
}

// -> a NEW product object with the queued edit laid over the server copy. `product` is
// untouched. A missing/invalid edit returns a shallow copy unchanged.
function overlay(product, edit) {
    var out = Object.assign({}, product)
    if (!edit || edit.action !== "update") return out
    var f = changedFields(edit.before, edit.after)
    var keys = Object.keys(f)
    for (var i = 0; i < keys.length; ++i) out[keys[i]] = f[keys[i]]
    return out
}

// products: array of normalized product docs; snapshot: OutboxStore.unsyncedByEntity("inventory").
// -> a new array, same order; only products with a queued edit are replaced.
function overlayAll(products, snapshot) {
    var out = []
    for (var i = 0; i < products.length; ++i) {
        var p = products[i]
        var s = snapshot ? snapshot[p.productId] : undefined
        out.push(s && s.edit ? overlay(p, s.edit) : p)
    }
    return out
}

// -> { productId: "pending" | "parked" } from the same snapshot.
function statesOf(snapshot) {
    var out = {}
    if (!snapshot) return out
    var ids = Object.keys(snapshot)
    for (var i = 0; i < ids.length; ++i) out[ids[i]] = snapshot[ids[i]].state
    return out
}
