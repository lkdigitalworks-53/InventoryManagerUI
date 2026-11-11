"use strict";
// Picker v2, slice S3: the New Order dialog is wired to the picker sheet. NOW-01..16. Plan:
// docs/superpowers/plans/2026-11-11-product-picker-v2-s3-new-order.md. Like pickerSheetWiring.test.js these read the QML
// text (qmltestrunner cannot load Felgo), so they pin WIRING, not painting; two of them (NOW-14, NOW-15) also RUN the
// dialog's real hook literal and its real _applyPicked body in a sandbox against the real helpers, so the glue between
// the sheet, the hooks and the cart is executed and not just read.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, extractFunction } = require("./testSupport/qmlHelpers");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const DLG = read("qml/pages/NewOrderDialog.qml");
const STORE = read("qml/model/StockBatchStore.qml");
const NP = load("NewOrderPicker.js");
const PM = load("PickerSheetModel.js");
const PD = load("PickerDraft.js");
const plain = (v) => JSON.parse(JSON.stringify(v));
const noComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/(\s)\/\/ .*$/gm, "$1");
const CODE = noComments(DLG);

// Text from the first `open` after `head` to its matching `close`, brackets counted (strings in these literals hold none).
function literal(src, head, open, close) {
    const at = src.indexOf(head);
    assert.ok(at >= 0, head + " not found");
    const start = src.indexOf(open, at);
    let depth = 0, i = start;
    for (; i < src.length; i++) { if (src[i] === open) depth++; else if (src[i] === close && --depth === 0) break; }
    return src.substring(start, i + 1);
}

