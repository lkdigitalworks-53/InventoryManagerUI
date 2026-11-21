"use strict";
// Picker rebuild cost on a synthetic big shop (picker v2, slice S5d; KNOWN-ISSUES 14, 19c, 25).
//   node scripts/bench/pickerBench.cjs            table, no gate
//   node scripts/bench/pickerBench.cjs --json     same numbers as JSON
// NOT a CI gate and NOT a phone number: this is Node's V8 running the REAL helper files with hooks that copy the cost
// shape of the store lookups the dialogs pass (a linear scan per product for the outbox, a linear scan of the cart).
// QML's V4 engine is slower than V8 (no JIT on iOS), so read each figure as a floor; the ratio between rows is what
// carries over. Real numbers come from device checks 46 and 64.
const path = require("node:path");
const { load } = require(path.join(__dirname, "..", "..", "functions", "test", "testSupport", "qmlHelpers"));
const PM = load("PickerSheetModel.js");
const NP = load("NewOrderPicker.js");
const Draft = load("PickerDraft.js");

const WANT_JSON = process.argv.includes("--json");

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
// An outbox of `k` queued operations, none for the products listed, as OutboxStore.hasQueuedOperationFor walks it.
function outbox(k) {
    const items = [];
    for (let i = 0; i < k; ++i) items.push({ opType: i % 2 ? "restock" : "order", ops: [{ entity: "inventory", entityId: "Q" + i }] });
    return items;
}
function hasQueuedOperationFor(items, opType, entity, id) {
    for (let i = 0; i < items.length; ++i) {
        const it = items[i];
        if (it.opType !== opType || !it.ops) continue;
        for (let j = 0; j < it.ops.length; ++j) if (it.ops[j].entity === entity && it.ops[j].entityId === id) return true;
    }
    return false;
}
function forProduct(all, id) {                      // StockBatchStore.forProduct, line for line
    if (!id) return [];
    const out = [];
    for (let i = 0; i < all.length; ++i) if (all[i].productId === id) out.push(all[i]);
    out.sort((a, b) => (a.receivedDate || "").localeCompare(b.receivedDate || ""));
    return out;
}
function cartOf(lines, products) {
    const out = [];
    for (let i = 0; i < lines; ++i) out.push({ productId: products[1 + i * 2].productId, name: "L" + i, qty: 1, price: 10, discount: 0 });
    return out;
}

function ms(fn, reps) {
    fn();                                           // warm up
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < reps; ++i) fn();
    return Number(process.hrtime.bigint() - t0) / 1e6 / reps;
}
const round = (x) => Math.round(x * 100) / 100;

const rows = [];
function record(group, label, value) { rows.push({ group, label, ms: round(value) }); }

// 1. one rebuild of the sheet (what every stepper tap, refresh and debounced key pays), commitCheck OFF.
for (const n of [500, 2000, 5000, 20000]) {
    for (const outboxSize of [0, 200]) {
        for (const lines of [3, 60]) {
            const products = catalog(n, 12);
            const ob = outbox(outboxSize);
            const cart = cartOf(lines, products);
            const hooks = {
                hasPendingMint: () => false,
                hasQueuedRestock: (id) => hasQueuedOperationFor(ob, "restock", "inventory", id),
                unsyncedState: () => "",
                hasPrice: (p) => NP.priceOf(p) !== null,
                inOrderQty: (id) => NP.cartQty(cart, id),
                availableFor: (p) => NP.availableFor(p, cart)
            };
            const input = { products, hooks, orderLines: cart, draft: {}, query: "", category: "All", inStockOnly: false };
            const reps = n >= 20000 ? 3 : 10;
            record("rebuild (no dry run)", "N=" + n + " outbox=" + outboxSize + " cartLines=" + lines, ms(() => PM.build(input), reps));
        }
    }
}
// 2. the categories pass alone (KI 19c): is it worth caching?
for (const n of [2000, 20000]) {
    const products = catalog(n, 12);
    record("categories pass alone", "N=" + n, ms(() => PM.categories(products), 10));
}
// 3. the dry run (KI 25): opsCheck with `k` lines in the plan and a ledger of `b` batches, forProduct per line.
for (const b of [1000, 5000, 20000]) {
    for (const k of [5, 30, 60]) {
        const products = catalog(Math.max(b / 3, 100), 12);
        const all = batches(Math.max(b / 3, 100), 3);
        const byId = {}; products.forEach((p) => { byId[p.productId] = p; });
        const lookup = { productOf: (id) => byId[id] || null, batchesOf: (id) => forProduct(all, id) };
        const draft = {};
        for (let i = 0; i < k; ++i) draft[products[1 + i * 2].productId] = 1;
        const plan = Draft.commitPlan(draft, []);
        const r = NP.opsCheck([], plan, lookup);
        record("dry run (opsCheck)", "batches=" + all.length + " planLines=" + k + " ok=" + r.ok, ms(() => NP.opsCheck([], plan, lookup), 5));
    }
}

if (WANT_JSON) { console.log(JSON.stringify(rows, null, 1)); process.exit(0); }
let g = "";
for (const r of rows) {
    if (r.group !== g) { g = r.group; console.log("\n" + g); }
    console.log("  " + r.label.padEnd(46) + String(r.ms).padStart(9) + " ms");
}
