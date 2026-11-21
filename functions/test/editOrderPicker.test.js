"use strict";
// EditOrderPicker (qml/helper/EditOrderPicker.js). Cases EOP-01..38 (EOP-24 went with the pass-through wrapper it tested, PR #196 second sweep), plan:
// docs/superpowers/plans/2026-11-12-product-picker-v2-s4-edit-order.md. The QML twin tests/tst_EditOrderPicker.qml is
// derived from these bodies (PAIR-01 in pickerDormancy.test.js); a title ending "(Node only)" is left out of the twin.
// What this proves: the three things Edit Order does differently from New Order (status-aware stock, booked tax on a
// completed order, dry run for pending and processing only) and that everything else is NewOrderPicker's, unchanged.
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const EP = load("EditOrderPicker.js");
const NP = load("NewOrderPicker.js");

// QML-PRELUDE-BEGIN
function prod(id, stock, over) {
    var p = { productId: id, name: "Name " + id, stock: stock, sellingPrice: 10, price: 4, taxable: false, taxPercent: 0 };
    for (var k in (over || {})) p[k] = over[k];
    return p;
}
// A dialog row as _lineItemArray() hands it over (quantity, not qty).
function row(id, quantity, over) {
    var r = { productId: id, name: "Name " + id, price: 10, quantity: quantity, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 };
    for (var k in (over || {})) r[k] = over[k];
    return r;
}
// A picker line as linesOf makes it.
function line(id, qty, over) {
    var l = { productId: id, name: "Name " + id, qty: qty, price: 10, discountType: "flat", discountValue: 0 };
    for (var k in (over || {})) l[k] = over[k];
    return l;
}
function orig(id, quantity, taxable, taxPercent) { return { productId: id, quantity: quantity, taxable: taxable, taxPercent: taxPercent }; }
function ctx(status, original) { return { status: status, original: original || [] }; }
function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
function lk(products, batchMap) {
    var byId = {};
    for (var i = 0; i < products.length; ++i) byId[products[i].productId] = products[i];
    return {
        productOf: function(id) { return has(byId, id) ? byId[id] : null; },
        batchesOf: function(id) { return (batchMap && has(batchMap, id)) ? batchMap[id] : []; }
    };
}
function plan(adds, bumps) { return { adds: adds || [], bumps: bumps || [] }; }
function e(id, qty) { return { productId: id, qty: qty }; }
// n products P0..P(n-1), each stock 2 with two batches of 1: a line of 2 costs 2 batch changes + 1 stock + 1 sale.
function world(n) {
    var products = [];
    var batchMap = {};
    for (var i = 0; i < n; ++i) {
        products.push(prod("P" + i, 2));
        batchMap["P" + i] = [{ batchId: "b" + i + "a", supplierId: "", qtyRemaining: 1, unitCost: 1 },
                             { batchId: "b" + i + "b", supplierId: "", qtyRemaining: 1, unitCost: 1 }];
    }
    return { lookup: lk(products, batchMap), products: products };
}
function lineRange(from, to, qty) {
    var out = [];
    for (var i = from; i < to; ++i) out.push(line("P" + i, qty));
    return out;
}
function addRange(from, to, qty) {
    var out = [];
    for (var i = from; i < to; ++i) out.push(e("P" + i, qty));
    return out;
}
// A small deterministic generator, so a failing monkey run can be replayed from its seed.
function rng(seed) {
    var s = seed % 2147483647;
    if (s <= 0) s += 2147483646;
    return function() { s = (s * 16807) % 2147483647; return (s - 1) / 2147483646; };
}
// Reads a scope index through the public Edit API (an index answers before `original` is looked at).
// What an index built by scopeOf holds for a product (its sums), read directly: EP.heldAtCompletion now trusts an index only
// for the rows it was made from (PR #210 sweep, F1), so it is not a way to read a bare index any more.
function idxQty(index, id) {
    var k = "k:" + id;
    return (index && index.sums && Object.prototype.hasOwnProperty.call(index.sums, k)) ? index.sums[k] : 0;
}
// QML-PRELUDE-END

test("EOP-01 linesOf: one picker line per row in the same order, quantity renamed qty, discount normalised, junk rows blank, not a list is empty", () => {
    const rows = [row("A", 2, { discountType: "percent", discountValue: 12 }), null, row("B", 5, { discountType: "weird", discountValue: undefined }), 7];
    const out = EP.linesOf(rows);
    eq(out.length, 4);
    eq(out[0], line("A", 2, { discountType: "percent", discountValue: 12 }));
    eq(out[1], { productId: "", name: "", qty: 0, price: 0, discountType: "flat", discountValue: 0 });
    eq(out[2], line("B", 5));
    eq(out[3].productId, "");
    for (const bad of [undefined, null, 5, "x", {}]) eq(EP.linesOf(bad), []);
});

test("EOP-02 availableFor, pending and processing: on-hand minus what the order holds, exactly New Order's formula", () => {
    for (const st of ["pending", "processing"]) {
        eq(EP.availableFor(prod("A", 10), [line("A", 3)], ctx(st)), 7);
        eq(EP.availableFor(prod("A", 10), [], ctx(st)), 10);
        eq(EP.availableFor(prod("A", 3), [line("A", 5)], ctx(st)), 0);
        eq(EP.availableFor(prod("A", 10), [line("A", 2), line("A", 3)], ctx(st)), 5);
        eq(EP.availableFor(prod("A", 3.9), [], ctx(st)), 3);
        // the original lines are ignored: this order has not taken its units out of stock yet
        eq(EP.availableFor(prod("A", 10), [line("A", 3)], ctx(st, [orig("A", 3, false, 0)])), 7);
    }
});

test("EOP-03 availableFor, completed: on-hand plus the units the order held minus what it holds now", () => {
    const c = ctx("completed", [orig("A", 3, false, 0)]);
    eq(EP.availableFor(prod("A", 4), [line("A", 3)], c), 4);      // unchanged line: available is the true on-hand
    eq(EP.availableFor(prod("A", 4), [line("A", 1)], c), 6);      // returned two: they are back on the shelf
    eq(EP.availableFor(prod("A", 4), [line("A", 5)], c), 2);      // two more taken
    eq(EP.availableFor(prod("A", 4), [], c), 7);                  // line removed: all three free for a re-add
    eq(EP.availableFor(prod("A", 0), [line("A", 3)], c), 0);
    eq(EP.availableFor(prod("A", 0), [line("A", 9)], c), 0);      // never negative
    eq(EP.availableFor(prod("A", 4.9), [line("A", 3)], c), 4);    // whole units
    eq(EP.availableFor(prod("A", 4), [line("A", 2), line("A", 1)], c), 4);   // all lines of the product count
    eq(EP.availableFor(prod("A", 5), [line("A", 1.5)], c), 6);    // 5 + 3 - 1.5 = 6.5, whole units
});

test("EOP-04 availableFor, completed: a product that was not on the order at completion has no units to give back", () => {
    const c = ctx("completed", [orig("B", 5, false, 0)]);
    eq(EP.availableFor(prod("A", 4), [line("A", 1)], c), 3);
    eq(EP.availableFor(prod("A", 4), [], c), 4);
    eq(EP.availableFor(prod("A", 4), [], ctx("completed")), 4);
    eq(EP.availableFor(prod("A", 4), [], ctx("completed", undefined)), 4);
});

