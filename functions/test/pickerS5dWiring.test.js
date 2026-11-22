"use strict";
// Picker v2, slice S5d: the per-build cart index. S5D-01..10. Plan:
// docs/superpowers/plans/2026-11-21-product-picker-v2-s5d-measure-and-cart-index.md. Like the S3/S4/S5c wiring tests these
// read the QML text (qmltestrunner cannot load Felgo) and RUN the dialogs' real hook literals and real row-snapshot
// functions in a sandbox against the real helpers, so the glue is executed, not just read. What they pin:
//   - the scope opens with the gate set LAST and closes with the gate cleared FIRST (a half-made scope can never be read),
//   - inside a build the hooks answer from the index and give EXACTLY the scan's answers (S5D-02..05),
//   - the cost shape: cart reads (New Order) and ListModel reads (Edit Order) do not grow with the catalog (S5D-06),
//     counted, not timed, so a noisy CI machine cannot flake it,
//   - a scope never outlives its build and a scope that cannot be made falls back to the scan (S5D-07, S5D-08).
// How fast it feels on a phone is what device checks 134 to 136 are for.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { spawnSync } = require("node:child_process");
const { load, extractFunction } = require("./testSupport/qmlHelpers");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const noComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/(\s)\/\/ .*$/gm, "$1");
const NEW = noComments(read("qml/pages/NewOrderDialog.qml"));
const EDIT = noComments(read("qml/pages/OrderDetailDialog.qml"));
const NP = load("NewOrderPicker.js");
const EP = load("EditOrderPicker.js");
const PM = load("PickerSheetModel.js");
const plain = (v) => JSON.parse(JSON.stringify(v));

function literal(src, head, open, close) {
    const at = src.indexOf(head);
    assert.ok(at >= 0, head + " not found");
    const start = src.indexOf(open, at);
    let depth = 0, i = start;
    for (; i < src.length; i++) { if (src[i] === open) depth++; else if (src[i] === close && --depth === 0) break; }
    return src.substring(start, i + 1);
}

// ---- worlds ----
function catalog(n) {
    const out = [];
    for (let i = 0; i < n; ++i)
        out.push({ productId: "P" + i, name: "Product " + i, sku: "SKU-" + i, category: "Cat " + (i % 5),
                   stock: (i % 7 === 0) ? 0 : (i % 11 === 0 ? 2.5 : 3 + (i % 9)), sellingPrice: 10 + (i % 5), minStock: 2, unit: "pcs" });
    return out;
}
const stores = (products) => ({
    InventoryStore: { getById: (id) => products.filter((p) => p.productId === id)[0] || null, hasQueuedRestock: () => false, syncStateOf: () => "" },
    StockBatchStore: { hasPendingMint: () => false, forProduct: () => [] }
});
const cartLine = (id, qty) => ({ name: "N " + id, qty: qty, price: 10, productId: id, discountType: "flat", discountValue: 0 });
// Lines for products P1, P3, P5, ... (stock above zero for most), a second line of P1, a fractional line, a numeric id.
function cartOf(L) {
    const out = [];
    for (let i = 0; i < L; ++i) out.push(cartLine("P" + (1 + 2 * i), 1 + (i % 2)));
    if (L > 0) out.push(cartLine("P1", 1));
    if (L > 2) out.push(cartLine("P3", 0.5));
    return out;
}

