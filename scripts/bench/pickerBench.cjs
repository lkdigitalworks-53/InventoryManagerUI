"use strict";
// Picker rebuild cost on a synthetic big shop (picker v2, slice S5d; KNOWN-ISSUES 14, 19c, 25; plan
// docs/superpowers/plans/2026-11-21-product-picker-v2-s5d-measure-and-cart-index.md).
//   node scripts/bench/pickerBench.cjs              table
//   node scripts/bench/pickerBench.cjs --json       the same numbers as JSON
//   node scripts/bench/pickerBench.cjs --quick      small sizes (the test S5D-09 uses it; seconds, not a minute)
//
// NOT a CI gate and NOT a phone number: this is Node's V8 running the REAL helper files with hooks that copy the cost
// shape of the lookups the dialogs pass (a linear scan of the outbox per product, a linear scan of the cart or of the
// ListModel rows per call). QML's V4 engine is slower than V8 (no JIT on iOS), so read each figure as a floor; the ratio
// between rows is what carries over. Real numbers come from device checks 46, 64 and 134 to 136.
//
// Each rebuild row is measured twice, before and after S5d, and the two views are compared: if the indexed build does not
// return exactly the view the scan returns, this script exits 1 (it is also a correctness cross-check).
const path = require("node:path");
const { load } = require(path.join(__dirname, "..", "..", "functions", "test", "testSupport", "qmlHelpers"));
const PM = load("PickerSheetModel.js");
const NP = load("NewOrderPicker.js");
const EP = load("EditOrderPicker.js");
const Draft = load("PickerDraft.js");

const QUICK = process.argv.includes("--quick");
const WANT_JSON = process.argv.includes("--json");
const SIZES = QUICK ? [200, 800] : [500, 2000, 5000, 20000];
const CARTS = QUICK ? [3, 20] : [3, 20, 60];
const OUTBOX = 200;

function catalog(n, cats) {
    const out = [];
    for (let i = 0; i < n; ++i)
        out.push({ productId: "P" + i, name: "Product number " + i, sku: "SKU-" + i, category: "Cat " + (i % cats),
                   stock: (i % 7 === 0) ? 0 : 5 + (i % 40), sellingPrice: 10 + (i % 90), minStock: 3, unit: "pcs" });
    return out;
}
function batches(n, perProduct) {
    const out = [];
    for (let i = 0; i < n; ++i)
        for (let b = 0; b < perProduct; ++b)
            out.push({ batchId: "B" + i + "-" + b, productId: "P" + i, qtyRemaining: 3 + b, receivedDate: "2026-0" + (1 + (b % 9)) + "-1" + (i % 9), costPrice: 5 });
    return out;
}
function outbox(k) {
    const items = [];
    for (let i = 0; i < k; ++i) items.push({ opType: i % 2 ? "restock" : "order", ops: [{ entity: "inventory", entityId: "Q" + i }] });
    return items;
}
function hasQueuedOperationFor(items, opType, entity, id) {      // OutboxStore.hasQueuedOperationFor, line for line
    for (let i = 0; i < items.length; ++i) {
        const it = items[i];
        if (it.opType !== opType || !it.ops) continue;
        for (let j = 0; j < it.ops.length; ++j) if (it.ops[j].entity === entity && it.ops[j].entityId === id) return true;
    }
    return false;
}
function forProduct(all, id) {                                   // StockBatchStore.forProduct, line for line
    if (!id) return [];
    const out = [];
    for (let i = 0; i < all.length; ++i) if (all[i].productId === id) out.push(all[i]);
    out.sort((a, b) => (a.receivedDate || "").localeCompare(b.receivedDate || ""));
    return out;
}
function cartOf(L, products) {
    const out = [];
    for (let i = 0; i < L; ++i) out.push({ productId: products[1 + i * 2].productId, name: "L" + i, qty: 1 + (i % 2), price: 10, discountType: "flat", discountValue: 0 });
    return out;
}
// Edit Order's rows as the ListModel holds them, and the per-call snapshot (OrderDetailDialog._lineItemArray + linesOf):
// one new object per row per call, which is what the pre-S5d hooks paid for every product, twice.
function rowsFrom(cart) { return cart.map((l) => ({ productId: l.productId, name: l.name, price: l.price, quantity: l.qty, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 })); }
function snapshot(rows) {
    const arr = [];
    for (let i = 0; i < rows.length; ++i) {
        const pr = rows[i];
        arr.push({ productId: pr.productId, name: pr.name, price: pr.price, quantity: pr.quantity,
                   discountType: pr.discountType === "percent" ? "percent" : "flat", discountValue: pr.discountValue || 0, taxable: !!pr.taxable, taxPercent: pr.taxPercent || 0 });
    }
    return EP.linesOf(arr);
}

