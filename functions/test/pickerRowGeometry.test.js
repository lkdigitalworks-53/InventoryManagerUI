"use strict";
// PickerRowGeometry (qml/helper/PickerRowGeometry.js). Cases GEOM-01..12, plan:
// docs/superpowers/plans/2026-11-04-product-picker-v2-s2-sheet-component.md. The QML twin
// tests/tst_PickerRowGeometry.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const PG = load("PickerRowGeometry.js");
// QML-PRELUDE-BEGIN
// What is left for the pills beside the stepper, from the sizes the helper returns (the helper no longer returns it:
// the row only needs to know whether it wraps).
function pillsOf(g, width) { return width - 2 * g.pad - (g.minus + g.gap + g.field + g.gap + g.plus) - g.gap; }
// QML-PRELUDE-END

test("GEOM-01 digitsOf counts the digits of a whole quantity, 1 to 6", () => {
    eq(PG.digitsOf(0), 1);
    eq(PG.digitsOf(7), 1);
    eq(PG.digitsOf(40), 2);
    eq(PG.digitsOf(12.9), 2);
    eq(PG.digitsOf(999999), 6);
    eq(PG.digitsOf(10000000), 6);
});
test("GEOM-02 digitsOf treats junk as one digit", () => {
    const junk = [-5, NaN, Infinity, undefined, null, "40", {}, []];
    for (let i = 0; i < junk.length; ++i) eq(PG.digitsOf(junk[i]), 1);
});
test("GEOM-03 junk width or unit gives zero sizes and wrapped pills", () => {
    const bad = [[0, 1], [-1, 1], [NaN, 1], ["300", 1], [null, 1], [undefined, 1], [300, 0], [300, -2], [300, NaN], [300, "1"]];
    for (let i = 0; i < bad.length; ++i) {
        const g = PG.layout(bad[i][0], bad[i][1], 10, 1);
        eq(g, { gap: 0, pad: 0, minus: 0, plus: 0, field: 0, fieldHeight: 0, pillsWrap: true, minHeight: 0 });
    }
});
test("GEOM-04 every touch target is at least 48 units at every scale", () => {
    const units = [1, 1.5, 2, 2.75, 3, 4];
    for (let i = 0; i < units.length; ++i) {
        const u = units[i];
        const g = PG.layout(360 * u, u, 40, 1);
        ok(g.minus >= 48 * u && g.plus >= 48 * u && g.fieldHeight >= 48 * u && g.field >= 48 * u, "target below 48 units at unit " + u);
    }
});
test("GEOM-05 the field has room for six digits when the stock needs them", () => {
    const six = PG.layout(400, 1, 999999, 1);
    ok(six.field >= 6 * PG.DIGIT + PG.FIELD_PAD, "six digits do not fit: " + six.field);
    eq(PG.layout(400, 1, 40, 1).field, 48);
    ok(six.field > PG.layout(400, 1, 40, 1).field, "the field did not widen");
});
test("GEOM-06 the stepper is its three targets plus two gaps of at least 8 units", () => {
    const g = PG.layout(400, 1, 500, 1);
    ok(g.gap >= 8, "gap below 8 units");
    eq(g.minus + g.gap + g.field + g.gap + g.plus, 48 + 8 + 48 + 8 + 48);
});
test("GEOM-07 a wide row keeps the pills beside the stepper with at least the floor left for them", () => {
    const g = PG.layout(420, 1, 500, 1);
    eq(g.pillsWrap, false);
    ok(pillsOf(g, 420) >= PG.MIN_PILLS, "pills below the floor");
});
test("GEOM-08 a narrow row puts the pills on their own line", () => {
    const g = PG.layout(240, 1, 500, 1);
    eq(g.pillsWrap, true);
    ok(pillsOf(g, 240) < PG.MIN_PILLS, "there was room beside the stepper");
});
test("GEOM-08b the pills stay beside the stepper at exactly the floor and wrap one unit below it", () => {
    const edge = 2 * PG.PAD + 160 + PG.GAP + PG.MIN_PILLS;
    eq([PG.layout(edge, 1, 500, 1).pillsWrap, pillsOf(PG.layout(edge, 1, 500, 1), edge)], [false, PG.MIN_PILLS]);
    eq(PG.layout(edge - 1, 1, 500, 1).pillsWrap, true);
});
test("GEOM-09 a card narrower than the stepper wraps the pills and never gives a negative size", () => {
    for (const w of [1, 50, 200, 211]) {
        const g = PG.layout(w, 1, 999999, 1);
        eq(g.pillsWrap, true);
        ok(g.gap > 0 && g.pad > 0 && g.minus > 0 && g.plus > 0 && g.field > 0 && g.fieldHeight > 0 && g.minHeight > 0, "a size is not positive at width " + w);
    }
    eq(PG.layout(280, 1, 999999, 1).pillsWrap, true);
});
test("GEOM-10 a large system font widens the field and heightens the row; a small or junk one counts as 1", () => {
    const base = PG.layout(400, 1, 999999, 1);
    const big = PG.layout(400, 1, 999999, 2);
    ok(big.field > base.field, "field did not widen");
    ok(big.minHeight > base.minHeight, "row did not grow");
    const same = [0.5, 0, -2, NaN, undefined, "2"];
    for (let i = 0; i < same.length; ++i) eq(PG.layout(400, 1, 999999, same[i]), base);
});
test("GEOM-11 the row is at least one touch target plus its padding high, and taller when the pills wrap", () => {
    const wide = PG.layout(420, 1, 500, 1);
    const narrow = PG.layout(240, 1, 500, 1);
    ok(wide.minHeight >= 48 + 2 * wide.pad, "row shorter than a target plus padding");
    ok(narrow.minHeight > wide.minHeight, "wrapped pills did not add a line");
    // pad 12 + line 1 (48) + gap 8 + line 2 (48, or 48 + gap 8 + a 24 pill line when wrapped) + pad 12
    eq(wide.minHeight, 128);
    eq(narrow.minHeight, 160);
});
test("GEOM-12 sizes scale with the unit, and a seeded monkey keeps every invariant", () => {
    const one = PG.layout(400, 1, 500, 1);
    const two = PG.layout(800, 2, 500, 1);
    eq([two.gap, two.pad, two.minus, two.plus, two.field, two.fieldHeight, two.minHeight].map((v) => v / 2),
       [one.gap, one.pad, one.minus, one.plus, one.field, one.fieldHeight, one.minHeight]);
    eq(two.pillsWrap, one.pillsWrap);
    const rand = FX.rng(5);
    let wraps = 0, narrow = 0;
    for (let i = 0; i < 1000; ++i) {
        const u = 0.75 + rand() * 3.25;
        const w = (100 + rand() * 1100) * u;
        const fs = 0.5 + rand() * 2.5;
        const maxQty = [0, 1, 9, 40, 500, 99999, 999999, 5000000][Math.floor(rand() * 8)];
        const g = PG.layout(w, u, maxQty, fs);
        ok(g.minus >= 48 * u - 1e-9 && g.plus >= 48 * u - 1e-9 && g.fieldHeight >= 48 * u - 1e-9 && g.field >= 48 * u - 1e-9, "target below 48 units");
        ok(g.gap >= 8 * u - 1e-9 && g.minHeight >= 48 * u, "negative or tiny size");
        // the row wraps exactly when less than the floor is left beside the stepper
        eq(g.pillsWrap, pillsOf(g, w) < PG.MIN_PILLS * u);
        if (g.pillsWrap) wraps++;
        if (pillsOf(g, w) < 0) narrow++;
        noThrow(() => PG.layout(w, u, maxQty, fs));
    }
    ok(wraps > 50 && wraps < 950, "the monkey never reached both layouts: " + wraps);
    ok(narrow > 0, "the monkey never reached a card too narrow to fit");
});
