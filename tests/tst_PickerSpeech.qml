import QtQuick
import QtTest
import "../qml/helper/PickerSpeech.js" as SP
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/pickerSpeech.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "PickerSpeech"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function full(over) {
        var r = { name: "Basmati Rice", productId: "P-101", unit: "kg", price: 120, pillLabel: "8 kg left", inOrderLabel: "",
                  qty: 0, atMax: false, canAdd: true, reasonText: "" };
        for (var k in (over || {})) r[k] = over[k];
        return r;
    }
    function junkPool() {
        return [undefined, null, NaN, Infinity, -Infinity, -1, 0, 0.5, 1, 2.9, 7, "", " ", "  x  ", "3",
                true, false, {}, [], [1], function () { return 1; }];
    }

    function test_SPK_01_a_normal_row_says_name_id_price_per_unit_and_how_much_is_lef() {
        eq(SP.row(full(), "Rs 120.00"), "Basmati Rice, P-101, Rs 120.00 per kg, 8 kg left");
    }

    function test_SPK_02_every_part_in_its_order_name_id_price_pill_in_order_selected() {
        const r = full({ qty: 5, atMax: true, inOrderLabel: "In this order: 2 kg", pillLabel: "5 kg left" });
        eq(SP.row(r, "Rs 120.00"),
            "Basmati Rice, P-101, Rs 120.00 per kg, 5 kg left, In this order: 2 kg, 5 selected, Maximum reached");
    }

    function test_SPK_03_a_price_is_spoken_only_when_the_row_price_is_above_zero_and_() {
        eq(SP.row(full({ price: 0 }), "Rs 0.00"), "Basmati Rice, P-101, 8 kg left");
        const bad = [-1, NaN, Infinity, -Infinity, "120", null, undefined, {}, [], true];
        for (let i = 0; i < bad.length; ++i) eq(SP.row(full({ price: bad[i] }), "Rs 120.00"), "Basmati Rice, P-101, 8 kg left");
        eq(SP.row(full(), ""), "Basmati Rice, P-101, 8 kg left");
        eq(SP.row(full(), "   "), "Basmati Rice, P-101, 8 kg left");
        eq(SP.row(full(), null), "Basmati Rice, P-101, 8 kg left");
        eq(SP.row(full(), 120), "Basmati Rice, P-101, 8 kg left");
    }

    function test_SPK_04_the_unit_is_trimmed_and_a_missing_or_blank_unit_leaves_the_p() {
        eq(SP.row(full({ unit: "  dozen boxes " }), "Rs 9.00"), "Basmati Rice, P-101, Rs 9.00 per dozen boxes, 8 kg left");
        eq(SP.row(full({ unit: "" }), "Rs 9.00"), "Basmati Rice, P-101, Rs 9.00, 8 kg left");
        eq(SP.row(full({ unit: "   " }), "Rs 9.00"), "Basmati Rice, P-101, Rs 9.00, 8 kg left");
        eq(SP.row(full({ unit: 5 }), "Rs 9.00"), "Basmati Rice, P-101, Rs 9.00, 8 kg left");
    }

    function test_SPK_05_the_reason_is_spoken_only_when_the_row_cannot_be_added_and_a() {
        const off = full({ canAdd: false, reasonText: "No selling price", pillLabel: "No price", price: 0 });
        eq(SP.row(off, "Rs 0.00"), "Basmati Rice, P-101, No price, No selling price");
        eq(SP.row(full({ canAdd: true, reasonText: "stale text" }), "Rs 120.00"), "Basmati Rice, P-101, Rs 120.00 per kg, 8 kg left");
        const notTrue = [false, undefined, null, 0, 1, "true", {}, []];
        for (let i = 0; i < notTrue.length; ++i)
            eq(SP.row(full({ canAdd: notTrue[i], reasonText: "Order full" }), "Rs 1.00"),
                "Basmati Rice, P-101, Rs 1.00 per kg, 8 kg left, Order full");
    }

    function test_SPK_06_a_part_that_repeats_an_earlier_one_is_spoken_once_whatever_i() {
        const out = full({ canAdd: false, pillLabel: "Out of stock", reasonText: "out of stock", price: 0 });
        eq(SP.row(out, ""), "Basmati Rice, P-101, Out of stock");
        eq(SP.row(full({ name: "P-101" }), "Rs 1.00"), "P-101, Rs 1.00 per kg, 8 kg left");
        eq(SP.row(full({ name: "A", productId: "a", pillLabel: "A", price: 0 }), ""), "A");
    }

    function test_SPK_07_a_picked_quantity_is_spoken_only_as_a_whole_number_of_at_lea() {
        eq(SP.row(full({ qty: 1 }), ""), "Basmati Rice, P-101, 8 kg left, 1 selected");
        eq(SP.row(full({ qty: 2.9 }), ""), "Basmati Rice, P-101, 8 kg left, 2 selected");
        eq(SP.row(full({ qty: 999999 }), ""), "Basmati Rice, P-101, 8 kg left, 999999 selected");
        const none = [0, 0.99, -3, NaN, Infinity, -Infinity, "3", null, undefined, true, {}, []];
        for (let i = 0; i < none.length; ++i) eq(SP.row(full({ qty: none[i] }), ""), "Basmati Rice, P-101, 8 kg left");
    }

    function test_SPK_08_maximum_is_spoken_only_for_an_atmax_of_exactly_true() {
        eq(SP.row(full({ atMax: true }), ""), "Basmati Rice, P-101, 8 kg left, Maximum reached");
        const no = [false, undefined, null, 1, "true", {}, []];
        for (let i = 0; i < no.length; ++i) eq(SP.row(full({ atMax: no[i] }), ""), "Basmati Rice, P-101, 8 kg left");
    }

    function test_SPK_09_text_parts_are_trimmed_and_blank_or_non_text_parts_are_left_() {
        eq(SP.row(full({ name: "  Rice  ", productId: " P1 ", pillLabel: "  3 left " }), ""), "Rice, P1, 3 left");
        eq(SP.row(full({ name: "", pillLabel: "" }), ""), "P-101");
        eq(SP.row(full({ name: 5, productId: null, pillLabel: undefined, inOrderLabel: {}, reasonText: [] }), ""), "");
        eq(SP.row({}, "Rs 1.00"), "");
    }

    function test_SPK_10_a_missing_or_junk_row_never_throws_and_says_nothing() {
        const bad = [undefined, null, 5, "x", true, NaN, function () { return 1; }];
        for (let i = 0; i < bad.length; ++i) {
            noThrow(() => SP.row(bad[i], "Rs 1.00"));
            eq(SP.row(bad[i], "Rs 1.00"), "");
        }
        noThrow(() => SP.row());
        eq(SP.row(), "");
    }

    function test_SPK_11_seeded_monkey_600_rounds_of_junk_in_every_field_a_string_no_() {
        const rand = FX.rng(52);
        const pool = junkPool();
        const keys = ["name", "productId", "unit", "price", "pillLabel", "inOrderLabel", "qty", "atMax", "canAdd", "reasonText"];
        for (let round = 0; round < 600; ++round) {
            const r = {};
            for (let k = 0; k < keys.length; ++k) if (rand() < 0.85) r[keys[k]] = pool[Math.floor(rand() * pool.length)];
            const price = pool[Math.floor(rand() * pool.length)];
            const before = FX.canon(r);
            let text = "";
            noThrow(() => { text = SP.row(r, price); });
            ok(typeof text === "string", "not a string in round " + round);
            ok(!/undefined|NaN|\bnull\b|\[object|Infinity/.test(text), "junk word in: " + text);
            ok(text === text.trim() && !/^,|,\s*$|,\s*,/.test(text), "stray separator in: " + text);
            eq(SP.row(r, price), text);
            eq(FX.canon(r), before);
        }
    }
}
