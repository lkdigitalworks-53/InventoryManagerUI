import QtQuick
import QtTest
import "../qml/helper/CartStepperGeometry.js" as CG
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/cartStepperGeometry.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "CartStepperGeometry"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function test_CSG_01_a_button_is_a_48_unit_touch_target_with_a_smaller_painted_fr() {
        const g = CG.layout(1, false);
        eq(g.target, 48);
        eq(g.height, 48);
        eq(g.visual, 32);
        eq(g.inset, 8);
        ok(g.visual < g.target, "the frame must sit inside the target");
        eq(g.inset * 2 + g.visual, g.target);
    }

    function test_CSG_02_every_size_scales_with_the_unit_and_the_target_never_drops_b() {
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
    }

    function test_CSG_03_junk_or_non_positive_unit_gives_all_zeros() {
        const bad = [0, -1, NaN, Infinity, "1", null, undefined, {}, []];
        for (let i = 0; i < bad.length; ++i) {
            eq(CG.layout(bad[i], true), { target: 0, visual: 0, qty: 0, gap: 0, inset: 0, width: 0, height: 0 });
            eq(CG.rowWidth(bad[i], true, [64]), 0);
        }
    }

    function test_CSG_04_width_counts_two_buttons_or_three_when_removable_with_the_qu() {
        eq(CG.layout(1, false).width, 48 + 4 + 28 + 4 + 48);
        eq(CG.layout(1, true).width, 48 + 4 + 28 + 4 + 48 + 4 + 48);
        eq(CG.layout(2, false).width, 2 * (48 + 4 + 28 + 4 + 48));
        eq(CG.layout(1, "yes").width, CG.layout(1, false).width);
        eq(CG.layout(1, 1).width, CG.layout(1, false).width);
    }

    function test_CSG_05_rowwidth_adds_the_extra_fixed_items_the_price_field_and_one_() {
        eq(CG.rowWidth(1, true, []), CG.layout(1, true).width);
        eq(CG.rowWidth(1, true, [64]), CG.layout(1, true).width + 64 + 4);
        eq(CG.rowWidth(1, true, [64, 20]), CG.layout(1, true).width + 64 + 20 + 8);
        eq(CG.rowWidth(2, true, [64]), 2 * CG.rowWidth(1, true, [64]));
    }

    function test_CSG_06_junk_extras_are_ignored_no_width_and_no_gap() {
        const base = CG.rowWidth(1, false, []);
        eq(CG.rowWidth(1, false, undefined), base);
        eq(CG.rowWidth(1, false, "64"), base);
        eq(CG.rowWidth(1, false, [0, -5, NaN, "9", null, undefined]), base);
        eq(CG.rowWidth(1, false, [0, 64, -1]), base + 64 + 4);
    }

    function test_CSG_07_the_edit_order_controls_row_price_field_stepper_remove_fits_() {
        // 320 wide, minus the page margin (2 x 16) and the controls row margin (2 x 14): the room the row really has.
        const room = 320 - 2 * 16 - 2 * 14;
        ok(CG.rowWidth(1, true, [64]) <= room, "Edit Order row needs " + CG.rowWidth(1, true, [64]) + " of " + room);
        ok(CG.layout(1, false).width <= room, "New Order stepper does not fit");
        // the old trailing-slot layout (everything on the title's row) could not have: it needs more than half the row
        ok(CG.rowWidth(1, true, [64]) > room / 2, "the stacked layout is what makes the targets fit");
    }
}