function newGlue(products, cart, pickerOverride) {
    const dlg = { selectedProducts: cart, _buildLines: null, _buildIndex: null };
    const s = stores(products);
    dlg._pickerLookup = vm.runInNewContext("(" + literal(NEW, "readonly property var _pickerLookup", "{", "}") + ")", s);
    dlg._pickerHooks = vm.runInNewContext("(" + literal(NEW, "readonly property var _pickerHooks", "{", "}") + ")",
        Object.assign({ Picker: pickerOverride || NP, dlg: dlg }, s));
    return { dlg, hooks: dlg._pickerHooks };
}
const rowOf = (id, q, over) => Object.assign({ productId: id, name: "Name " + id, price: 10, quantity: q, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }, over || {});
function rowsOf(L) { return cartOf(L).map((l) => rowOf(l.productId, l.qty)); }
// A ListModel double that counts every get(): the real cost of the Edit Order snapshot.
function fakeModel(rows, counter) {
    return { get count() { return rows.length; }, get: (i) => { counter.gets++; return rows[i]; } };
}
function editGlue(products, rows, status, original, counter, EditOverride) {
    const dlg = { _orderStatus: status, _originalLines: original || [], _buildLines: null, _buildCtx: null, _buildScope: null };
    const s = stores(products);
    const sandbox = Object.assign({ products: fakeModel(rows, counter || { gets: 0 }), Edit: EditOverride || EP, NP: NP, dlg: dlg }, s);
    const script = ["_lineItemArray", "_pickerLinesNow", "_pickerCtx"].map((n) => extractFunction("pages/OrderDetailDialog.qml", n)).join("\n")
        + "\nvar _pickerLookup = (" + literal(EDIT, "readonly property var _pickerLookup", "{", "}") + ");"
        + "\nvar _pickerHooks = (" + literal(EDIT, "readonly property var _pickerHooks", "{", "}") + ");";
    vm.createContext(sandbox);
    vm.runInContext(script, sandbox);
    dlg._pickerLinesNow = sandbox._pickerLinesNow;
    dlg._pickerCtx = sandbox._pickerCtx;
    dlg._pickerLookup = sandbox._pickerLookup;
    return { dlg, hooks: sandbox._pickerHooks, rows };
}
const ORIGINAL = [{ productId: "P1", quantity: 3, taxable: false, taxPercent: 0 }, { productId: "P1", quantity: 1, taxable: false, taxPercent: 0 },
                  { productId: "P2", quantity: 2.5, taxable: false, taxPercent: 0 }, { productId: "P4", quantity: 2, taxable: false, taxPercent: 0 }];

function build(g, products, over) {
    return PM.build(Object.assign({ products: products, hooks: g.hooks, orderLines: [], draft: {}, query: "", category: "All", inStockOnly: false }, over || {}));
}
// The same hooks without the scope: the pre-S5d behaviour, the scan, as the oracle.
function scanOnly(hooks) { return Object.assign({}, hooks, { beginBuild: undefined, endBuild: undefined }); }

// ---- source pins ----
test("S5D-01 both dialogs declare the build scope as plain properties, open it with the gate set LAST and close it with the gate cleared FIRST; Edit Order reads its rows once", () => {
    for (const p of ["_buildLines", "_buildIndex"]) assert.ok(new RegExp("property var " + p + ": null").test(NEW), "New Order lacks " + p);
    for (const p of ["_buildLines", "_buildCtx", "_buildScope"]) assert.ok(new RegExp("property var " + p + ": null").test(EDIT), "Edit Order lacks " + p);

    const nBegin = literal(NEW, "beginBuild:", "{", "}"), nEnd = literal(NEW, "endBuild:", "{", "}");
    assert.ok(nBegin.indexOf("dlg._buildLines =") >= 0 && nBegin.indexOf("dlg._buildLines =") < nBegin.indexOf("dlg._buildIndex ="), "New: the index is the gate, set last");
    assert.ok(nEnd.indexOf("dlg._buildIndex = null") >= 0 && nEnd.indexOf("dlg._buildIndex = null") < nEnd.indexOf("dlg._buildLines = null"), "New: the index is cleared first");

    const eBegin = literal(EDIT, "beginBuild:", "{", "}"), eEnd = literal(EDIT, "endBuild:", "{", "}");
    const at = (s, t) => s.indexOf(t);
    assert.ok(at(eBegin, "dlg._buildScope =") > at(eBegin, "dlg._buildLines =") && at(eBegin, "dlg._buildScope =") > at(eBegin, "dlg._buildCtx ="), "Edit: the scope is the gate, set last");
    assert.ok(at(eEnd, "dlg._buildScope = null") >= 0 && at(eEnd, "dlg._buildScope = null") < at(eEnd, "dlg._buildCtx = null") && at(eEnd, "dlg._buildScope = null") < at(eEnd, "dlg._buildLines = null"), "Edit: the scope is cleared first");
    assert.equal((eBegin.match(/_pickerLinesNow\(\)/g) || []).length, 1, "the rows are read from the ListModel once per build");
    assert.equal((eBegin.match(/_pickerCtx\(\)/g) || []).length, 1);

    // the fast branch of each hook never reads the live cart: the live read is only the fallback after the ternary's colon
    const hooksNew = literal(NEW, "readonly property var _pickerHooks", "{", "}");
    const hooksEdit = literal(EDIT, "readonly property var _pickerHooks", "{", "}");
    for (const name of ["inOrderQty", "availableFor"]) {
        const bodyN = literal(hooksNew, name + ":", "{", "}"), bodyE = literal(hooksEdit, name + ":", "{", "}");
        assert.ok(!/selectedProducts/.test(bodyN.split(" : ")[0]), "New " + name + ": the fast branch reads the live cart");
        assert.ok(!/_pickerLinesNow/.test(bodyE.split(" : ")[0]), "Edit " + name + ": the fast branch reads the live rows");
        assert.ok(/selectedProducts/.test(bodyN.split(" : ")[1]) && /_pickerLinesNow/.test(bodyE.split(" : ")[1]), name + ": the fallback is the old scan");
    }
});

