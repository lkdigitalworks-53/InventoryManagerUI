import QtQuick
import QtTest
import "../qml/model"

// Regression tests for the activity/notification model.
//
// 1) Notifications-vs-history split (2026-06-18): the Notifications sheet may
//    dismiss/clear entries WITHOUT erasing dashboard recent-activity history.
//    `entries` is the full history; `notifications` is the dismissable view;
//    only clear() wipes.
// 2) Same-account suppression: a notification must NOT appear for an action this
//    account performed itself. Entries are stamped with `actorUid`; the
//    `notifications` view and `unreadCount` exclude own-account entries, but
//    `entries` (dashboard history) still shows them.
TestCase {
    name: "ActivityLog"

    readonly property string me: "uid-self"
    readonly property string other: "uid-other"

    function init() {
        // Known account + empty history before each case. clear() is the hard wipe.
        AuthStore.uid = me
        ActivityLog.clear()
    }

    // ── Notifications-vs-history split ────────────────────────────────────────

    function test_dismiss_keeps_history_drops_from_notifications() {
        ActivityLog.record("order", "O1", "sub", "O1", other)
        ActivityLog.record("product_added", "P1", "sub", "P1", other)
        compare(ActivityLog.entries.length, 2)
        compare(ActivityLog.notifications.length, 2)

        var id = ActivityLog.entries[0].id   // newest first → "P1"
        ActivityLog.dismiss(id)

        compare(ActivityLog.entries.length, 2, "history must NOT shrink on dismiss")
        compare(ActivityLog.notifications.length, 1)
        compare(ActivityLog.notifications[0].title, "O1")
    }

    function test_dismissAll_keeps_history_empties_notifications() {
        ActivityLog.record("order", "O1", "sub", "O1", other)
        ActivityLog.record("staff_added", "S1", "sub", "S1", other)

        ActivityLog.dismissAll()

        compare(ActivityLog.entries.length, 2, "Clear-all must NOT touch dashboard history")
        compare(ActivityLog.notifications.length, 0)
    }

    function test_clear_wipes_everything() {
        ActivityLog.record("order", "O1", "sub", "O1", other)
        ActivityLog.clear()
        compare(ActivityLog.entries.length, 0)
        compare(ActivityLog.notifications.length, 0)
        compare(ActivityLog.unreadCount, 0)
    }

    function test_record_bumps_revision_for_reactive_views() {
        var before = ActivityLog.revision
        ActivityLog.record("order", "O1", "sub", "O1", other)
        verify(ActivityLog.revision > before)
        var afterRecord = ActivityLog.revision
        ActivityLog.dismiss(ActivityLog.entries[0].id)
        verify(ActivityLog.revision > afterRecord, "dismiss must bump revision so views refresh")
    }

    // ── Same-account suppression ──────────────────────────────────────────────

    function test_own_action_is_not_notified_but_stays_in_history() {
        // Default actor = current account (no explicit actorUid).
        ActivityLog.record("product_updated", "P1", "sub", "P1")
        compare(ActivityLog.entries.length, 1, "own action is recorded in history")
        compare(ActivityLog.notifications.length, 0, "own action must NOT notify")
        compare(ActivityLog.unreadCount, 0, "own action must NOT raise the bell badge")
    }

    function test_other_account_action_notifies() {
        ActivityLog.record("product_updated", "P1", "sub", "P1", other)
        compare(ActivityLog.notifications.length, 1)
        compare(ActivityLog.unreadCount, 1)
    }

    function test_mixed_only_others_notify() {
        ActivityLog.record("order", "MINE", "sub", "O1", me)
        ActivityLog.record("order", "THEIRS", "sub", "O2", other)
        ActivityLog.record("product_added", "MINE2", "sub", "P1")   // default = me
        compare(ActivityLog.entries.length, 3, "dashboard history shows all three")
        compare(ActivityLog.notifications.length, 1, "only the other account's action notifies")
        compare(ActivityLog.notifications[0].title, "THEIRS")
        compare(ActivityLog.unreadCount, 1)
    }

    function test_legacy_entry_without_actor_treated_as_own() {
        // Pre-stamp entries had no actorUid and were always self-generated.
        ActivityLog.record("order", "O1", "sub", "O1", "")
        compare(ActivityLog.notifications.length, 0)
        compare(ActivityLog.unreadCount, 0)
    }

    function test_views_recompute_on_account_switch() {
        ActivityLog.record("order", "O1", "sub", "O1", other)
        compare(ActivityLog.unreadCount, 1, "other account's action notifies me")
        // Switch to the actor's own account: it should no longer notify them.
        AuthStore.uid = other
        compare(ActivityLog.unreadCount, 0, "after switch, that account sees it as own")
        compare(ActivityLog.notifications.length, 0)
    }

    function test_dismiss_decrements_unread() {
        ActivityLog.record("order", "O1", "sub", "O1", other)
        ActivityLog.record("order", "O2", "sub", "O2", other)
        compare(ActivityLog.unreadCount, 2)
        ActivityLog.dismiss(ActivityLog.entries[0].id)
        compare(ActivityLog.unreadCount, 1, "dismissing an unread notification clears its badge count")
    }

    function test_markAllRead_clears_unread() {
        ActivityLog.record("order", "O1", "sub", "O1", other)
        compare(ActivityLog.unreadCount, 1)
        ActivityLog.markAllRead()
        compare(ActivityLog.unreadCount, 0)
        compare(ActivityLog.notifications.length, 1, "read entries still show in the sheet")
    }
}
