import QtQuick
import QtTest
import "../qml/helper/SheetFooter.js" as SF

// Headless tests for the BottomSheet footer floor (the width the primary button keeps so a
// label like "Stay signed in" is never ellipsized to "S..."). Pure JS, no singletons.
// BottomSheet.qml itself cannot run here (Felgo, no App context): its wiring is pinned by
// .github/scripts/__tests__/signOutGuardWiring.test.js and checked on a device.
// Test plan: docs/superpowers/test-plans/2026-10-28-signout-sheet-footer-width-test-plan.md
TestCase {
    name: "SheetFooter"

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    // ---- constants (pinned to literals so a silent change is a red test) ----
    function test_constants() {
        compare(SF.SLACK, 2)
        compare(SF.MAX_SHARE, 0.65)
    }

    // ---- happy ----
    function test_label_padding_and_slack_add_up() {
        // 100 label + 32 padding + 2 slack, well under the cap (0.65 * 360 = 234)
        compare(SF.primaryFloor(100, 32, 360), 134)
    }

    function test_fractional_label_is_rounded_up() {
        compare(SF.primaryFloor(100.2, 32, 360), 135)   // ceil(100.2) = 101
        compare(SF.primaryFloor(100.0, 32, 360), 134)
        compare(SF.primaryFloor(0.1, 32, 360), 35)      // any positive label counts
    }

    function test_stay_signed_in_on_a_small_phone() {
        // ~104 dp label at 14sp bold, 32 dp padding, 312 dp row (360 dp phone, 20 dp margins).
        // The old layout gave the primary about 87 dp here; the floor is 138 dp.
        var floor = SF.primaryFloor(104, 32, 312)
        compare(floor, 138)
        verify(floor > 87)
    }

    function test_roomier_screens_keep_the_same_floor() {
        compare(SF.primaryFloor(104, 32, 342), 138)
        compare(SF.primaryFloor(104, 32, 600), 138)
    }

    // ---- cap ----
    function test_cap_applies_when_label_is_too_long() {
        compare(SF.primaryFloor(400, 32, 200), 200 * SF.MAX_SHARE)
        compare(SF.primaryFloor(400, 32, 200), 130)
    }

    function test_cap_boundary() {
        // need == cap: either branch gives the same number
        compare(SF.primaryFloor(96, 32, 200), 130)       // need = 96 + 32 + 2 = 130
        // one dp more than the cap: capped
        compare(SF.primaryFloor(97, 32, 200), 130)
        // one dp less: not capped
        compare(SF.primaryFloor(95, 32, 200), 129)
    }

    function test_cap_leaves_room_for_the_secondary_button() {
        // Even with an absurd label the secondary keeps 35 percent of the row.
        var row = 300
        var floor = SF.primaryFloor(5000, 32, row)
        verify(floor <= row * SF.MAX_SHARE)
        verify(row - floor >= row * (1 - SF.MAX_SHARE) - 1e-9)
    }

    function test_narrowest_supported_layout_width() {
        // 240 dp is the design minimum: row 200 dp. Floor is capped, never above the row.
        var floor = SF.primaryFloor(104, 32, 200)
        compare(floor, 130)
        verify(floor < 200)
    }

    // ---- negative: bad inputs never produce NaN, negatives, or a throw ----
    function test_no_label_means_no_floor() {
        compare(SF.primaryFloor(0, 32, 360), 0)
        compare(SF.primaryFloor(-5, 32, 360), 0)
        compare(SF.primaryFloor(undefined, 32, 360), 0)
        compare(SF.primaryFloor(null, 32, 360), 0)
        compare(SF.primaryFloor(NaN, 32, 360), 0)
        compare(SF.primaryFloor(Infinity, 32, 360), 0)
        compare(SF.primaryFloor("104", 32, 360), 0)
        compare(SF.primaryFloor({}, 32, 360), 0)
    }

    function test_row_without_width_means_no_floor() {
        // Before the first layout pass the footer width is 0: no floor yet, never negative.
        compare(SF.primaryFloor(104, 32, 0), 0)
        compare(SF.primaryFloor(104, 32, -50), 0)
        compare(SF.primaryFloor(104, 32, NaN), 0)
        compare(SF.primaryFloor(104, 32, undefined), 0)
        compare(SF.primaryFloor(104, 32, Infinity), 0)
        compare(SF.primaryFloor(104, 32, "360"), 0)
    }

    function test_bad_padding_counts_as_zero() {
        compare(SF.primaryFloor(100, undefined, 360), 102)
        compare(SF.primaryFloor(100, NaN, 360), 102)
        compare(SF.primaryFloor(100, -8, 360), 102)
        compare(SF.primaryFloor(100, "32", 360), 102)
        compare(SF.primaryFloor(100, null, 360), 102)
    }

    function test_missing_arguments_do_not_throw() {
        compare(SF.primaryFloor(), 0)
        compare(SF.primaryFloor(104), 0)
        compare(SF.primaryFloor(104, 32), 0)
    }

    // ---- edge ----
    function test_zero_padding() {
        compare(SF.primaryFloor(100, 0, 360), 102)
    }

    function test_tiny_label() {
        compare(SF.primaryFloor(1, 32, 360), 35)
    }

    function test_huge_values_stay_finite() {
        var f = SF.primaryFloor(1e12, 1e12, 1e12)
        verify(isFinite(f))
        compare(f, 1e12 * SF.MAX_SHARE)
    }

    function test_does_not_mutate_or_depend_on_earlier_calls() {
        var a = SF.primaryFloor(104, 32, 312)
        SF.primaryFloor(900, 99, 50)
        SF.primaryFloor(NaN, NaN, NaN)
        compare(SF.primaryFloor(104, 32, 312), a)
    }

    // ---- regression: the reported device bug ----
    function test_regression_long_secondary_label_cannot_squeeze_the_primary() {
        // Real wording from SignOutSheet. Natural label widths at 14sp bold (approximate).
        var stay = 104        // "Stay signed in"
        var stayWs = 150      // "Stay in workspace"
        var padding = 32
        var phones = [320, 360, 390, 412, 480]
        for (var i = 0; i < phones.length; i++) {
            var row = phones[i] - 2 * 20      // sheet side margins
            var f = SF.primaryFloor(stay, padding, row)
            // The primary keeps its whole label whenever the cap allows it ...
            if (stay + padding + SF.SLACK <= row * SF.MAX_SHARE)
                compare(f, stay + padding + SF.SLACK)
            // ... and never more than the cap.
            verify(f <= row * SF.MAX_SHARE)
            verify(f > 0)
            var g = SF.primaryFloor(stayWs, padding, row)
            verify(g <= row * SF.MAX_SHARE)
            verify(g >= f)
        }
    }

    // ---- scenarios: the labels every BottomSheet user passes ----
    function test_every_primary_label_in_the_app_gets_a_sane_floor() {
        // Rough natural widths (dp) of the primary labels at 14sp bold: short to long.
        var widths = [28, 34, 52, 58, 63, 71, 80, 104, 110, 118, 130, 150]
        var row = 312
        var last = -1
        for (var i = 0; i < widths.length; i++) {
            var f = SF.primaryFloor(widths[i], 32, row)
            verify(f > widths[i] || f === row * SF.MAX_SHARE)   // label + padding fits, or capped
            verify(f >= last)                                    // monotonic in the label
            last = f
        }
    }

    // ---- monkey: seeded, invariants only ----
    function test_monkey_invariants() {
        var rnd = _rng(20261028)
        var junk = [undefined, null, NaN, Infinity, -Infinity, -1, 0, "x", {}, [], true]
        for (var i = 0; i < 4000; i++) {
            var label = rnd() < 0.2 ? junk[Math.floor(rnd() * junk.length)] : rnd() * 600
            var pad = rnd() < 0.2 ? junk[Math.floor(rnd() * junk.length)] : rnd() * 80
            var row = rnd() < 0.2 ? junk[Math.floor(rnd() * junk.length)] : rnd() * 1200
            var f = SF.primaryFloor(label, pad, row)
            verify(typeof f === "number")
            verify(isFinite(f))
            verify(f >= 0)
            if (typeof row === "number" && isFinite(row) && row > 0)
                verify(f <= row * SF.MAX_SHARE + 1e-9)
            else
                compare(f, 0)
            if (typeof label === "number" && isFinite(label) && label > 0 && f > 0) {
                var p = (typeof pad === "number" && isFinite(pad) && pad > 0) ? pad : 0
                verify(f <= Math.ceil(label) + p + SF.SLACK + 1e-9)
            }
        }
    }

    function test_monkey_monotonic_in_each_argument() {
        var rnd = _rng(7)
        for (var i = 0; i < 1500; i++) {
            var label = 1 + rnd() * 400
            var pad = rnd() * 60
            var row = 1 + rnd() * 900
            var base = SF.primaryFloor(label, pad, row)
            verify(SF.primaryFloor(label + 10, pad, row) >= base - 1e-9)
            verify(SF.primaryFloor(label, pad + 10, row) >= base - 1e-9)
            verify(SF.primaryFloor(label, pad, row + 10) >= base - 1e-9)
        }
    }
}
