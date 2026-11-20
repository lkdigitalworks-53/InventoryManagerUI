import QtQuick
import QtTest
import "../qml/helper/BackRouter.js" as BR
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/backRouter.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "BackRouter"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    // A dialog double that records what the router did to it.
    function dlg(opened, extra) {
        var d = { opened: opened, closed: 0, close: function() { d.closed += 1 } };
        var keys = extra ? Object.keys(extra) : [];
        for (var i = 0; i < keys.length; ++i) d[keys[i]] = extra[keys[i]];
        return d;
    }

    function test_BR_01_no_dialog_an_empty_list_or_junk_nothing_open_the_caller_carr() {
        eq(BR.route([]), "none");
        eq(BR.route(undefined), "none");
        eq(BR.route(null), "none");
        eq(BR.route("x"), "none");
        eq(BR.route([null, undefined, 0]), "none");
    }

    function test_BR_02_closed_dialogs_are_skipped_and_never_touched() {
        const a = dlg(false), b = dlg(false, { busy: true });
        eq(BR.route([a, b]), "none");
        eq(a.closed + b.closed, 0);
    }

    function test_BR_03_the_first_open_dialog_is_closed_exactly_as_before() {
        const a = dlg(false), b = dlg(true), c = dlg(true);
        eq(BR.route([a, b, c]), "closed");
        eq([a.closed, b.closed, c.closed], [0, 1, 0]);
    }

    function test_BR_04_a_busy_dialog_swallows_back_it_stays_open_and_nothing_behind() {
        const a = dlg(true, { busy: true }), b = dlg(true);
        eq(BR.route([a, b]), "swallowed");
        eq(a.closed + b.closed, 0);
    }

    function test_BR_05_a_dialog_that_consumes_back_stays_open_and_the_press_stops_t() {
        let asked = 0;
        const a = dlg(true, { consumeBack: function() { asked += 1; return true } }), b = dlg(true);
        eq(BR.route([a, b]), "consumed");
        eq(asked, 1);
        eq(a.closed + b.closed, 0);
    }

    function test_BR_06_a_dialog_that_does_not_consume_back_is_closed() {
        const a = dlg(true, { consumeBack: function() { return false } });
        eq(BR.route([a]), "closed");
        eq(a.closed, 1);
    }

    function test_BR_07_only_exactly_true_counts_as_consumed() {
        const answers = [undefined, null, 0, 1, "true", {}, []];
        for (let i = 0; i < answers.length; ++i) {
            const a = dlg(true, { consumeBack: function() { return answers[i] } });
            eq(BR.route([a]), "closed");
            eq(a.closed, 1);
        }
    }

    function test_BR_08_a_consumeback_that_throws_is_a_broken_hook_the_dialog_closes() {
        const a = dlg(true, { consumeBack: function() { throw new Error("boom") } });
        eq(BR.route([a]), "closed");
        eq(a.closed, 1);
    }

    function test_BR_09_consumeback_is_optional_and_ignored_when_it_is_not_a_functio() {
        const a = dlg(true, { consumeBack: "yes" });
        eq(BR.route([a]), "closed");
        eq(a.closed, 1);
    }

    function test_BR_10_a_busy_dialog_is_not_asked_busy_wins_over_consumeback() {
        let asked = 0;
        const a = dlg(true, { busy: true, consumeBack: function() { asked += 1; return true } });
        eq(BR.route([a]), "swallowed");
        eq(asked, 0);
    }

    function test_BR_11_the_dialog_under_a_consuming_one_is_not_touched_and_a_later_() {
        let up = true;
        const under = dlg(true), top = dlg(true, { consumeBack: function() { return up } });
        eq(BR.route([top, under]), "consumed");
        up = false;
        eq(BR.route([top, under]), "closed");
        eq([top.closed, under.closed], [1, 0]);
    }
}
