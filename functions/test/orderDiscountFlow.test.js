"use strict";

// Atomic-ops NO3c (design 2026-11-26-no3c-edit-order-money-fields-design.md): the pure discount decisions both order sheets use.
// The limits are checked against the REAL OrdersStore.computeOrderTotals: whatever the helper accepts is never clamped by it.

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const { load, plain, extractFunction } = require("./testSupport/qmlHelpers");

const OF = load("OrderFlow.js");
const money = (n) => "₹" + n;

const totals = (() => {
    const ctx = { Math, Object, parseFloat };
    vm.createContext(ctx);
    vm.runInContext(extractFunction("model/OrdersStore.qml", "computeOrderTotals"), ctx);
    return (line) => plain(ctx.computeOrderTotals([line]));
})();
const edit = (text, current, type, gross) => plain(OF.discountEdit(text, current, type, gross));

test("DF-1 isRow: only a whole number inside the list", () => {
    assert.equal(OF.isRow(0, 1), true);
    assert.equal(OF.isRow(1, 2), true);
    for (const [i, n] of [[-1, 2], [2, 2], [0, 0], [0.5, 2], [NaN, 2], [undefined, 2], [null, 2], ["0", 2], [Infinity, 2], [{}, 2]])
        assert.equal(OF.isRow(i, n), false, String(i) + "/" + n);
});

test("DF-2 discountEdit: plain decimals inside the limit are set, for both types, edges included", () => {
    for (const [t, type, gross, v] of [["0", "flat", 300, 0], ["12.5", "flat", 300, 12.5], ["300", "flat", 300, 300], [" 7 ", "flat", 300, 7],
        [".5", "percent", 300, 0.5], ["100", "percent", 300, 100], ["100", "percent", 1, 100], ["5.", "percent", 0, 5]])
        assert.deepEqual(edit(t, 3, type, gross), { kind: "set", value: v }, JSON.stringify([t, type, gross]));
});

test("DF-3 discountEdit: junk, a sign, an exponent, a comma are 'invalid'; above the limit names the limit", () => {
    for (const t of ["-5", "1e2", "1,5", "12abc", "1.2.3", "abc", ".", "+5", "₹5", "5%", "٣"])
        for (const type of ["flat", "percent"]) assert.deepEqual(edit(t, 3, type, 300), { kind: "refused", reason: "invalid" }, t);
    for (const t of ["100.01", "101", "9".repeat(40)]) assert.deepEqual(edit(t, 3, "percent", 1e9), { kind: "refused", reason: "percent" }, t);
    for (const t of ["300.01", "301", "9".repeat(40)]) assert.deepEqual(edit(t, 3, "flat", 300), { kind: "refused", reason: "amount" }, t);
});

test("DF-4 discountEdit: blank means no discount; the shown text is unchanged even when the stored value is over the limit", () => {
    for (const t of ["", "   ", undefined, null]) assert.deepEqual(edit(t, 3, "flat", 300), { kind: "set", value: 0 });
    for (const [t, cur] of [["3", 3], [" 3 ", 3], ["150", 150], ["0", 0], ["0", undefined], ["0", null]])
        assert.deepEqual(edit(t, cur, "percent", 300), { kind: "unchanged" }, JSON.stringify([t, cur]));
    assert.deepEqual(edit("3.0", 3, "flat", 300), { kind: "set", value: 3 }, "same number, other spelling: set, the dialog sees no change");
});

test("DF-5 discountFits: float noise on the line amount does not refuse the exact amount; a bad amount fits only 0", () => {
    assert.ok(0.7 * 3 < 2.1, "the case this guards");
    assert.equal(OF.discountFits(2.1, "flat", 0.7 * 3), true);
    assert.equal(OF.discountFits(2.11, "flat", 0.7 * 3), false);
    for (const gross of [NaN, undefined, Infinity, -Infinity, -5]) {
        assert.equal(OF.discountFits(0, "flat", gross), true, String(gross));
        assert.equal(OF.discountFits(1, "flat", gross), false, String(gross));
    }
    for (const v of [-1, NaN, Infinity, "5", undefined]) assert.equal(OF.discountFits(v, "percent", 10), false, String(v));
});

test("DF-6 the three reason texts are distinct, plain and non-empty; the amount text shows the line amount; unknown is ''", () => {
    const t = ["invalid", "percent", "amount"].map((r) => OF.discountText(r, "₹300"));
    assert.equal(new Set(t).size, 3);
    assert.ok(t[2].includes("₹300") && t[1].includes("100"));
    assert.equal(OF.discountText("nope", "x"), "");
});

test("DF-7 discountSwitch: the free-line bug: flat 500 switched to percent becomes 0 and says so, never 100%", () => {
    const r = plain(OF.discountSwitch(null, 500, "percent", 1000, money(1000)));
    assert.equal(r.value, 0);
    assert.ok(r.message.includes("percentage") && r.message.endsWith("It is now 0"), r.message);
});