test("EOP-05 availableFor: any status that is not exactly completed uses the stricter first formula (fail closed)", () => {
    const original = [orig("A", 3, false, 0)];
    for (const st of ["", "Completed", "complete", "done", undefined, null, 5, {}])
        eq(EP.availableFor(prod("A", 4), [line("A", 3)], { status: st, original: original }), 1);
    for (const c of [undefined, null, 5, "completed", []]) eq(EP.availableFor(prod("A", 4), [line("A", 3)], c), 1);
});

test("EOP-06 availableFor: ids match as strings, junk original quantities count 0, anything that is not a product has 0", () => {
    const c = ctx("completed", [orig(7, 3, false, 0), orig("J", "3", false, 0), orig("K", -2, false, 0), orig("L", NaN, false, 0), null, 5, { quantity: 4 }]);
    eq(EP.availableFor(prod("7", 4), [line(7, 3)], c), 4);
    eq(EP.availableFor(prod(7, 4), [line("7", 3)], c), 4);
    for (const id of ["J", "K", "L"]) eq(EP.availableFor(prod(id, 4), [], c), 4);
    for (const p of [undefined, null, 5, "x", {}, [], { productId: "", stock: 5 }, { stock: 5 }]) eq(EP.availableFor(p, [], c), 0);
    for (const s of [0, -3, NaN, Infinity, "5", undefined, null]) eq(EP.availableFor(prod("A", s), [], ctx("completed", [orig("A", 2, false, 0)])), 2);
});

test("EOP-07 seedOf: a completed order's product keeps its BOOKED tax, everything else takes the CURRENT tax", () => {
    const p = prod("A", 9, { taxable: true, taxPercent: 18 });
    eq(EP.seedOf(p, ctx("completed", [orig("A", 2, true, 5)])), { taxable: true, taxPercent: 5 });
    eq(EP.seedOf(p, ctx("completed", [orig("A", 2, false, 0)])), { taxable: false, taxPercent: 0 });   // booked as not taxable stays so
    eq(EP.seedOf(p, ctx("completed", [orig("B", 2, true, 5)])), { taxable: true, taxPercent: 18 });
    eq(EP.seedOf(p, ctx("completed")), { taxable: true, taxPercent: 18 });
    eq(EP.seedOf(p, ctx("pending", [orig("A", 2, true, 5)])), { taxable: true, taxPercent: 18 });
    eq(EP.seedOf(p, ctx("processing", [orig("A", 2, true, 5)])), { taxable: true, taxPercent: 18 });
    eq(EP.seedOf(prod("A", 9), ctx("pending")), { taxable: false, taxPercent: 0 });
});

test("EOP-08 seedOf: a rate that is not a finite number >= 0 is 0, a missing product is untaxed, nothing throws", () => {
    for (const bad of [-1, NaN, Infinity, "18", undefined, null, {}]) {
        eq(EP.seedOf(prod("A", 9, { taxable: true, taxPercent: bad }), ctx("pending")), { taxable: true, taxPercent: 0 });
        eq(EP.seedOf(prod("A", 9), ctx("completed", [orig("A", 1, true, bad)])), { taxable: true, taxPercent: 0 });
    }
    for (const p of [undefined, null, 5, "x"]) eq(EP.seedOf(p, ctx("pending")), { taxable: false, taxPercent: 0 });
    noThrow(() => EP.seedOf(prod("A", 1), undefined));
});

test("EOP-09 applyPlan, pending: a new product is appended with name, selling price, flat discount 0 and the CURRENT tax; no row is set", () => {
    const lookup = lk([prod("A", 9, { taxable: true, taxPercent: 12 }), prod("B", 9, { sellingPrice: undefined, price: 6 })]);
    const r = EP.applyPlan([line("X", 1)], plan([e("A", 3), e("B", 2)]), ctx("pending"), lookup);
    eq(r.skipped, []);
    eq(r.sets, []);
    eq(r.appends, [
        { productId: "A", name: "Name A", price: 10, quantity: 3, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 12 },
        { productId: "B", name: "Name B", price: 6, quantity: 2, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }]);
});

test("EOP-10 applyPlan: a bump sets the line's NEW total by its row index and appends nothing; price, discount and tax are not part of it", () => {
    const lookup = lk([prod("A", 9), prod("B", 9)]);
    const lines = [line("X", 1), line("A", 2, { price: 7.5, discountType: "percent", discountValue: 10 })];
    const r = EP.applyPlan(lines, plan([], [e("A", 3)]), ctx("pending"), lookup);
    eq(r.skipped, []);
    eq(r.appends, []);
    eq(r.sets, [{ index: 1, productId: "A", quantity: 5 }]);
    eq(lines[1].price, 7.5);
});

test("EOP-11 applyPlan, completed: a bump is capped by on-hand plus the original units, and the cut is reported", () => {
    const c = ctx("completed", [orig("A", 3, true, 5)]);
    const lookup = lk([prod("A", 2)]);
    const r = EP.applyPlan([line("A", 3)], plan([], [e("A", 9)]), c, lookup);
    eq(r.sets, [{ index: 0, productId: "A", quantity: 5 }]);
    eq(r.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 2, asked: 9 }]);
});

test("EOP-12 applyPlan, completed: a line removed in this edit and picked again returns at its BOOKED tax, capped by on-hand plus its original units", () => {
    const c = ctx("completed", [orig("A", 3, true, 5)]);
    const lookup = lk([prod("A", 1, { taxable: true, taxPercent: 18 })]);
    const r = EP.applyPlan([], plan([e("A", 4)]), c, lookup);
    eq(r.sets, []);
    eq(r.appends, [{ productId: "A", name: "Name A", price: 10, quantity: 4, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 5 }]);
    eq(r.skipped, []);
    const over = EP.applyPlan([], plan([e("A", 9)]), c, lookup);
    eq(over.appends[0].quantity, 4);
    eq(over.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 4, asked: 9 }]);
});

test("EOP-13 applyPlan, completed: a product that was never on the order is added at the CURRENT tax and may use only what is on hand", () => {
    const c = ctx("completed", [orig("B", 3, true, 5)]);
    const lookup = lk([prod("A", 2, { taxable: true, taxPercent: 18 })]);
    const r = EP.applyPlan([line("B", 3)], plan([e("A", 5)]), c, lookup);
    eq(r.appends, [{ productId: "A", name: "Name A", price: 10, quantity: 2, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 18 }]);
    eq(r.skipped, [{ productId: "A", name: "Name A", reason: "reduced", added: 2, asked: 5 }]);
});

test("EOP-14 applyPlan: a stale plan never makes a duplicate line (an add for a product now on the order is a bump, a bump for one that is not is an add)", () => {
    const lookup = lk([prod("A", 9), prod("B", 9)]);
    const r = EP.applyPlan([line("A", 2)], plan([e("A", 1)], [e("B", 2)]), ctx("pending"), lookup);
    eq(r.sets, [{ index: 0, productId: "A", quantity: 3 }]);
    eq(r.appends.length, 1);
    eq(r.appends[0].productId, "B");
    eq(r.appends[0].quantity, 2);
});

test("EOP-15 applyPlan: two entries for one product together never exceed the stock, in either status", () => {
    const lookup = lk([prod("A", 5)]);
    const p = plan([e("A", 4)], [e("A", 4)]);
    const pending = EP.applyPlan([line("A", 1)], p, ctx("pending"), lookup);
    eq(pending.sets, [{ index: 0, productId: "A", quantity: 5 }]);
    const done = EP.applyPlan([line("A", 1)], p, ctx("completed", [orig("A", 1, false, 0)]), lookup);
    eq(done.sets, [{ index: 0, productId: "A", quantity: 6 }]);
});

