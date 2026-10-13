import QtQuick
import QtTest
import "../qml/helper/BulkApproveProgress.js" as BAP

// Headless tests for the state behind the Orders banner's "Approve all pending" button
// (pressed/busy look, progress bar, "All approved" hold). Pure JS, no singletons.
// Design + on-device plan: docs/superpowers/test-plans/2026-10-13-approve-all-progress-test-plan.md
//
// OrdersPage.qml itself cannot be instantiated under qmltestrunner (Constants imports Felgo,
// see tests/tst_NewOrderDialogSubmitGuard.qml), so the page's loop is modelled by _page()
// below with a plain-JS stand-in, same technique as that file. Wiring of the real page is
// pinned by .github/scripts/__tests__/ordersPageApproveWiring.test.js and the device plan.
TestCase {
    name: "BulkApproveProgress"

    // Stand-in for OrdersPage: one state object, replaced on every change, plus the two side
    // effects the page triggers (hold timer, error dialog).
    function _page() {
        return {
            s: BAP.newState(), starts: 0, holds: 0, dialogs: 0,
            tap: function(outcomes) {
                if (!BAP.canStart(this.s)) return false
                this.s = BAP.start(outcomes.length)
                if (outcomes.length > 0) this.starts++
                var bad = false
                for (var i = 0; i < outcomes.length; ++i) {
                    this.s = BAP.step(this.s, outcomes[i])
                    if (outcomes[i] !== "ok") bad = true
                }
                if (this.s.phase === "done") this.holds++
                if (bad) this.dialogs++
                return true
            },
            holdElapsed: function() { this.s = BAP.newState() }
        }
    }

    // Small deterministic PRNG (LCG) so a failing monkey run reproduces from its seed.
    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    // ── newState / canStart ──────────────────────────────────────────────────

    function test_newState_is_idle_and_zeroed() {
        var s = BAP.newState()
        compare(s.phase, "idle")
        compare(s.total, 0)
        compare(s.done, 0)
        compare(s.failed, 0)
        compare(s.lockedOut, 0)
    }

    function test_canStart_only_when_idle() {
        compare(BAP.canStart(BAP.newState()), true)
        compare(BAP.canStart(BAP.start(2)), false)
        compare(BAP.canStart(BAP.step(BAP.start(1), "ok")), false)
        compare(BAP.canStart(null), false)
        compare(BAP.canStart(undefined), false)
    }

    // ── start ────────────────────────────────────────────────────────────────

    function test_start_valid_total_is_running() {
        var s = BAP.start(3)
        compare(s.phase, "running")
        compare(s.total, 3)
        compare(s.done, 0)
    }

    function test_start_nothing_to_approve_stays_idle() {
        var bad = [0, -1, NaN, undefined, null, "abc", Infinity, -Infinity, 0.4]
        for (var i = 0; i < bad.length; ++i)
            compare(BAP.start(bad[i]).phase, "idle", "total " + bad[i])
    }

    function test_start_floors_and_accepts_numeric_string() {
        compare(BAP.start(2.7).total, 2)
        compare(BAP.start("3").total, 3)
    }

    // ── step ─────────────────────────────────────────────────────────────────

    function test_step_ok_advances_and_stays_running() {
        var s = BAP.step(BAP.start(3), "ok")
        compare(s.phase, "running")
        compare(s.done, 1)
        compare(s.failed, 0)
        compare(s.lockedOut, 0)
    }

    function test_step_last_order_moves_to_done() {
        var s = BAP.step(BAP.step(BAP.start(2), "ok"), "ok")
        compare(s.phase, "done")
        compare(s.done, 2)
    }

    function test_step_locked_counts_lockedOut_not_failed() {
        var s = BAP.step(BAP.start(2), "locked")
        compare(s.lockedOut, 1)
        compare(s.failed, 0)
    }

    function test_step_failed_counts_failed() {
        var s = BAP.step(BAP.start(2), "failed")
        compare(s.failed, 1)
        compare(s.lockedOut, 0)
    }

    function test_step_unknown_outcome_counts_as_failed() {
        var bad = [undefined, null, "", "weird", 0, 1, true]
        for (var i = 0; i < bad.length; ++i) {
            var s = BAP.step(BAP.start(2), bad[i])
            compare(s.failed, 1, "outcome " + bad[i])
            compare(BAP.approved(s), 0, "outcome " + bad[i])
        }
    }

    function test_step_ignored_when_not_running() {
        var idle = BAP.newState()
        compare(BAP.step(idle, "ok"), idle)
        var done = BAP.step(BAP.start(1), "ok")
        compare(BAP.step(done, "ok"), done)
        compare(BAP.step(null, "ok"), null)
        compare(BAP.step(undefined, "ok"), undefined)
    }

    function test_step_ignored_when_malformed_state_already_counted_all() {
        var odd = { phase: "running", total: 2, done: 2, failed: 0, lockedOut: 0 }
        compare(BAP.step(odd, "ok"), odd)
    }

    function test_step_returns_new_object_and_leaves_old_untouched() {
        var before = BAP.start(3)
        var after = BAP.step(before, "failed")
        verify(after !== before)
        compare(before.done, 0)
        compare(before.failed, 0)
    }

    // ── fraction / approved / allOk ──────────────────────────────────────────

    function test_fraction_values() {
        compare(BAP.fraction(BAP.newState()), 0)
        compare(BAP.fraction(null), 0)
        compare(BAP.fraction(BAP.start(4)), 0)
        compare(BAP.fraction(BAP.step(BAP.start(4), "ok")), 0.25)
        compare(BAP.fraction(BAP.step(BAP.start(3), "ok")), 1 / 3)
        compare(BAP.fraction(BAP.step(BAP.start(1), "failed")), 1)
    }

    function test_fraction_guards_malformed_states() {
        compare(BAP.fraction({ phase: "running", total: 0, done: 0 }), 0)
        compare(BAP.fraction({ phase: "running", total: 2, done: 5 }), 1)
        compare(BAP.fraction({ phase: "idle", total: 3, done: 2 }), 0)
    }

    function test_approved_subtracts_failed_and_locked() {
        var s = BAP.step(BAP.step(BAP.step(BAP.start(3), "ok"), "failed"), "locked")
        compare(BAP.approved(s), 1)
        compare(BAP.approved(null), 0)
    }

    function test_allOk_only_for_finished_clean_run() {
        compare(BAP.allOk(null), false)
        compare(BAP.allOk(BAP.newState()), false)
        compare(BAP.allOk(BAP.step(BAP.start(2), "ok")), false)
        compare(BAP.allOk(BAP.step(BAP.step(BAP.start(2), "ok"), "ok")), true)
        compare(BAP.allOk(BAP.step(BAP.step(BAP.start(2), "ok"), "failed")), false)
        compare(BAP.allOk(BAP.step(BAP.step(BAP.start(2), "ok"), "locked")), false)
    }

    // ── regression: the bugs this change fixes ───────────────────────────────

    // Before: no busy flag, so a double tap ran two loops; DataModel refused the second
    // completion of each order and the second loop reported them as "Insufficient inventory".
    function test_regression_second_tap_while_running_is_refused() {
        var p = _page()
        p.s = BAP.start(3)
        compare(p.tap(["ok", "ok", "ok"]), false)
        compare(p.starts, 0)
        compare(p.s.phase, "running")
        compare(p.dialogs, 0)
    }

    function test_regression_tap_during_end_hold_is_refused() {
        var p = _page()
        compare(p.tap(["ok"]), true)
        compare(p.s.phase, "done")
        compare(p.tap(["ok"]), false)
        compare(p.starts, 1)
    }

    // Before: the banner hid itself when the pending count hit 0, so the last step and any
    // success state were never visible. The state must stay non-idle until the hold elapses.
    function test_regression_done_state_is_not_idle_until_hold_elapses() {
        var p = _page()
        p.tap(["ok", "ok"])
        verify(p.s.phase !== "idle")
        compare(BAP.fraction(p.s), 1)
        compare(p.holds, 1)
        p.holdElapsed()
        compare(p.s.phase, "idle")
    }

    function test_regression_late_callback_cannot_overflow_progress() {
        var s = BAP.step(BAP.start(1), "ok")
        for (var i = 0; i < 5; ++i) s = BAP.step(s, "ok")
        compare(s.done, 1)
        compare(BAP.fraction(s), 1)
    }

    // ── functional: the page's loop through the helper ──────────────────────

    function test_functional_all_orders_approved() {
        var p = _page()
        compare(p.tap(["ok", "ok", "ok"]), true)
        compare(BAP.allOk(p.s), true)
        compare(p.dialogs, 0)
        compare(p.holds, 1)
    }

    function test_functional_mixed_outcomes_report_counts() {
        var p = _page()
        p.tap(["ok", "failed", "locked", "ok"])
        compare(p.s.phase, "done")
        compare(BAP.approved(p.s), 2)
        compare(p.s.failed, 1)
        compare(p.s.lockedOut, 1)
        compare(BAP.allOk(p.s), false)
        compare(p.dialogs, 1)
        compare(p.holds, 1)
    }

    function test_functional_all_locked() {
        var p = _page()
        p.tap(["locked", "locked"])
        compare(BAP.approved(p.s), 0)
        compare(p.s.lockedOut, 2)
        compare(p.s.failed, 0)
    }

    function test_functional_zero_orders_shows_nothing() {
        var p = _page()
        compare(p.tap([]), true)
        compare(p.s.phase, "idle")
        compare(p.holds, 0)
        compare(p.dialogs, 0)
    }

    function test_functional_single_order_jumps_zero_to_full() {
        var s = BAP.start(1)
        compare(BAP.fraction(s), 0)
        s = BAP.step(s, "ok")
        compare(BAP.fraction(s), 1)
        compare(s.phase, "done")
    }

    function test_functional_fraction_is_monotonic_across_a_run() {
        var s = BAP.start(7)
        var last = BAP.fraction(s)
        var out = ["ok", "failed", "locked", "ok", "ok", "failed", "ok"]
        for (var i = 0; i < out.length; ++i) {
            s = BAP.step(s, out[i])
            verify(BAP.fraction(s) > last, "step " + i)
            last = BAP.fraction(s)
        }
        compare(last, 1)
    }

    function test_functional_second_run_allowed_after_hold() {
        var p = _page()
        p.tap(["ok"])
        p.holdElapsed()
        compare(p.tap(["ok", "ok"]), true)
        compare(p.starts, 2)
        compare(p.s.total, 2)
    }

    // ── monkey: random call sequences never break the invariants ────────────

    function _checkInvariants(s, label) {
        verify(s.done >= 0 && s.done <= s.total, label + ": done in range")
        verify(s.failed >= 0 && s.lockedOut >= 0, label + ": counts non-negative")
        verify(s.failed + s.lockedOut <= s.done, label + ": bad <= done")
        var f = BAP.fraction(s)
        verify(f >= 0 && f <= 1, label + ": fraction in 0..1")
        compare(s.phase === "done", s.total > 0 && s.done === s.total, label + ": done iff all counted")
        compare(f === 1, s.phase === "done", label + ": full bar iff done")
        compare(s.phase === "idle", s.total === 0, label + ": idle iff no total")
    }

    function test_monkey_random_sequences_keep_invariants() {
        var seeds = [1, 7, 42, 2026, 99991]
        var outcomes = ["ok", "failed", "locked", undefined, null, "weird", 3]
        var totals = [0, 1, 2, 5, 13, -4, NaN, "6", 2.9]
        for (var k = 0; k < seeds.length; ++k) {
            var rnd = _rng(seeds[k])
            var s = BAP.newState()
            for (var i = 0; i < 400; ++i) {
                var r = rnd()
                var snapshot = JSON.stringify(s)
                var next
                if (r < 0.15) {
                    next = BAP.canStart(s) ? BAP.start(totals[Math.floor(rnd() * totals.length)]) : s
                } else if (r < 0.2) {
                    next = BAP.newState()
                } else {
                    next = BAP.step(s, outcomes[Math.floor(rnd() * outcomes.length)])
                }
                compare(JSON.stringify(s), snapshot, "seed " + seeds[k] + " step " + i + ": input untouched")
                s = next
                _checkInvariants(s, "seed " + seeds[k] + " step " + i)
            }
        }
    }
}
