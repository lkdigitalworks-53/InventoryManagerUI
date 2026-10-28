.pragma library

// Tenant rules for StockBatchStore's durable queue of batch-id mints that failed
// (E2E-TESTING-ROADMAP item 1, Decision 1). Design: docs/superpowers/specs/2026-10-26-pending-mints-tenant-scope-design.md
//
// Why this exists: the queue is Settings-backed on the DEVICE and sign-out does not clear it
// (the owed batch is real: the product's stock delta already landed). A mint and the batch write
// both resolve the tenant at call time, so a retry that ran after another tenant signed in would
// mint THAT tenant's counter and write a batch for the old tenant's product id. Every queued item
// therefore carries the tenant it was queued under, and only that tenant may see it, hide a product
// for it, or retry it.
//
// Pure: no QML, no stores. Never throws; malformed input yields empty results.
// An item is { id, tenantId, productId, supplierId, qty, unitCost, note }.

function _isTenant(t) { return typeof t === "string" && t.length > 0 }

function _valid(it) {
    return !!it && typeof it === "object"
        && typeof it.id === "string" && it.id.length > 0
        && _isTenant(it.tenantId)
        && typeof it.productId === "string" && it.productId.length > 0
        && typeof it.qty === "number" && isFinite(it.qty) && it.qty > 0
}

// A new queue item, or null when it could never be replayed (no tenant, no product, qty not a
// positive finite number). qty goes through Number() so a caller passing "3" does not queue an
// item that normalize() would throw away on the next launch.
function make(id, tenantId, productId, supplierId, qty, unitCost, note) {
    var it = {
        id: id,
        tenantId: tenantId,
        productId: productId,
        supplierId: supplierId || "",
        qty: Number(qty),
        unitCost: unitCost,
        note: note || ""
    }
    return _valid(it) ? it : null
}

// Cleans a persisted list. Drops anything that cannot be replayed safely, in particular items
// saved before this fix (no tenantId): replaying them under whichever tenant is signed in is
// exactly the bug. `rejected` holds what was dropped, in order, so the caller can keep it.
// -> { items, dropped, rejected }
function normalize(list) {
    var src = Array.isArray(list) ? list : []
    var items = []
    var rejected = []
    for (var i = 0; i < src.length; ++i) {
        if (_valid(src[i])) items.push(src[i])
        else rejected.push(src[i])
    }
    return { items: items, dropped: rejected.length, rejected: rejected }
}

// Appends `entries` to a saved JSON array of quarantined items and keeps the newest `cap`
// (default 50). Quarantine, not replay: the owed batch is real money in the FIFO ledger, so a
// refused item is kept for support instead of being destroyed. A damaged `prevJson` starts a
// fresh list. -> JSON string
function appendRejected(prevJson, entries, cap) {
    var prev = []
    try {
        var parsed = JSON.parse(prevJson)
        if (Array.isArray(parsed)) prev = parsed
    } catch (e) { prev = [] }
    var all = prev.concat(Array.isArray(entries) ? entries : [])
    var keep = Math.max(1, Math.floor(cap) || 50)
    return JSON.stringify(all.slice(-keep))
}

// Items queued under `tenantId`. Empty when no tenant is signed in.
function forTenant(list, tenantId) {
    if (!_isTenant(tenantId) || !Array.isArray(list)) return []
    return list.filter(function(it) { return !!it && it.tenantId === tenantId })
}

// Does `tenantId` owe a batch for `productId`? (Hides the product from order pickers.)
// Called per product row by the pickers, so it allocates nothing.
function has(list, tenantId, productId) {
    if (!_isTenant(tenantId) || !Array.isArray(list)
            || typeof productId !== "string" || productId.length === 0) return false
    return list.some(function(it) {
        return !!it && it.tenantId === tenantId && it.productId === productId
    })
}

// The items a retry pass should start now: this tenant's, not already in flight.
// inFlight = { itemId: true }.
function due(list, tenantId, inFlight) {
    var busy = (inFlight && typeof inFlight === "object") ? inFlight : {}
    return forTenant(list, tenantId).filter(function(it) { return busy[it.id] !== true })
}

// The same tenant, and a real one. A retry whose mint answers after the person switched
// account must NOT write the batch: it stays queued for its own tenant. Also the "is this
// tenant's batch ledger loaded?" test (loadedTenant vs the signed-in tenant): nextBatchId
// floors its counter with the highest LOCAL batch id, so minting against an empty or another
// tenant's ledger could reissue a used id.
function sameTenant(itemTenant, currentTenant) {
    return _isTenant(itemTenant) && itemTenant === currentTenant
}

// A new list without the item `id` (by id, not index: the list may have changed meanwhile).
// Ids are Date.now()_random, unique per device in practice; two items sharing an id would both go.
function without(list, id) {
    return Array.isArray(list) ? list.filter(function(it) { return !it || it.id !== id }) : []
}