test("EOP-16 applyPlan: sold out, no price (new line only), gone and throwing lookups are refused and reported; a line with no price can still be bumped", () => {
    const lookup = lk([prod("S", 0), prod("N", 9, { sellingPrice: undefined, price: undefined }), prod("A", 9, { sellingPrice: undefined, price: undefined })]);
    const r = EP.applyPlan([line("A", 2)], plan([e("S", 1), e("N", 1), e("Z", 1)], [e("A", 1)]), ctx("pending"), lookup);
    eq(r.appends, []);
    eq(r.sets, [{ index: 0, productId: "A", quantity: 3 }]);
    eq(r.skipped.map(function(s) { return s.productId + ":" + s.reason; }), ["S:out-of-stock", "N:no-price", "Z:gone"]);
    const boom = { productOf: function() { throw new Error("x"); }, batchesOf: function() { return []; } };
    const g = EP.applyPlan([], plan([e("A", 1)]), ctx("pending"), boom);
    eq(g.appends, []);
    eq(g.skipped.map(function(s) { return s.reason; }), ["gone"]);
    // a catalog that answers once and then loses the product (it left between the stock read and the tax read): refused, never added untaxed
    let calls = 0;
    const flaky = { productOf: function(id) { calls++; return calls <= 1 ? prod("A", 9, { taxable: true, taxPercent: 18 }) : null; }, batchesOf: function() { return []; } };
    const f = EP.applyPlan([], plan([e("A", 1)]), ctx("pending"), flaky);
    eq(f.appends, []);
    eq(f.skipped.map(function(s) { return s.reason; }), ["gone"]);
});

test("EOP-17 applyPlan: invalid entries (blank id, fractional, zero, negative, text, NaN) are refused as invalid, never added", () => {
    const lookup = lk([prod("A", 9)]);
    const bad = [e("", 1), e("A", 1.5), e("A", 0), e("A", -2), e("A", "3"), e("A", NaN), { productId: 5, qty: 1 }, null, 7, undefined];
    const r = EP.applyPlan([], plan(bad), ctx("pending"), lookup);
    eq(r.appends, []);
    eq(r.sets, []);
    eq(r.skipped.length, bad.length);
    for (const s of r.skipped) eq(s.reason, "invalid");
});

test("EOP-18 applyPlan: the lines it was given are never changed", () => {
    const lookup = lk([prod("A", 9), prod("B", 9)]);
    const lines = [line("A", 2, { price: 3 })];
    const before = JSON.stringify(lines);
    EP.applyPlan(lines, plan([e("B", 2)], [e("A", 1)]), ctx("pending"), lookup);
    eq(JSON.stringify(lines), before);
});

test("EOP-19 applyPlan: a row index is the index of its row, even next to a junk row or a numeric id", () => {
    const rows = [row("X", 1), null, row(7, 2)];
    const lines = EP.linesOf(rows);
    const lookup = lk([prod("7", 9)]);
    const r = EP.applyPlan(lines, plan([], [e("7", 3)]), ctx("pending"), lookup);
    eq(r.sets, [{ index: 2, productId: 7, quantity: 5 }]);
});

test("EOP-20 applyPlan: nothing it is given can make it throw; it answers empty", () => {
    noThrow(() => {
        for (const lines of [undefined, null, 5, "x", {}]) for (const pl of [undefined, null, 5, {}, { adds: 5, bumps: "x" }]) for (const c of [undefined, null, 5, {}])
            for (const lookup of [undefined, null, 5, {}, { productOf: 5 }]) {
                const r = EP.applyPlan(lines, pl, c, lookup);
                if (r.sets.length !== 0 || r.appends.length !== 0) throw new Error("added something from junk");
            }
    });
});

test("EOP-21 commitCheck: a completed order is always ok (its edit has no operation cap), even when a pending one of that size is refused", () => {
    const w = world(60);
    const big = addRange(0, 60, 2);
    eq(EP.commitCheck([], plan(big), ctx("completed"), w.lookup), { ok: true, text: "" });
    eq(EP.commitCheck([], plan(big), ctx("pending"), w.lookup).ok, false);
    eq(EP.commitCheck([], plan(big), ctx("processing"), w.lookup).ok, false);
});

test("EOP-22 commitCheck, pending and processing: the dry run judges the size only; a small order passes, the line that tips it over is refused with words", () => {
    const w = world(60);
    for (const st of ["pending", "processing"]) {
        eq(EP.commitCheck(lineRange(0, 48, 2), plan(addRange(48, 49, 2)), ctx(st), w.lookup), { ok: true, text: "" });
        const r = EP.commitCheck(lineRange(0, 49, 2), plan(addRange(49, 50, 2)), ctx(st), w.lookup);
        eq(r.ok, false);
        ok(r.text.length > 0);
    }
});

test("EOP-23 commitCheck fails closed for a pending order when it cannot read the catalog or batches; an unknown status is checked too", () => {
    const w = world(3);
    const noBatches = { productOf: w.lookup.productOf };
    eq(EP.commitCheck([], plan([e("P0", 1)]), ctx("pending"), noBatches).ok, false);
    eq(EP.commitCheck([], plan([e("P0", 1)]), ctx("pending"), undefined).ok, false);
    eq(EP.commitCheck([], plan([e("P0", 1)]), ctx("pending"), { productOf: function() { throw new Error("x"); }, batchesOf: function() { return []; } }).ok, true);
    eq(EP.commitCheck(undefined, plan([e("P0", 1)]), ctx("pending"), w.lookup).ok, true);
    eq(EP.commitCheck([], plan(addRange(0, 3, 1)), undefined, w.lookup).ok, true);
    eq(EP.commitCheck([], plan(addRange(0, 60, 2)), { status: "weird" }, world(60).lookup).ok, false);
});

test("EOP-25 monkey, seeded: over random orders and plans no product ever ends above its limit, no line is removed or duplicated, no price or tax of an existing row is touched, in both statuses", () => {
    for (let seed = 1; seed <= 150; ++seed) {
        const rand = rng(seed);
        const n = 1 + Math.floor(rand() * 6);
        const products = [];
        for (let i = 0; i < n; ++i) products.push(prod("P" + i, Math.floor(rand() * 9), { taxable: rand() < 0.5, taxPercent: Math.floor(rand() * 28) }));
        const completed = rand() < 0.5;
        const original = [];
        const rows = [];
        for (let i = 0; i < n; ++i) {
            if (rand() < 0.5) { const q = 1 + Math.floor(rand() * 4); original.push(orig("P" + i, q, rand() < 0.5, Math.floor(rand() * 28))); if (rand() < 0.7) rows.push(row("P" + i, Math.max(1, q + Math.floor(rand() * 3) - 1), { price: 3 + i })); }
            else if (!completed && rand() < 0.4) rows.push(row("P" + i, 1 + Math.floor(rand() * 3), { price: 3 + i }));
        }
        const c = ctx(completed ? "completed" : "pending", original);
        const lines = EP.linesOf(rows);
        const adds = [], bumps = [];
        const m = Math.floor(rand() * 6);
        for (let k = 0; k < m; ++k) (rand() < 0.5 ? adds : bumps).push(e("P" + Math.floor(rand() * (n + 1)), Math.floor(rand() * 7) - 1 + (rand() < 0.1 ? 0.5 : 0)));
        const r = EP.applyPlan(lines, plan(adds, bumps), c, lk(products));
        const total = {};
        const next = lines.map(function(l) { return { productId: l.productId, qty: l.qty }; });
        for (const s of r.sets) { ok(s.index >= 0 && s.index < lines.length, "set index in range, seed " + seed); next[s.index].qty = s.quantity; ok(s.quantity > lines[s.index].qty, "a set only adds, seed " + seed); }
        for (const a of r.appends) next.push({ productId: a.productId, qty: a.quantity });
        const seen = {};
        for (const l of next) { total[l.productId] = (total[l.productId] || 0) + l.qty; }
        for (const a of r.appends) { ok(!seen[a.productId], "a product is appended once, seed " + seed); seen[a.productId] = true; ok(lines.every(function(l) { return String(l.productId) !== a.productId; }), "no duplicate of an existing line, seed " + seed); ok(a.quantity > 0 && a.discountValue === 0 && a.discountType === "flat", "shape, seed " + seed); }
        for (const p of products) {
            const o = completed ? original.filter(function(x) { return x.productId === p.productId; })[0] : null;
            const heldBefore = lines.reduce(function(s2, l) { return l.productId === p.productId ? s2 + l.qty : s2; }, 0);
            const limit = Math.max(heldBefore, p.stock + (o ? o.quantity : 0));
            ok((total[p.productId] || 0) <= limit, "limit of " + p.productId + ", seed " + seed + ": " + (total[p.productId] || 0) + " > " + limit);
        }
        eq(next.length >= lines.length, true);
    }
});