function common(ob) {
    return { hasPendingMint: () => false, hasQueuedRestock: (id) => hasQueuedOperationFor(ob, "restock", "inventory", id), unsyncedState: () => "", hasPrice: (p) => NP.priceOf(p) !== null };
}
// The four hook sets. Each returns the hooks the dialog would hand the sheet at that point of history.
function newScan(ob, cart) {
    return Object.assign(common(ob), { inOrderQty: (id) => NP.cartQty(cart, id), availableFor: (p) => NP.availableFor(p, cart) });
}
function newIndexed(ob, cart) {                                  // the literal in NewOrderDialog.qml, with the closure state
    let lines = null, index = null;
    return Object.assign(common(ob), {
        beginBuild: () => { lines = cart; index = NP.qtyIndex(lines, "qty"); },
        endBuild: () => { index = null; lines = null; },
        inOrderQty: (id) => index ? NP.cartQty(lines, id, index) : NP.cartQty(cart, id),
        availableFor: (p) => index ? NP.availableFor(p, lines, index) : NP.availableFor(p, cart)
    });
}
function editScan(ob, rows, ctx) {
    return Object.assign(common(ob), { inOrderQty: (id) => NP.cartQty(snapshot(rows), id), availableFor: (p) => EP.availableFor(p, snapshot(rows), ctx) });
}
function editIndexed(ob, rows, ctx) {                            // the literal in OrderDetailDialog.qml
    let lines = null, c = null, scope = null;
    return Object.assign(common(ob), {
        beginBuild: () => { const l = snapshot(rows), cx = ctx; lines = l; c = cx; scope = EP.scopeOf(l, cx); },
        endBuild: () => { scope = null; c = null; lines = null; },
        inOrderQty: (id) => scope ? NP.cartQty(lines, id, scope.cart) : NP.cartQty(snapshot(rows), id),
        availableFor: (p) => scope ? EP.availableFor(p, lines, c, scope) : EP.availableFor(p, snapshot(rows), ctx)
    });
}

function ms(fn, reps, once) {
    // `once`: a build that already takes seconds is run one time, no warm-up (the figure is large, noise is not the point)
    if (once) { const t0 = process.hrtime.bigint(); fn(); return Number(process.hrtime.bigint() - t0) / 1e6; }
    fn();                                                        // warm up
    let best = Infinity;                                         // best of 3 batches: the least noisy figure
    for (let b = 0; b < 3; ++b) {
        const t0 = process.hrtime.bigint();
        for (let i = 0; i < reps; ++i) fn();
        best = Math.min(best, Number(process.hrtime.bigint() - t0) / 1e6 / reps);
    }
    return best;
}
const round = (x) => Math.round(x * 100) / 100;
const canon = (v) => JSON.stringify(v);

const rows = [];
function record(group, variant, label, value) { rows.push({ group, variant, label, ms: round(value) }); }

// 1. one rebuild of the sheet (what every stepper tap, refresh and debounced key pays), commitCheck OFF.
for (const n of SIZES) {
    const products = catalog(n, 12);
    const ob = outbox(OUTBOX);
    for (const L of CARTS) {
        const cart = cartOf(L, products);
        const reps = n >= 20000 ? 2 : (n >= 5000 ? 4 : 8);
        const label = "N=" + n + " cart=" + L;
        const run = (hooks, orderLines, extra) => () => PM.build(Object.assign({ products, hooks, orderLines, draft: {}, query: "", category: "All", inStockOnly: false }, extra || {}));

        const a = run(newScan(ob, cart), cart), b = run(newIndexed(ob, cart), cart);
        if (canon(a()) !== canon(b())) { console.error("MISMATCH new order " + label); process.exit(1); }
        record("rebuild", "new order, scan hooks (before S5d)", label, ms(a, reps));
        record("rebuild", "new order, index (S5d)", label, ms(b, reps));

        for (const status of ["pending", "completed"]) {
            const ctx = { status, original: [{ productId: products[1].productId, quantity: 3, taxable: false, taxPercent: 0 }, { productId: products[3].productId, quantity: 2, taxable: false, taxPercent: 0 }] };
            const edRows = rowsFrom(cart);
            const lines = snapshot(edRows);
            const c = run(editScan(ob, edRows, ctx), lines), d = run(editIndexed(ob, edRows, ctx), lines);
            if (canon(c()) !== canon(d())) { console.error("MISMATCH edit order " + status + " " + label); process.exit(1); }
            const heavy = n >= 5000 && L >= 20;                  // the per-call variant takes seconds here: one run
            record("rebuild", "edit order, per-call rows (before S5d)", label + " " + status, ms(c, heavy ? 1 : Math.max(1, Math.floor(reps / 2)), heavy));
            record("rebuild", "edit order, one snapshot + index (S5d)", label + " " + status, ms(d, reps));
        }
    }
}
// 2. the categories pass alone (KI 19c): is it worth caching?
for (const n of QUICK ? [800] : [2000, 20000]) {
    const products = catalog(n, 12);
    record("categories", "categories()", "N=" + n, ms(() => PM.categories(products), 10));
}
// 3. the dry run (KI 25): opsCheck with `k` lines in the plan and a ledger of `b` batches, forProduct per line.
for (const b of QUICK ? [1000] : [1000, 5000, 20000]) {
    for (const k of QUICK ? [5, 30] : [5, 30, 60]) {
        const products = catalog(Math.max(Math.floor(b / 3), 100), 12);
        const all = batches(products.length, 3);
        const byId = {}; products.forEach((p) => { byId[p.productId] = p; });
        const lookup = { productOf: (id) => byId[id] || null, batchesOf: (id) => forProduct(all, id) };
        const draft = {};
        for (let i = 0; i < k; ++i) draft[products[1 + i * 2].productId] = 1;
        const plan = Draft.commitPlan(draft, []);
        const r = NP.opsCheck([], plan, lookup);
        record("dry run", "opsCheck", "batches=" + all.length + " planLines=" + k + " ok=" + r.ok, ms(() => NP.opsCheck([], plan, lookup), 5));
    }
}

if (WANT_JSON) { console.log(JSON.stringify(rows, null, 1)); process.exit(0); }
let g = "", v = "";
for (const r of rows) {
    if (r.group !== g) { g = r.group; v = ""; console.log("\n== " + g); }
    if (r.variant !== v) { v = r.variant; console.log("  " + v); }
    console.log("    " + r.label.padEnd(40) + String(r.ms).padStart(9) + " ms");
}