// ---- the hooks, executed ----
test("S5D-02 New Order: inside a build the real hooks answer from the index and give exactly the scan's answers; outside a build they scan", () => {
    const products = catalog(80);
    const g = newGlue(products, cartOf(30));
    const answers = () => products.map((p) => [g.hooks.inOrderQty(p.productId), g.hooks.availableFor(p)]);
    const scan = answers();
    assert.equal(g.dlg._buildIndex, null);
    g.hooks.beginBuild();
    assert.ok(g.dlg._buildIndex && g.dlg._buildIndex.qtyIndex === true, "beginBuild made no index");
    assert.equal(g.dlg._buildLines, g.dlg.selectedProducts, "the snapshot is the cart it indexed");
    const fast = answers();
    g.hooks.endBuild();
    assert.deepEqual(fast, scan);
    assert.equal(g.dlg._buildIndex, null);
    assert.equal(g.dlg._buildLines, null);
    assert.ok(scan.some((a) => a[0] > 1), "the fixture holds two lines of one product");
    assert.ok(scan.some((a) => a[0] % 1 !== 0), "the fixture holds a fractional line");
});
test("S5D-03 Edit Order: inside a build the real hooks answer from the scope and give exactly the scan's answers, for every status; the live rows are read once", () => {
    const products = catalog(80);
    for (const status of ["pending", "processing", "completed"]) {
        const counter = { gets: 0 };
        const rows = rowsOf(30);
        const g = editGlue(products, rows, status, ORIGINAL, counter);
        const answers = () => products.map((p) => [g.hooks.inOrderQty(p.productId), g.hooks.availableFor(p)]);
        const scan = answers();
        assert.equal(g.dlg._buildScope, null);
        counter.gets = 0;
        g.hooks.beginBuild();
        assert.ok(g.dlg._buildScope && g.dlg._buildScope.cart.qtyIndex === true, status + ": beginBuild made no scope");
        assert.equal(status === "completed" ? g.dlg._buildScope.held.qtyIndex : g.dlg._buildScope.held, status === "completed" ? true : null);
        const fast = answers();
        g.hooks.endBuild();
        assert.deepEqual(fast, scan, status);
        assert.equal(counter.gets, rows.length, status + ": the ListModel was read once per row, not once per product");
        assert.equal(g.dlg._buildScope, null);
        assert.equal(g.dlg._buildCtx, null);
        assert.equal(g.dlg._buildLines, null);
    }
});

