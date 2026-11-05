import QtQuick
import QtTest
import "../qml/helper/PickerRowGeometry.js" as PG
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/pickerRowGeometry.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "PickerRowGeometry"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function test_GEOM_01_digitsof_counts_the_digits_of_a_whole_quantity_1_to_6() {
        eq(PG.digitsOf(0), 1);
        eq(PG.digitsOf(7), 1);
        eq(PG.digitsOf(40), 2);
        eq(PG.digitsOf(12.9), 2);
        eq(PG.digitsOf(999999), 6);
        eq(PG.digitsOf(10000000), 6);
    }

    function test_GEOM_02_digitsof_treats_junk_as_one_digit() {
        const junk = [-5, NaN, Infinity, undefined, null, "40", {}, []];
        for (let i = 0; i < junk.length; ++i) eq(PG.digitsOf(junk[i]), 1);
    }

    function test_GEOM_03_junk_width_or_unit_gives_ok_false_and_no_size() {
        const bad = [[0, 1], [-1, 1], [NaN, 1], ["300", 1], [null, 1], [undefined, 1], [300, 0], [300, -2], [300, NaN], [300, "1"]];
        for (let i = 0; i < bad.length; ++i) {
            const g = PG.layout(bad[i][0], bad[i][1], 10, 1);
            eq(g.ok, false);
            eq(g.fits, false);
            eq([g.photo, g.minus, g.plus, g.field, g.stepper, g.pills, g.minHeight], [0, 0, 0, 0, 0, 0, 0]);
        }
    }

    function test_GEOM_04_every_touch_target_is_at_least_48_units_at_every_scale() {
        const units = [1, 1.5, 2, 2.75, 3, 4];
        for (let i = 0; i < units.length; ++i) {
            const u = units[i];
            const g = PG.layout(360 * u, u, 40, 1);
            ok(g.minus >= 48 * u && g.plus >= 48 * u && g.fieldHeight >= 48 * u && g.field >= 48 * u, "target below 48 units at unit " + u);
        }
    }

    function test_GEOM_05_the_field_has_room_for_six_digits_when_the_stock_needs_them() {
        const six = PG.layout(400, 1, 999999, 1);
        ok(six.field >= 6 * PG.DIGIT + PG.FIELD_PAD, "six digits do not fit: " + six.field);
        eq(PG.layout(400, 1, 40, 1).field, 48);
        ok(six.field > PG.layout(400, 1, 40, 1).field, "the field did not widen");
    }

    function test_GEOM_06_the_stepper_is_its_three_targets_plus_two_gaps_of_at_least_8() {
        const g = PG.layout(400, 1, 500, 1);
        eq(g.stepper, g.minus + g.gap + g.field + g.gap + g.plus);
        ok(g.gap >= 8, "gap below 8 units");
    }

    function test_GEOM_07_a_wide_row_keeps_the_pills_beside_the_stepper_and_fills_the_() {
        const g = PG.layout(420, 1, 500, 1);
        eq(g.pillsWrap, false);
        ok(g.pills >= PG.MIN_PILLS, "pills below the floor");
        eq(2 * g.pad + g.stepper + g.gap + g.pills, 420);
    }

    function test_GEOM_08_a_narrow_row_puts_the_pills_on_their_own_line_at_the_full_in() {
        const g = PG.layout(240, 1, 500, 1);
        eq(g.pillsWrap, true);
        eq(g.pills, 240 - 2 * g.pad);
        eq(g.fits, true);
    }

    function test_GEOM_08b_the_pills_stay_beside_the_stepper_at_exactly_the_floor_and_w() {
        const edge = 2 * PG.PAD + 160 + PG.GAP + PG.MIN_PILLS;
        eq([PG.layout(edge, 1, 500, 1).pillsWrap, PG.layout(edge, 1, 500, 1).pills], [false, PG.MIN_PILLS]);
        eq(PG.layout(edge - 1, 1, 500, 1).pillsWrap, true);
    }

    function test_GEOM_09_fits_is_false_only_when_the_stepper_alone_is_wider_than_the_() {
        eq(PG.layout(200, 1, 999999, 1).fits, false);
        eq(PG.layout(280, 1, 999999, 1).fits, true);
        eq(PG.layout(212, 1, 999999, 1).fits, true);
        eq(PG.layout(211, 1, 999999, 1).fits, false);
    }

    function test_GEOM_10_a_large_system_font_widens_the_field_and_heightens_the_row_a() {
        const base = PG.layout(400, 1, 999999, 1);
        const big = PG.layout(400, 1, 999999, 2);
        ok(big.field > base.field, "field did not widen");
        ok(big.minHeight > base.minHeight, "row did not grow");
        const same = [0.5, 0, -2, NaN, undefined, "2"];
        for (let i = 0; i < same.length; ++i) eq(PG.layout(400, 1, 999999, same[i]), base);
    }

    function test_GEOM_11_the_row_is_at_least_one_touch_target_plus_its_padding_high_a() {
        const wide = PG.layout(420, 1, 500, 1);
        const narrow = PG.layout(240, 1, 500, 1);
        ok(wide.minHeight >= 48 + 2 * wide.pad, "row shorter than a target plus padding");
        ok(narrow.minHeight > wide.minHeight, "wrapped pills did not add a line");
    }

    function test_GEOM_12_sizes_scale_with_the_unit_and_a_seeded_monkey_keeps_every_in() {
        const one = PG.layout(400, 1, 500, 1);
        const two = PG.layout(800, 2, 500, 1);
        eq([two.photo, two.minus, two.plus, two.field, two.stepper, two.pills, two.minHeight].map((v) => v / 2),
           [one.photo, one.minus, one.plus, one.field, one.stepper, one.pills, one.minHeight]);
        const rand = FX.rng(5);
        let wraps = 0, narrow = 0;
        for (let i = 0; i < 1000; ++i) {
            const u = 0.75 + rand() * 3.25;
            const w = (100 + rand() * 1100) * u;
            const fs = 0.5 + rand() * 2.5;
            const maxQty = [0, 1, 9, 40, 500, 99999, 999999, 5000000][Math.floor(rand() * 8)];
            const g = PG.layout(w, u, maxQty, fs);
            ok(g.ok, "ok false for a valid input");
            ok(g.minus >= 48 * u - 1e-9 && g.plus >= 48 * u - 1e-9 && g.fieldHeight >= 48 * u - 1e-9 && g.field >= 48 * u - 1e-9, "target below 48 units");
            ok(g.gap >= 8 * u - 1e-9 && g.pills >= 0 && g.minHeight >= 48 * u, "negative or tiny size");
            if (g.pillsWrap) { wraps++; ok(Math.abs(g.pills - Math.max(0, w - 2 * g.pad)) < 1e-6, "wrapped pills not the full width"); }
            else ok(Math.abs(2 * g.pad + g.stepper + g.gap + g.pills - w) < 1e-6, "widths do not add up");
            if (!g.fits) narrow++;
            noThrow(() => PG.layout(w, u, maxQty, fs));
        }
        ok(wraps > 50 && wraps < 950, "the monkey never reached both layouts: " + wraps);
        ok(narrow > 0, "the monkey never reached a card too narrow to fit");
    }
}
