"use strict";
// ProductPickability (qml/helper/ProductPickability.js). Cases PICK-01..25, plan:
// docs/superpowers/plans/2026-11-03-product-picker-v2-s1-pure-helpers.md. The QML twin
// tests/tst_ProductPickability.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const PK = load("ProductPickability.js");

// QML-PRELUDE-BEGIN
function prod(id) { return { productId: id, name: "n" + id }; }
function ctx(over) {
    var c = { availableFor: function() { return 5; } };
    for (var k in (over || {})) c[k] = over[k];
    return c;
}
function brief(r) { return { visibility: r.visibility, reason: r.reason, available: r.available, maxQty: r.maxQty }; }
// QML-PRELUDE-END

test("PICK-01 a product with stock is enabled", () => {
    eq(brief(PK.classify(prod("A"), ctx())), { visibility: "enabled", reason: "", available: 5, maxQty: 5 });
});
test("PICK-02 zero stock is disabled as out of stock", () => {
    eq(brief(PK.classify(prod("A"), ctx({ availableFor: () => 0 }))),
       { visibility: "disabled", reason: "out-of-stock", available: 0, maxQty: 0 });
});
test("PICK-03 junk stock values count as out of stock", () => {
    const junk = [-3, NaN, undefined, "7", Infinity];
    for (let i = 0; i < junk.length; ++i) {
        const v = junk[i];
        eq(brief(PK.classify(prod("A"), ctx({ availableFor: () => v }))),
           { visibility: "disabled", reason: "out-of-stock", available: 0, maxQty: 0 });
    }
});
test("PICK-04 fractional stock is floored", () => {
    eq(brief(PK.classify(prod("A"), ctx({ availableFor: () => 3.7 }))),
       { visibility: "enabled", reason: "", available: 3, maxQty: 3 });
});
test("PICK-05 pending mint hides the product", () => {
    eq(brief(PK.classify(prod("A"), ctx({ hasPendingMint: () => true }))),
       { visibility: "hidden", reason: "pending-mint", available: 0, maxQty: 0 });
});
test("PICK-06 a queued restock hides the product", () => {
    const r = PK.classify(prod("A"), ctx({ hasQueuedRestock: () => true }));
    eq([r.visibility, r.reason], ["hidden", "queued-restock"]);
});
test("PICK-07 a pending unsynced edit hides the product", () => {
    const r = PK.classify(prod("A"), ctx({ unsyncedState: () => "pending" }));
    eq([r.visibility, r.reason], ["hidden", "unsynced-edit"]);
});
test("PICK-08 a parked edit hides it, other states do not", () => {
    eq(PK.classify(prod("A"), ctx({ unsyncedState: () => "parked" })).reason, "unsynced-edit");
    const other = ["", "x", undefined];
    for (let i = 0; i < other.length; ++i) {
        const v = other[i];
        eq(PK.classify(prod("A"), ctx({ unsyncedState: () => v })).visibility, "enabled");
    }
});
test("PICK-09 a delete in flight hides the product", () => {
    const r = PK.classify(prod("A"), ctx({ isDeleting: () => true }));
    eq([r.visibility, r.reason], ["hidden", "deleting"]);
});
test("PICK-10 hide reasons have a fixed precedence and beat out of stock", () => {
    const all = { hasPendingMint: () => true, hasQueuedRestock: () => true, unsyncedState: () => "pending",
                  isDeleting: () => true, availableFor: () => 0 };
    eq(PK.classify(prod("A"), all).reason, "pending-mint");
    all.hasPendingMint = () => false;
    eq(PK.classify(prod("A"), all).reason, "queued-restock");
    all.hasQueuedRestock = () => false;
    eq(PK.classify(prod("A"), all).reason, "unsynced-edit");
    all.unsyncedState = () => "";
    eq(PK.classify(prod("A"), all).reason, "deleting");
    all.isDeleting = () => false;
    eq(PK.classify(prod("A"), all).reason, "out-of-stock");
});
test("PICK-11 order full disables a new product", () => {
    const r = PK.classify(prod("A"), ctx({ lineLimitReached: true }));
    eq([r.visibility, r.reason, r.maxQty], ["disabled", "order-full", 0]);
    eq(PK.classify(prod("A"), ctx({ lineLimitReached: 1 })).visibility, "enabled");
    eq(PK.classify(prod("A"), ctx({ lineLimitReached: "yes" })).visibility, "enabled");
});
test("PICK-12 order full still allows a product already on the order", () => {
    const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, inOrderQty: () => 2 }));
    eq([r.visibility, r.inOrder], ["enabled", 2]);
});
test("PICK-13 order full still allows a product already in the draft", () => {
    const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, inDraft: () => 3 }));
    eq([r.visibility, r.inDraft], ["enabled", 3]);
});
test("PICK-14 out of stock wins over order full", () => {
    const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, availableFor: () => 0 }));
    eq(r.reason, "out-of-stock");
});
test("PICK-15 a missing hook or context fails closed", () => {
    eq(PK.classify(prod("A"), {}).reason, "out-of-stock");
    eq(PK.classify(prod("A"), undefined).reason, "out-of-stock");
    eq(PK.classify(prod("A"), null).reason, "out-of-stock");
    eq(PK.classify(prod("A"), {}).visibility, "disabled");
});
test("PICK-16 a throwing hook disables the row as unavailable", () => {
    const boom = () => { throw new Error("boom"); };
    const a = PK.classify(prod("A"), ctx({ availableFor: boom }));
    eq([a.visibility, a.reason, a.maxQty], ["disabled", "unavailable", 0]);
    const b = PK.classify(prod("A"), ctx({ hasPendingMint: boom }));
    eq([b.visibility, b.reason, b.maxQty], ["disabled", "unavailable", 0]);
});
test("PICK-17 junk order and draft quantities become 0", () => {
    const vals = [4, -1, "2", NaN];
    const want = [4, 0, 0, 0];
    for (let i = 0; i < vals.length; ++i) {
        const v = vals[i];
        const r = PK.classify(prod("A"), ctx({ inOrderQty: () => v, inDraft: () => v }));
        eq([r.inOrder, r.inDraft], [want[i], want[i]]);
    }
});
test("PICK-18 a product that is not a product is unavailable, never a throw", () => {
    const junk = [null, undefined, 5, [], {}];
    for (let i = 0; i < junk.length; ++i) {
        const v = junk[i];
        noThrow(() => PK.classify(v, ctx()));
        eq([PK.classify(v, ctx()).visibility, PK.classify(v, ctx()).reason], ["disabled", "unavailable"]);
    }
});
test("PICK-19 summarize counts hidden products and keeps the rest", () => {
    const list = [prod("A"), prod("B"), prod("C"), prod("D"), prod("E")];
    const c = ctx({ hasPendingMint: (id) => id === "B", unsyncedState: (id) => (id === "D" ? "parked" : "") });
    const s = PK.summarize(list, c, {});
    eq([s.rows.length, s.hiddenCount], [3, 2]);
});
test("PICK-20 summarize keeps the input order", () => {
    const list = [prod("C"), prod("A"), prod("B")];
    const s = PK.summarize(list, ctx({ hasPendingMint: (id) => id === "A" }), {});
    eq(s.rows.map((r) => r.product.productId), ["C", "B"]);
});
test("PICK-21 inStockOnly drops only out of stock rows", () => {
    const list = [prod("OUT"), prod("FULL"), prod("BAD"), prod("OK"), prod("HID")];
    const c = {
        availableFor: (p) => {
            if (p.productId === "OUT") return 0;
            if (p.productId === "BAD") throw new Error("boom");
            return 5;
        },
        hasPendingMint: (id) => id === "HID",
        lineLimitReached: true,
        inOrderQty: (id) => (id === "OK" ? 1 : 0)
    };
    const s = PK.summarize(list, c, { inStockOnly: true });
    eq(s.rows.map((r) => r.reason), ["order-full", "unavailable", ""]);
    eq(s.hiddenCount, 1);
});
test("PICK-22 summarize of a non-array is empty", () => {
    const bad = [[], null, "x", undefined];
    for (let i = 0; i < bad.length; ++i) eq(PK.summarize(bad[i], ctx(), {}), { rows: [], hiddenCount: 0 });
});
test("PICK-23 summarize skips junk entries without counting them", () => {
    const s = PK.summarize([null, 5, [], prod("A")], ctx(), {});
    eq([s.rows.length, s.hiddenCount], [1, 0]);
});
test("PICK-24 inputs are never changed", () => {
    const list = FX.freeze([prod("A"), prod("B")]);
    const c = FX.freeze({ availableFor: () => 5, lineLimitReached: false });
    noThrow(() => PK.summarize(list, c, { inStockOnly: true }));
    noThrow(() => PK.classify(list[0], c));
    eq(list.length, 2);
});
test("PICK-25 seeded monkey, 400 rounds", () => {
    const rand = FX.rng(3);
    const outcomes = [true, false, "throw", "junk", 0, 5, -2, "parked", "pending", ""];
    const hook = () => {
        const o = outcomes[Math.floor(rand() * outcomes.length)];
        return () => { if (o === "throw") throw new Error("boom"); return o === "junk" ? { x: 1 } : o; };
    };
    for (let round = 0; round < 400; ++round) {
        const list = [];
        const n = Math.floor(rand() * 9);
        for (let i = 0; i < n; ++i) list.push(rand() < 0.1 ? null : prod("P" + i));
        const c = { availableFor: hook(), hasPendingMint: hook(), hasQueuedRestock: hook(), unsyncedState: hook(),
                    isDeleting: hook(), inOrderQty: hook(), inDraft: hook(), lineLimitReached: rand() < 0.3 };
        let s = { rows: [], hiddenCount: 0 };
        let t = { rows: [], hiddenCount: 0 };
        noThrow(() => { s = PK.summarize(list, c, {}); t = PK.summarize(list, c, { inStockOnly: true }); });
        const valid = list.filter((p) => !!p).length;
        eq(s.rows.length + s.hiddenCount, valid);
        ok(t.rows.length <= s.rows.length, "inStockOnly added rows");
        eq(t.hiddenCount, s.hiddenCount);
        for (let k = 0; k < s.rows.length; ++k) {
            const r = s.rows[k];
            ok(r.visibility !== "hidden", "hidden row in rows");
            if (r.visibility === "enabled") ok(r.maxQty >= 1, "enabled row without capacity");
            else eq(r.maxQty, 0);
        }
    }
});
