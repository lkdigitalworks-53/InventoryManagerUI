import QtQuick
import QtTest
import "../qml/helper/RefreshPolicy.js" as RP

// Headless tests for the non-blanking refresh policy (L4a). Pure JS, no singletons. DataModel's coordinator and
// the stores' refresh glue are covered by .github/scripts/__tests__/refresh{Behavior,Wiring}.test.js (real
// function bodies in a Node sandbox) and tst_StoreRefresh.qml; the same policy contract runs in Node in
// refreshPolicy.test.js with hand mutants. This file proves it in the real Qt JS engine.
// Design: docs/superpowers/specs/2026-11-02-l4a-resume-refresh-design.md
// Test plan: docs/superpowers/test-plans/2026-11-02-l4a-resume-refresh-test-plan.md
TestCase {
    name: "RefreshPolicy"

    readonly property double now: 1700000000000

    function _quiet() {
        return { online: true, sessionOpen: true, accessBlock: "", checking: false, refreshing: false,
                 storeBusy: false, outboxPending: 0, outboxRevision: 7, gatewayInFlight: 0, lockHeld: false, photoPending: 0 }
    }
    function _with(o) {
        var s = _quiet()
        for (var k in o) s[k] = o[k]
        return s
    }

    function test_constants() {
        compare(RP.STALE_MS, 300000)
        compare(RP.SPACING_MS, 15000)
        compare(RP.WANT_TTL_MS, 120000)
        compare(RP.POLL_MS, 5000)
        compare(RP.RUN_TTL_MS, 180000)
    }

    function test_quiet_stale_session_runs_for_every_trigger() {
        var t = ["resume", "reconnect", "manual"]
        for (var i = 0; i < t.length; ++i) compare(RP.decide(t[i], _quiet(), now, now - 400000, 0).action, "run")
        compare(RP.decide("resume", _quiet(), now, 0, 0).action, "run")
        compare(RP.decide("resume", _quiet(), NaN, now, now).action, "run")
    }

    function test_bad_triggers_drop() {
        var t = [undefined, null, "", "x", "RESUME", 1]
        for (var i = 0; i < t.length; ++i) compare(RP.decide(t[i], _quiet(), now, 0, 0).action, "drop")
    }

    function test_staleness_applies_to_resume_and_reconnect_not_manual() {
        compare(RP.decide("resume", _quiet(), now, now - 299999, 0).reason, "fresh")
        compare(RP.decide("resume", _quiet(), now, now - 300000, 0).action, "run")
        compare(RP.decide("reconnect", _quiet(), now, now - 1000, 0).action, "drop")
        compare(RP.decide("manual", _quiet(), now, now - 1000, 0).action, "run")
        compare(RP.decide("resume", _quiet(), now, now + 5000, 0).action, "run")   // clock went backwards: stale, not wedged
    }

    function test_spacing_applies_to_every_trigger() {
        compare(RP.decide("manual", _quiet(), now, 0, now - 14999).reason, "too-soon")
        compare(RP.decide("manual", _quiet(), now, 0, now - 15000).action, "run")
        compare(RP.decide("manual", _quiet(), now, 0, now + 9000).action, "run")
    }

    function test_hard_blockers_drop() {
        compare(RP.decide("resume", _with({ online: false }), now, 0, 0).reason, "offline")
        compare(RP.decide("resume", _with({ sessionOpen: false }), now, 0, 0).reason, "no-session")
        var b = ["removed", "suspended", "role", "unverified", "moved"]
        for (var i = 0; i < b.length; ++i) compare(RP.decide("manual", _with({ accessBlock: b[i] }), now, 0, 0).reason, "blocked")
        compare(RP.decide("resume", null, now, 0, 0).reason, "no-state")
        compare(RP.decide("resume", _with({ online: false, outboxPending: 3 }), now, 0, 0).action, "drop")
    }

    function test_soft_blockers_wait_in_order() {
        var cases = [["checking", { checking: true }], ["refreshing", { refreshing: true }], ["store-loading", { storeBusy: true }],
                     ["outbox", { outboxPending: 1 }], ["in-flight", { gatewayInFlight: 2 }], ["lock", { lockHeld: true }], ["photos", { photoPending: 1 }]]
        for (var i = 0; i < cases.length; ++i) {
            compare(RP.decide("resume", _with(cases[i][1]), now, 0, 0).reason, cases[i][0])
            compare(RP.decide("manual", _with(cases[i][1]), now, 0, 0).action, "wait")
        }
        compare(RP.decide("resume", _with({ checking: true, outboxPending: 5, lockHeld: true }), now, 0, 0).reason, "checking")
        compare(RP.decide("resume", _with({ outboxPending: 2 }), now, now - 1000, 0).action, "drop")   // fresh beats wait
    }

    function test_junk_in_the_snapshot_fails_closed() {
        var junk = [undefined, null, NaN, "x", 1, {}, []]
        for (var i = 0; i < junk.length; ++i) {
            verify(RP.decide("resume", _with({ online: junk[i] }), now, 0, 0).action !== "run")
            verify(RP.decide("resume", _with({ checking: junk[i] }), now, 0, 0).action !== "run")
            verify(RP.decide("resume", _with({ outboxPending: junk[i] }), now, 0, 0).action !== "run")
            verify(RP.decide("resume", _with({ accessBlock: junk[i] }), now, 0, 0).action !== "run")
        }
    }

    function test_swapOk() {
        verify(RP.swapOk(7, _quiet()))
        verify(!RP.swapOk(7, _with({ outboxRevision: 8 })))
        verify(!RP.swapOk(7, _with({ outboxRevision: 6 })))
        verify(!RP.swapOk(7, _with({ outboxPending: 1 })))
        verify(!RP.swapOk(7, _with({ gatewayInFlight: 1 })))
        verify(!RP.swapOk(7, _with({ lockHeld: true })))
        verify(!RP.swapOk(7, _with({ photoPending: 1 })))
        verify(!RP.swapOk(7, _with({ online: false })))
        verify(!RP.swapOk(7, _with({ accessBlock: "removed" })))
        verify(RP.swapOk(7, _with({ checking: true })))
        verify(!RP.swapOk("x", _with({ outboxRevision: "x" })))
        verify(!RP.swapOk(NaN, _with({ outboxRevision: NaN })))
        verify(!RP.swapOk(7, null))
    }

    function test_wantExpired() {
        verify(!RP.wantExpired(now, now + 119999))
        verify(RP.wantExpired(now, now + 120000))
        verify(RP.wantExpired(now, now - 1))
        verify(RP.wantExpired(undefined, now))
        verify(RP.wantExpired(now, NaN))
    }

    function test_runLost() {
        verify(!RP.runLost(now, now + 179999))
        verify(RP.runLost(now, now + 180000))
        verify(RP.runLost(now, now - 1))
        verify(RP.runLost(undefined, now))
        verify(RP.runLost(now, NaN))
    }

    function test_allCommitted() {
        verify(RP.allCommitted(["committed", "committed"]))
        var bad = ["discarded", "failed", "superseded", "skipped", "", undefined, null]
        for (var i = 0; i < bad.length; ++i) verify(!RP.allCommitted(["committed", bad[i]]))
        verify(!RP.allCommitted([]))
        verify(!RP.allCommitted(null))
        verify(!RP.allCommitted("committed"))
    }

    function test_monkey_a_run_always_has_an_open_swap_gate() {
        var s = 99
        function rnd() { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296 }
        var runs = 0
        for (var i = 0; i < 4000; ++i) {
            var snap = { online: rnd() > 0.1, sessionOpen: rnd() > 0.1, accessBlock: rnd() > 0.9 ? "removed" : "", checking: rnd() > 0.85,
                         refreshing: rnd() > 0.9, storeBusy: rnd() > 0.9, outboxPending: rnd() > 0.7 ? 2 : 0, outboxRevision: 3,
                         gatewayInFlight: rnd() > 0.9 ? 1 : 0, lockHeld: rnd() > 0.9, photoPending: rnd() > 0.9 ? 1 : 0 }
            var d = RP.decide(["resume", "reconnect", "manual"][Math.floor(rnd() * 3)], snap, now, 0, 0)
            if (d.action === "run") { runs++; verify(RP.swapOk(3, snap)) }
        }
        verify(runs > 200)
    }
}
