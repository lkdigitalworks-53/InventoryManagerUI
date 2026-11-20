"use strict";
// PickerGuards (qml/helper/PickerGuards.js). Cases PGD-01..11, plan:
// docs/superpowers/plans/2026-11-20-product-picker-v2-s5c-touch-back-toggle.md. The QML twin
// tests/tst_PickerGuards.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const GD = load("PickerGuards.js");

test("PGD-01 the two windows are positive and the Back window is the longer one", () => {
    ok(GD.BACK_REPEAT_MS > 0 && GD.TOGGLE_REPEAT_MS > 0, "windows must be positive");
    ok(GD.BACK_REPEAT_MS >= GD.TOGGLE_REPEAT_MS, "Back may arrive through two routes, so it gets the longer window");
    ok(GD.BACK_REPEAT_MS <= 1000, "a window near a second would swallow a real second press");
});
test("PGD-02 a second sight inside the window is a repeat, at or past the window it is not", () => {
    eq(GD.isRepeat(1000, 1000, 400), true);
    eq(GD.isRepeat(1000, 1399, 400), true);
    eq(GD.isRepeat(1000, 1400, 400), false);
    eq(GD.isRepeat(1000, 5000, 400), false);
});
test("PGD-03 the first sight is never a repeat (lastAt 0 or negative)", () => {
    eq(GD.isRepeat(0, 100, 400), false);
    eq(GD.isRepeat(-5, 100, 400), false);
});
test("PGD-04 a clock that went backwards is never a repeat", () => {
    eq(GD.isRepeat(2000, 1999, 400), false);
    eq(GD.isRepeat(2000, 0, 400), false);
});
test("PGD-05 junk input is never a repeat", () => {
    const junk = [NaN, Infinity, -Infinity, "1000", null, undefined, {}, []];
    for (let i = 0; i < junk.length; ++i) {
        eq(GD.isRepeat(junk[i], 1100, 400), false);
        eq(GD.isRepeat(1000, junk[i], 400), false);
        eq(GD.isRepeat(1000, 1100, junk[i]), false);
    }
});
test("PGD-06 a zero or negative window is never a repeat", () => {
    eq(GD.isRepeat(1000, 1000, 0), false);
    eq(GD.isRepeat(1000, 1001, -400), false);
});
test("PGD-07 Back on a sheet that is not up passes through, whatever else is true", () => {
    eq(GD.backRoute({ opened: false, busy: false, confirmOpen: false }), "pass");
    eq(GD.backRoute({ opened: false, busy: true, confirmOpen: true }), "pass");
    eq(GD.backRoute({}), "pass");
});
test("PGD-08 a busy sheet swallows Back, even with the question open", () => {
    eq(GD.backRoute({ opened: true, busy: true, confirmOpen: false }), "swallow");
    eq(GD.backRoute({ opened: true, busy: true, confirmOpen: true }), "swallow");
});
test("PGD-09 with the discard question open, Back answers it", () => {
    eq(GD.backRoute({ opened: true, busy: false, confirmOpen: true }), "dismiss-confirm");
});
test("PGD-10 otherwise Back asks the sheet to close", () => {
    eq(GD.backRoute({ opened: true, busy: false, confirmOpen: false }), "request-close");
    eq(GD.backRoute({ opened: true }), "request-close");
});
test("PGD-11 junk state: only exactly true counts, a missing state is not open", () => {
    eq(GD.backRoute(undefined), "pass");
    eq(GD.backRoute(null), "pass");
    eq(GD.backRoute("opened"), "pass");
    eq(GD.backRoute({ opened: 1 }), "pass");
    eq(GD.backRoute({ opened: "true" }), "pass");
    eq(GD.backRoute({ opened: true, busy: 1, confirmOpen: 1 }), "request-close");
    eq(GD.backRoute({ opened: true, busy: "yes", confirmOpen: false }), "request-close");
});
