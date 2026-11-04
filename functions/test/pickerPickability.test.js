"use strict";
// ProductPickability (qml/helper/ProductPickability.js). Cases PICK-01..34, plan:
// docs/superpowers/plans/2026-11-03-product-picker-v2-s1-pure-helpers.md. The QML twin
// tests/tst_ProductPickability.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const PK = load("ProductPickability.js");

// QML-PRELUDE-BEGIN
function prod(id) { return { productId: id, name: "n" + id }; }
function ctx(over) {
    var c = { availableFor: function() { return 5; }, hasPendingMint: function() { return false; }, unsyncedState: function() { return ""; } };
    for (var k in (over || {})) c[k] = over[k];
    return c;
}
function brief(r) { return { visibility: r.visibility, reason: r.reason, available: r.available, maxQty: r.maxQty }; }
// QML-PRELUDE-END

test("PICK-01 a product with stock is enabled", () => {
    eq(brief(PK.classify(prod("A"), ctx())), { visibility: "enabled", reason: "", available: 5, maxQty: 5 });
    eq(PK.classify(prod("A"), ctx()), { product: prod("A"), visibility: "enabled", reason: "", available: 5, maxQty: 5, inOrder: 0, inDraft: 0 });
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
test("PICK-06 a queued restock hides the product, asked by product id", () => {
    const r = PK.classify(prod("A"), ctx({ hasQueuedRestock: (id) => id === "A" }));
    eq([r.visibility, r.reason], ["hidden", "queued-restock"]);
    eq(PK.classify(prod("A"), ctx({ hasQueuedRestock: (id) => id === "B" })).visibility, "enabled");
});
test("PICK-07 a pending unsynced edit hides the product", () => {
    const r = PK.classify(prod("A"), ctx({ unsyncedState: () => "pending" }));
    eq([r.visibility, r.reason], ["hidden", "unsynced-edit"]);
});
test("PICK-08 a parked edit hides it, other states do not", () => {
    eq(PK.classify(prod("A"), ctx({ unsyncedState: () => "parked" })).reason, "unsynced-edit");
    const none = ["", undefined, null];
    for (let i = 0; i < none.length; ++i) {
        const v = none[i];
        eq(PK.classify(prod("A"), ctx({ unsyncedState: () => v })).visibility, "enabled");
    }
    // anything else is an unknown state, and an unknown state hides: a wrong hook cannot open the guard
    const odd = ["x", { state: "pending" }, 1, true, [], false];
    for (let i = 0; i < odd.length; ++i) {
        const v = odd[i];
        eq(PK.classify(prod("A"), ctx({ unsyncedState: () => v })).reason, "unsynced-edit");
    }
});
test("PICK-09 a delete in flight hides the product, asked by product id", () => {
    const r = PK.classify(prod("A"), ctx({ isDeleting: (id) => id === "A" }));
    eq([r.visibility, r.reason], ["hidden", "deleting"]);
    eq(PK.classify(prod("A"), ctx({ isDeleting: (id) => id === "B" })).visibility, "enabled");
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
    // a truthy non-boolean counts as reached: a sloppy ctx cannot open the cap
    eq(PK.classify(prod("A"), ctx({ lineLimitReached: 1 })).reason, "order-full");
    eq(PK.classify(prod("A"), ctx({ lineLimitReached: "yes" })).reason, "order-full");
    eq(PK.classify(prod("A"), ctx({ lineLimitReached: 0 })).visibility, "enabled");
    eq(PK.classify(prod("A"), ctx({ lineLimitReached: "" })).visibility, "enabled");
    eq(PK.classify(prod("A"), ctx({ lineLimitReached: false })).visibility, "enabled");
});
test("PICK-12 order full still allows a product already on the order", () => {
    const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, inOrderQty: (id) => (id === "A" ? 2 : 0) }));
    eq([r.visibility, r.inOrder, r.maxQty], ["enabled", 2, 5]);
});
test("PICK-13 order full still allows a product already in the draft", () => {
    const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, inDraft: (id) => (id === "A" ? 3 : 0) }));
    eq([r.visibility, r.inDraft, r.maxQty], ["enabled", 3, 5]);
    eq(PK.classify(prod("A"), ctx({ lineLimitReached: true, inDraft: (id) => (id === "B" ? 3 : 0) })).reason, "order-full");
});
test("PICK-14 out of stock wins over order full", () => {
    const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, availableFor: () => 0 }));
    eq(r.reason, "out-of-stock");
});
test("PICK-15 a missing hook or context fails closed", () => {
    eq(PK.classify(prod("A"), {}).reason, "unavailable");
    eq(PK.classify(prod("A"), undefined).reason, "unavailable");
    eq(PK.classify(prod("A"), null).reason, "unavailable");
    eq(PK.classify(prod("A"), {}).visibility, "disabled");
    // the two guards that must exist: without either, the row is never addable
    const noMint = { availableFor: () => 5, unsyncedState: () => "" };
    const noSync = { availableFor: () => 5, hasPendingMint: () => false };
    eq([PK.classify(prod("A"), noMint).visibility, PK.classify(prod("A"), noMint).reason, PK.classify(prod("A"), noMint).maxQty], ["disabled", "unavailable", 0]);
    eq([PK.classify(prod("A"), noSync).visibility, PK.classify(prod("A"), noSync).reason, PK.classify(prod("A"), noSync).maxQty], ["disabled", "unavailable", 0]);
    // a mistyped hook name is the same as a missing one
    eq(PK.classify(prod("A"), ctx({ hasPendingMint: undefined, hasPendingMints: () => false })).reason, "unavailable");
    // no availableFor: out of stock
    const noStock = { hasPendingMint: () => false, unsyncedState: () => "" };
    eq(PK.classify(prod("A"), noStock).reason, "out-of-stock");
    // the two optional guards may be absent
    eq(PK.classify(prod("A"), ctx()).visibility, "enabled");
});
test("PICK-16 a throwing hook disables the row as unavailable", () => {
    const boom = () => { throw new Error("boom"); };
    const a = PK.classify(prod("A"), ctx({ availableFor: boom }));
    eq([a.visibility, a.reason, a.maxQty], ["disabled", "unavailable", 0]);
    const b = PK.classify(prod("A"), ctx({ hasPendingMint: boom }));
    eq([b.visibility, b.reason, b.maxQty], ["disabled", "unavailable", 0]);
});
test("PICK-17 junk order and draft quantities become 0", () => {
    const vals = [4, -1, "2", NaN, 2.9];
    const want = [4, 0, 0, 0, 2];
    for (let i = 0; i < vals.length; ++i) {
        const v = vals[i];
        const r = PK.classify(prod("A"), ctx({ inOrderQty: () => v, inDraft: () => v }));
        eq([r.inOrder, r.inDraft], [want[i], want[i]]);
    }
    const r2 = PK.classify(prod("A"), ctx({ inOrderQty: () => 2, inDraft: () => 3 }));
    eq([r2.inOrder, r2.inDraft], [2, 3]);
});
test("PICK-18 a product that is not a product is unavailable, never a throw", () => {
    const junk = [null, undefined, 5, [], {}, { productId: 5 }, { productId: "" }, { productId: null }, { productId: 0 }];
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
        unsyncedState: () => "",
        lineLimitReached: true,
        inOrderQty: (id) => (id === "OK" ? 1 : 0)
    };
    const s = PK.summarize(list, c, { inStockOnly: true });
    eq(s.rows.map((r) => r.reason), ["order-full", "unavailable", ""]);
    eq(s.hiddenCount, 1);
    // a truthy flag counts as on, and a falsy one as off
    eq(PK.summarize(list, c, { inStockOnly: 1 }).rows.length, 3);
    eq(PK.summarize(list, c, { inStockOnly: 0 }).rows.length, 4);
    eq(PK.summarize(list, c).rows.length, 4);
});
test("PICK-22 summarize of a non-array is empty", () => {
    const bad = [[], null, "x", undefined];
    for (let i = 0; i < bad.length; ++i) eq(PK.summarize(bad[i], ctx(), {}), { rows: [], hiddenCount: 0 });
});
test("PICK-23 summarize skips junk entries without counting them", () => {
    const s = PK.summarize([null, 5, [], { productId: 7 }, { productId: "" }, prod("A")], ctx(), {});
    eq([s.rows.length, s.hiddenCount], [1, 0]);
});
test("PICK-24 inputs are never changed", () => {
    const list = FX.freeze([prod("A"), prod("B")]);
    const c = FX.freeze({ availableFor: () => 5, hasPendingMint: () => false, unsyncedState: () => "", lineLimitReached: false });
    noThrow(() => PK.summarize(list, c, { inStockOnly: true }));
    noThrow(() => PK.classify(list[0], c));
    eq(list.length, 2);
});
test("PICK-25 seeded monkey, 400 rounds", () => {
    const rand = FX.rng(3);
    // each hook mostly answers "fine", sometimes odd, sometimes throws, so every outcome is reached
    const mk = (fine, odd) => {
        const r = rand();
        if (r < 0.7) return () => fine;
        if (r < 0.85) return () => odd[Math.floor(rand() * odd.length)];
        return () => { throw new Error("boom"); };
    };
    const seen = { enabled: 0, disabled: 0, hidden: 0 };
    for (let round = 0; round < 400; ++round) {
        const list = [];
        const n = Math.floor(rand() * 9);
        for (let i = 0; i < n; ++i) list.push(rand() < 0.1 ? null : prod("P" + i));
        const c = { availableFor: mk(5, [0, -2, NaN, "7", 3.5]), hasPendingMint: mk(false, [true, { x: 1 }]),
                    hasQueuedRestock: mk(false, [true, 1]), unsyncedState: mk("", ["parked", "pending", { x: 1 }]),
                    isDeleting: mk(false, [true]), inOrderQty: mk(0, [2, -1, "x"]), inDraft: mk(0, [3, NaN]),
                    lineLimitReached: rand() < 0.3 };
        let s = { rows: [], hiddenCount: 0 };
        let t = { rows: [], hiddenCount: 0 };
        noThrow(() => { s = PK.summarize(list, c, {}); t = PK.summarize(list, c, { inStockOnly: true }); });
        seen.hidden += s.hiddenCount;
        const valid = list.filter((p) => !!p).length;
        eq(s.rows.length + s.hiddenCount, valid);
        ok(t.rows.length <= s.rows.length, "inStockOnly added rows");
        eq(t.hiddenCount, s.hiddenCount);
        for (let k = 0; k < s.rows.length; ++k) {
            const r = s.rows[k];
            ok(r.visibility !== "hidden", "hidden row in rows");
            seen[r.visibility]++;
            if (r.visibility === "enabled") ok(r.maxQty >= 1, "enabled row without capacity");
            else eq(r.maxQty, 0);
        }
    }
    ok(seen.enabled > 20 && seen.disabled > 20 && seen.hidden > 20, "the monkey never reached every outcome: " + FX.canon(seen));
});
test("PICK-26 a hidden product stays hidden when the order is also full", () => {
    const r = PK.classify(prod("A"), ctx({ hasPendingMint: () => true, lineLimitReached: true }));
    eq([r.visibility, r.reason, r.maxQty], ["hidden", "pending-mint", 0]);
});
test("PICK-27 a hook that answers with any truthy value hides", () => {
    eq(PK.classify(prod("A"), ctx({ hasPendingMint: () => ({}) })).reason, "pending-mint");
    eq(PK.classify(prod("A"), ctx({ hasPendingMint: () => "yes" })).reason, "pending-mint");
    eq(PK.classify(prod("A"), ctx({ hasQueuedRestock: () => 1 })).reason, "queued-restock");
    eq(PK.classify(prod("A"), ctx({ isDeleting: () => "x" })).reason, "deleting");
});
test("PICK-28 a throwing optional hook disables the row too", () => {
    const boom = () => { throw new Error("boom"); };
    eq(PK.classify(prod("A"), ctx({ hasQueuedRestock: boom })).reason, "unavailable");
    eq(PK.classify(prod("A"), ctx({ isDeleting: boom })).reason, "unavailable");
    eq(PK.classify(prod("A"), ctx({ unsyncedState: boom })).reason, "unavailable");
    eq(PK.classify(prod("A"), ctx({ inOrderQty: boom })).reason, "unavailable");
    eq(PK.classify(prod("A"), ctx({ inDraft: boom })).reason, "unavailable");
});
test("PICK-29 the row keeps the very product object", () => {
    const p = prod("A");
    ok(PK.classify(p, ctx()).product === p, "a copy was returned");
    ok(PK.summarize([p], ctx(), {}).rows[0].product === p, "a copy was returned");
});
test("PICK-30 hooks are asked with the product id, availableFor with the product", () => {
    const asked = [];
    const c = {
        hasPendingMint: (id) => { asked.push(["mint", id]); return false; },
        hasQueuedRestock: (id) => { asked.push(["restock", id]); return false; },
        unsyncedState: (id) => { asked.push(["sync", id]); return ""; },
        isDeleting: (id) => { asked.push(["del", id]); return false; },
        inOrderQty: (id) => { asked.push(["order", id]); return 0; },
        inDraft: (id) => { asked.push(["draft", id]); return 0; },
        availableFor: (p) => { asked.push(["avail", p.productId]); return 1; }
    };
    PK.classify(prod("Z9"), c);
    eq(asked, [["mint", "Z9"], ["restock", "Z9"], ["sync", "Z9"], ["del", "Z9"], ["order", "Z9"], ["draft", "Z9"], ["avail", "Z9"]]);
});
test("PICK-31 a hidden product is never asked about stock", () => {
    let asked = 0;
    PK.classify(prod("A"), ctx({ hasPendingMint: () => true, availableFor: () => { asked++; return 5; } }));
    eq(asked, 0);
});
test("PICK-32 summarize keeps disabled rows and counts only hidden ones", () => {
    const list = [prod("A"), prod("B"), prod("C")];
    const c = ctx({ availableFor: (p) => (p.productId === "B" ? 0 : 5), unsyncedState: (id) => (id === "C" ? "pending" : "") });
    const s = PK.summarize(list, c, {});
    eq(s.rows.map((r) => r.visibility), ["enabled", "disabled"]);
    eq(s.hiddenCount, 1);
});
test("PICK-33 the reasons are the fixed names the UI will show", () => {
    eq(PK.REASON, { pendingMint: "pending-mint", queuedRestock: "queued-restock", unsyncedEdit: "unsynced-edit",
                    deleting: "deleting", outOfStock: "out-of-stock", orderFull: "order-full", unavailable: "unavailable" });
});
test("PICK-34 a fresh row object per call", () => {
    const a = PK.classify(prod("A"), ctx());
    const b = PK.classify(prod("A"), ctx());
    ok(a !== b, "same row twice");
    a.maxQty = 99;
    eq(b.maxQty, 5);
});
