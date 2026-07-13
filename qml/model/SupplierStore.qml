pragma Singleton
import QtQuick

// First-class supplier records, persisted to Firestore at
// `tenants/{tenantId}/suppliers/{supplierId}`. Replaces the old PartyStore
// (which was a QSettings-backed list of bare names): suppliers now carry
// metadata that survives a device wipe and can be referenced by stable id
// from `stock_batches`, `transactions`, and the analytics layer.
//
// Naming convention: ids are `SUP-NNN` (zero-padded), generated locally
// from the highest seen number — same shape as InventoryStore / OrdersStore.
QtObject {
    id: root

    // Live array of supplier records — newest mutation bumps `revision` so
    // bindings refresh deterministically (a bare property change is sometimes
    // missed by Repeater / ColumnLayout the same way it is in OrdersStore).
    property var suppliers: []
    property int revision: 0
    onSuppliersChanged: revision++

    // Bounded collection (capped by realistic business size) — the UI needs
    // the full set for search/dropdowns, so we page to exhaustion rather than
    // exposing a partial list. Same pattern as InventoryStore/StaffStore.
    // Ordered by Firestore's document name (the query() default), not
    // createdAt — some legacy supplier docs predate that field entirely (see
    // the "!s.createdAt" default below), and Firestore's orderBy silently
    // EXCLUDES documents missing the ordered field from query results.
    // __name__ is always present on every document, so nothing gets dropped.
    readonly property int _pageSize: 50
    property bool hasMore: true
    property bool loadingMore: false
    property var _cursor: null

    // Only fetch here if tenant context is ALREADY known (lazy/warm
    // creation). On cold start with a persisted session this singleton could
    // otherwise be created before AuthStore.loadSession() has run, hitting
    // Firestore with an unscoped path and 403. Main.qml's
    // onTenantContextReady already re-syncs every store once tenant context
    // resolves — defer to that.
    Component.onCompleted: {
        if (AuthStore.tenantId.length > 0)
            _load()
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    function _load() {
        _resetAndFetch()
    }

    function _resetAndFetch() {
        suppliers = []
        hasMore = true
        _cursor = null
        _fetchFromFirebase()
    }

    function _normalizeSuppliers(arr) {
        for (var i = 0; i < arr.length; ++i) {
            var s = arr[i]
            if (!s.supplierId) s.supplierId = s.id || ""
            if (!s.name) s.name = ""
            if (!s.contact) s.contact = ""
            if (s.leadTimeDays === undefined || s.leadTimeDays === null) s.leadTimeDays = 0
            if (!s.terms) s.terms = ""
            if (!s.notes) s.notes = ""
            if (!s.createdAt) s.createdAt = ""
            if (!s.updatedAt) s.updatedAt = ""
        }
        return arr
    }

    function _fetchFromFirebase() {
        if (loadingMore) return
        loadingMore = true
        FirebaseService.query("suppliers", { limit: _pageSize, startAfter: _cursor }, function(ok, result) {
            loadingMore = false
            if (!ok || !result) {
                console.warn("[SupplierStore] Firestore sync failed",
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
                return
            }
            var arr = suppliers.concat(_normalizeSuppliers(result.items))
            arr.sort(function(a, b) {
                return (a.name || "").localeCompare(b.name || "")
            })
            suppliers = arr
            hasMore = result.hasMore
            _cursor = result.nextCursor
            if (hasMore) {
                // Bounded collection: keep paging until Firestore reports no
                // more pages, so `suppliers` ends up complete either way —
                // just fetched in bounded chunks instead of one unbounded
                // request.
                _fetchFromFirebase()
            } else {
                console.log("[SupplierStore] Synced", suppliers.length, "suppliers (all pages)")
            }
        })
    }

    function syncFromFirebase() { _resetAndFetch() }

    // Drop in-memory state. Used on sign-out so a relogin doesn't briefly
    // show the previous tenant's supplier list.
    function clear() {
        suppliers = []
        revision++
    }

    // ── Identity helpers ───────────────────────────────────────────────────

    function nextSupplierId() {
        var max = 0
        for (var i = 0; i < suppliers.length; ++i) {
            var num = parseInt(String(suppliers[i].supplierId).split('-')[1])
            if (!isNaN(num) && num > max) max = num
        }
        return 'SUP-' + String(max + 1).padStart(3, '0')
    }

    function getById(id) {
        if (!id) return null
        for (var i = 0; i < suppliers.length; ++i)
            if (suppliers[i].supplierId === id) return suppliers[i]
        return null
    }

    function findByName(name) {
        if (!name) return null
        var lower = String(name).toLowerCase()
        for (var i = 0; i < suppliers.length; ++i)
            if ((suppliers[i].name || "").toLowerCase() === lower) return suppliers[i]
        return null
    }

    // Convenience for UI bindings that only need the display name; never
    // throws when `id` doesn't resolve so chip labels degrade gracefully.
    function nameOf(id) {
        var s = getById(id)
        return s ? s.name : ""
    }

    // ── CRUD ───────────────────────────────────────────────────────────────

    // Adds a supplier (deduped case-insensitively by name). Returns the new
    // record on success, or the existing record if the name already exists —
    // callers can read `.supplierId` without branching.
    function addSupplier(fields) {
        if (!fields || !fields.name) return null
        var trimmed = String(fields.name).trim()
        if (trimmed.length === 0) return null
        var existing = findByName(trimmed)
        if (existing) return existing

        var nowIso = new Date().toISOString()
        var doc = {
            supplierId: nextSupplierId(),
            name: trimmed,
            contact: fields.contact || "",
            leadTimeDays: parseInt(fields.leadTimeDays) || 0,
            terms: fields.terms || "",
            notes: fields.notes || "",
            createdAt: nowIso,
            updatedAt: nowIso
        }

        var arr = suppliers.slice()
        arr.push(doc)
        arr.sort(function(a, b) { return (a.name || "").localeCompare(b.name || "") })
        suppliers = arr
        Gateway.recordMutation("supplier", doc.supplierId, "create", null, doc)
        return doc
    }

    // Patch an existing supplier — only the keys present in `fields` are
    // touched, so callers can update name without clobbering contact info.
    function updateSupplier(supplierId, fields) {
        var idx = -1
        for (var i = 0; i < suppliers.length; ++i)
            if (suppliers[i].supplierId === supplierId) { idx = i; break }
        if (idx < 0) return null
        var arr = suppliers.slice()
        var before = Object.assign({}, arr[idx])
        var s = Object.assign({}, arr[idx])
        if (fields.name !== undefined)         s.name = String(fields.name).trim()
        if (fields.contact !== undefined)      s.contact = fields.contact
        if (fields.leadTimeDays !== undefined) s.leadTimeDays = parseInt(fields.leadTimeDays) || 0
        if (fields.terms !== undefined)        s.terms = fields.terms
        if (fields.notes !== undefined)        s.notes = fields.notes
        s.updatedAt = new Date().toISOString()
        arr[idx] = s
        arr.sort(function(a, b) { return (a.name || "").localeCompare(b.name || "") })
        suppliers = arr
        Gateway.recordMutation("supplier", supplierId, "update", before, s)
        return s
    }

    // Delete is rare — historical batches still reference the id, so the
    // remove only drops the master record. Analytics that walk batches will
    // show the supplier as "(removed)" via `nameOf` returning "".
    function removeSupplier(supplierId) {
        var arr = []
        var found = false
        var before = null
        for (var i = 0; i < suppliers.length; ++i) {
            if (suppliers[i].supplierId === supplierId) { found = true; before = Object.assign({}, suppliers[i]); continue }
            arr.push(suppliers[i])
        }
        if (!found) return
        suppliers = arr
        Gateway.recordMutation("supplier", supplierId, "delete", before, null)
    }
}