test("EOP-26 parity with New Order: a pending order with no tax gets the same quantities and the same skipped list from both helpers, 200 seeded plans (Node only)", () => {
    for (let seed = 1; seed <= 200; ++seed) {
        const rand = rng(seed * 7919);
        const n = 1 + Math.floor(rand() * 5);
        const products = [];
        for (let i = 0; i < n; ++i) products.push(prod("P" + i, Math.floor(rand() * 8)));
        const rows = [];
        for (let i = 0; i < n; ++i) if (rand() < 0.4) rows.push(row("P" + i, 1 + Math.floor(rand() * 3)));
        const adds = [], bumps = [];
        for (let k = 0; k < Math.floor(rand() * 5); ++k) (rand() < 0.5 ? adds : bumps).push(e("P" + Math.floor(rand() * (n + 1)), Math.floor(rand() * 6)));
        const lines = EP.linesOf(rows);
        const a = EP.applyPlan(lines, plan(adds, bumps), ctx("pending"), lk(products));
        const b = NP.applyPlan(lines, plan(adds, bumps), lk(products));
        eq(a.skipped, b.skipped);
        const viaEdit = lines.map(function(l) { return { productId: l.productId, qty: l.qty }; });
        for (const s of a.sets) viaEdit[s.index].qty = s.quantity;
        for (const x of a.appends) viaEdit.push({ productId: x.productId, qty: x.quantity });
        eq(viaEdit, b.lines.map(function(l) { return { productId: l.productId, qty: l.qty }; }));
    }
});

test("EOP-27 originalOf: ids match as strings in both directions, the first match wins, blank ids and junk entries never match, not a list is null", () => {
    const list = [null, 5, orig("", 9, true, 5), orig(7, 2, true, 18), orig("A", 3, false, 0), orig("A", 8, true, 5)];
    eq(EP.originalOf(list, "7").quantity, 2);    // numeric id on the order, string id asked
    eq(EP.originalOf(list, 7).quantity, 2);
    eq(EP.originalOf([orig("7", 4, false, 0)], 7).quantity, 4);    // string id on the order, numeric id asked
    eq(EP.originalOf(list, "A").quantity, 3);    // first match
    for (const blank of ["", undefined, null, "Z"]) eq(EP.originalOf(list, blank), null);
    for (const bad of [undefined, null, 5, "x", {}]) eq(EP.originalOf(bad, "A"), null);
    // the helper's own readers use it: a numeric id on the order is booked tax and units for a string id
    const c = ctx("completed", [orig(7, 2, true, 18)]);
    eq(EP.seedOf(prod("7", 5, { taxable: false, taxPercent: 0 }), c), { taxable: true, taxPercent: 18 });
    eq(EP.availableFor(prod("7", 1), [], c), 3);
});

test("EOP-28 applyPlan: a bump keeps a fractional quantity the line already holds, a line with no usable quantity counts as 0, the limit still holds", () => {
    const lookup = lk([prod("A", 10)]);
    for (const status of ["pending", "completed"]) {
        const c = ctx(status, status === "completed" ? [orig("A", 2.5, false, 0)] : []);
        const r = EP.applyPlan([line("A", 2.5)], plan([], [e("A", 1)]), c, lookup);
        eq(r.sets, [{ index: 0, productId: "A", quantity: 3.5 }]);
        eq(r.skipped, []);
    }
    for (const bad of [0, -3, NaN, undefined, "2"]) {
        const r = EP.applyPlan([line("A", bad)], plan([], [e("A", 2)]), ctx("pending"), lookup);
        eq(r.sets, [{ index: 0, productId: "A", quantity: 2 }]);
    }
    const r2 = EP.applyPlan([line("A", 2.5)], plan([], [e("A", 5)]), ctx("pending"), lk([prod("A", 5)]));
    eq(r2.sets, [{ index: 0, productId: "A", quantity: 4.5 }]);
    eq(r2.skipped.map(function(s) { return s.reason; }), ["reduced"]);
});

test("EOP-29 applyPlan: a junk row inside the lines keeps its index and never makes it throw, and a new product is still appended after it", () => {
    const lines = [null, line("A", 1), 7, "x", line("B", 2)];
    let r = null;
    noThrow(() => { r = EP.applyPlan(lines, plan([e("C", 1)], [e("B", 1), e("A", 2)]), ctx("pending"), lk([prod("A", 9), prod("B", 9)])); });
    eq(r.sets, [{ index: 1, productId: "A", quantity: 3 }, { index: 4, productId: "B", quantity: 3 }]);
    eq(r.appends.length, 0);
    eq(r.skipped.map(function(s) { return s.reason; }), ["gone"]);
    const r2 = EP.applyPlan(lines, plan([e("N", 2)], []), ctx("pending"), lk([prod("A", 9), prod("B", 9), prod("N", 9)]));
    eq(r2.sets, []);
    eq(r2.appends.map(function(a) { return [a.productId, a.quantity]; }), [["N", 2]]);
    eq(lines.length, 5);
    eq(lines[0], null);
});

test("EOP-30 monkey, seeded, fractional quantities and junk rows: a set only adds and points at its own row, a product never ends above its whole-unit limit, in both statuses", () => {
    for (let seed = 1; seed <= 150; ++seed) {
        const rand = rng(seed + 1000);
        const n = 1 + Math.floor(rand() * 5);
        const products = [];
        for (let i = 0; i < n; ++i) products.push(prod("P" + i, Math.floor(rand() * 9)));
        const completed = rand() < 0.5;
        const original = [];
        const lines = [];
        for (let i = 0; i < n; ++i) {
            if (rand() < 0.3) lines.push(rand() < 0.5 ? null : 7);
            if (rand() < 0.7) {
                const q = 0.5 * (1 + Math.floor(rand() * 8));
                lines.push(line("P" + i, q));
                if (completed && rand() < 0.7) original.push(orig("P" + i, q, false, 0));
            }
        }
        const adds = [], bumps = [];
        for (let k = 0; k < Math.floor(rand() * 6); ++k) (rand() < 0.5 ? adds : bumps).push(e("P" + Math.floor(rand() * (n + 1)), 1 + Math.floor(rand() * 4)));
        const r = EP.applyPlan(lines, plan(adds, bumps), ctx(completed ? "completed" : "pending", original), lk(products));
        const next = lines.map(function(l) { return (l && typeof l === "object") ? { productId: l.productId, qty: l.qty } : null; });
        for (const s of r.sets) {
            ok(s.index >= 0 && s.index < next.length && next[s.index] !== null && next[s.index].productId === s.productId, "a set points at its own row, seed " + seed);
            ok(s.quantity > next[s.index].qty, "a set only adds, seed " + seed);
            next[s.index].qty = s.quantity;
        }
        for (const a of r.appends) next.push({ productId: a.productId, qty: a.quantity });
        for (const p of products) {
            let held = 0, after = 0;
            for (let i = 0; i < lines.length; ++i) if (lines[i] && lines[i].productId === p.productId && lines[i].qty > 0) held += lines[i].qty;
            for (const l of next) if (l && l.productId === p.productId && l.qty > 0) after += l.qty;
            let heldAtDone = 0;   // what a completed order already holds out of stock, exactly as booked (sweep F1: it was floored)
            if (completed) for (const x of original) if (x.productId === p.productId) heldAtDone += x.quantity;
            const limit = Math.max(held, p.stock + heldAtDone);
            ok(after <= limit, "limit of " + p.productId + ", seed " + seed + ": " + after + " > " + limit);
        }
    }
});

