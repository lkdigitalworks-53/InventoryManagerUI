import QtQuick
import QtTest
import "../qml/helper/PickerGuards.js" as GD
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/pickerGuards.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "PickerGuards"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function test_PGD_01_the_two_windows_are_positive_and_the_back_window_is_the_long() {
        ok(GD.BACK_REPEAT_MS > 0 && GD.TOGGLE_REPEAT_MS > 0, "windows must be positive");
        ok(GD.BACK_REPEAT_MS >= GD.TOGGLE_REPEAT_MS, "Back may arrive through two routes, so it gets the longer window");
        ok(GD.BACK_REPEAT_MS <= 1000, "a window near a second would swallow a real second press");
    }

    function test_PGD_02_a_second_sight_inside_the_window_is_a_repeat_at_or_past_the_() {
        eq(GD.isRepeat(1000, 1000, 400), true);
        eq(GD.isRepeat(1000, 1399, 400), true);
        eq(GD.isRepeat(1000, 1400, 400), false);
        eq(GD.isRepeat(1000, 5000, 400), false);
    }

    function test_PGD_03_the_first_sight_is_never_a_repeat_lastat_0_or_negative() {
        eq(GD.isRepeat(0, 100, 400), false);
        eq(GD.isRepeat(-5, 100, 400), false);
    }

    function test_PGD_04_a_clock_that_went_backwards_is_never_a_repeat() {
        eq(GD.isRepeat(2000, 1999, 400), false);
        eq(GD.isRepeat(2000, 0, 400), false);
    }

    function test_PGD_05_junk_input_is_never_a_repeat() {
        const junk = [NaN, Infinity, -Infinity, "1000", null, undefined, {}, []];
        for (let i = 0; i < junk.length; ++i) {
            eq(GD.isRepeat(junk[i], 1100, 400), false);
            eq(GD.isRepeat(1000, junk[i], 400), false);
            eq(GD.isRepeat(1000, 1100, junk[i]), false);
        }
    }

    function test_PGD_06_a_zero_or_negative_window_is_never_a_repeat() {
        eq(GD.isRepeat(1000, 1000, 0), false);
        eq(GD.isRepeat(1000, 1001, -400), false);
    }

    function test_PGD_07_back_on_a_sheet_that_is_not_up_passes_through_whatever_else_() {
        eq(GD.backRoute({ opened: false, busy: false, confirmOpen: false }), "pass");
        eq(GD.backRoute({ opened: false, busy: true, confirmOpen: true }), "pass");
        eq(GD.backRoute({}), "pass");
    }

    function test_PGD_08_a_busy_sheet_swallows_back_even_with_the_question_open() {
        eq(GD.backRoute({ opened: true, busy: true, confirmOpen: false }), "swallow");
        eq(GD.backRoute({ opened: true, busy: true, confirmOpen: true }), "swallow");
    }

    function test_PGD_09_with_the_discard_question_open_back_answers_it() {
        eq(GD.backRoute({ opened: true, busy: false, confirmOpen: true }), "dismiss-confirm");
    }

    function test_PGD_10_otherwise_back_asks_the_sheet_to_close() {
        eq(GD.backRoute({ opened: true, busy: false, confirmOpen: false }), "request-close");
        eq(GD.backRoute({ opened: true }), "request-close");
    }

    function test_PGD_11_junk_state_only_exactly_true_counts_a_missing_state_is_not_o() {
        eq(GD.backRoute(undefined), "pass");
        eq(GD.backRoute(null), "pass");
        eq(GD.backRoute("opened"), "pass");
        eq(GD.backRoute({ opened: 1 }), "pass");
        eq(GD.backRoute({ opened: "true" }), "pass");
        eq(GD.backRoute({ opened: true, busy: 1, confirmOpen: 1 }), "request-close");
        eq(GD.backRoute({ opened: true, busy: "yes", confirmOpen: false }), "request-close");
    }
}
