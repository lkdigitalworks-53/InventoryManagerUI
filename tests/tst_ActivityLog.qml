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

    // ── adopt: a row the SERVER wrote (atomic-ops R5b) ─────────────────────────
    // Node twin: functions/test/activityLogAdopt.test.js (the real function body).

    function _row(id, sec) {
        return { id: id, kind: "product_restocked", title: "t", subtitle: "s", entityId: "p1",
                 timestamp: "2026-06-15T12:00:" + (sec < 10 ? "0" : "") + sec + ".000Z",
                 read: false, dismissed: false, actorUid: me }
    }

    function _ids() {
        var out = []
        for (var i = 0; i < ActivityLog.entries.length; ++i) out.push(ActivityLog.entries[i].id)
        return out.join(",")
    }

    function test_adopt_places_a_row_by_timestamp_newest_first() {
        verify(ActivityLog.adopt(_row("a3", 30)))
        verify(ActivityLog.adopt(_row("a1", 10)))
        verify(ActivityLog.adopt(_row("a2", 20)))
        compare(_ids(), "a3,a2,a1")
    }

    function test_adopt_ignores_an_id_already_held() {
        verify(ActivityLog.adopt(_row("a1", 10)))
        var rev = ActivityLog.revision
        compare(ActivityLog.adopt(_row("a1", 50)), false)
        compare(ActivityLog.entries.length, 1)
        compare(ActivityLog.revision, rev, "no change, no revision bump")
    }

    function test_adopt_refuses_what_is_not_a_feed_row() {
        var bad = [null, undefined, 5, "x", {}, { id: "", timestamp: "t" }, { id: "a" }, { id: "a", timestamp: 5 }]
        for (var i = 0; i < bad.length; ++i) compare(ActivityLog.adopt(bad[i]), false)
        compare(ActivityLog.entries.length, 0)
    }

    function test_adopt_keeps_at_most_50_and_skips_a_row_older_than_all_of_them() {
        var arr = []
        for (var i = 0; i < 50; ++i) arr.push(_row("e" + i, 59 - i))
        ActivityLog.entries = arr
        compare(ActivityLog.adopt(_row("old", 1)), false)
        compare(ActivityLog.entries.length, 50)
        var newest = _row("newest", 59)
        newest.timestamp = "2026-06-15T13:00:00.000Z"   // strictly newer than e0 (an equal time goes AFTER the row held)
        verify(ActivityLog.adopt(newest))
        compare(ActivityLog.entries.length, 50)
        compare(ActivityLog.entries[0].id, "newest")
    }

    function test_an_adopted_own_row_shows_in_history_but_not_in_the_bell() {
        verify(ActivityLog.adopt(_row("mine", 10)))
        compare(ActivityLog.entries.length, 1)
        compare(ActivityLog.notifications.length, 0)
        compare(ActivityLog.unreadCount, 0)
    }
}