test("EOP-31 applyPlan: a row whose quantity is NaN or not a number is never in sets (NaN !== NaN made it look changed), the touched rows still are, nothing is written into it", () => {
    const lines = [line("A", NaN), line("B", 2), line("C", undefined), line("D", "2"), line("E", -1), line("F", Infinity)];
    const prods = [prod("A", 9), prod("B", 9), prod("C", 9), prod("D", 9), prod("E", 9), prod("F", 9)];
    const before = JSON.stringify(lines);
    const r = EP.applyPlan(lines, plan([], [e("B", 1)]), ctx("pending"), lk(prods));
    eq(r.sets, [{ index: 1, productId: "B", quantity: 3 }]);
    eq(r.appends.length, 0);
    eq(JSON.stringify(lines), before);
    // a bump ON the NaN row counts the row as holding 0: it gets a real, finite quantity
    const r2 = EP.applyPlan(lines, plan([], [e("A", 2)]), ctx("pending"), lk(prods));
    eq(r2.sets, [{ index: 0, productId: "A", quantity: 2 }]);
    // an untouched plan changes nothing at all, however bad the rows are
    eq(EP.applyPlan(lines, plan([], []), ctx("completed", [orig("A", 1, false, 0)]), lk(prods)).sets, []);
});

// Picker v2, S5b: ONE stock rule for the sheet (availableFor), the + stepper (stepUp) and the save check (stockShortfalls).
test("EOP-32 ceilingFor: whole units on hand; a completed order adds the units it held at completion; a product that left the catalog has no stock; a blank id or an unknown status never gets more", () => {
    eq(EP.ceilingFor("A", prod("A", 5), ctx("pending")), 5);
    eq(EP.ceilingFor("A", prod("A", 5), ctx("processing", [orig("A", 3, false, 0)])), 5);
    eq(EP.ceilingFor("A", prod("A", 5), ctx("completed", [orig("A", 3, false, 0)])), 8);
    eq(EP.ceilingFor("A", prod("A", 5), ctx("completed")), 5);
    eq(EP.ceilingFor("A", prod("A", 5), ctx("completed", [orig("B", 3, false, 0)])), 5);
    eq(EP.ceilingFor("A", prod("A", 2.5), ctx("pending")), 2);
    eq(EP.ceilingFor("A", prod("A", 2.5), ctx("completed", [orig("A", 2.5, false, 0)])), 4.5);   // the booked 2.5 counts 2.5, not 2 (sweep F1; was pinned at 4)
    eq(EP.ceilingFor("A", prod("A", -2), ctx("completed", [orig("A", 3, false, 0)])), 3);
    // gone: no stock, a completed order can still go back to what it held
    eq(EP.ceilingFor("A", null, ctx("pending")), 0);
    eq(EP.ceilingFor("A", null, ctx("completed", [orig("A", 3, false, 0)])), 3);
    eq(EP.ceilingFor("A", undefined, ctx("completed")), 0);
    // the id decides the original line, and matches as a string
    eq(EP.ceilingFor(7, prod(7, 1), ctx("completed", [orig("7", 2, false, 0)])), 3);
    for (const blank of ["", undefined, null]) eq(EP.ceilingFor(blank, prod("A", 5), ctx("completed", [orig("A", 3, false, 0)])), 0);
    // an unknown or missing status takes the stricter first formula
    for (const st of ["", "cancelled", undefined, 7]) eq(EP.ceilingFor("A", prod("A", 5), ctx(st, [orig("A", 3, false, 0)])), 5);
    eq(EP.ceilingFor("A", prod("A", 5), undefined), 5);
});

test("EOP-33 availableFor is the ceiling minus the cart in both statuses, for every stock, original and cart shape (whole quantities)", () => {
    const stocks = [0, 1, 2, 2.5, 5, -1, NaN];
    const origs = [[], [orig("A", 2, false, 0)], [orig("A", 3, false, 0)], [orig("A", 2.5, false, 0)]];
    const carts = [[], [line("A", 1)], [line("A", 3)], [line("A", 2), line("A", 2)], [line("B", 4)], [line("A", 9)]];
    const heldOf = (cart) => { let n = 0; for (const l of cart) if (l.productId === "A" && l.qty > 0) n += l.qty; return n; };
    for (const status of ["pending", "processing", "completed"]) {
        for (const st of stocks) {
            for (const o of origs) {
                for (const cart of carts) {
                    const p = prod("A", st);
                    const c = ctx(status, o);
                    eq(EP.availableFor(p, cart, c), Math.max(0, Math.floor(EP.ceilingFor("A", p, c) - heldOf(cart))));   // whole units, also when the ceiling is fractional (sweep F1)
                }
            }
        }
    }
    eq(EP.availableFor(prod("", 5), [], ctx("completed")), 0);
    eq(EP.availableFor(null, [], ctx("pending")), 0);
});

test("EOP-34 stepUp: one more up to the ceiling; never above it, never below what the row holds; a fractional stock allows whole units only", () => {
    const up = (qty, p, c, lines) => EP.stepUp(qty, "A", p, c, lines || [line("A", qty)]);
    eq(up(2, prod("A", 5), ctx("pending")), 3);
    eq(up(5, prod("A", 5), ctx("pending")), 5);
    eq(up(6, prod("A", 5), ctx("pending")), 6);          // over the ceiling already: + never pulls it down
    eq(up(0, prod("A", 5), ctx("pending")), 1);
    eq(up(1, prod("A", 2.5), ctx("pending")), 2);
    eq(up(2, prod("A", 2.5), ctx("pending")), 2);        // the old stepper offered 3 here
    // completed: the order's own units are already out of stock
    const done = ctx("completed", [orig("A", 3, true, 5)]);
    eq(up(3, prod("A", 1), done), 4);
    eq(up(4, prod("A", 1), done), 4);
    eq(up(1, prod("A", 0), done), 2);
    eq(up(3, prod("A", 0), done), 3);
    // a product that left the catalog: a pending row can not go up, a completed row can go back to what it held
    eq(up(2, null, ctx("pending")), 2);
    eq(up(1, null, done), 2);
    eq(up(3, null, done), 3);
    // a blank id never goes up
    eq(EP.stepUp(2, "", prod("A", 5), ctx("pending"), [line("", 2)]), 2);
    // two lines of one product (a legacy order): the ceiling is shared
    const two = [line("A", 2), line("A", 2)];
    eq(up(2, prod("A", 5), ctx("pending"), two), 3);
    eq(up(2, prod("A", 4), ctx("pending"), two), 2);
    eq(up(2, prod("A", 4), ctx("pending"), [line("A", 2), line("B", 4)]), 3);
    // a row with no usable quantity counts as holding nothing: + gives it one more, within the ceiling
    eq(up(0, prod("A", 0), ctx("pending")), 0);
    eq(up(-3, prod("A", 0), ctx("pending")), -2);
    eq(up(-3, prod("A", 5), ctx("pending"), [line("A", -3), line("A", 4)]), -2);
    // junk quantities come back as they are
    ok(isNaN(up(NaN, prod("A", 5), ctx("pending"), [])));
    eq(up(undefined, prod("A", 5), ctx("pending"), []), undefined);
    eq(up("2", prod("A", 5), ctx("pending"), []), "2");
    eq(up(Infinity, prod("A", 5), ctx("pending"), []), Infinity);
});

