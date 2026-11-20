"use strict";
// CartStepperGeometry (qml/helper/CartStepperGeometry.js). Cases CSG-01..07, plan:
// docs/superpowers/plans/2026-11-20-product-picker-v2-s5c-touch-back-toggle.md. The QML twin
// tests/tst_CartStepperGeometry.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const CG = load("CartStepperGeometry.js");

test("CSG-01 a button is a 48 unit touch target with a smaller painted frame inside it", () => {
    const g = CG.layout(1, false);
    eq(g.target, 48);
    eq(g.height, 48);
    eq(g.visual, 32);
    eq(g.inset, 8);
    ok(g.visual < g.target, "the frame must sit inside the target");
    eq(g.inset * 2 + g.visual, g.target);
});
test("CSG-02 every size scales with the unit and the target never drops below 48 units", () => {
    const units = [1, 1.5, 2, 2.75, 3, 4];
    for (let i = 0; i < units.length; ++i) {
        const u = units[i];
        const g = CG.layout(u, true);
        eq(g.target, 48 * u);
        ok(g.target >= 48 * u && g.height >= 48 * u, "target below 48 units at unit " + u);
        eq(g.visual, 32 * u);
        eq(g.qty, 28 * u);
        eq(g.gap, 4 * u);
    }
});
test("CSG-03 junk or non-positive unit gives all zeros", () => {
    const bad = [0, -1, NaN, Infinity, "1", null, undefined, {}, []];
    for (let i = 0; i < bad.length; ++i) {
        eq(CG.layout(bad[i], true), { target: 0, visual: 0, qty: 0, gap: 0, inset: 0, width: 0, height: 0 });
        eq(CG.rowWidth(bad[i], true, [64]), 0);
    }
});
test("CSG-04 width counts two buttons, or three when removable, with the quantity text and a gap between each pair", () => {
    eq(CG.layout(1, false).width, 48 + 4 + 28 + 4 + 48);
    eq(CG.layout(1, true).width, 48 + 4 + 28 + 4 + 48 + 4 + 48);
    eq(CG.layout(2, false).width, 2 * (48 + 4 + 28 + 4 + 48));
    eq(CG.layout(1, "yes").width, CG.layout(1, false).width);
    eq(CG.layout(1, 1).width, CG.layout(1, false).width);
});
test("CSG-05 rowWidth adds the extra fixed items (the price field) and one more gap for each", () => {
    eq(CG.rowWidth(1, true, []), CG.layout(1, true).width);
    eq(CG.rowWidth(1, true, [64]), CG.layout(1, true).width + 64 + 4);
    eq(CG.rowWidth(1, true, [64, 20]), CG.layout(1, true).width + 64 + 20 + 8);
    eq(CG.rowWidth(2, true, [64]), 2 * CG.rowWidth(1, true, [64]));
});
test("CSG-06 junk extras are ignored: no width and no gap", () => {
    const base = CG.rowWidth(1, false, []);
    eq(CG.rowWidth(1, false, undefined), base);
    eq(CG.rowWidth(1, false, "64"), base);
    eq(CG.rowWidth(1, false, [0, -5, NaN, "9", null, undefined]), base);
    eq(CG.rowWidth(1, false, [0, 64, -1]), base + 64 + 4);
});
test("CSG-07 the Edit Order controls row (price field, stepper, remove) fits a 320 unit phone, the New Order stepper fits beside nothing else", () => {
    // 320 wide, minus the page margin (2 x 16) and the controls row margin (2 x 14): the room the row really has.
    const room = 320 - 2 * 16 - 2 * 14;
    ok(CG.rowWidth(1, true, [64]) <= room, "Edit Order row needs " + CG.rowWidth(1, true, [64]) + " of " + room);
    ok(CG.layout(1, false).width <= room, "New Order stepper does not fit");
    // the old trailing-slot layout (everything on the title's row) could not have: it needs more than half the row
    ok(CG.rowWidth(1, true, [64]) > room / 2, "the stacked layout is what makes the targets fit");
});
