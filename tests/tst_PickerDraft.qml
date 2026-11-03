import QtQuick
import QtTest
import "../qml/helper/PickerDraft.js" as PD
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/pickerDraft.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "PickerDraft"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function test_DRFT_01_empty_gives_a_new_empty_draft_each_time() {
        const a = PD.empty();
        const b = PD.empty();
        eq(a, {});
        ok(a !== b, "same object returned twice");
    }

    function test_DRFT_02_parseqty_accepts_digits_only() {
        eq(PD.parseQty("3"), { ok: true, qty: 3 });
        eq(PD.parseQty(" 12 "), { ok: true, qty: 12 });
        eq(PD.parseQty(7), { ok: true, qty: 7 });
        eq(PD.parseQty("0"), { ok: true, qty: 0 });
        eq(PD.parseQty("007"), { ok: true, qty: 7 });
    }

    function test_DRFT_03_parseqty_refuses_everything_else() {
        const bad = ["", "  ", "abc", "2.5", 2.5, "-1", -1, "+3", "1e3", NaN, Infinity, null, undefined, {}, []];
        for (let i = 0; i < bad.length; ++i) eq(PD.parseQty(bad[i]), { ok: false, qty: 0 });
    }

    function test_DRFT_04_parseqty_allows_six_digits_at_most() {
        eq(PD.parseQty("999999"), { ok: true, qty: 999999 });
        eq(PD.parseQty("1000000"), { ok: false, qty: 0 });
    }

    function test_DRFT_05_setqty_sets_a_quantity() {
        eq(PD.setQty({}, "A", "3", 10), { A: 3 });
    }

    function test_DRFT_06_setqty_clamps_to_the_maximum() {
        eq(PD.setQty({}, "A", "50", 8), { A: 8 });
    }

    function test_DRFT_07_setqty_with_0_removes_the_product() {
        eq(PD.setQty({ A: 3 }, "A", "0", 10), {});
    }

    function test_DRFT_08_setqty_with_junk_text_leaves_the_draft_and_returns_a_new_obj() {
        const d = { A: 3 };
        const junk = ["abc", "2.5", ""];
        for (let i = 0; i < junk.length; ++i) {
            const r = PD.setQty(d, "A", junk[i], 10);
            eq(r, { A: 3 });
            ok(r !== d, "returned the input object");
        }
    }

    function test_DRFT_09_a_missing_or_junk_maximum_removes_the_product() {
        eq(PD.setQty({ A: 3 }, "A", "2", 0), {});
        eq(PD.setQty({ A: 3 }, "A", "2", undefined), {});
        eq(PD.setQty({ A: 3 }, "A", "2", -4), {});
        eq(PD.setQty({ A: 3 }, "A", "2", NaN), {});
        eq(PD.setQty({}, "A", "2", 0), {});
    }

    function test_DRFT_10_hostile_ids_leave_the_draft_alone() {
        const ids = ["__proto__", "", 5, null, undefined];
        for (let i = 0; i < ids.length; ++i) {
            noThrow(() => PD.setQty({ A: 1 }, ids[i], "3", 10));
            eq(PD.setQty({ A: 1 }, ids[i], "3", 10), { A: 1 });
        }
        eq(({}).polluted, undefined);
        eq(Object.prototype.hasOwnProperty.call(Object.prototype, "3"), false);
    }

    function test_DRFT_11_step_up_from_nothing() {
        eq(PD.step({}, "A", 1, 5), { A: 1 });
    }

    function test_DRFT_12_step_down_to_zero_removes_the_product() {
        eq(PD.step({ A: 1 }, "A", -1, 5), {});
    }

    function test_DRFT_13_step_up_stops_at_the_maximum() {
        eq(PD.step({ A: 5 }, "A", 1, 5), { A: 5 });
    }

    function test_DRFT_14_step_down_below_zero_changes_nothing() {
        eq(PD.step({}, "A", -1, 5), {});
        eq(PD.step({ B: 2 }, "A", -1, 5), { B: 2 });
    }

    function test_DRFT_15_a_junk_step_leaves_the_draft() {
        const bad = [NaN, 1.5, "1", Infinity, null];
        for (let i = 0; i < bad.length; ++i) eq(PD.step({ A: 2 }, "A", bad[i], 5), { A: 2 });
    }

    function test_DRFT_16_no_function_changes_its_input() {
        const d = FX.freeze({ A: 2, B: 1 });
        const lines = FX.freeze([{ productId: "A", qty: 1 }]);
        noThrow(() => PD.setQty(d, "A", "4", 9));
        noThrow(() => PD.step(d, "B", 1, 9));
        noThrow(() => PD.totals(d, () => 1));
        noThrow(() => PD.commitPlan(d, lines));
        noThrow(() => PD.lineLimitReached(lines, d));
        noThrow(() => PD.reconcile(d, () => 1));
        eq(d, { A: 2, B: 1 });
    }

    function test_DRFT_17_totals_count_items_lines_and_the_amount() {
        const prices = { A: 10, B: 5 };
        eq(PD.totals({ A: 2, B: 3 }, (id) => prices[id]), { items: 5, lines: 2, amount: 35 });
    }

    function test_DRFT_18_the_amount_is_rounded_to_two_decimals() {
        eq(PD.totals({ A: 1, B: 1 }, (id) => ({ A: 0.1, B: 0.2 })[id]).amount, 0.3);
        eq(PD.totals({ A: 3 }, () => 19.999).amount, 60);
    }

    function test_DRFT_19_junk_prices_count_as_0_and_never_break_the_counts() {
        const bad = [undefined, NaN, -5, "9"];
        for (let i = 0; i < bad.length; ++i) {
            const v = bad[i];
            eq(PD.totals({ A: 2 }, () => v), { items: 2, lines: 1, amount: 0 });
        }
        eq(PD.totals({ A: 2 }, undefined), { items: 2, lines: 1, amount: 0 });
        eq(PD.totals({ A: 0, B: "3", C: 2, D: 1.5 }, () => 1), { items: 2, lines: 1, amount: 2 });
        eq(PD.totals(null, () => 1), { items: 0, lines: 0, amount: 0 });
    }

    function test_DRFT_20_commitplan_splits_adds_and_bumps_sorted_by_id() {
        eq(PD.commitPlan({ B: 2, A: 1, C: 4 }, [{ productId: "B", qty: 9 }]),
           { adds: [{ productId: "A", qty: 1 }, { productId: "C", qty: 4 }], bumps: [{ productId: "B", qty: 2 }] });
    }

    function test_DRFT_21_a_corrupt_draft_entry_never_reaches_the_plan() {
        const plan = PD.commitPlan({ A: 0, B: -1, C: 2.5, D: "3", E: NaN, F: 2 }, []);
        eq(plan, { adds: [{ productId: "F", qty: 2 }], bumps: [] });
    }

    function test_DRFT_22_empty_and_null_inputs_give_an_empty_plan() {
        eq(PD.commitPlan({}, []), { adds: [], bumps: [] });
        eq(PD.commitPlan(null, []), { adds: [], bumps: [] });
        eq(PD.commitPlan({ A: 1 }, null), { adds: [{ productId: "A", qty: 1 }], bumps: [] });
    }

    function test_DRFT_23_an_existing_line_is_found_whatever_its_quantity_field_is_cal() {
        const shapes = [{ productId: "A", qty: 3 }, { productId: "A", quantity: 3 }, { productId: "A" }];
        for (let i = 0; i < shapes.length; ++i)
            eq(PD.commitPlan({ A: 1 }, [shapes[i]]), { adds: [], bumps: [{ productId: "A", qty: 1 }] });
    }

    function test_DRFT_24_linecountafter_counts_distinct_existing_lines_plus_adds() {
        const lines = [{ productId: "A" }, { productId: "A" }, { productId: "B" }];
        eq(PD.lineCountAfter(lines, { adds: [{ productId: "C" }, { productId: "D" }] }), 4);
        eq(PD.lineCountAfter(lines, null), 2);
        eq(PD.lineCountAfter(lines, {}), 2);
        eq(PD.lineCountAfter(null, null), 0);
    }

    function test_DRFT_25_the_line_limit_counts_new_lines_only() {
        const lines = [];
        for (let i = 0; i < PD.MAX_LINES - 1; ++i) lines.push({ productId: "L" + i });
        eq(PD.lineLimitReached(lines, {}), false);
        eq(PD.lineLimitReached(lines, { NEW: 1 }), true);
        eq(PD.lineLimitReached(lines, { L1: 4 }), false);
    }

    function test_DRFT_27_reconcile_clamps_to_the_current_maximum() {
        eq(PD.reconcile({ A: 5, B: 2 }, (id) => ({ A: 3, B: 9 })[id]), { A: 3, B: 2 });
    }

    function test_DRFT_28_reconcile_removes_what_is_no_longer_available_and_fails_clos() {
        eq(PD.reconcile({ A: 5, B: 2, C: 1 }, (id) => ({ A: 0, B: undefined })[id]), {});
        eq(PD.reconcile({ A: 5 }, undefined), {});
        eq(PD.reconcile({ A: 5 }, null), {});
        eq(PD.reconcile({ A: 0, B: "3", C: 2.5, D: 2 }, () => 9), { D: 2 });
    }

    function test_DRFT_29_reconcile_of_a_draft_within_limits_returns_an_equal_new_obje() {
        const d = { A: 1, B: 2 };
        const r = PD.reconcile(d, () => 9);
        eq(r, d);
        ok(r !== d, "returned the input object");
    }

    function test_DRFT_30_seeded_monkey_400_rounds() {
        const rand = FX.rng(11);
        const texts = ["1", "5", "0", "abc", "2.5", "", "999999", "1000000", " 3 "];
        const pids = ["A", "B", "C", "__proto__", "", "D"];
        const pick = (list) => list[Math.floor(rand() * list.length)];
        for (let round = 0; round < 400; ++round) {
            let d = PD.empty();
            const lines = rand() < 0.5 ? [{ productId: "B" }] : [];
            for (let i = 0; i < 20; ++i) {
                const r = rand();
                const maxQty = pick([0, 1, 4, 9, -1, undefined, 50]);
                if (r < 0.45) d = PD.setQty(d, pick(pids), pick(texts), maxQty);
                else if (r < 0.8) d = PD.step(d, pick(pids), pick([1, -1, 2, 1.5]), maxQty);
                else d = PD.reconcile(d, () => pick([0, 1, 3, 8]));
            }
            let sum = 0;
            for (const k in d) {
                ok(Number.isInteger(d[k]) && d[k] >= 1 && d[k] <= 999999, "bad quantity " + d[k]);
                sum += d[k];
            }
            const plan = PD.commitPlan(d, lines);
            let planSum = 0;
            const seen = {};
            const all = plan.adds.concat(plan.bumps);
            for (let i = 0; i < all.length; ++i) { planSum += all[i].qty; ok(!seen[all[i].productId], "id in both lists"); seen[all[i].productId] = true; }
            eq(planSum, sum);
            const sortedAdds = plan.adds.map((e) => e.productId).slice().sort();
            eq(plan.adds.map((e) => e.productId), sortedAdds);
            const sortedBumps = plan.bumps.map((e) => e.productId).slice().sort();
            eq(plan.bumps.map((e) => e.productId), sortedBumps);
        }
    }
}
