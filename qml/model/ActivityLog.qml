pragma Singleton
import QtQuick

// In-memory activity feed. Stores write to it via record(); the dashboard
// recent-activity card and the notifications sheet read from it.
//
// Each entry: { id, kind, title, subtitle, entityId, timestamp, read, dismissed, actorUid }
//   kind: "order" | "product_added" | "product_updated" | "product_restocked"
//         | "low_stock" | "staff_added" | "staff_updated" | "import"
//   actorUid: the account that performed the action (defaults to the current
//             account at record time). Used to suppress self-notifications.
//
// THREE views share this one history:
//   • `entries`       — the full history. The dashboard recent-activity card
//                       and the Activity ("See all") page read this directly,
//                       so you always see your OWN actions in your history.
//   • `notifications` — the alerting view: history minus dismissed entries AND
//                       minus entries this account performed itself. You should
//                       not be pinged about an action you just took; the bell
//                       is for things needing attention (others' actions, etc.).
//                       The Notifications sheet reads this.
//   • `unreadCount`   — count of unread, non-dismissed, NOT-own entries; drives
//                       the dashboard bell badge so it never lights up for your
//                       own actions.
//
// Dismissing/clearing in the Notifications sheet only flips `dismissed`, so it
// never erases dashboard recent-activity history. Only sign-out hard-wipes via
// clear() (to stop one tenant's activity leaking into the next session).
//
// Cap at 50 entries to keep memory tidy. Newest first.
QtObject {
    id: root

    property var entries: []
    property int revision: 0

    // Persist the feed to Firestore (tenant-scoped via FirebaseService) so the
    // full history survives sign-out/sign-in and app reinstall. Without this the
    // log was in-memory only: clear() on sign-out wiped it and nothing re-synced,
    // so every non-order activity (product/staff edits) vanished on re-login
    // while orders survived only because they re-derive from OrdersStore.
    Component.onCompleted: _fetchFromFirebase()

    function _fetchFromFirebase() {
        FirebaseService.get("activity_log", function(ok, data) {
            if (!ok) {
                console.warn("[ActivityLog] Firestore sync failed",
                             FirebaseService.lastStatusCode, FirebaseService.lastError)
                return
            }
            var arr = FirebaseService.toArray(data)
            arr.sort(function(a, b) {
                return (b.timestamp || "").localeCompare(a.timestamp || "")
            })
            if (arr.length > 50) arr = arr.slice(0, 50)
            entries = arr
            revision++
            console.log("[ActivityLog] Synced", arr.length, "entries")
        })
    }

    function syncFromFirebase() { _fetchFromFirebase() }

    // Bulk upsert the in-memory feed. Newest-50 cap mirrors record(); a deleted
    // older row simply stops being re-pushed (the collection self-trims on the
    // next fresh-start cutover, and 50 stale rows are harmless).
    function _pushAllToFirebase() {
        var obj = {}
        var src = entries || []
        for (var i = 0; i < src.length; ++i)
            obj[src[i].id] = src[i]
        FirebaseService.put("activity_log", obj, function(ok) {
            if (!ok) console.warn("[ActivityLog] Firestore bulk write failed",
                                  FirebaseService.lastStatusCode, FirebaseService.lastError)
        })
    }

    // Current account id, cached so the views below bind to it explicitly and
    // recompute on account switch (avoids a function call hiding the dependency
    // inside a hot binding).
    readonly property string _currentUid: AuthStore.uid

    // An entry counts as "own" when its actor is the current account — or when
    // it has no actor (legacy / pre-stamp entries were always self-generated).
    function _isOwn(e, uid) {
        var a = (e && e.actorUid) || ""
        return a === "" || a === uid
    }

    // Notifications-sheet view: full history minus dismissed minus self-actions.
    // Declarative so the sheet updates the instant `entries` (or the current
    // account) changes.
    readonly property var notifications: {
        var uid = root._currentUid
        return (entries || []).filter(function(e) { return !e.dismissed && !root._isOwn(e, uid) })
    }

    // Bell badge: unread, not dismissed, not performed by this account.
    readonly property int unreadCount: {
        var uid = root._currentUid
        return (entries || []).filter(function(e) {
            return !e.read && !e.dismissed && !root._isOwn(e, uid)
        }).length
    }

    // entityId is optional but lets click-handlers route to the right dialog
    // (e.g. open the product or staff member that the entry refers to).
    // actorUid is optional; it defaults to the current account so a locally
    // performed action is recognised as "own" and suppressed from the bell.
    // A future cross-account sync that records OTHERS' actions locally should
    // pass their uid here so those DO notify.
    function record(kind, title, subtitle, entityId, actorUid) {
        var arr = (entries || []).slice()
        arr.unshift({
            id: "act-" + Date.now() + "-" + Math.floor(Math.random() * 1000),
            kind: kind || "info",
            title: title || "",
            subtitle: subtitle || "",
            entityId: entityId || "",
            timestamp: new Date().toISOString(),
            read: false,
            dismissed: false,
            actorUid: (actorUid !== undefined && actorUid !== null) ? actorUid : AuthStore.uid
        })
        if (arr.length > 50) arr = arr.slice(0, 50)
        entries = arr
        revision++
        _pushAllToFirebase()
    }

    function markAllRead() {
        if (unreadCount === 0) return
        var arr = []
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            arr.push({
                id: e.id, kind: e.kind, title: e.title,
                subtitle: e.subtitle, entityId: e.entityId || "",
                timestamp: e.timestamp, read: true,
                dismissed: e.dismissed || false, actorUid: e.actorUid || ""
            })
        }
        entries = arr
        revision++
        _pushAllToFirebase()
    }

    // Hard wipe of ALL history. Used only on sign-out — the Notifications sheet
    // must NOT call this (it would erase dashboard recent-activity history too);
    // it uses dismiss()/dismissAll() instead.
    function clear() {
        entries = []
        revision++
    }

    // Hide a single entry from the Notifications sheet without deleting it from
    // history. The dashboard recent-activity card keeps showing it. Drives the
    // sheet's swipe / tap-to-dismiss.
    function dismiss(id) {
        if (!id) return
        var arr = []
        var changed = false
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            if (e.id === id && !e.dismissed) {
                arr.push({
                    id: e.id, kind: e.kind, title: e.title,
                    subtitle: e.subtitle, entityId: e.entityId || "",
                    timestamp: e.timestamp, read: e.read, dismissed: true,
                    actorUid: e.actorUid || ""
                })
                changed = true
            } else {
                arr.push(e)
            }
        }
        if (!changed) return
        entries = arr
        revision++
        _pushAllToFirebase()
    }

    // "Clear all" in the Notifications sheet — hide every currently-visible
    // entry from the sheet while leaving history fully intact.
    function dismissAll() {
        var arr = []
        var changed = false
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            if (!e.dismissed) {
                arr.push({
                    id: e.id, kind: e.kind, title: e.title,
                    subtitle: e.subtitle, entityId: e.entityId || "",
                    timestamp: e.timestamp, read: e.read, dismissed: true,
                    actorUid: e.actorUid || ""
                })
                changed = true
            } else {
                arr.push(e)
            }
        }
        if (!changed) return
        entries = arr
        revision++
        _pushAllToFirebase()
    }

    // Friendly relative-time label for an ISO timestamp.
    function timeAgo(ts) {
        if (!ts) return ""
        var d = new Date(ts)
        if (isNaN(d.getTime())) return ""
        var diffSec = Math.floor((Date.now() - d.getTime()) / 1000)
        if (diffSec < 60) return "just now"
        if (diffSec < 3600) return Math.floor(diffSec / 60) + "m ago"
        if (diffSec < 86400) return Math.floor(diffSec / 3600) + "h ago"
        var days = Math.floor(diffSec / 86400)
        if (days < 7) return days + "d ago"
        return d.toLocaleDateString()
    }
}
