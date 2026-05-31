pragma Singleton
import QtQuick

// FIFO backfill is intentionally a no-op now. The earlier implementation
// promoted every PartyStore name into a Supplier and synthesised batches
// from `purchase`/`created` transactions — but PartyStore is QSettings-
// backed (not tenant-scoped), and the new write paths (`recordCreated` /
// `recordPurchase`) already create batches. Running on a fresh account
// therefore (a) leaked the previous account's supplier names into the new
// tenant and (b) duplicated every newly-created batch.
//
// We keep the singleton + flag doc so older builds that already ran the
// migration are still considered "done" and so the call site in Main.qml
// continues to compile. The Firestore flag write makes future logic
// idempotent if a real migration is ever needed again.
QtObject {
    id: root

    property bool busy: false
    property bool _completed: false

    function runIfNeeded() {
        if (busy || _completed) return
        if (!AuthStore || !AuthStore.tenantId) return
        busy = true
        var nowIso = new Date().toISOString()
        FirebaseService.put("_migrations/fifo_v1",
                            { done: true, completedAt: nowIso, note: "no-op" },
                            function(ok) {
            _completed = true
            busy = false
            if (!ok) console.warn("[Migration] fifo_v1 flag write failed (no-op)")
        })
    }

    // Reset the per-process flag on sign-out so the next tenant context can
    // re-evaluate (still a no-op, but cheap and tidy).
    function reset() {
        _completed = false
        busy = false
    }
}
