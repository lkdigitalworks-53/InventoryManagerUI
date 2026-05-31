pragma Singleton
import QtQuick

// In-memory activity feed. Stores write to it via record(); the dashboard
// recent-activity card and the notifications sheet read from it.
//
// Each entry: { id, kind, title, subtitle, timestamp, read }
//   kind: "order" | "product_added" | "product_updated" | "product_restocked"
//         | "low_stock" | "staff_added" | "staff_updated"
//
// Cap at 50 entries to keep memory tidy. Newest first.
QtObject {
    id: root

    property var entries: []
    property int unreadCount: 0
    property int revision: 0

    // entityId is optional but lets click-handlers route to the right
    // dialog (e.g. open the product or staff member that the entry refers to).
    function record(kind, title, subtitle, entityId) {
        var arr = (entries || []).slice()
        arr.unshift({
            id: "act-" + Date.now() + "-" + Math.floor(Math.random() * 1000),
            kind: kind || "info",
            title: title || "",
            subtitle: subtitle || "",
            entityId: entityId || "",
            timestamp: new Date().toISOString(),
            read: false
        })
        if (arr.length > 50) arr = arr.slice(0, 50)
        entries = arr
        unreadCount++
        revision++
    }

    function markAllRead() {
        if (unreadCount === 0) return
        var arr = []
        for (var i = 0; i < entries.length; ++i) {
            var e = entries[i]
            arr.push({
                id: e.id, kind: e.kind, title: e.title,
                subtitle: e.subtitle, entityId: e.entityId || "",
                timestamp: e.timestamp, read: true
            })
        }
        entries = arr
        unreadCount = 0
        revision++
    }

    function clear() {
        entries = []
        unreadCount = 0
        revision++
    }

    // Remove a single entry by its id. Adjusts unreadCount if the removed
    // entry was unread. Used by NotificationsSheet's swipe / click-to-dismiss.
    function remove(id) {
        if (!id) return
        var arr = []
        var dropped = null
        for (var i = 0; i < entries.length; ++i) {
            if (entries[i].id === id) { dropped = entries[i]; continue }
            arr.push(entries[i])
        }
        if (!dropped) return
        if (!dropped.read && unreadCount > 0) unreadCount--
        entries = arr
        revision++
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