test("DF-8 discountSwitch: the typed text wins over the stored value and is read under the NEW type", () => {
    assert.deepEqual(plain(OF.discountSwitch("15", 500, "percent", 1000, money(1000))), { value: 15, message: "" });
    assert.deepEqual(plain(OF.discountSwitch(null, 15, "flat", 1000, money(1000))), { value: 15, message: "" });
    assert.deepEqual(plain(OF.discountSwitch("", 15, "flat", 1000, money(1000))), { value: 0, message: "" });
    assert.deepEqual(plain(OF.discountSwitch(null, undefined, "flat", 1000, money(1000))), { value: 0, message: "" });
    // typed text equal to the stored one is still checked against the new type
    assert.equal(OF.discountSwitch("500", 500, "percent", 1000, money(1000)).value, 0);
    assert.equal(OF.discountSwitch("abc", 5, "flat", 1000, money(1000)).value, 0);
    const amt = OF.discountSwitch(null, 50, "flat", 40, money(40));
    assert.equal(amt.value, 0);
    assert.ok(amt.message.includes("₹40"));
});

const line = (over) => Object.assign({ productId: "P1", name: "Soap", price: 100, quantity: 3, discountType: "flat", discountValue: 0 }, over);
const problems = (l, errors, saved) => plain(OF.lineProblems(l, errors || {}, money, saved));

test("DF-9 lineProblems: a clean line has none", () => {
    assert.deepEqual(problems(line()), []);
    assert.deepEqual(problems(line({ discountValue: 300 })), []);
    assert.deepEqual(problems(line({ discountType: "percent", discountValue: 100 })), []);
    assert.deepEqual(problems(line({ discountType: undefined, discountValue: undefined })), []);
});

test("DF-10 lineProblems: unread refusals block, each naming the line and what it holds now", () => {
    const p = problems(line({ discountValue: 7 }), { price: "x", discount: "y" });
    assert.equal(p.length, 2);
    assert.equal(p[0], OF.priceBlockedText("Soap", "₹100"));
    assert.ok(p[1].startsWith("Soap: ") && p[1].includes("₹7") && p[1].includes("discount field"), p[1]);
    assert.ok(problems(line({ discountType: "percent", discountValue: 7 }), { discount: "y" })[0].includes("7%"));
    assert.ok(problems(line({ name: "" }), { discount: "y" })[0].startsWith("An item: "));
});

test("DF-11 lineProblems: a discount that no longer fits blocks, with the limit", () => {
    const flat = problems(line({ quantity: 1, discountValue: 150 }));
    assert.equal(flat.length, 1);
    assert.ok(flat[0].includes("₹100") && flat[0].includes("Change the discount"), flat[0]);
    assert.ok(problems(line({ discountType: "percent", discountValue: 101 }))[0].includes("100%"));
    assert.equal(problems(line({ discountValue: -1 })).length, 1);
});

test("DF-12 lineProblems: a line identical to a saved one is left alone; any change to it is checked again", () => {
    const odd = line({ quantity: 1, discountValue: 150 });
    assert.deepEqual(problems(odd, {}, [Object.assign({}, odd)]), []);
    assert.deepEqual(problems(odd, {}, [line(), Object.assign({}, odd)]), [], "any saved line may match (repeated product)");
    assert.deepEqual(problems(odd, {}, [Object.assign({}, odd, { productId: "P1", discountValue: "150" })]).length, 1, "a text value is not the same value");
    for (const k of [{ price: 99 }, { quantity: 2 }, { discountType: "percent" }, { discountValue: 151 }, { productId: "P2" }])
        assert.equal(problems(odd, {}, [Object.assign({}, odd, k)]).length, 1, JSON.stringify(k));
    // old orders: no product id, matched by name; numeric ids match as text
    const noId = line({ productId: "", quantity: 1, discountValue: 150 });
    assert.deepEqual(problems(noId, {}, [Object.assign({}, noId)]), []);
    assert.equal(problems(noId, {}, [Object.assign({}, noId, { name: "Other" })]).length, 1);
    assert.deepEqual(problems(line({ productId: "7", quantity: 1, discountValue: 150 }), {}, [line({ productId: 7, quantity: 1, discountValue: 150 })]), []);
    // a refusal still blocks a saved line
    assert.equal(problems(odd, { discount: "y" }, [Object.assign({}, odd)]).length, 1);
    for (const junk of [null, undefined, "x", [null]]) assert.equal(problems(odd, {}, junk).length, 1);
});

test("DF-13 monkey: 20000 random texts: never throws; every accepted discount is inside the limit and is NOT clamped by the real totals", () => {
    let seed = 20261126;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
    const alphabet = "01234567890123456789....,--+e %₹abc";
    const seen = { set: 0, refused: 0, unchanged: 0 };
    for (let n = 0; n < 20000; n++) {
        let t = ""; const len = Math.floor(rnd() * 8);
        for (let i = 0; i < len; i++) t += alphabet[Math.floor(rnd() * alphabet.length)];
        if (n % 50 === 0) t = "3";
        const type = rnd() < 0.5 ? "flat" : "percent";
        const price = Math.floor(rnd() * 100000) / 100, qty = 1 + Math.floor(rnd() * 20);
        const r = OF.discountEdit(t, 3, type, price * qty);
        seen[r.kind]++;
        if (r.kind !== "set") continue;
        const applied = totals({ price, quantity: qty, discountType: type, discountValue: r.value }).discount;
        const meant = type === "percent" ? price * qty * r.value / 100 : r.value;
        assert.ok(Math.abs(applied - meant) <= 0.011, JSON.stringify({ t, type, price, qty, applied, meant }));
    }
    assert.ok(seen.set > 200 && seen.refused > 2000 && seen.unchanged > 100, JSON.stringify(seen));
});