// ---- the sheet, end to end ----
test("S5D-04 New Order: a whole sheet build with the real hooks returns exactly the view the scan gives, for empty, small and drafted carts", () => {
    const products = catalog(120);
    for (const L of [0, 1, 3, 25, 59]) {
        for (const draft of [{}, { P2: 2, P4: 1 }, { P1: 1, P3: 99, P9: 2 }]) {
            const g = newGlue(products, cartOf(L));
            const o = { orderLines: g.dlg.selectedProducts, draft: draft };
            assert.deepEqual(plain(build(g, products, o)), plain(PM.build(Object.assign({ products: products, hooks: scanOnly(g.hooks), query: "", category: "All", inStockOnly: false }, o))), "L=" + L);
            assert.equal(g.dlg._buildIndex, null, "the scope is closed after the build");
        }
    }
});
test("S5D-05 Edit Order: a whole sheet build with the real hooks returns exactly the view the scan gives, for every status, with a draft, a filter and the in-stock toggle", () => {
    const products = catalog(120);
    for (const status of ["pending", "processing", "completed"]) {
        for (const L of [0, 3, 25]) {
            for (const extra of [{}, { draft: { P2: 2, P4: 1 } }, { query: "Product 1", inStockOnly: true }, { category: "Cat 2" }]) {
                const g = editGlue(products, rowsOf(L), status, ORIGINAL);
                const o = Object.assign({ orderLines: g.dlg._pickerLinesNow() }, extra);
                assert.deepEqual(plain(build(g, products, o)), plain(PM.build(Object.assign({ products: products, hooks: scanOnly(g.hooks), draft: {}, query: "", category: "All", inStockOnly: false }, o))), status + " L=" + L);
                assert.equal(g.dlg._buildScope, null, "the scope is closed after the build");
            }
        }
    }
});

// ---- cost shape: counted, not timed ----
test("S5D-06 cart reads (New Order) and ListModel reads (Edit Order) per build do not grow with the catalog", () => {
    const L = 20;
    const readsNew = (n, scan) => {
        const products = catalog(n);
        const cart = cartOf(L);
        let reads = 0;
        for (const l of cart) { const id = l.productId, q = l.qty; Object.defineProperty(l, "productId", { get() { reads++; return id; } }); Object.defineProperty(l, "qty", { get() { reads++; return q; } }); }
        const g = newGlue(products, cart);
        if (scan) g.hooks = scanOnly(g.hooks);
        build(g, products, { orderLines: g.dlg.selectedProducts });
        return reads;
    };
    const small = readsNew(40), big = readsNew(800);
    assert.equal(big, small, "cart reads grew with the catalog: " + small + " -> " + big);
    // the oracle: the scan path at the same size reads the cart for every product, twice (N x L), so it is far above
    const scanBig = readsNew(800, true);
    assert.ok(scanBig > 20 * big, "the scan path should read the cart per product (" + scanBig + ") against the index (" + big + ")");

    const rowsHeld = rowsOf(L).length;
    const getsEdit = (n, status) => {
        const counter = { gets: 0 };
        const products = catalog(n);
        const g = editGlue(products, rowsOf(L), status, ORIGINAL, counter);
        build(g, products, { orderLines: [] });    // the sheet's own orderLines is the notifier copy, not a ListModel read
        return counter.gets;
    };
    for (const status of ["pending", "completed"]) {
        assert.equal(getsEdit(40, status), rowsHeld, status + ": the ListModel is read once per row per build");
        assert.equal(getsEdit(800, status), rowsHeld, status + ": ListModel reads grew with the catalog");
    }
});