test("EOP-35 the stepper and the product sheet agree: a + tap raises a single row exactly when availableFor offers one more unit, in both statuses", () => {
    for (const status of ["pending", "completed"]) {
        for (const st of [0, 1, 2, 2.5, 3, 5, -1]) {
            for (const heldAtCompletion of [0, 2, 3]) {
                for (const qty of [0, 1, 2, 3, 4, 6]) {
                    const p = prod("A", st);
                    const c = ctx(status, heldAtCompletion ? [orig("A", heldAtCompletion, false, 0)] : []);
                    const lines = [line("A", qty)];
                    const after = EP.stepUp(qty, "A", p, c, lines);
                    eq(after > qty, EP.availableFor(p, lines, c) >= 1);
                    ok(after === qty || after === qty + 1);
                }
            }
        }
    }
});

test("EOP-36 stockShortfalls: a product holding more than its ceiling is listed once with the whole units on hand and how many too many; equal is fine; a return never trips it", () => {
    const find = (lines, c, ps) => EP.stockShortfalls(lines, c, (id) => { for (const p of ps) if (String(p.productId) === String(id)) return p; return null; });
    eq(find([line("A", 3)], ctx("pending"), [prod("A", 2)]), [{ productId: "A", name: "Name A", stock: 2, need: 1 }]);
    eq(find([line("A", 2)], ctx("pending"), [prod("A", 2)]), []);
    eq(find([line("A", 3)], ctx("pending"), [prod("A", 2.5)]), [{ productId: "A", name: "Name A", stock: 2, need: 1 }]);
    eq(find([line("A", 1)], ctx("pending"), [prod("A", -2)]), [{ productId: "A", name: "Name A", stock: 0, need: 1 }]);
    // completed: the units it held are already out; on-hand low or negative never blocks an unchanged or smaller line
    const done = ctx("completed", [orig("A", 3, false, 0)]);
    eq(find([line("A", 3)], done, [prod("A", 0)]), []);
    eq(find([line("A", 3)], done, [prod("A", -2)]), []);
    eq(find([line("A", 1)], done, [prod("A", 0)]), []);
    eq(find([line("A", 5)], done, [prod("A", 1)]), [{ productId: "A", name: "Name A", stock: 1, need: 1 }]);
    eq(find([line("A", 5)], done, [prod("A", 2)]), []);
    // the check is per product, not per line: two lines of one product share the stock
    eq(find([line("A", 2), line("A", 2)], ctx("pending"), [prod("A", 3)]), [{ productId: "A", name: "Name A", stock: 3, need: 1 }]);
    eq(find([line("A", 2), line("B", 2)], ctx("pending"), [prod("A", 3), prod("B", 3)]), []);
    // several products: order of first appearance
    eq(find([line("B", 9), line("A", 9)], ctx("pending"), [prod("A", 1), prod("B", 2)]).map((s) => s.productId), ["B", "A"]);
    // ids match as strings, in both directions
    eq(find([line(7, 3)], ctx("completed", [orig("7", 1, false, 0)]), [prod("7", 1)]), [{ productId: "7", name: "Name 7", stock: 1, need: 1 }]);
    // lines that hold nothing usable count nothing
    eq(find([line("A", 0), line("A", -4), line("A", NaN)], ctx("pending"), [prod("A", 0)]), []);
});

test("EOP-37 stockShortfalls: a product that left the catalog, a throwing reader, a blank id, a junk row and a lines value that is not a list are skipped, never thrown on", () => {
    const gone = () => null;
    eq(EP.stockShortfalls([line("A", 9)], ctx("pending"), gone), []);
    eq(EP.stockShortfalls([line("A", 9)], ctx("pending"), () => { throw new Error("x"); }), []);
    eq(EP.stockShortfalls([line("A", 9)], ctx("pending"), () => 5), []);
    eq(EP.stockShortfalls([line("A", 9)], ctx("pending"), undefined), []);
    eq(EP.stockShortfalls([line("", 9), line(undefined, 9), line(null, 9)], ctx("pending"), () => prod("A", 0)), []);
    // and the reader is not even asked about a blank id
    let asked = 0;
    EP.stockShortfalls([line("", 9), line(undefined, 9), line(null, 9)], ctx("pending"), () => { asked++; return prod("A", 0); });
    eq(asked, 0);
    eq(EP.stockShortfalls([null, undefined, 5, "A", [], line("A", 9)], ctx("pending"), () => prod("A", 1)).length, 1);
    for (const notList of [undefined, null, 5, "A", {}]) eq(EP.stockShortfalls(notList, ctx("pending"), () => prod("A", 0)), []);
    // a product named like an Object property is an ordinary id
    eq(EP.stockShortfalls([line("constructor", 3), line("__proto__", 3)], ctx("pending"), (id) => prod(id, 1)).map((s) => s.productId), ["constructor", "__proto__"]);
});

test("EOP-38 shortfallText keeps the wording the dialog has always used", () => {
    eq(EP.shortfallText({ productId: "A", name: "Widget", stock: 2, need: 1 }), "Widget: only 2 in stock, need 1 more");
    eq(EP.shortfallText({ productId: "A", name: "Widget", stock: 0, need: 12 }), "Widget: only 0 in stock, need 12 more");
    eq(EP.shortfallText({ productId: "A", name: "Widget", stock: 2, need: 1.5 }), "Widget: only 2 in stock, need 1.5 more");
});

test("EOP-39 monkey, seeded: over random orders the save check lists a product exactly when its lines hold more than its ceiling, each product once, and the stepper never raises a row past the ceiling (Node only)", () => {
    let seed = 39;
    const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
    const ids = ["A", "B", "C", "D"];
    for (let i = 0; i < 500; i++) {
        const products = ids.map((id) => prod(id, [Math.floor(rnd() * 8), rnd() * 8, -1, 0][Math.floor(rnd() * 4)]));
        const status = ["pending", "processing", "completed"][Math.floor(rnd() * 3)];
        const originals = ids.filter(() => rnd() < 0.5).map((id) => orig(id, Math.floor(rnd() * 5), false, 0));
        const c = ctx(status, originals);
        const lines = [];
        for (let k = Math.floor(rnd() * 6); k > 0; k--) lines.push(line(ids[Math.floor(rnd() * 4)], Math.floor(rnd() * 6)));
        const byId = (id) => products.filter((p) => p.productId === id)[0] || null;
        const got = EP.stockShortfalls(lines, c, byId);
        eq(new Set(got.map((s) => s.productId)).size, got.length);
        for (const id of ids) {
            const held = NP.cartQty(lines, id);
            const cap = EP.ceilingFor(id, byId(id), c);
            const entry = got.filter((s) => s.productId === id)[0];
            if (held > cap) { ok(entry && entry.need === held - cap, "missing or wrong entry for " + id); }
            else ok(!entry, "entry for " + id + " but held " + held + " <= " + cap);
        }
        for (let r = 0; r < lines.length; r++) {
            const after = EP.stepUp(lines[r].qty, lines[r].productId, byId(lines[r].productId), c, lines);
            ok(after >= lines[r].qty && after - lines[r].qty <= 1, "step out of range");
            if (after > lines[r].qty) ok(NP.cartQty(lines, lines[r].productId) + 1 <= EP.ceilingFor(lines[r].productId, byId(lines[r].productId), c), "stepped past the ceiling");
        }
    }
});

