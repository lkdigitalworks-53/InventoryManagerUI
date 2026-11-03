"use strict";
// Functional layer for the picker helpers: search -> pickability -> draft -> commit plan -> the REAL
// CompletionPlan.build (qml/helper/CompletionPlan.js, loaded as text). Proves a picker commit makes an
// order the planner accepts, and that MAX_LINES keeps a typical order under the server's change cap.
// Cases FLOW-01..08. Node only (the QML twins cover the pure cases; this one needs two helpers at once).
const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./testSupport/qmlHelpers");
const PS = load("ProductSearch.js");
const PK = load("ProductPickability.js");
const PD = load("PickerDraft.js");
const CP = load("CompletionPlan.js");

function catalog(n) {
    const out = [];
    for (let i = 0; i < n; ++i)
        out.push({ productId: "P" + String(i).padStart(4, "0"), name: "Item " + i, sku: "SKU-" + i,
                   category: i % 3 === 0 ? "Tea" : "Veg", stock: 10 + (i % 5), sellingPrice: 5 + i });
    return out;
}
function plan(orderLines, products, batchesPerProduct) {
    const stock = {}, batches = {};
    products.forEach((p) => {
        stock[p.productId] = p.stock;
        const bs = [], per = Math.max(1, batchesPerProduct || 1);
        for (let b = 0; b < per; ++b) bs.push({ batchId: p.productId + "-b" + b, supplierId: "s", qtyRemaining: Math.ceil(p.stock / per), unitCost: 1 });
        batches[p.productId] = bs;
    });
    return CP.build({
        orderId: "ORD-1", epoch: 1, now: "2026-11-03T00:00:00Z", clampStock: false,
        lines: orderLines.map((l) => ({ line: l, productId: l.productId, name: l.name, qty: l.qty })),
        stockByProduct: stock, batchesByProduct: batches
    }, {
        orderUpdate: (lines) => ({ before: { id: "ORD-1" }, after: { id: "ORD-1", lines: lines } }),
        saleDocs: (after) => after.lines.map((l, i) => ({ txId: "tx-" + i }))
    });
}
const ctxFor = (products, extra) => {
    const byId = {};
    products.forEach((p) => { byId[p.productId] = p; });
    const c = { availableFor: (p) => byId[p.productId].stock };
    for (const k in (extra || {})) c[k] = extra[k];
    return c;
};

test("FLOW-01 happy path: search, set quantities, commit, the planner accepts the order", () => {
    const products = catalog(300);
    const hits = PS.filter(products, "item 1", { category: "Veg" });
    assert.ok(hits.length > 3);
    const rows = PK.summarize(hits, ctxFor(products), {}).rows;
    let d = PD.empty();
    d = PD.setQty(d, rows[0].product.productId, "2", rows[0].maxQty);
    d = PD.step(d, rows[1].product.productId, 1, rows[1].maxQty);
    d = PD.setQty(d, rows[2].product.productId, "999", rows[2].maxQty);
    const cp = PD.commitPlan(d, []);
    assert.equal(cp.adds.length, 3);
    const lines = cp.adds.map((a) => ({ productId: a.productId, name: a.productId, qty: a.qty }));
    const r = plan(lines, products, 1);
    assert.equal(r.ok, true);
});
test("FLOW-02 hidden products never reach the rows, so never the draft", () => {
    const products = catalog(20);
    const c = ctxFor(products, { hasPendingMint: (id) => id === "P0001", unsyncedState: (id) => (id === "P0002" ? "parked" : "") });
    const s = PK.summarize(PS.filter(products, ""), c, {});
    assert.equal(s.hiddenCount, 2);
    assert.ok(!s.rows.some((r) => r.product.productId === "P0001" || r.product.productId === "P0002"));
});
test("FLOW-03 a draft survives search and chip changes", () => {
    const products = catalog(30);
    const c = ctxFor(products);
    let d = PD.setQty({}, "P0004", "3", 10);
    PK.summarize(PS.filter(products, "zzz"), c, {});
    PK.summarize(PS.filter(products, "", { category: "Tea" }), c, {});
    assert.deepEqual(JSON.parse(JSON.stringify(PD.commitPlan(d, []).adds)), [{ productId: "P0004", qty: 3 }]);
});
test("FLOW-04 a product that goes out of stock mid-draft is reconciled away", () => {
    const stock = { P0001: 5, P0002: 5 };
    let d = { P0001: 4, P0002: 2 };
    stock.P0001 = 1; stock.P0002 = 0;
    d = PD.reconcile(d, (id) => stock[id]);
    assert.deepEqual(JSON.parse(JSON.stringify(d)), { P0001: 1 });
});
test("FLOW-05 MAX_LINES new lines plan within the server cap when each product has one batch", () => {
    const products = catalog(PD.MAX_LINES + 5);
    const lines = products.slice(0, PD.MAX_LINES).map((p) => ({ productId: p.productId, name: p.name, qty: 1 }));
    const r = plan(lines, products, 1);
    assert.equal(r.ok, true, JSON.stringify(r.errors));
    assert.ok(r.ops.length <= CP.MAX_OPS);
});
test("FLOW-06 an order at the line limit disables a new product but not one already on it", () => {
    const products = catalog(PD.MAX_LINES + 2);
    const orderLines = products.slice(0, PD.MAX_LINES).map((p) => ({ productId: p.productId, qty: 1 }));
    assert.equal(PD.lineLimitReached(orderLines, {}), true);
    const c = ctxFor(products, { lineLimitReached: true, inOrderQty: (id) => (orderLines.some((l) => l.productId === id) ? 1 : 0) });
    assert.equal(PK.classify(products[PD.MAX_LINES], c).reason, "order-full");
    assert.equal(PK.classify(products[0], c).visibility, "enabled");
});
test("FLOW-07 a product spread over many batches can still exceed the cap: CompletionPlan refuses, nothing crashes", () => {
    const products = catalog(PD.MAX_LINES);
    products.forEach((p) => { p.stock = 40; });
    const lines = products.map((p) => ({ productId: p.productId, name: p.name, qty: 40 }));
    const r = plan(lines, products, 10);
    assert.equal(r.ok, false);
    assert.equal(r.reason, "too-many-ops");
});
test("FLOW-08 two commits of the same product make one line, the second a bump", () => {
    const first = PD.commitPlan({ P0001: 2 }, []);
    assert.equal(first.adds.length, 1);
    const second = PD.commitPlan({ P0001: 3 }, [{ productId: "P0001", quantity: 2 }]);
    assert.equal(second.adds.length, 0);
    assert.equal(second.bumps.length, 1);
});
