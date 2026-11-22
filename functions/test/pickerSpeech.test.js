"use strict";
// PickerSpeech (qml/helper/PickerSpeech.js). Cases SPK-01..12, plan:
// docs/superpowers/plans/2026-11-22-product-picker-v2-s5e1-talkback-and-targets.md. The QML twin
// tests/tst_PickerSpeech.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const SP = load("PickerSpeech.js");
const PM = load("PickerSheetModel.js");

// QML-PRELUDE-BEGIN
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
// QML-PRELUDE-END

test("SPK-01 a normal row says name, ID, price per unit and how much is left", () => {
    eq(SP.row(full(), "Rs 120.00"), "Basmati Rice, P-101, Rs 120.00 per kg, 8 kg left");
});
test("SPK-02 every part in its order: name, ID, price, pill, in order, selected, maximum", () => {
    const r = full({ qty: 5, atMax: true, inOrderLabel: "In this order: 2 kg", pillLabel: "5 kg left" });
    eq(SP.row(r, "Rs 120.00"),
        "Basmati Rice, P-101, Rs 120.00 per kg, 5 kg left, In this order: 2 kg, 5 selected, Maximum reached");
});
test("SPK-03 a price is spoken only when the row price is above zero and the shown price is text", () => {
    eq(SP.row(full({ price: 0 }), "Rs 0.00"), "Basmati Rice, P-101, 8 kg left");
    const bad = [-1, NaN, Infinity, -Infinity, "120", null, undefined, {}, [], true];
    for (let i = 0; i < bad.length; ++i) eq(SP.row(full({ price: bad[i] }), "Rs 120.00"), "Basmati Rice, P-101, 8 kg left");
    eq(SP.row(full(), ""), "Basmati Rice, P-101, 8 kg left");
    eq(SP.row(full(), "   "), "Basmati Rice, P-101, 8 kg left");
    eq(SP.row(full(), null), "Basmati Rice, P-101, 8 kg left");
    eq(SP.row(full(), 120), "Basmati Rice, P-101, 8 kg left");
});
test("SPK-04 the unit is trimmed, and a missing or blank unit leaves the price alone", () => {
    eq(SP.row(full({ unit: "  dozen boxes " }), "Rs 9.00"), "Basmati Rice, P-101, Rs 9.00 per dozen boxes, 8 kg left");
    eq(SP.row(full({ unit: "" }), "Rs 9.00"), "Basmati Rice, P-101, Rs 9.00, 8 kg left");
    eq(SP.row(full({ unit: "   " }), "Rs 9.00"), "Basmati Rice, P-101, Rs 9.00, 8 kg left");
    eq(SP.row(full({ unit: 5 }), "Rs 9.00"), "Basmati Rice, P-101, Rs 9.00, 8 kg left");
});
test("SPK-05 the reason is spoken only when the row cannot be added, and anything but true counts as cannot", () => {
    const off = full({ canAdd: false, reasonText: "No selling price", pillLabel: "No price", price: 0 });
    eq(SP.row(off, "Rs 0.00"), "Basmati Rice, P-101, No price, No selling price");
    eq(SP.row(full({ canAdd: true, reasonText: "stale text" }), "Rs 120.00"), "Basmati Rice, P-101, Rs 120.00 per kg, 8 kg left");
    const notTrue = [false, undefined, null, 0, 1, "true", {}, []];
    for (let i = 0; i < notTrue.length; ++i)
        eq(SP.row(full({ canAdd: notTrue[i], reasonText: "Order full" }), "Rs 1.00"),
            "Basmati Rice, P-101, Rs 1.00 per kg, 8 kg left, Order full");
});
test("SPK-06 a part that repeats an earlier one is spoken once, whatever its case", () => {
    const out = full({ canAdd: false, pillLabel: "Out of stock", reasonText: "out of stock", price: 0 });
    eq(SP.row(out, ""), "Basmati Rice, P-101, Out of stock");
    eq(SP.row(full({ name: "P-101" }), "Rs 1.00"), "P-101, Rs 1.00 per kg, 8 kg left");
    eq(SP.row(full({ name: "A", productId: "a", pillLabel: "A", price: 0 }), ""), "A");
});
test("SPK-07 a picked quantity is spoken only as a whole number of at least one, rounded down", () => {
    eq(SP.row(full({ qty: 1 }), ""), "Basmati Rice, P-101, 8 kg left, 1 selected");
    eq(SP.row(full({ qty: 2.9 }), ""), "Basmati Rice, P-101, 8 kg left, 2 selected");
    eq(SP.row(full({ qty: 999999 }), ""), "Basmati Rice, P-101, 8 kg left, 999999 selected");
    const none = [0, 0.99, -3, NaN, Infinity, -Infinity, "3", null, undefined, true, {}, []];
    for (let i = 0; i < none.length; ++i) eq(SP.row(full({ qty: none[i] }), ""), "Basmati Rice, P-101, 8 kg left");
});
test("SPK-08 maximum is spoken only for an atMax of exactly true", () => {
    eq(SP.row(full({ atMax: true }), ""), "Basmati Rice, P-101, 8 kg left, Maximum reached");
    const no = [false, undefined, null, 1, "true", {}, []];
    for (let i = 0; i < no.length; ++i) eq(SP.row(full({ atMax: no[i] }), ""), "Basmati Rice, P-101, 8 kg left");
});
test("SPK-09 text parts are trimmed, and blank or non-text parts are left out with no stray separator", () => {
    eq(SP.row(full({ name: "  Rice  ", productId: " P1 ", pillLabel: "  3 left " }), ""), "Rice, P1, 3 left");
    eq(SP.row(full({ name: "", pillLabel: "" }), ""), "P-101");
    eq(SP.row(full({ name: 5, productId: null, pillLabel: undefined, inOrderLabel: {}, reasonText: [] }), ""), "");
    eq(SP.row({}, "Rs 1.00"), "");
});
test("SPK-10 a missing or junk row never throws and says nothing", () => {
    const bad = [undefined, null, 5, "x", true, NaN, function () { return 1; }];
    for (let i = 0; i < bad.length; ++i) {
        noThrow(() => SP.row(bad[i], "Rs 1.00"));
        eq(SP.row(bad[i], "Rs 1.00"), "");
    }
    noThrow(() => SP.row());
    eq(SP.row(), "");
});
test("SPK-11 seeded monkey, 600 rounds of junk in every field: a string, no junk words, no stray separators, pure", () => {
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
});
test("SPK-12 the speech reads the keys the real sheet model gives a row, and a no-price row never says a price (Node only)", () => {
    const hooks = {
        hasPendingMint: () => false, unsyncedState: () => "",
        availableFor: (p) => (typeof p.stock === "number" ? p.stock : 0),
        hasPrice: (p) => typeof p.sellingPrice === "number",
    };
    const products = [
        { productId: "A1", name: "Priced", stock: 4, sellingPrice: 25, unit: "kg" },
        { productId: "B2", name: "Unpriced", stock: 4, unit: "pcs" },
        { productId: "C3", name: "Empty", stock: 0, sellingPrice: 10 },
    ];
    const v = PM.build({ products, hooks, orderLines: [], draft: { A1: 3 }, query: "", category: "All", inStockOnly: false });
    const keys = ["name", "productId", "unit", "price", "pillLabel", "inOrderLabel", "qty", "atMax", "canAdd", "reasonText"];
    for (const row of v.rows) for (const k of keys) assert.ok(k in row, "the model row has no key " + k + ": speech would go quiet");
    const by = (id) => v.rows.find((r) => r.productId === id);
    assert.equal(SP.row(by("A1"), "Rs 25.00"), "Priced, A1, Rs 25.00 per kg, 4 kg left, 3 selected");
    assert.equal(SP.row(by("B2"), "Rs 0.00"), "Unpriced, B2, No price, No selling price");
    assert.equal(SP.row(by("C3"), "Rs 10.00"), "Empty, C3, Rs 10.00 per pcs, Out of stock");
});
