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

// Cleans a persisted list. Drops anything that cannot be replayed safely, in particular items
// saved before this fix (no tenantId): replaying them under whichever tenant is signed in is
// exactly the bug. -> { items, dropped }
function normalize(list) {
    var src = Array.isArray(list) ? list : []
    var items = []
    for (var i = 0; i < src.length; ++i) if (_valid(src[i])) items.push(src[i])
    return { items: items, dropped: src.length - items.length }
}

// Items queued under `tenantId`. Empty when no tenant is signed in.
function forTenant(list, tenantId) {
    if (!_isTenant(tenantId) || !Array.isArray(list)) return []
    return list.filter(function(it) { return !!it && it.tenantId === tenantId })
}

// Does `tenantId` owe a batch for `productId`? (Hides the product from order pickers.)
function has(list, tenantId, productId) {
    var mine = forTenant(list, tenantId)
    for (var i = 0; i < mine.length; ++i) if (mine[i].productId === productId) return true
    return false
}

// The items a retry pass should start now: this tenant's, not already in flight.
// inFlight = { itemId: true }.
function due(list, tenantId, inFlight) {
    var busy = (inFlight && typeof inFlight === "object") ? inFlight : {}
    return forTenant(list, tenantId).filter(function(it) { return busy[it.id] !== true })
}

// The same tenant, and a real one. A retry whose mint answers after the person switched
// account must NOT write the batch: it stays queued for its own tenant.
function sameTenant(itemTenant, currentTenant) {
    return _isTenant(itemTenant) && itemTenant === currentTenant
}

// A new list without the item `id` (by id, not index: the list may have changed meanwhile).
function without(list, id) {
    return Array.isArray(list) ? list.filter(function(it) { return !it || it.id !== id }) : []
}
