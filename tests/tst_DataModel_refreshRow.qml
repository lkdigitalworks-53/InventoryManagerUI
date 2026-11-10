import QtQuick
import QtTest
import "../qml/model"
import "../qml/logic"

// L4b: DataModel's refresh-row API in the real Qt engine: manualRefresh() answers { action, reason }, refreshState and
// lastSyncMs follow the engine, and an abandoned manual wish signals while an abandoned automatic one stays silent.
// The full scenario set (partial, re-arm, lost run, watchdog timer, monkey) runs in Node over the real function bodies:
// .github/scripts/__tests__/refreshBehavior.test.js. Design: docs/superpowers/specs/2026-11-04-l4b-refresh-row-design.md
//
// NOT RUN IN THIS SANDBOX: no Qt toolchain; CI is the first run.
TestCase {
    name: "DataModel_refreshRow"

    Logic { id: testLogic }
    DataModel { id: dm; dispatcher: testLogic }
    SignalSpy { id: spy; target: dm; signalName: "manualRefreshUnfinished" }

    property bool _wasOnline: true

    function init() {
        _wasOnline = AuthService.isOnline
        dm._clearWant()
        dm._refreshRunning = false
        spy.clear()
    }

    function cleanup() {
        dm._clearWant()
        AuthService.isOnline = _wasOnline
    }

    function test_offline_manual_refresh_is_dropped_with_its_reason() {
        AuthService.isOnline = false
        var d = dm.manualRefresh()
        compare(d.action, "drop")
        compare(d.reason, "offline")
        compare(dm.refreshState, "idle")
    }

    function test_request_refresh_still_returns_the_bare_action() {
        AuthService.isOnline = false
        compare(dm.requestRefresh("manual"), "drop")
        compare(dm.requestRefresh("nonsense"), "drop")
    }

    function test_last_sync_follows_the_engine() {
        dm._lastSyncMs = 12345
        compare(dm.lastSyncMs, 12345)
    }

    function test_refresh_state_follows_run_and_wish() {
        compare(dm.refreshState, "idle")
        dm._wantTrigger = "resume"
        compare(dm.refreshState, "waiting")
        dm._refreshRunning = true
        compare(dm.refreshState, "running")
        dm._refreshRunning = false
        dm._clearWant()
        compare(dm.refreshState, "idle")
    }

    function test_a_manual_wish_that_waited_out_its_time_signals_once() {
        dm._wantTrigger = "manual"
        dm._wantSinceMs = Date.now() - 130000
        dm._pollWant()
        compare(spy.count, 1)
        compare(spy.signalArguments[0][0], "gave-up")
        compare(dm._wantTrigger, "")
        dm._pollWant()
        compare(spy.count, 1)
    }

    function test_an_automatic_wish_that_waited_out_its_time_stays_silent() {
        dm._wantTrigger = "resume"
        dm._wantSinceMs = Date.now() - 130000
        dm._pollWant()
        compare(spy.count, 0)
        compare(dm._wantTrigger, "")
    }

    // Review of PR #186: an automatic request must not touch a waiting manual wish (the "wait" branch itself needs a
    // signed-in session, so it runs in Node over the real function bodies; here a dropped request is checked).
    function test_a_dropped_automatic_request_leaves_a_manual_wish_alone() {
        AuthService.isOnline = false
        dm._wantTrigger = "manual"
        dm._wantSinceMs = Date.now() - 1000
        compare(dm.requestRefresh("resume"), "drop")
        compare(dm._wantTrigger, "manual")
    }
}