test("NOW-01 the combo, its two parallel arrays, its rebuild and the old add function are gone", () => {
    for (const name of ["productCombo", "productNames", "_pickerProducts", "_rebuildPickerNames", "addSelectedProduct", "_inCartQty", "_availableStock"])
        assert.ok(!CODE.includes(name), name + " is still in NewOrderDialog.qml");
    assert.ok(!/AppComboBox\s*\{\s*id:\s*product/.test(CODE));
});

test("NOW-02 the dialog declares one ProductPickerSheet and binds all five inputs and the one output", () => {
    assert.equal((CODE.match(/\bProductPickerSheet\s*\{/g) || []).length, 1);
    const body = literal(CODE, "ProductPickerSheet {", "{", "}");
    for (const line of ["id: picker", "products: InventoryStore.products", "hooks: dlg._pickerHooks", "orderLines: dlg.selectedProducts",
                        "revision: dlg._pickerRevision", "onCommitted: function(plan) { dlg._applyPicked(plan) }"])
        assert.ok(body.includes(line), "missing: " + line);
});

test("NOW-03 the hooks are the six the helpers expect, each wired to the store that owns the guard, and no isDeleting", () => {
    const hooks = literal(CODE, "readonly property var _pickerHooks", "{", "}");
    const expected = {
        hasPendingMint: "StockBatchStore.hasPendingMint(id)",
        hasQueuedRestock: "InventoryStore.hasQueuedRestock(id)",
        unsyncedState: "InventoryStore.syncStateOf(id)",
        inOrderQty: "Picker.cartQty(dlg.selectedProducts, id)",
        availableFor: "Picker.availableFor(p, dlg.selectedProducts)",
        commitCheck: "Picker.opsCheck(dlg.selectedProducts, plan, dlg._pickerLookup)"
    };
    for (const k of Object.keys(expected)) assert.ok(new RegExp(k + ":\\s*function\\([a-z]+\\)\\s*\\{\\s*return " + expected[k].replace(/[().]/g, "\\$&") + "\\s*\\}").test(hooks), k);
    assert.equal((hooks.match(/\w+:\s*function/g) || []).length, 6);
    assert.ok(!/isDeleting/.test(hooks));
    const lookup = literal(CODE, "readonly property var _pickerLookup", "{", "}");
    assert.ok(/productOf:\s*function\(id\)\s*\{\s*return InventoryStore\.getById\(id\)\s*\}/.test(lookup));
    assert.ok(/batchesOf:\s*function\(id\)\s*\{\s*return StockBatchStore\.forProduct\(id\)\s*\}/.test(lookup));
});

test("NOW-04 the revision is the sum of every counter the hooks read, pending mints and the outbox included", () => {
    const m = /readonly property int _pickerRevision:([^\n]*(?:\n\s*\+[^\n]*)*)/.exec(CODE);
    assert.ok(m, "_pickerRevision not found");
    const terms = m[1].split("+").map((t) => t.trim()).filter(Boolean).sort();
    assert.deepEqual(terms, ["InventoryStore.revision", "OutboxStore.revision", "StockBatchStore.mintRevision", "StockBatchStore.revision"]);
});

test("NOW-05 StockBatchStore ticks mintRevision on every change of the pending-mint list", () => {
    assert.ok(/property int mintRevision: 0\s*\n\s*on_PendingMintsChanged: mintRevision\+\+/.test(STORE));
    assert.equal((STORE.match(/mintRevision/g) || []).length, 2, "mintRevision should only be declared and ticked here");
    // the revision must exist where the sheet reads it: nowhere else writes it
    assert.ok(!/mintRevision\s*=/.test(STORE));
});

test("NOW-06 _applyPicked applies the plan with applyPlan, replaces the cart and reports what it skipped", () => {
    const fn = noComments(extractFunction("pages/NewOrderDialog.qml", "_applyPicked"));
    assert.ok(fn.includes("Picker.applyPlan(selectedProducts, plan, _pickerLookup)"));
    assert.ok(fn.includes("selectedProducts = res.lines"));
    assert.ok(fn.includes("errorLabel.text = Picker.skippedNote(res.skipped)"));
});

test("NOW-07 the trigger is a 48 dp ghost button that opens the sheet, is off while an order is being placed, and says what it does", () => {
    const btn = literal(CODE, "GhostButton {", "{", "}");
    assert.ok(btn.includes("enabled: !dlg.busy"));
    assert.ok(btn.includes("onClicked: picker.open()"));
    assert.ok(btn.includes('qsTr("Add more products")') && btn.includes('qsTr("Add products")'));
    assert.ok(/implicitHeight: dp\(48\)/.test(read("qml/components/GhostButton.qml")));
});

test("NOW-08 closing the order sheet closes the picker; opening it leaves the picker to reset itself", () => {
    const closed = literal(CODE, "onClosed:", "{", "}");
    assert.ok(closed.includes("picker.close()"));
    const opened = literal(CODE, "onOpened:", "{", "}");
    assert.ok(!/picker/.test(opened));
});

test("NOW-09 only New Order uses the sheet: Edit Order keeps its combo until S4", () => {
    const offenders = [];
    const walk = (dir) => { for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) walk(full);
        else if (/\.qml$/.test(e.name) && /ProductPickerSheet\s*\{/.test(fs.readFileSync(full, "utf8"))) offenders.push(path.relative(ROOT, full).split(path.sep).join("/"));
    } };
    walk(path.join(ROOT, "qml"));
    assert.deepEqual(offenders.filter((f) => f !== "qml/components/ProductPickerSheet.qml"), ["qml/pages/NewOrderDialog.qml"].filter((f) => offenders.includes(f)));
    assert.deepEqual(offenders, ["qml/pages/NewOrderDialog.qml"]);
    assert.ok(read("qml/pages/OrderDetailDialog.qml").includes("productCombo"));
});

test("NOW-10 the submit check stays the final guard: busy first, then name, at least one line, and stock per line", () => {
    const fn = noComments(extractFunction("pages/NewOrderDialog.qml", "trySubmit"));
    assert.ok(fn.indexOf("if (busy) return") >= 0 && fn.indexOf("if (busy) return") < fn.indexOf("errs.push"));
    assert.ok(fn.includes("Add at least one product"));
    assert.ok(fn.includes("if (inv && sp.qty > inv.stock)"));
});

test("NOW-11 the dry run's stand-in for the sale documents matches TransactionStore.buildSaleDocs: one per line with a quantity, nothing else", () => {
    const fn = noComments(extractFunction("model/TransactionStore.qml", "buildSaleDocs"));
    assert.equal((fn.match(/docs\.push\(/g) || []).length, 1, "buildSaleDocs now pushes in more than one place: update DRY_HOOKS in NewOrderPicker.js");
    assert.ok(fn.includes("if (!qty) continue"), "buildSaleDocs no longer skips a line without a quantity: update DRY_HOOKS");
    const loop = fn.substring(fn.indexOf("for (var i = 0; i < order.products.length"));
    assert.ok(loop.indexOf("docs.push(") > loop.indexOf("if (!qty) continue"));
    // and the helper's own stand-in counts exactly that
    assert.ok(/if \(ls\[i\]\.qty > 0\) docs\.push/.test(read("qml/helper/NewOrderPicker.js")));
});

test("NOW-12 the dry run uses the real planner and the real limit, nothing copied", () => {
    const src = read("qml/helper/NewOrderPicker.js");
    assert.ok(/\.import "CompletionPlan\.js" as CP/.test(src) && /CP\.build\(/.test(src));
    assert.ok(!/\bMAX_OPS\b|\b200\b/.test(noComments(src)), "the limit must come from CompletionPlan, not be repeated here");
});

test("NOW-13 the changed QML and JS files are balanced: braces, parentheses and brackets", () => {
    for (const f of ["qml/pages/NewOrderDialog.qml", "qml/helper/NewOrderPicker.js", "qml/helper/PickerSheetModel.js", "qml/model/StockBatchStore.qml"]) {
        const src = noComments(read(f)).replace(/"(?:\\.|[^"\\])*"/g, '""').replace(/\/\[[^\n]*?\/(?=\s*\})/g, "");
        for (const [open, close] of [["{", "}"], ["(", ")"], ["[", "]"]]) {
            const o = src.split(open).length - 1, c = src.split(close).length - 1;
            assert.equal(o, c, f + ": " + open + close + " unbalanced (" + o + " vs " + c + ")");
        }
    }
});

// ---- the glue, executed ----
function fakeWorld(over) {
    const w = Object.assign({
        products: [
            { productId: "A", name: "Alpha", sku: "SKU-A", category: "X", stock: 5, sellingPrice: 10, price: 4, unit: "pcs" },
            { productId: "B", name: "Beta", sku: "SKU-B", category: "X", stock: 0, sellingPrice: 20, price: 8 },
            { productId: "C", name: "Gamma", sku: "SKU-C", category: "Y", stock: 9, sellingPrice: 5, price: 2 },
            { productId: "D", name: "Delta", sku: "SKU-D", category: "Y", stock: 9, sellingPrice: 7, price: 3 },
            { productId: "E", name: "Eps", sku: "SKU-E", category: "Y", stock: 9, sellingPrice: 7, price: 3 }
        ],
        pendingMint: {}, queuedRestock: {}, syncState: {}, batches: {}
    }, over || {});
    const InventoryStore = {
        getById: (id) => w.products.filter((p) => p.productId === id)[0] || null,
        hasQueuedRestock: (id) => !!w.queuedRestock[id],
        syncStateOf: (id) => w.syncState[id] || ""
    };
    const StockBatchStore = { hasPendingMint: (id) => !!w.pendingMint[id], forProduct: (id) => w.batches[id] || [] };
    return { w, InventoryStore, StockBatchStore };
}

function dialogGlue(world, cart) {
    const dlg = { selectedProducts: cart || [] };
    dlg._pickerLookup = vm.runInNewContext("(" + literal(CODE, "readonly property var _pickerLookup", "{", "}") + ")",
        { InventoryStore: world.InventoryStore, StockBatchStore: world.StockBatchStore });
    dlg._pickerHooks = vm.runInNewContext("(" + literal(CODE, "readonly property var _pickerHooks", "{", "}") + ")",
        { InventoryStore: world.InventoryStore, StockBatchStore: world.StockBatchStore, Picker: NP, dlg: dlg });
    const errorLabel = { text: "" };
    const fnSrc = extractFunction("pages/NewOrderDialog.qml", "_applyPicked");
    const apply = vm.runInNewContext("(" + fnSrc.replace(/^function _applyPicked/, "function") + ")",
        { Picker: NP, errorLabel: errorLabel, get selectedProducts() { return dlg.selectedProducts; }, set selectedProducts(v) { dlg.selectedProducts = v; },
          _pickerLookup: dlg._pickerLookup });
    return { dlg, errorLabel, apply };
}

function viewOf(g, world, draft, extra) {
    return PM.build(Object.assign({ products: world.w.products, hooks: g.dlg._pickerHooks, orderLines: g.dlg.selectedProducts,
                                    draft: draft || {}, query: "", category: "All", inStockOnly: false }, extra || {}));
}

test("NOW-14 the real hook literal, run against the real sheet model: hidden by the three store guards, disabled when out of stock, counted by the cart", () => {
    const world = fakeWorld();
    world.w.pendingMint.C = true;
    world.w.queuedRestock.D = true;
    world.w.syncState.E = "parked";
    const g = dialogGlue(world, [{ name: "Alpha", qty: 2, price: 10, productId: "A", discountType: "flat", discountValue: 0 }]);
    const v = viewOf(g, world, {});
    assert.deepEqual(plain(v.rows.map((r) => [r.productId, r.canAdd, r.maxQty])), [["A", true, 3], ["B", false, 0]]);
    assert.equal(v.hiddenCount, 3);
    assert.equal(v.rows[0].inOrderLabel, "In this order: 2 pcs");
    // a mint that lands (the store forgets it) shows the product again on the next read
    delete world.w.pendingMint.C;
    assert.deepEqual(plain(viewOf(g, world, {}).rows.map((r) => r.productId)), ["A", "B", "C"]);
});

test("NOW-15 the real _applyPicked: a plan from the real sheet model becomes cart lines, a second plan bumps them, drift is clamped and reported", () => {
    const world = fakeWorld();
    const g = dialogGlue(world, []);
    // first pick: A x3 and C x2
    let v = viewOf(g, world, PD.step(PD.step({}, "A", 3, 5), "C", 2, 9));
    assert.deepEqual(plain(v.canCommit), { ok: true, reason: "" });
    g.apply(PD.commitPlan(v.draft, g.dlg.selectedProducts));
    assert.deepEqual(plain(g.dlg.selectedProducts.map((l) => [l.productId, l.qty, l.price, l.name])), [["A", 3, 10, "Alpha"], ["C", 2, 5, "Gamma"]]);
    assert.equal(g.errorLabel.text, "");
    // second pick: A x2 more (bump), D x1 (add); the sheet's maxQty for A is now 2
    v = viewOf(g, world, PD.step(PD.step({}, "A", 2, 2), "D", 1, 9));
    assert.equal(v.rows.filter((r) => r.productId === "A")[0].maxQty, 2);
    g.apply(PD.commitPlan(v.draft, g.dlg.selectedProducts));
    assert.deepEqual(plain(g.dlg.selectedProducts.map((l) => [l.productId, l.qty])), [["A", 5], ["C", 2], ["D", 1]]);
    // drift between the last tap and the Add tap: another device sold A down to 4, E left the catalog
    world.w.products[0].stock = 4;
    world.w.products = world.w.products.filter((p) => p.productId !== "E");
    g.apply({ adds: [{ productId: "E", qty: 1 }], bumps: [{ productId: "A", qty: 1 }] });
    assert.deepEqual(plain(g.dlg.selectedProducts.map((l) => [l.productId, l.qty])), [["A", 5], ["C", 2], ["D", 1]]);
    assert.equal(g.errorLabel.text, "Not added as picked. Alpha: out of stock now; E: no longer in the catalog");
    // the next clean pick clears the message
    g.apply({ adds: [], bumps: [{ productId: "C", qty: 1 }] });
    assert.equal(g.errorLabel.text, "");
    assert.equal(g.dlg.selectedProducts.filter((l) => l.productId === "C")[0].qty, 3);
});

test("NOW-16 the real hooks refuse an order the planner could not complete in one operation, and the sheet closes the gate with the planner's words", () => {
    const products = [], batches = {};
    for (let i = 0; i < 60; ++i) {
        products.push({ productId: "P" + i, name: "N" + i, sku: "S" + i, category: "C", stock: 2, sellingPrice: 10, price: 4 });
        batches["P" + i] = [{ batchId: "a" + i, supplierId: "", qtyRemaining: 1, unitCost: 1 }, { batchId: "b" + i, supplierId: "", qtyRemaining: 1, unitCost: 1 }];
    }
    const world = fakeWorld({ products: products, batches: batches });
    const g = dialogGlue(world, []);
    const draftOf = (n) => { let d = {}; for (let i = 0; i < n; ++i) d = PD.step(d, "P" + i, 2, 2); return d; };
    const ok49 = viewOf(g, world, draftOf(49));
    assert.deepEqual(plain(ok49.canCommit), { ok: true, reason: "" });
    const v50 = viewOf(g, world, draftOf(50));
    assert.deepEqual(plain(v50.canCommit), { ok: false, reason: "check-failed" });
    assert.ok(/too many items/.test(v50.commitNote) && /201 changes, limit 200/.test(v50.commitNote), v50.commitNote);
    // the cheap line cap is still the first gate: the hook is not what stops a 61st line
    const full = viewOf(g, world, draftOf(1), { orderLines: Array.from({ length: 60 }, (_, i) => ({ productId: "L" + i, qty: 1 })) });
    assert.equal(full.canCommit.reason, "too-many-lines");
});
