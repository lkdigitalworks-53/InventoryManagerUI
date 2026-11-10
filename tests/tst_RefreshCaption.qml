import QtQuick
import QtTest
import "../qml/helper/RefreshCaption.js" as RC

// Headless tests for the refresh row's pure helper (L4b). The full contract with 33 hand mutants runs in Node in
// .github/scripts/__tests__/refreshCaption.test.js; this file proves the main cases in the real Qt JS engine.
// Design: docs/superpowers/specs/2026-11-04-l4b-refresh-row-design.md
// Test plan: docs/superpowers/test-plans/2026-11-04-l4b-refresh-row-test-plan.md
TestCase {
    name: "RefreshCaption"

    readonly property double now: 1700000000000

    function _v(o) {
        var s = { online: true, state: "idle", lastSyncMs: now - 4 * 60000, nowMs: now }
        for (var k in o) s[k] = o[k]
        return RC.view(s)
    }

    function test_age_text_boundaries() {
        compare(RC.ageText(now, now), "just now")
        compare(RC.ageText(now - 59999, now), "just now")
        compare(RC.ageText(now - 60000, now), "1 min ago")
        compare(RC.ageText(now - 3599999, now), "59 min ago")
        compare(RC.ageText(now - 3600000, now), "1 h ago")
        compare(RC.ageText(now - 86400000, now), "1 d ago")
    }

    function test_age_text_never_shows_the_future_or_a_guess() {
        compare(RC.ageText(now + 5000, now), "just now")
        compare(RC.ageText(0, now), "")
        compare(RC.ageText(NaN, now), "")
        compare(RC.ageText(now - 1000, undefined), "")
    }

    function test_view_states() {
        compare(_v({}).text, "Updated 4 min ago")
        verify(_v({}).enabled)
        verify(!_v({}).busy)
        compare(_v({ lastSyncMs: 0 }).text, "Tap to refresh")
        compare(_v({ state: "running" }).text, "Refreshing…")
        verify(_v({ state: "running" }).busy)
        verify(!_v({ state: "running" }).enabled)
        compare(_v({ state: "waiting" }).text, "Waiting to refresh…")
        verify(!_v({ state: "waiting" }).enabled)
    }

    function test_offline_beats_everything() {
        compare(_v({ online: false }).text, "Offline · Updated 4 min ago")
        compare(_v({ online: false, state: "running" }).text, "Offline · Updated 4 min ago")
        verify(!_v({ online: false }).enabled)
        compare(_v({ online: false, lastSyncMs: 0 }).text, "Offline")
    }

    function test_junk_is_a_disabled_row() {
        verify(!RC.view(null).enabled)
        verify(!RC.view(undefined).enabled)
        verify(!_v({ state: "zzz" }).enabled)
        verify(!_v({ online: "yes" }).enabled)
    }

    function test_accessible_name() {
        compare(RC.accessibleName(_v({})), "Updated 4 min ago. Tap to refresh.")
        compare(RC.accessibleName(_v({ state: "running" })), "Refreshing…")
        compare(RC.accessibleName(null), "Refresh")
    }

    function test_request_messages() {
        compare(RC.requestMessage({ action: "run", reason: "" }), "")
        compare(RC.requestMessage({ action: "wait", reason: "outbox" }), "Sending your changes first. The refresh follows.")
        compare(RC.requestMessage({ action: "wait", reason: "lock" }), "Finish editing first. The refresh follows.")
        compare(RC.requestMessage({ action: "wait", reason: "checking" }), "Busy for a moment. Refreshing as soon as it is free.")
        compare(RC.requestMessage({ action: "drop", reason: "too-soon" }), "Just refreshed. Try again in a few seconds.")
        compare(RC.requestMessage({ action: "drop", reason: "offline" }), "You are offline. Connect to the internet and try again")
        compare(RC.requestMessage({ action: "drop", reason: "blocked" }), "Can't refresh right now.")
        compare(RC.requestMessage(null), "")
    }

    function test_unfinished_messages() {
        compare(RC.unfinishedMessage("gave-up"), "Couldn't refresh. Tap the refresh button to try again.")
        compare(RC.unfinishedMessage("partial"), "Some lists could not be updated. Tap the refresh button to try again.")
        compare(RC.unfinishedMessage("zzz"), "")
    }

    // Review of PR #186: stuck writes (the optional second argument) change what a wait on the outbox says.
    function test_stuck_writes_change_the_outbox_wait_and_the_gave_up_message() {
        var stuck = "Some changes are not syncing, so the refresh waits. Open the sync message at the top to fix or discard them."
        compare(RC.requestMessage({ action: "wait", reason: "outbox" }, 2), stuck)
        compare(RC.requestMessage({ action: "wait", reason: "outbox" }, 0), "Sending your changes first. The refresh follows.")
        compare(RC.requestMessage({ action: "wait", reason: "outbox" }, undefined), "Sending your changes first. The refresh follows.")
        compare(RC.requestMessage({ action: "wait", reason: "in-flight" }, 2), "Sending your changes first. The refresh follows.")
        compare(RC.requestMessage({ action: "run", reason: "" }, 2), "")
        compare(RC.unfinishedMessage("gave-up", 1), "Couldn't refresh: some changes are not syncing. Fix or discard them, then tap the refresh button.")
        compare(RC.unfinishedMessage("gave-up", 0), "Couldn't refresh. Tap the refresh button to try again.")
        compare(RC.unfinishedMessage("partial", 3), "Some lists could not be updated. Tap the refresh button to try again.")
    }
}
