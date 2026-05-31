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

    Component.onCompleted: _load()

    // ── Lifecycle ──────────────────────────────────────────────────────────

    function _load() {
        suppliers = []
        _fetchFromFirebase()
    }

    function _fetchFromFirebase() {
        FirebaseService.get("suppliers", function(ok, data) {
            if (!ok) {
                console.warn("[SupplierStore] Firestore sync failed",
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
                return
            }
            var arr = FirebaseService.toArray(data)
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
            arr.sort(function(a, b) {
                return (a.name || "").localeCompare(b.name || "")
            })
            suppliers = arr
            console.log("[SupplierStore] Synced", arr.length, "suppliers")
        })
    }

    function syncFromFirebase() { _fetchFromFirebase() }

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
        FirebaseService.put("suppliers/" + doc.supplierId, doc, function(ok) {
            if (!ok) console.warn("[SupplierStore] write failed for", doc.supplierId,
                                  FirebaseService.lastStatusCode, FirebaseService.lastError)
        })
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
        FirebaseService.put("suppliers/" + supplierId, s, function(ok) {
            if (!ok) console.warn("[SupplierStore] update failed for", supplierId)
        })
        return s
    }

    // Delete is rare — historical batches still reference the id, so the
    // remove only drops the master record. Analytics that walk batches will
    // show the supplier as "(removed)" via `nameOf` returning "".
    function removeSupplier(supplierId) {
        var arr = []
        var found = false
        for (var i = 0; i < suppliers.length; ++i) {
            if (suppliers[i].supplierId === supplierId) { found = true; continue }
            arr.push(suppliers[i])
        }
        if (!found) return
        suppliers = arr
        FirebaseService.remove("suppliers/" + supplierId, function(ok) {
            if (!ok) console.warn("[SupplierStore] delete failed for", supplierId)
        })
    }
}