test("EOP-40 ceilingFor on a completed order adds ALL the lines the order held for the product, exactly as booked (two lines add up, a line of 2.5 is 2.5) on top of the whole units on hand", () => {
    eq(EP.ceilingFor("A", prod("A", 0), ctx("completed", [orig("A", 3, false, 0), orig("A", 2, false, 0)])), 5);
    eq(EP.ceilingFor("A", prod("A", 4), ctx("completed", [orig("A", 3, false, 0), orig("B", 9, false, 0), orig("A", 2, false, 0)])), 9);
    eq(EP.ceilingFor("A", prod("A", 0), ctx("completed", [orig("A", 2.5, false, 0)])), 2.5);
    eq(EP.ceilingFor("A", prod("A", 2.5), ctx("completed", [orig("A", 2.5, false, 0)])), 4.5);
    eq(EP.ceilingFor("A", null, ctx("completed", [orig("A", 3, false, 0), orig("A", 2, false, 0)])), 5);
    eq(EP.ceilingFor(7, prod(7, 1), ctx("completed", [orig("7", 2, false, 0), orig(7, 1, false, 0)])), 4);
    // a held quantity that is not a positive number holds nothing
    eq(EP.ceilingFor("A", prod("A", 1), ctx("completed", [orig("A", -2, false, 0), orig("A", NaN, false, 0), orig("A", "3", false, 0), orig("A", Infinity, false, 0), orig("A", 2, false, 0)])), 3);
    eq(EP.ceilingFor("A", prod("A", 1), ctx("completed", [null, 5, orig("", 4, false, 0), orig(undefined, 4, false, 0)])), 1);
    // pending and processing hold nothing from stock: the originals are not read
    eq(EP.ceilingFor("A", prod("A", 1), ctx("pending", [orig("A", 3, false, 0), orig("A", 2, false, 0)])), 1);
    eq(EP.ceilingFor("A", prod("A", 1), ctx("processing", [orig("A", 3, false, 0), orig("A", 2, false, 0)])), 1);
});

test("EOP-41 stockShortfalls: saving a COMPLETED order with its lines unchanged or smaller never asks for stock, whatever is on hand (two lines of one product, a line of 2.5, stock 0, 0.5, negative, product gone); a real raise still does, with the right count", () => {
    const find = (lines, c, ps) => EP.stockShortfalls(lines, c, (id) => { for (const p of ps) if (String(p.productId) === String(id)) return p; return null; });
    const dup = ctx("completed", [orig("A", 3, false, 0), orig("A", 2, false, 0)]);
    for (const stock of [0, 0.5, -3, 1, 7.5]) eq(find([line("A", 3), line("A", 2)], dup, [prod("A", stock)]), []);
    eq(find([line("A", 3), line("A", 2)], dup, []), []);
    const half = ctx("completed", [orig("A", 2.5, false, 0)]);
    for (const stock of [0, 0.5, -3, 1, 2.5]) eq(find([line("A", 2.5)], half, [prod("A", stock)]), []);
    // smaller is fine as well
    eq(find([line("A", 1), line("A", 2)], dup, [prod("A", 0)]), []);
    eq(find([line("A", 2)], half, [prod("A", 0)]), []);
    // a real raise: the units beyond what it held must be on hand
    eq(find([line("A", 3), line("A", 2), line("A", 2)], dup, [prod("A", 1)]), [{ productId: "A", name: "Name A", stock: 1, need: 1 }]);
    eq(find([line("A", 3), line("A", 2), line("A", 1)], dup, [prod("A", 1)]), []);
    eq(find([line("A", 3)], half, [prod("A", 0)]), [{ productId: "A", name: "Name A", stock: 0, need: 0.5 }]);
});

test("EOP-42 stepUp on a COMPLETED order that held two lines of one product or a line of 2.5: never lowers a row, never makes a fraction, can go back up to what the order held", () => {
    const dup = ctx("completed", [orig("A", 3, false, 0), orig("A", 2, false, 0)]);
    const two = [line("A", 3), line("A", 2)];
    eq(EP.stepUp(3, "A", prod("A", 0), dup, two), 3);
    eq(EP.stepUp(2, "A", prod("A", 0), dup, two), 2);
    eq(EP.stepUp(1, "A", prod("A", 0), dup, [line("A", 3), line("A", 1)]), 2);
    eq(EP.stepUp(3, "A", prod("A", 1), dup, two), 4);
    const half = ctx("completed", [orig("A", 2.5, false, 0)]);
    eq(EP.stepUp(2.5, "A", prod("A", 0), half, [line("A", 2.5)]), 2.5);
    eq(EP.stepUp(2, "A", prod("A", 0), half, [line("A", 2)]), 2);
    eq(EP.stepUp(1, "A", prod("A", 0), half, [line("A", 1)]), 2);
});

test("EOP-43 monkey, seeded: a COMPLETED order saved with its lines unchanged or smaller never asks for stock; with one more unit of a product it asks exactly when no whole unit is on hand (Node only)", () => {
    let seed = 43;
    const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
    const ids = ["A", "B", "C"];
    for (let i = 0; i < 600; i++) {
        const stock = [0, 0.5, -3, 1, 2.5, 7][Math.floor(rnd() * 6)];
        const products = rnd() < 0.15 ? [] : ids.map((id) => prod(id, stock));
        const byId = (id) => products.filter((p) => p.productId === id)[0] || null;
        const original = [];
        for (let k = Math.floor(rnd() * 6); k > 0; k--) original.push(orig(ids[Math.floor(rnd() * 3)], (1 + Math.floor(rnd() * 8)) / 2, false, 0));
        const c = ctx("completed", original);
        const same = original.map((o) => line(o.productId, o.quantity));
        eq(EP.stockShortfalls(same, c, byId), []);
        const smaller = original.filter(() => rnd() < 0.8).map((o) => line(o.productId, Math.floor(rnd() * (o.quantity * 2 + 1)) / 2));
        eq(EP.stockShortfalls(smaller, c, byId), []);
        if (original.length === 0) continue;
        const id = original[0].productId;
        const got = EP.stockShortfalls(same.concat([line(id, 1)]), c, byId).filter((s) => s.productId === id).map((s) => s.need);
        const whole = byId(id) ? Math.max(0, Math.floor(byId(id).stock)) : 1;
        eq(got, whole === 0 ? [1] : []);
    }
});

