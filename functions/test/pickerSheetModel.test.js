"use strict";
// PickerSheetModel (qml/helper/PickerSheetModel.js). Cases SHEET-01..26, plan:
// docs/superpowers/plans/2026-11-04-product-picker-v2-s2-sheet-component.md. The QML twin
// tests/tst_PickerSheetModel.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const PM = load("PickerSheetModel.js");

// QML-PRELUDE-BEGIN
function rowKeys() {
    return ["productId", "name", "sku", "category", "unit", "photoId", "price", "available", "maxQty", "inOrder", "qty",
            "canAdd", "reason", "reasonText", "pillStatus", "pillLabel", "inOrderLabel", "atMax"];
}
function strKeys() { return ["productId", "name", "sku", "category", "unit", "photoId", "reason", "reasonText", "pillStatus", "pillLabel", "inOrderLabel"]; }
function numKeys() { return ["price", "available", "maxQty", "inOrder", "qty"]; }
function boolKeys() { return ["canAdd", "atMax"]; }
function prod(id, stock, over) {
    var p = { productId: id, name: "Name " + id, sku: "SKU-" + id, category: "Cat", stock: stock, sellingPrice: 10, minStock: 1 };
    for (var k in (over || {})) p[k] = over[k];
    return p;
}
function hooks(over) {
    var h = {
        hasPendingMint: function() { return false; },
        unsyncedState: function() { return ""; },
        availableFor: function(p) { return typeof p.stock === "number" ? p.stock : 0; }
    };
    for (var k in (over || {})) h[k] = over[k];
    return h;
}
function mk(products, over) {
    var inp = { products: products, hooks: hooks(), orderLines: [], draft: {}, query: "", category: "All", inStockOnly: false };
    for (var k in (over || {})) inp[k] = over[k];
    return PM.build(inp);
}
function ids(v) { var out = []; for (var i = 0; i < v.rows.length; ++i) out.push(v.rows[i].productId); return out; }
function lines(n) { var out = []; for (var i = 0; i < n; ++i) out.push({ productId: "L" + i, qty: 1 }); return out; }
// QML-PRELUDE-END

