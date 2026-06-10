pragma Singleton
import QtQuick
import QtCore

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
// Queue item shape:
//   { requestId, entity, entityId, action, before, after,
//     clientTimestamp, enqueuedAt, attempts, nextAttemptAt }
QtObject {
    id: root

    property var items: []
    property int pendingCount: 0
    property int revision: 0

    // Backoff schedule (ms): 2s, 8s, 30s, 2m, 10m, then capped.
    readonly property var _backoffMs: [2000, 8000, 30000, 120000, 600000]

    property Settings _settings: Settings {
        category: "OutboxStore"
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

    // Append a new call. `requestId` is the idempotency key — the gateway
    // dedupes on it, so re-enqueuing the same id is harmless. Returns the
    // stored item.
    function enqueue(call) {
        var nowMs = Date.now()
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
        var arr = items.slice()
        arr.push(item)
        items = arr
        _save()
        return item
    }

    // Items whose nextAttemptAt is due, oldest first. Gateway sends these.
    function dueItems() {
        var nowMs = Date.now()
        var out = []
        for (var i = 0; i < items.length; ++i)
            if ((items[i].nextAttemptAt || 0) <= nowMs) out.push(items[i])
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
        _refresh()
    }
}
