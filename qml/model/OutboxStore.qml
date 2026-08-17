pragma Singleton
import QtQuick
import QtCore

import "../helper/SettingsPath.js" as SettingsPath

// Durable outbox for compliance-gateway calls (P0). Every mutation routed
// through Gateway is enqueued here FIRST (persisted to QSettings), then sent.
// On success the item is dequeued; on failure it stays and is retried with
// exponential backoff. This is what turns the old fire-and-forget Firestore
// writes into a guarantee that a books-of-account ledger entry is never
// silently lost — it survives app relaunch, offline periods, and crashes.
//
// Per the singleton constraint (SKILLS.md Skill 20) this QtObject holds no
// Timer/Connections — Gateway owns the drain timer and calls drainDue()/
// markSent()/markFailed() against this store.
//
// Queue item shape (single mutation):
//   { requestId, entity, entityId, action, before, after,
//     clientTimestamp, enqueuedAt, attempts, nextAttemptAt }
// Queue item shape (batch mutation, via enqueueBatch — backs
// Gateway.recordMutations):
//   { requestId, entity, items: [{entityId, action, before, after}, ...],
//     clientTimestamp, enqueuedAt, attempts, nextAttemptAt }
// Queue item shape (delta mutation, via enqueueDelta — new this session,
// backs Gateway.recordDelta, Component 4 of the async-write-sequencing
// design): { requestId, entity, entityId, deltas: {field: numericDelta},
//   floors: {field: minValue}, clientTimestamp, enqueuedAt, attempts,
//   nextAttemptAt } — distinguished from a plain item by having `deltas`
// instead of `before`/`after`.
// dueItems/markSent/markFailed/nextDueInMs only key off requestId, so all
// three shapes flow through them unchanged — only enqueue/enqueueBatch/
// enqueueDelta differ, in how they build the item and (new this session)
// how they coalesce with an existing not-in-flight item for the same key.
QtObject {
    id: root

    property var items: []
    property int pendingCount: 0
    property int revision: 0

    // In-flight tracking (Component 1, async-write-sequencing design §3).
    // Ephemeral — deliberately NOT persisted to Settings, since a real
    // in-flight XHR doesn't survive a relaunch anyway; on restart every item
    // in `items` is just "due" again, safely, via the Cloud Function's
    // requestId-keyed idempotency. Maps "entity/entityId" -> the requestId
    // of whichever item is currently dispatched for that key, so enqueue()
    // can tell "this candidate IS the in-flight one, don't touch its
    // payload" apart from "this key merely HAS something in flight, block
    // sending but coalescing elsewhere for this key is still fine".
    property var _inFlightKeys: ({})

    // Backoff schedule (ms): 2s, 8s, 30s, 2m, 10m, then capped.
    readonly property var _backoffMs: [2000, 8000, 30000, 120000, 600000]

    property Settings _settings: Settings {
        category: "OutboxStore"
        // See qml/helper/SettingsPath.js -- "" under a real app build
        // (Application.organization is set, defers to normal QSettings
        // resolution, untouched); an explicit temp-file path only when it
        // isn't (qmltestrunner), so the whole reason this store exists --
        // durability across a relaunch -- is actually exercised by the test
        // suite instead of silently no-op-ing.
        fileName: SettingsPath.settingsFileNameOverride(
                      Application.organization,
                      StandardPaths.writableLocation(StandardPaths.TempLocation))
        property string itemsJson: ""
    }

    Component.onCompleted: _load()

    function _load() {
        if (_settings.itemsJson && _settings.itemsJson.length > 2) {
            try {
                var arr = JSON.parse(_settings.itemsJson)
                if (Array.isArray(arr)) items = arr
            } catch (e) {
                items = []
            }
        }
        _refresh()
    }

    function _save() {
        _settings.itemsJson = JSON.stringify(items)
        _refresh()
    }

    function _refresh() {
        pendingCount = items.length
        revision++
    }

    function _keyFor(entity, entityId) {
        return entity + "/" + entityId
    }

    // Every key an item touches — one for a single call, one per member
    // entityId for a batch. Delta items ("deltas" present) key the same way
    // a single call does, since they're always single-entity.
    function _keysForItem(item) {
        if (item.items) {
            var out = []
            for (var i = 0; i < item.items.length; ++i)
                out.push(_keyFor(item.entity, item.items[i].entityId))
            return out
        }
        return [_keyFor(item.entity, item.entityId)]
    }

    // Is ANYTHING in flight for any key this item touches? Used by
    // dueItems() — blocks both re-sending the actual in-flight item AND
    // sending a waiting sibling for the same key before its predecessor
    // clears.
    function _isItemBlocked(item) {
        var keys = _keysForItem(item)
        for (var i = 0; i < keys.length; ++i)
            if (_inFlightKeys[keys[i]]) return true
        return false
    }

    // Called by Gateway right before it fires the network request for
    // `item` (single, batch, or delta — all pass their stored item object,
    // not just a requestId, so this never needs to re-look-up an item that
    // may already have been removed by markSent by the time it's called).
    function markInFlight(item) {
        var keys = _keysForItem(item)
        var map = Object.assign({}, _inFlightKeys)
        for (var i = 0; i < keys.length; ++i) map[keys[i]] = item.requestId
        _inFlightKeys = map
    }

    // Called by Gateway once `item`'s request has resolved, success or
    // failure — frees its keys for both draining and future coalescing.
    // Only clears entries this exact item owns (matched by requestId), so a
    // stale/duplicate call can't accidentally free a DIFFERENT item's hold.
    function clearInFlight(item) {
        var keys = _keysForItem(item)
        var map = Object.assign({}, _inFlightKeys)
        for (var i = 0; i < keys.length; ++i) {
            if (map[keys[i]] === item.requestId) delete map[keys[i]]
        }
        _inFlightKeys = map
    }

    // Append a new call. `requestId` is the idempotency key — the gateway
    // dedupes on it, so re-enqueuing the same id is harmless. If a
    // NOT-in-flight item already exists for the same entity+entityId,
    // merges into it instead of appending (keeps the earliest
    // before/action, takes the latest after) — see design doc §3. If the
    // only existing item for this key IS the in-flight one, appends as a
    // separate held item instead of touching its already-dispatched payload.
    // Returns the stored (possibly merged) item.
    function enqueue(call) {
        var nowMs = Date.now()
        var arr = items.slice()

        for (var i = 0; i < arr.length; ++i) {
            var candidate = arr[i]
            if (candidate.items || candidate.deltas) continue // batches/deltas aren't merge targets for a plain call
            if (candidate.entity !== call.entity || candidate.entityId !== call.entityId) continue
            var key = _keyFor(call.entity, call.entityId)
            if (_inFlightKeys[key] === candidate.requestId) continue // this IS the dispatched one — don't touch it

            arr[i] = Object.assign({}, candidate, {
                after: call.after === undefined ? null : call.after
            })
            items = arr
            _save()
            return arr[i]
        }

        var item = {
            requestId: call.requestId,
            entity: call.entity,
            entityId: call.entityId,
            action: call.action,
            before: call.before === undefined ? null : call.before,
            after: call.after === undefined ? null : call.after,
            clientTimestamp: call.clientTimestamp || new Date().toISOString(),
            enqueuedAt: nowMs,
            attempts: 0,
            nextAttemptAt: nowMs
        }
        arr.push(item)
        items = arr
        _save()
        return item
    }

    // Append a new batch call (Gateway.recordMutations) — one outbox item
    // represents the WHOLE batch; it's retried as a unit, not per-sub-item.
    function enqueueBatch(call) {
        var nowMs = Date.now()
        var item = {
            requestId: call.requestId,
            entity: call.entity,
            items: call.items || [],
            clientTimestamp: call.clientTimestamp || new Date().toISOString(),
            enqueuedAt: nowMs,
            attempts: 0,
            nextAttemptAt: nowMs
        }
        var arr = items.slice()
        arr.push(item)
        items = arr
        _save()
        return item
    }

    // Append a new delta call (Gateway.recordDelta — Component 4). Unlike
    // enqueue(), coalescing SUMS the deltas for a matching not-in-flight key
    // instead of taking the latest — two queued stock deductions for the
    // same batch should both apply, not one clobber the other. Floors are
    // taken from the LATEST call (they're a property of the call site, not
    // something that accumulates).
    function enqueueDelta(call) {
        var nowMs = Date.now()
        var arr = items.slice()

        for (var i = 0; i < arr.length; ++i) {
            var candidate = arr[i]
            if (!candidate.deltas) continue
            if (candidate.entity !== call.entity || candidate.entityId !== call.entityId) continue
            var key = _keyFor(call.entity, call.entityId)
            if (_inFlightKeys[key] === candidate.requestId) continue

            var summed = Object.assign({}, candidate.deltas)
            var callDeltas = call.deltas || {}
            for (var field in callDeltas)
                summed[field] = (summed[field] || 0) + callDeltas[field]

            arr[i] = Object.assign({}, candidate, {
                deltas: summed,
                floors: call.floors || candidate.floors,
                clamps: call.clamps || candidate.clamps
            })
            items = arr
            _save()
            return arr[i]
        }

        var item = {
            requestId: call.requestId,
            entity: call.entity,
            entityId: call.entityId,
            deltas: call.deltas || {},
            floors: call.floors || {},
            clamps: call.clamps || {},
            clientTimestamp: call.clientTimestamp || new Date().toISOString(),
            enqueuedAt: nowMs,
            attempts: 0,
            nextAttemptAt: nowMs
        }
        arr.push(item)
        items = arr
        _save()
        return item
    }

    // Items whose nextAttemptAt is due, oldest first, and whose key isn't
    // currently blocked by something already in flight. Gateway sends these.
    function dueItems() {
        var nowMs = Date.now()
        var out = []
        for (var i = 0; i < items.length; ++i) {
            if ((items[i].nextAttemptAt || 0) > nowMs) continue
            if (_isItemBlocked(items[i])) continue
            out.push(items[i])
        }
        return out
    }

    function hasPending() { return items.length > 0 }

    // Soonest nextAttemptAt across all items, or -1 if empty. Gateway uses
    // this to schedule its drain timer without busy-polling.
    function nextDueInMs() {
        if (items.length === 0) return -1
        var nowMs = Date.now()
        var soonest = -1
        for (var i = 0; i < items.length; ++i) {
            var due = Math.max(0, (items[i].nextAttemptAt || 0) - nowMs)
            if (soonest < 0 || due < soonest) soonest = due
        }
        return soonest
    }

    function markSent(requestId) {
        var arr = []
        for (var i = 0; i < items.length; ++i)
            if (items[i].requestId !== requestId) arr.push(items[i])
        items = arr
        _save()
    }

    // Bump attempts and push out nextAttemptAt per the backoff schedule.
    function markFailed(requestId) {
        var arr = items.slice()
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].requestId !== requestId) continue
            var attempts = (arr[i].attempts || 0) + 1
            var idx = Math.min(attempts - 1, _backoffMs.length - 1)
            var delay = _backoffMs[idx]
            arr[i] = Object.assign({}, arr[i], {
                attempts: attempts,
                nextAttemptAt: Date.now() + delay
            })
            break
        }
        items = arr
        _save()
    }

    // Drop the whole queue. Used on sign-out so a pending tenant's writes
    // never replay under the next account.
    function clear() {
        items = []
        _settings.itemsJson = ""
        _inFlightKeys = ({})
        _refresh()
    }
}