// ---- a scope never outlives its build; a scope that cannot be made falls back ----
test("S5D-07 inside a build the hooks answer for the snapshot even if the live order changes; after the build they answer for the live order again", () => {
    const products = catalog(20);
    const g = newGlue(products, cartOf(3));
    const before = g.hooks.inOrderQty("P1");
    g.hooks.beginBuild();
    g.dlg.selectedProducts = [cartLine("P1", 50)];
    assert.equal(g.hooks.inOrderQty("P1"), before, "the build must see ONE consistent order");
    g.hooks.endBuild();
    assert.equal(g.hooks.inOrderQty("P1"), 50, "after the build the live order decides again");

    const rows = rowsOf(3);
    const e = editGlue(products, rows, "pending", []);
    const eBefore = e.hooks.inOrderQty("P1");
    e.hooks.beginBuild();
    rows[0].quantity = 40;
    assert.equal(e.hooks.inOrderQty("P1"), eBefore);
    e.hooks.endBuild();
    assert.equal(e.hooks.inOrderQty("P1"), eBefore + 39);

    // two builds in a row: the second sees the change, nothing is remembered between them
    const g2 = newGlue(products, cartOf(3));
    const v1 = build(g2, products, { orderLines: g2.dlg.selectedProducts });
    g2.dlg.selectedProducts = [cartLine("P1", 3)];
    const v2 = build(g2, products, { orderLines: g2.dlg.selectedProducts });
    const row = (v, id) => v.rows.filter((r) => r.productId === id)[0];
    assert.notEqual(row(v1, "P1").inOrderLabel, row(v2, "P1").inOrderLabel);
    assert.equal(row(v2, "P1").inOrderLabel, "In this order: 3 pcs");
});
test("S5D-08 a scope that cannot be made (the index code throws) never stops the sheet: no scope is left behind and the view is the scan's", () => {
    const products = catalog(40);
    const bad = Object.assign({}, NP, { qtyIndex: () => { throw new Error("index"); } });
    const g = newGlue(products, cartOf(10), bad);
    const o = { orderLines: g.dlg.selectedProducts, draft: { P2: 1 } };
    const v = build(g, products, o);
    assert.equal(g.dlg._buildIndex, null);
    assert.deepEqual(plain(v), plain(PM.build(Object.assign({ products: products, hooks: scanOnly(g.hooks), query: "", category: "All", inStockOnly: false }, o))));

    const badEdit = Object.assign({}, EP, { scopeOf: () => { throw new Error("scope"); } });
    const e = editGlue(products, rowsOf(10), "completed", ORIGINAL, { gets: 0 }, badEdit);
    const eo = { orderLines: e.dlg._pickerLinesNow(), draft: { P2: 1 } };
    const ev = build(e, products, eo);
    assert.equal(e.dlg._buildScope, null);
    assert.deepEqual(plain(ev), plain(PM.build(Object.assign({ products: products, hooks: scanOnly(e.hooks), query: "", category: "All", inStockOnly: false }, eo))));
});

// ---- the tool and the files ----
test("S5D-09 the bench script runs in quick mode, covers both dialogs before and after, and cross-checks that the indexed and the scanned build return the same view (it exits non-zero if they differ)", () => {
    const r = spawnSync(process.execPath, [path.join(ROOT, "scripts", "bench", "pickerBench.cjs"), "--quick", "--json"], { encoding: "utf8", timeout: 120000 });
    assert.equal(r.status, 0, r.stderr);
    const rows = JSON.parse(r.stdout);
    const variants = new Set(rows.filter((x) => x.group === "rebuild").map((x) => x.variant));
    for (const v of ["new order, scan hooks (before S5d)", "new order, index (S5d)", "edit order, per-call rows (before S5d)", "edit order, one snapshot + index (S5d)"])
        assert.ok(variants.has(v), "bench lacks the variant: " + v);
    for (const x of rows) assert.ok(typeof x.ms === "number" && isFinite(x.ms) && x.ms >= 0, JSON.stringify(x));
    assert.ok(rows.some((x) => x.group === "categories") && rows.some((x) => x.group === "dry run"));
});
test("S5D-10 the changed QML and JS files are balanced: braces, parentheses and brackets", () => {
    for (const f of ["qml/pages/NewOrderDialog.qml", "qml/pages/OrderDetailDialog.qml", "qml/helper/NewOrderPicker.js", "qml/helper/EditOrderPicker.js", "qml/helper/PickerSheetModel.js"]) {
        const src = noComments(read(f)).replace(/"(?:\\.|[^"\\])*"/g, '""').replace(/\/\[[^\n]*?\/(?=\s*\})/g, "");
        for (const [open, close] of [["{", "}"], ["(", ")"], ["[", "]"]]) {
            const o = src.split(open).length - 1, c = src.split(close).length - 1;
            assert.equal(o, c, f + ": " + open + close + " unbalanced (" + o + " vs " + c + ")");
        }
    }
});