test("SHEET-01 junk input never throws and gives an empty, uncommittable view", () => {
    const junk = [undefined, null, {}, 5, "x", [], { products: 5, hooks: 5, orderLines: "x", draft: 7 }];
    for (let i = 0; i < junk.length; ++i) {
        noThrow(() => PM.build(junk[i]));
        const v = PM.build(junk[i]);
        eq(v.rows, []);
        eq(v.draft, {});
        eq(v.canCommit, { ok: false, reason: "empty" });
        eq(v.empty.kind, "no-products");
        eq(v.hiddenCount, 0);
    }
});
test("SHEET-02 an empty query lists the catalog in catalog order, every row flat and complete", () => {
    const v = mk([prod("B", 5), prod("A", 5), prod("C", 5)]);
    eq(ids(v), ["B", "A", "C"]);
    for (let i = 0; i < v.rows.length; ++i) {
        const r = v.rows[i];
        eq(Object.keys(r).sort(), rowKeys().slice().sort());
        for (let k = 0; k < strKeys().length; ++k) eq(typeof r[strKeys()[k]], "string");
        for (let k = 0; k < numKeys().length; ++k) ok(typeof r[numKeys()[k]] === "number" && isFinite(r[numKeys()[k]]), numKeys()[k] + " is not a finite number");
        for (let k = 0; k < boolKeys().length; ++k) eq(typeof r[boolKeys()[k]], "boolean");
    }
});
test("SHEET-02b a plain row holds exactly these values: no reason text, no on-order label, not at max", () => {
    const v = mk([prod("A", 5, { unit: "kg", photoIds: ["p1"] })]);
    eq(v.rows[0], { productId: "A", name: "Name A", sku: "SKU-A", category: "Cat", unit: "kg", photoId: "p1", price: 10,
                    available: 5, maxQty: 5, inOrder: 0, qty: 0, canAdd: true, reason: "", reasonText: "",
                    pillStatus: "active", pillLabel: "5 left", inOrderLabel: "", atMax: false });
});
test("SHEET-03 row text: name falls back to the id, price prefers sellingPrice, photo is the first string", () => {
    const v = mk([
        prod("A", 5, { name: "", sellingPrice: undefined, price: 7, photoIds: ["p1", "p2"], unit: "kg" }),
        prod("B", 5, { name: undefined, sku: undefined, category: undefined, sellingPrice: "x", price: "y", photoIds: [5] }),
        prod("C", 5, { sellingPrice: 12.5, price: 99, photoIds: [] })
    ]);
    eq([v.rows[0].name, v.rows[0].price, v.rows[0].photoId, v.rows[0].unit], ["A", 7, "p1", "kg"]);
    eq([v.rows[1].name, v.rows[1].sku, v.rows[1].category, v.rows[1].price, v.rows[1].photoId], ["B", "", "", 0, ""]);
    eq([v.rows[2].price, v.rows[2].photoId], [12.5, ""]);
});
test("SHEET-04 availability pill: N left, Low at or under the minimum, never colour alone", () => {
    const v = mk([prod("A", 5, { minStock: 2 }), prod("B", 2, { minStock: 2 }), prod("C", 4, { minStock: undefined })]);
    eq([v.rows[0].pillStatus, v.rows[0].pillLabel], ["active", "5 left"]);
    eq([v.rows[1].pillStatus, v.rows[1].pillLabel], ["low", "2 left"]);
    eq([v.rows[2].pillStatus, v.rows[2].pillLabel], ["active", "4 left"]);
    // a minimum that is not a number never makes a product look low: "9" would coerce to 9 in a bare comparison
    eq(mk([prod("A", 5, { minStock: "9" }), prod("B", 5, { minStock: NaN }), prod("C", 5, { minStock: null })]).rows.map((r) => r.pillStatus), ["active", "active", "active"]);
});
test("SHEET-05 a pending mint, a queued restock, an unsynced edit and a delete in flight hide the row and are counted", () => {
    const v = mk([prod("A", 5), prod("B", 5), prod("C", 5), prod("D", 5), prod("E", 5)], {
        hooks: hooks({
            hasPendingMint: (id) => id === "A",
            hasQueuedRestock: (id) => id === "B",
            unsyncedState: (id) => (id === "C" ? "parked" : ""),
            isDeleting: (id) => id === "D"
        })
    });
    eq(ids(v), ["E"]);
    eq(v.hiddenCount, 4);
    eq(v.hiddenNote, "4 products hidden while they sync");
});
test("SHEET-05b a disabled row always has words, even for a reason code this file does not know", () => {
    eq(PM.reasonTextFor("out-of-stock"), "Out of stock");
    eq(PM.reasonTextFor("order-full"), "Order is full");
    eq(PM.reasonTextFor("unavailable"), "Not available right now");
    eq(PM.reasonTextFor("something-new"), "Not available right now");
    eq(PM.reasonTextFor(undefined), "Not available right now");
    eq(PM.reasonTextFor("__proto__"), "Not available right now");
});
test("SHEET-06 hiddenNote words: none, one, many, junk", () => {
    eq(PM.hiddenNote(0), "");
    eq(PM.hiddenNote(1), "1 product hidden while it syncs");
    eq(PM.hiddenNote(2), "2 products hidden while they sync");
    eq(PM.hiddenNote(undefined), "");
    eq(PM.hiddenNote(-3), "");
    eq(PM.hiddenNote("2"), "");
});
test("SHEET-07 the hidden count only covers products that match the search and the chip", () => {
    const products = [prod("A", 5, { name: "Apple", category: "Fruit" }), prod("B", 5, { name: "Banana", category: "Fruit" }),
                      prod("C", 5, { name: "Cab", category: "Veg" })];
    const h = hooks({ hasPendingMint: (id) => id === "B" || id === "C" });
    eq(mk(products, { hooks: h }).hiddenCount, 2);
    eq(mk(products, { hooks: h, query: "ban" }).hiddenCount, 1);
    eq(mk(products, { hooks: h, category: "Veg" }).hiddenCount, 1);
    eq(mk(products, { hooks: h, query: "zzz" }).hiddenCount, 0);
});
test("SHEET-08 an out-of-stock product is shown disabled with the words, and the toggle drops it", () => {
    const products = [prod("A", 5), prod("B", 0)];
    const v = mk(products);
    eq([v.rows[1].canAdd, v.rows[1].reason, v.rows[1].reasonText, v.rows[1].pillStatus, v.rows[1].pillLabel, v.rows[1].maxQty],
       [false, "out-of-stock", "Out of stock", "out of stock", "Out of stock", 0]);
    eq(v.rows[1].atMax, false);
    eq(ids(mk(products, { inStockOnly: true })), ["A"]);
    eq(mk(products, { inStockOnly: true }).hiddenCount, 0);
    eq(mk(products, { inStockOnly: true, query: "zzz" }).empty.kind, "no-match");
});
test("SHEET-09 at the line limit a new product is disabled as order full, a product on the order or in the draft is not", () => {
    const base = lines(59);
    const v = mk([prod("N1", 5), prod("N2", 5), prod("L3", 5)], {
        orderLines: base.concat([{ productId: "N2", qty: 2 }]),
        hooks: hooks({ inOrderQty: (id) => (id === "N2" ? 2 : (id === "L3" ? 1 : 0)) })
    });
    eq([v.rows[0].canAdd, v.rows[0].reason, v.rows[0].reasonText, v.rows[0].pillLabel], [false, "order-full", "Order is full", "Order full"]);
    eq([v.rows[1].canAdd, v.rows[1].inOrderLabel], [true, "In this order: 2"]);
    eq([v.rows[2].canAdd, v.rows[2].inOrderLabel], [true, "In this order: 1"]);
});
test("SHEET-10 a draft survives a search that hides its row, and the row comes back with its quantity", () => {
    const products = [prod("A", 5, { name: "Apple" }), prod("B", 5, { name: "Banana" })];
    const hidden = mk(products, { draft: { A: 2 }, query: "banana" });
    eq(ids(hidden), ["B"]);
    eq(hidden.draft, { A: 2 });
    eq(hidden.totals.items, 2);
    eq(hidden.draftChanged, false);
    const back = mk(products, { draft: hidden.draft, query: "" });
    eq([back.rows[0].productId, back.rows[0].qty], ["A", 2]);
});
test("SHEET-11 reconcile clamps a quantity above the stock and flags the change", () => {
    const v = mk([prod("A", 5)], { draft: { A: 9 } });
    eq(v.draft, { A: 5 });
    eq(v.draftChanged, true);
    eq([v.rows[0].qty, v.rows[0].atMax], [5, true]);
});
test("SHEET-12 reconcile drops a product that left the catalog, went out of stock or became hidden", () => {
    const products = [prod("A", 5), prod("B", 0), prod("C", 5)];
    const v = mk(products, { draft: { A: 1, B: 2, C: 3, Z: 4 }, hooks: hooks({ hasPendingMint: (id) => id === "C" }) });
    eq(v.draft, { A: 1 });
    eq(v.draftChanged, true);
});
test("SHEET-13 an unchanged draft is not flagged", () => {
    const v = mk([prod("A", 5), prod("B", 5)], { draft: { A: 2, B: 5 } });
    eq(v.draftChanged, false);
    eq(v.draft, { A: 2, B: 5 });
});
test("SHEET-14 the draft is capped by the stock that remains, never by what is already on the order", () => {
    const v = mk([prod("A", 5)], { draft: { A: 5 }, orderLines: [{ productId: "A", qty: 3 }], hooks: hooks({ inOrderQty: () => 3 }) });
    eq([v.rows[0].qty, v.rows[0].maxQty, v.rows[0].inOrder, v.rows[0].atMax], [5, 5, 3, true]);
});
test("SHEET-15 totals: items, lines and the amount at the selling price, a missing price counts as 0", () => {
    const products = [prod("A", 9, { sellingPrice: 2.5 }), prod("B", 9, { sellingPrice: undefined, price: 4 }), prod("C", 9, { sellingPrice: undefined, price: undefined })];
    const v = mk(products, { draft: { A: 2, B: 1, C: 3 } });
    eq(v.totals, { items: 6, lines: 3, amount: 9 });
});
test("SHEET-16 commit gate: empty, ok, and more than 60 lines", () => {
    const products = [prod("A", 5)];
    eq(mk(products).canCommit, { ok: false, reason: "empty" });
    eq(mk(products, { draft: { A: 1 } }).canCommit, { ok: true, reason: "" });
    eq(mk(products, { draft: { A: 1 } }).commitNote, "");
    const over = mk(products, { draft: { A: 1 }, orderLines: lines(60) });
    eq(over.canCommit, { ok: false, reason: "too-many-lines" });
    eq(over.commitNote, "An order holds at most 60 lines.");
});
test("SHEET-17 the empty states, each with its own words", () => {
    eq(mk([]).empty, { kind: "no-products", text: "There are no products to add yet." });
    const syncing = mk([prod("A", 5)], { hooks: hooks({ hasPendingMint: () => true }) });
    eq(syncing.empty, { kind: "all-hidden", text: "Everything that matches is still syncing." });
    eq(mk([prod("A", 0)], { inStockOnly: true }).empty, { kind: "none-in-stock", text: "No in-stock product matches." });
    eq(mk([prod("A", 5)], { query: "zzz" }).empty, { kind: "no-match", text: "No products match \"zzz\"." });
    eq(mk([prod("A", 5, { category: "Veg" })], { category: "Tea" }).empty, { kind: "no-match", text: "No products in this category." });
    eq(mk([prod("A", 5)]).empty, { kind: "", text: "" });
});
test("SHEET-18 a long query is cut to 40 characters in the empty text", () => {
    const q = "q".repeat(60);
    eq(mk([prod("A", 5)], { query: q }).empty.text, "No products match \"" + "q".repeat(40) + "...\".");
});
test("SHEET-19 categories: All first, no blanks or junk, case-insensitive, first spelling kept, sorted", () => {
    const list = [prod("A", 1, { category: "veg" }), prod("B", 1, { category: "Fruit" }), prod("C", 1, { category: "Veg" }),
                  prod("D", 1, { category: "  " }), prod("E", 1, { category: undefined }), prod("F", 1, { category: " tea " }),
                  { productId: 7, category: "Junk" }, null, 5, "x"];
    eq(PM.categories(list), ["All", "Fruit", "tea", "veg"]);
    eq(PM.categories(undefined), ["All"]);
    eq(PM.categories([]), ["All"]);
});
test("SHEET-20 the chip filters by category regardless of case, and search ranks like ProductSearch", () => {
    const tea = mk(FX.CATALOG.map((p) => ({ productId: p.productId, name: p.name, sku: p.sku, category: p.category, stock: 3, sellingPrice: 1 })), { category: "tea" });
    eq(ids(tea), ["PRD-003"]);
    const tomato = mk(FX.CATALOG.map((p) => ({ productId: p.productId, name: p.name, sku: p.sku, category: p.category, stock: 3, sellingPrice: 1 })), { query: "tomato" });
    eq(ids(tomato), ["PRD-001", "PRD-002"]);
});
test("SHEET-21 sameOrder: the same ids in the same order only", () => {
    const v = mk([prod("A", 5), prod("B", 5)]);
    eq(PM.sameOrder(["A", "B"], v.rows), true);
    eq(PM.sameOrder(["B", "A"], v.rows), false);
    eq(PM.sameOrder(["A"], v.rows), false);
    eq(PM.sameOrder(["A", "B", "C"], v.rows), false);
    eq(PM.sameOrder([], []), true);
    eq(PM.sameOrder(undefined, v.rows), false);
    eq(PM.sameOrder(["A", "B"], undefined), false);
    eq(PM.sameOrder(["A", "B"], [null, null]), false);
});
test("SHEET-22 a missing or partial hooks object fails closed: every row disabled, nothing addable, the draft dropped", () => {
    const products = [prod("A", 5), prod("B", 5)];
    const bad = [undefined, null, {}, 5, { availableFor: () => 5 }, { hasPendingMint: () => false, unsyncedState: () => "" }];
    for (let i = 0; i < bad.length; ++i) {
        const v = mk(products, { hooks: bad[i], draft: { A: 1 } });
        eq(ids(v), ["A", "B"]);
        for (let k = 0; k < v.rows.length; ++k) {
            eq([v.rows[k].canAdd, v.rows[k].maxQty], [false, 0]);
            // A missing availableFor reads as no stock (S1 behaviour: disabled, "Out of stock"); every other gap is "unavailable".
            ok(v.rows[k].reason === "unavailable" || (i === 5 && v.rows[k].reason === "out-of-stock"), "reason " + v.rows[k].reason + " for hooks case " + i);
            ok(v.rows[k].reasonText.length > 0 && v.rows[k].pillLabel.length > 0, "a disabled row without words");
        }
        eq(v.draft, {});
    }
});
test("SHEET-23 a hook that throws disables that row and nothing else", () => {
    const products = [prod("A", 5), prod("B", 5)];
    const v = mk(products, { hooks: hooks({ availableFor: (p) => { if (p.productId === "A") throw new Error("boom"); return 5; } }) });
    eq([v.rows[0].canAdd, v.rows[0].reason], [false, "unavailable"]);
    eq([v.rows[1].canAdd, v.rows[1].maxQty], [true, 5]);
});
test("SHEET-24 the hooks are asked by product id, and availableFor gets the product", () => {
    const seen = { mint: [], avail: [] };
    mk([prod("A", 5)], { hooks: hooks({ hasPendingMint: (id) => { seen.mint.push(id); return false; }, availableFor: (p) => { seen.avail.push(p.productId); return 5; } }) });
    ok(seen.mint.indexOf("A") >= 0, "hasPendingMint was not asked with the id");
    ok(seen.avail.indexOf("A") >= 0, "availableFor did not get the product");
});
test("SHEET-25 frozen inputs are never changed, and the result holds new objects", () => {
    const products = FX.freeze([prod("A", 5), prod("B", 0)]);
    const draft = FX.freeze({ A: 9 });
    const orderLines = FX.freeze([{ productId: "L", qty: 1 }]);
    const h = FX.freeze(hooks());
    const v = PM.build({ products: products, hooks: h, orderLines: orderLines, draft: draft, query: "", category: "All", inStockOnly: false });
    eq(v.draft, { A: 5 });
    ok(v.draft !== draft, "returned the input draft");
    ok(v.rows[0] !== products[0], "a row is the product object itself");
    eq(draft, { A: 9 });
});
test("SHEET-26 seeded monkey, 300 rounds: every row addable or explained, the draft always valid, the gate agrees with the draft", () => {
    const rand = FX.rng(23);
    const pick = (list) => list[Math.floor(rand() * list.length)];
    const seen = { rows: 0, disabled: 0, hidden: 0, empty: 0, committable: 0, drafted: 0 };
    for (let round = 0; round < 300; ++round) {
        const products = [];
        const n = Math.floor(rand() * 8);
        for (let i = 0; i < n; ++i)
            products.push(prod("P" + i, pick([0, 1, 4, 9, -2, NaN, 3.7]), { category: pick(["A", "a", "B", "", undefined]), name: pick(["Red", "Blue", "", "Réd"]) }));
        const hiddenIds = {};
        for (let i = 0; i < n; ++i) if (rand() < 0.25) hiddenIds["P" + i] = true;
        const draft = {};
        for (let i = 0; i < 10; ++i) if (rand() < 0.5) draft[pick(["P0", "P1", "P2", "P3", "P9", "__proto__", ""])] = pick([1, 2, 5, 50, 0, -1]);
        const v = mk(products, {
            draft: draft, query: pick(["", "red", "p1", "zzz", "  ", "r"]), category: pick(["All", "A", "B", "zz"]), inStockOnly: rand() < 0.3,
            orderLines: rand() < 0.1 ? lines(60) : [], hooks: hooks({ hasPendingMint: (id) => !!hiddenIds[id] })
        });
        let items = 0;
        for (const k in v.draft) {
            ok(Number.isInteger(v.draft[k]) && v.draft[k] >= 1, "bad draft quantity");
            items += v.draft[k];
            ok(!hiddenIds[k], "a hidden product stayed in the draft");
        }
        eq(v.totals.items, items);
        eq(v.canCommit.ok, items > 0 && v.canCommit.reason === "");
        for (let r = 0; r < v.rows.length; ++r) {
            const row = v.rows[r];
            ok(!hiddenIds[row.productId], "a hidden product is listed");
            ok(row.qty <= row.maxQty || (!row.canAdd && row.qty === 0), "quantity above the maximum");
            if (row.canAdd) ok(row.maxQty >= 1, "an addable row with no stock");
            else ok(row.reasonText.length > 0 && row.maxQty === 0, "a disabled row without words");
            eq(Object.keys(row).sort(), rowKeys().slice().sort());
            seen.rows++;
            if (!row.canAdd) seen.disabled++;
        }
        if (v.hiddenCount > 0) seen.hidden++;
        if (v.rows.length === 0) seen.empty++;
        if (v.canCommit.ok) seen.committable++;
        if (items > 0) seen.drafted++;
    }
    ok(seen.rows > 100 && seen.disabled > 20 && seen.hidden > 20 && seen.empty > 10 && seen.committable > 10 && seen.drafted > 10,
       "the monkey never reached every outcome: " + FX.canon(seen));
});
