pragma Singleton
import QtQuick
import "../components"

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

    // Set instead of the reset being silently dropped when _resetAndFetch()
    // arrives while a fetch is already in flight (see the guard below) --
    // e.g. a genuine account switch mid-sync. Consumed by _fetchFromFirebase's
    // callback the moment loadingMore goes back to false: that in-flight
    // fetch chain is abandoned (its result is for the stale tenant/account)
    // and a fresh _resetAndFetch() runs immediately instead. Design: SKILLS.md
    // Skill 39's "residual trade-off" note.
    property bool _resetPending: false
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
        Gateway.mutationConflicted.connect(_onMutationConflicted)
    }

    // Component 3's client-side half (review finding C3, 2026-08-06) — see
    // OrdersStore._onMutationConflicted for the full explanation. Reuses
    // _normalizeSuppliers (same function _load() already runs fetched data
    // through) so the patched record stays consistent with the array's
    // shape. Assigning `suppliers` below auto-bumps `revision` via
    // onSuppliersChanged — no manual bump needed here, unlike OrdersStore.
    function _onMutationConflicted(entity, entityId, current) {
        if (entity !== "supplier") return
        var arr = suppliers.slice()
        var idx = -1
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].supplierId === entityId) { idx = i; break }
        }
        if (current) {
            var normalized = _normalizeSuppliers([current])[0]
            if (idx >= 0) arr[idx] = normalized
            else arr.push(normalized)
        } else if (idx >= 0) {
            arr.splice(idx, 1)
        }
        suppliers = arr
        Toast.show(qsTr("This supplier was updated elsewhere — your change didn't save. Refreshed to the latest version."))
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    function _load() {
        _resetAndFetch()
    }

    function _resetAndFetch() {
        if (loadingMore) { _resetPending = true; return }
        suppliers = []
        hasMore = true
        _cursor = null
        _fetchFromFirebase()
    }

    // Legacy-data defaults for docs predating these fields — NOT a create-
    // vs-clone reshaping risk the way OrdersStore's old _clone() was (see
    // that file's 2026-07-30 note): updateSupplier/addSupplier both build
    // before/after from a plain `suppliers.slice()` + `Object.assign`, no
    // explicit field whitelist that could drift from what creation sends.
    // Keep it that way — don't introduce a reconstructing clone() here
    // without re-reading that note first.
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
            if (_resetPending) {
                _resetPending = false
                _resetAndFetch()
                return
            }
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

    // Async — see FirebaseService.mintCounterValue for why max(existing)+1
    // isn't safe (id reuse after delete, concurrent-add collisions).
    function nextSupplierId(callback) {
        var seedMax = 0
        for (var i = 0; i < suppliers.length; ++i) {
            var num = parseInt(String(suppliers[i].supplierId).split('-')[1])
            if (!isNaN(num) && num > seedMax) seedMax = num
        }
        FirebaseService.mintCounterValue("counters/suppliers", seedMax, function(ok, value) {
            callback(ok ? ('SUP-' + String(value).padStart(3, '0')) : "")
        })
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

    // Creates a supplier record with an ALREADY-MINTED id (skips
    // nextSupplierId's network round-trip). Used by bulk-import paths that
    // batch-reserve many ids in ONE round-trip upfront (see
    // InventoryStore.upsertMany) rather than minting once per row — the
    // caller is responsible for having already deduped by name and for the
    // id actually being reserved (via FirebaseService.mintCounterBatch).
    // deferWrite: see StockBatchStore.addBatch's identical pattern for why
    // (bulk import otherwise fires one individual write per new supplier).
    function addSupplierWithId(id, name, deferWrite) {
        var trimmed = String(name).trim()
        var nowIso = new Date().toISOString()
        var doc = {
            supplierId: id, name: trimmed, contact: "", leadTimeDays: 0,
            terms: "", notes: "", createdAt: nowIso, updatedAt: nowIso
        }
        var arr = suppliers.slice()
        arr.push(doc)
        arr.sort(function(a, b) { return (a.name || "").localeCompare(b.name || "") })
        suppliers = arr
        if (!deferWrite) Gateway.recordMutation("supplier", doc.supplierId, "create", null, doc)
        return doc
    }

    // Companion to addSupplierWithId(..., true) — fires ONE
    // Gateway.recordMutations() call for every doc collected across a
    // bulk-import loop, instead of one recordMutation() per new supplier.
    function addSupplierWithIdMany(docs) {
        if (!docs || docs.length === 0) return
        var mutationItems = []
        for (var i = 0; i < docs.length; ++i) {
            mutationItems.push({ entityId: docs[i].supplierId, action: "create", before: null, after: docs[i] })
        }
        Gateway.recordMutations("supplier", mutationItems)
    }

    // Adds a supplier (deduped case-insensitively by name). Async now — see
    // FirebaseService.mintCounterValue. callback(record) — record is the
    // EXISTING match if the name already existed (no network round-trip
    // needed for that case), the newly-created record on success, or null if
    // fields were invalid or minting failed.
    function addSupplier(fields, callback) {
        if (!fields || !fields.name) { if (callback) callback(null); return }
        var trimmed = String(fields.name).trim()
        if (trimmed.length === 0) { if (callback) callback(null); return }
        var existing = findByName(trimmed)
        if (existing) { if (callback) callback(existing); return }

        nextSupplierId(function(id) {
            if (!id) {
                console.warn("[SupplierStore] could not mint a supplierId — add aborted")
                if (callback) callback(null)
                return
            }
            var nowIso = new Date().toISOString()
            var doc = {
                supplierId: id,
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
            if (callback) callback(doc)
        })
    }

    // Patch an existing supplier — only the keys present in `fields` are
    // touched, so callers can update name without clobbering contact info.
    function updateSupplier(supplierId, fields) {
        var idx = -1
        for (var i = 0; i < suppliers.length; ++i)
            if (suppliers[i].supplierId === supplierId) { idx = i; break }
        if (idx < 0) return null

        if (fields.name !== undefined) {
            // addSupplier already treats names as unique (finds-or-returns
            // the existing one rather than creating a duplicate) — rename
            // should honor the same rule instead of allowing two suppliers
            // to end up sharing a name, which findByName's exact-match
            // free-text resolution (import/restock/add-product) would then
            // resolve inconsistently. Reject the whole update rather than
            // partially applying other fields — simplest to reason about,
            // matching how conflicts get handled elsewhere this session.
            var trimmedName = String(fields.name).trim()
            var lowerName = trimmedName.toLowerCase()
            for (var ci = 0; ci < suppliers.length; ++ci) {
                if (suppliers[ci].supplierId === supplierId) continue // itself is never a collision
                if ((suppliers[ci].name || "").toLowerCase() === lowerName) return null
            }
        }

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