test("EOP-44 lineFields (PR #202 sweep F2): an order that never stored a products array and still has no rows sends neither items nor products; every other order sends both, as they are", () => {
    const prods = [{ productId: "A", quantity: 2 }];
    eq(EP.lineFields(true, 0, 0, []), {});
    eq(EP.lineFields(true, 1, 2, prods), { items: 2, products: prods });
    eq(EP.lineFields(false, 0, 0, []), { items: 0, products: [] });
    eq(EP.lineFields(false, 2, 5, prods), { items: 5, products: prods });
    // only a real true means "never stored": anything else reads as stored, so a normal order is never left unsaved
    for (const junk of [undefined, null, 0, "", "true", 1]) eq(EP.lineFields(junk, 0, 0, []), { items: 0, products: [] });
    // a row count that is not a real 0 means there are rows
    for (const n of [undefined, NaN, -1, "0", 3]) eq(EP.lineFields(true, n, 0, []), { items: 0, products: [] });
});

// ---- S5d (plan 2026-11-21-product-picker-v2-s5d-measure-and-cart-index.md): the per-build scope ----
test("EOP-45 scopeOf: the cart index always; the held index only for a COMPLETED order; junk ctx and junk lines never throw", () => {
    const lines = [line("A", 2), line("A", 1), line("B", 4)];
    const original = [orig("A", 3, false, 0), orig("A", 1, false, 0), orig("C", 2.5, false, 0)];
    const done = EP.scopeOf(lines, ctx("completed", original));
    eq(idxQty(done.cart, "A"), 3);
    eq(idxQty(done.cart, "B"), 4);
    eq(idxQty(done.held, "A"), 4);
    eq(idxQty(done.held, "C"), 2.5);
    eq(idxQty(done.held, "B"), 0);
    // each index remembers the rows and the key it was made from (the same arrays, not copies)
    ok(done.cart.rows === lines && done.cart.field === "qty", "cart index: wrong source");
    ok(done.held.rows === original && done.held.field === "quantity", "held index: wrong source");
    for (const status of ["pending", "processing", "cancelled", "", undefined]) eq(EP.scopeOf(lines, ctx(status, original)).held, null);
    eq(idxQty(EP.scopeOf(lines, ctx("pending")).cart, "A"), 3);
    for (const junk of [undefined, null, 5, "x", {}, { status: "completed" }, { status: "completed", original: "x" }]) {
        noThrow(() => EP.scopeOf(undefined, junk));
        noThrow(() => EP.scopeOf("x", junk));
    }
    eq(idxQty(EP.scopeOf(lines, { status: "completed" }).held, "A"), 0);
});
test("EOP-46 availableFor, ceilingFor and heldAtCompletion answer the same with and without the scope: every status, two lines of one product, a line of 2.5, a product that left the catalog", () => {
    const original = [orig("A", 3, false, 0), orig("A", 1, false, 0), orig("C", 2.5, false, 0), orig("D", 2, false, 0)];
    const lines = [line("A", 2), line("A", 1), line("C", 0.5), line("E", 4), line("B", 0), line("B", -1)];
    const products = [prod("A", 5), prod("B", 0), prod("C", 1.5), prod("D", 3), prod("E", 4), prod("F", 7), null];
    for (const status of ["pending", "processing", "completed", "cancelled", "", undefined]) {
        const c = ctx(status, original);
        const scope = EP.scopeOf(lines, c);
        for (let i = 0; i < products.length; ++i) {
            const p = products[i];
            const id = p ? p.productId : "GONE";
            eq(EP.availableFor(p, lines, c, scope), EP.availableFor(p, lines, c));
            eq(EP.ceilingFor(id, p, c, scope), EP.ceilingFor(id, p, c));
            eq(EP.heldAtCompletion(original, id, scope.held), EP.heldAtCompletion(original, id));
        }
    }
    const c = ctx("completed", original);
    const scope = EP.scopeOf(lines, c);
    eq(EP.availableFor(prod("A", 5), lines, c, scope), 6);
    eq(EP.availableFor(prod("D", 3), lines, c, scope), 5);
    eq(EP.heldAtCompletion(original, "A", scope.held), 4);
    // a scope answers only for the very lines and original it was made from: anything else is scanned (PR #210 sweep, F1)
    eq(EP.heldAtCompletion([], "A", scope.held), 0);
    eq(EP.heldAtCompletion([orig("A", 100, false, 0)], "A", scope.held), 100);
    eq(EP.ceilingFor("A", prod("A", 5), ctx("completed", []), scope), 5);
    eq(EP.ceilingFor("A", prod("A", 5), ctx("completed", [orig("A", 100, false, 0)]), scope), 105);
    eq(EP.availableFor(prod("A", 5), [], ctx("pending"), scope), 5);
    eq(EP.availableFor(prod("A", 5), [], ctx("completed", []), scope), 5);
    eq(EP.availableFor(prod("A", 5), [], ctx("completed", []), { cart: EP.scopeOf([], ctx("pending")).cart, held: scope.held }), 5);
    // the cart index of a scope never answers for the held key (and the other way round): a swap is refused, not trusted
    eq(EP.heldAtCompletion(original, "A", scope.cart), 4);
    // made from these exact arrays, the scope is read and they are not read again: emptied in place AFTER, it still answers
    const ls = [line("A", 2), line("A", 1)], org = [orig("A", 3, false, 0), orig("A", 1, false, 0)];
    const c2 = ctx("completed", org), sc = EP.scopeOf(ls, c2);
    ls.length = 0; org.length = 0;
    eq(EP.ceilingFor("A", prod("A", 5), c2, sc), 9);
    eq(EP.availableFor(prod("A", 5), ls, c2, sc), 6);
    eq(EP.availableFor(prod("A", 5), ls, ctx("pending"), sc), 2);
});
test("EOP-47 a scope with no held index on a completed order falls back to the scan: wrong shape, never a wrong number", () => {
    const original = [orig("A", 3, false, 0)];
    const c = ctx("completed", original);
    const lines = [line("A", 1)];
    const half = { cart: EP.scopeOf(lines, ctx("pending")).cart, held: null };
    eq(EP.availableFor(prod("A", 5), lines, c, half), EP.availableFor(prod("A", 5), lines, c));
    eq(EP.ceilingFor("A", prod("A", 5), c, half), 8);
    for (const junk of [undefined, null, 5, "x", {}, { cart: "x", held: "y" }, { cart: [], held: [] }]) {
        eq(EP.availableFor(prod("A", 5), lines, c, junk), EP.availableFor(prod("A", 5), lines, c));
        eq(EP.ceilingFor("A", prod("A", 5), c, junk), 8);
    }
});
test("EOP-48 monkey, seeded: availableFor with a scope equals availableFor without, on random orders of every status (Node only)", () => {
    const rand = rng(48);
    const idPool = ["A", "B", "C", 1, "1", "", null, "__proto__"];
    const qtyPool = [0, 1, 2, 2.5, 0.1, 0.2, -1, NaN, 7, "3", null];
    const statuses = ["pending", "processing", "completed", "cancelled", ""];
    for (let round = 0; round < 300; round++) {
        const mkRows = (key) => {
            const out = [];
            const n = Math.floor(rand() * 12);
            for (let i = 0; i < n; i++) {
                const r = { productId: idPool[Math.floor(rand() * idPool.length)] };
                r[key] = qtyPool[Math.floor(rand() * qtyPool.length)];
                out.push(rand() < 0.05 ? null : r);
            }
            return out;
        };
        const c = ctx(statuses[Math.floor(rand() * statuses.length)], mkRows("quantity"));
        const lines = mkRows("qty");
        const scope = EP.scopeOf(lines, c);
        for (let k = 0; k < idPool.length; k++) {
            const p = idPool[k] === null || idPool[k] === "" ? null : prod(idPool[k], [0, 1, 2.5, 9][Math.floor(rand() * 4)]);
            eq(EP.availableFor(p, lines, c, scope), EP.availableFor(p, lines, c));
        }
    }
});
