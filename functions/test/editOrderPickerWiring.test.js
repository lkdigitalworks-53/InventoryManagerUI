"use strict";
// Picker v2, slice S4: the Edit Order dialog is wired to the picker sheet. EOW-01..16. Plan:
// docs/superpowers/plans/2026-11-12-product-picker-v2-s4-edit-order.md. Like newOrderPickerWiring.test.js these read the
// QML text (qmltestrunner cannot load Felgo), so they pin WIRING, not painting; EOW-12..14 also RUN the dialog's real
// hook literal, its real row snapshot and its real _applyPicked body in a sandbox against the real helpers and a fake
// ListModel, so the glue between the sheet, the hooks and the order's rows is executed and not just read.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, extractFunction } = require("./testSupport/qmlHelpers");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const DLG = read("qml/pages/OrderDetailDialog.qml");
const EP = load("EditOrderPicker.js");
const PM = load("PickerSheetModel.js");
const PD = load("PickerDraft.js");
const plain = (v) => JSON.parse(JSON.stringify(v));
const noComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/(\s)\/\/ .*$/gm, "$1");
const CODE = noComments(DLG);

function literal(src, head, open, close) {
    const at = src.indexOf(head);
    assert.ok(at >= 0, head + " not found");
    const start = src.indexOf(open, at);
    let depth = 0, i = start;
    for (; i < src.length; i++) { if (src[i] === open) depth++; else if (src[i] === close && --depth === 0) break; }
    return src.substring(start, i + 1);
}
const fn = (name) => noComments(extractFunction("pages/OrderDetailDialog.qml", name));
// openFor holds an unbalanced brace inside a comment, so extractFunction cannot bound it: take the text up to the next member.
const OPEN_FOR = CODE.slice(CODE.indexOf("function openFor("), CODE.indexOf("onClosed:"));

test("EOW-01 the combo, its names array, its stock helper and the old add button are gone; the catalog stays for legacy-order seeding only", () => {
    for (const name of ["productCombo", "catalogNames", "_availableStock", "IconActionButton"])
        assert.ok(!CODE.includes(name), name + " is still in OrderDetailDialog.qml");
    assert.ok(!/AppComboBox\s*\{\s*id:\s*product/.test(CODE));
    const rebuild = fn("_rebuildCatalog");
    assert.ok(rebuild.includes("StockBatchStore.hasPendingMint(p.productId)"), "the legacy seed still skips a pending mint");
    assert.ok(!rebuild.includes("avail") && !rebuild.includes("names"), "no names or availability any more");
    assert.ok(/catalog\.length >= 2 && itemCount >= 2/.test(CODE) && /catalog\[0\]\.productId/.test(CODE), "the legacy seed still reads the catalog");
    assert.equal((CODE.match(/_rebuildCatalog\(\)/g) || []).length, 2, "the definition and one call, from openFor");
    assert.ok(OPEN_FOR.includes("_rebuildCatalog()"));
});

test("EOW-02 the dialog declares one ProductPickerSheet and binds all four inputs and the one output", () => {
    assert.equal((CODE.match(/\bProductPickerSheet\s*\{/g) || []).length, 1);
    const body = literal(CODE, "ProductPickerSheet {", "{", "}");
    for (const line of ["id: picker", "products: InventoryStore.products", "hooks: dlg._pickerHooks", "orderLines: dlg._pickerLines",
                        "revision: dlg._pickerRevision", "onCommitted: function(plan) { dlg._applyPicked(plan) }"])
        assert.ok(body.includes(line), "missing: " + line);
});

test("EOW-03 the hooks are the six the helpers expect, each wired to the store or helper that owns the rule, and no isDeleting", () => {
    const hooks = literal(CODE, "readonly property var _pickerHooks", "{", "}");
    const expected = {
        hasPendingMint: "StockBatchStore.hasPendingMint(id)",
        hasQueuedRestock: "InventoryStore.hasQueuedRestock(id)",
        unsyncedState: "InventoryStore.syncStateOf(id)",
        inOrderQty: "Edit.cartQty(dlg._pickerLinesNow(), id)",
        availableFor: "Edit.availableFor(p, dlg._pickerLinesNow(), dlg._pickerCtx())",
        commitCheck: "Edit.commitCheck(dlg._pickerLinesNow(), plan, dlg._pickerCtx(), dlg._pickerLookup)"
    };
    for (const k of Object.keys(expected)) assert.ok(new RegExp(k + ":\\s*function\\([a-z]+\\)\\s*\\{\\s*return " + expected[k].replace(/[().]/g, "\\$&") + "\\s*\\}").test(hooks), k);
    assert.equal((hooks.match(/\w+:\s*function/g) || []).length, 6);
    assert.ok(!/isDeleting/.test(hooks));
    const lookup = literal(CODE, "readonly property var _pickerLookup", "{", "}");
    assert.ok(/productOf:\s*function\(id\)\s*\{\s*return InventoryStore\.getById\(id\)\s*\}/.test(lookup));
    assert.ok(/batchesOf:\s*function\(id\)\s*\{\s*return StockBatchStore\.forProduct\(id\)\s*\}/.test(lookup));
});

test("EOW-04 the revision is the same four counters as New Order: stock and catalog, batches, pending mints, the outbox", () => {
    const m = /readonly property int _pickerRevision:([^\n]*(?:\n\s*\+[^\n]*)*)/.exec(CODE);
    assert.ok(m, "_pickerRevision not found");
    const terms = m[1].split("+").map((t) => t.trim()).filter(Boolean).sort();
    assert.deepEqual(terms, ["InventoryStore.revision", "OutboxStore.revision", "StockBatchStore.mintRevision", "StockBatchStore.revision"]);
    const nod = read("qml/pages/NewOrderDialog.qml");
    const n = /readonly property int _pickerRevision:([^\n]*(?:\n\s*\+[^\n]*)*)/.exec(noComments(nod));
    assert.deepEqual(n[1].split("+").map((t) => t.trim()).filter(Boolean).sort(), terms, "Edit Order and New Order must watch the same counters");
});

test("EOW-05 _applyPicked reads the live rows, applies sets and appends to the model, recomputes once, clears the stale message and toasts what was skipped", () => {
    const f = fn("_applyPicked");
    assert.ok(f.includes("Edit.applyPlan(_pickerLinesNow(), plan, _pickerCtx(), _pickerLookup)"));
    assert.ok(/products\.setProperty\(res\.sets\[i\]\.index, "quantity", res\.sets\[i\]\.quantity\)/.test(f));
    assert.ok(/products\.append\(res\.appends\[j\]\)/.test(f));
    assert.equal((f.match(/recomputeSubtotal\(\)/g) || []).length, 1, "one recompute, after both loops");
    assert.ok(f.indexOf("recomputeSubtotal()") > f.indexOf("products.append"));
    assert.ok(f.includes('stockErrorLabel.text = ""'));
    assert.ok(f.includes("const note = Edit.skippedNote(res.skipped)"));
    assert.ok(/if \(note\.length > 0\) Toast\.show\(note\)/.test(f));
    assert.ok(!/products\.remove|products\.clear/.test(f), "the picker never removes a row");
    assert.ok(!/setProperty\([^)]*"(price|discountType|discountValue|taxable|taxPercent)"/.test(f), "the picker never touches an existing row's price, discount or tax");
});

test("EOW-06 the trigger is a ghost button that opens the sheet, is off while a save is in flight, and says what it does", () => {
    const btn = literal(CODE, "GhostButton {", "{", "}");
    assert.ok(btn.includes("enabled: !dlg.busy"));
    assert.ok(btn.includes("onClicked: picker.open()"));
    assert.ok(btn.includes('qsTr("Add more products")') && btn.includes('qsTr("Add products")'));
    assert.ok(btn.includes("products.count > 0"));
});

test("EOW-07 closing the dialog closes the picker first; opening it leaves the picker to reset itself", () => {
    const closed = literal(CODE, "onClosed:", "{", "}");
    assert.ok(closed.trimStart().slice(1).trimStart().startsWith("picker.close()"), "picker.close() must be the first statement");
    assert.ok(OPEN_FOR.length > 500 && !/picker/.test(OPEN_FOR));
});

test("EOW-08 the sheet is told when the rows change: recomputeSubtotal refreshes _pickerLines and no longer rebuilds the catalog", () => {
    const f = fn("recomputeSubtotal");
    assert.ok(f.includes("_pickerLines = Edit.linesOf(lineArr)"));
    assert.ok(!f.includes("_rebuildCatalog") && !f.includes("productCombo"));
    assert.ok(/property var _pickerLines: \[\]/.test(CODE));
});

test("EOW-09 the picker's stock formula and tax rule read the order's SAVED status and its lines at completion, not the status combo", () => {
    const f = fn("_pickerCtx");
    assert.ok(/return \{ status: dlg\._orderStatus, original: dlg\._originalLines \}/.test(f));
    assert.ok(!/statusCombo/.test(f));
    const open = OPEN_FOR;
    assert.ok(open.indexOf("_orderStatus = String(o.status") < open.indexOf("_rebuildCatalog()"));
    assert.ok(open.indexOf("_originalLines = (o.products") < open.indexOf("_rebuildCatalog()"));
});

test("EOW-10 only the two order dialogs use the sheet", () => {
    const offenders = [];
    const walk = (dir) => { for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) walk(full);
        else if (/\.qml$/.test(e.name) && /ProductPickerSheet\s*\{/.test(fs.readFileSync(full, "utf8"))) offenders.push(path.relative(ROOT, full).split(path.sep).join("/"));
    } };
    walk(path.join(ROOT, "qml"));
    assert.deepEqual(offenders.sort(), ["qml/pages/NewOrderDialog.qml", "qml/pages/OrderDetailDialog.qml"]);
});

test("EOW-11 the guards that belong to the order stay in the dialog: lock, busy, stock check on save, history sync for completed edits, the + stepper's own ceiling", () => {
    const save = fn("_save");
    for (const needle of ["_lockState", "needFromStock > inv.stock", "TransactionStore.hasMore", "adjustRequested", "busy = true"])
        assert.ok(save.includes(needle), "_save lost: " + needle);
    // the row stepper's ceiling for a completed order is still on-hand plus the original quantity
    assert.ok(/maxQ = onHand \+ \(orig \? \(orig\.quantity \|\| 0\) : 0\)/.test(CODE));
    // the helper's completed formula says the same thing
    assert.ok(/_whole\(product\.stock\) \+ origQty - NP\.cartQty/.test(read("qml/helper/EditOrderPicker.js")));
});

test("EOW-12 the changed QML and JS files are balanced: braces, parentheses and brackets", () => {
    for (const f of ["qml/pages/OrderDetailDialog.qml", "qml/helper/EditOrderPicker.js", "qml/helper/NewOrderPicker.js"]) {
        const src = noComments(read(f)).replace(/"(?:\\.|[^"\\])*"/g, '""').replace(/\/\[[^\n]*?\/(?=\s*\})/g, "");
        for (const [open, close] of [["{", "}"], ["(", ")"], ["[", "]"]]) {
            const o = src.split(open).length - 1, c = src.split(close).length - 1;
            assert.equal(o, c, f + ": " + open + close + " unbalanced (" + o + " vs " + c + ")");
        }
    }
});

// ---- the glue, executed ----
function fakeModel(rows) {
    const a = rows.map((r) => Object.assign({}, r));
    return { rows: a, get count() { return a.length; }, get: (i) => a[i], setProperty: (i, k, v) => { a[i][k] = v; }, append: (o) => { a.push(Object.assign({}, o)); } };
}
function fakeWorld(over) {
    const w = Object.assign({
        products: [
            { productId: "A", name: "Alpha", sku: "SKU-A", category: "X", stock: 5, sellingPrice: 10, price: 4, taxable: true, taxPercent: 18 },
            { productId: "B", name: "Beta", sku: "SKU-B", category: "X", stock: 0, sellingPrice: 20, price: 8, taxable: false, taxPercent: 0 },
            { productId: "C", name: "Gamma", sku: "SKU-C", category: "Y", stock: 9, sellingPrice: 5, price: 2, taxable: true, taxPercent: 12 },
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
const row = (id, q, over) => Object.assign({ productId: id, name: "Name " + id, price: 10, quantity: q, discountType: "flat", discountValue: 0, taxable: false, taxPercent: 0 }, over || {});

// The dialog's real functions and literals, in one sandbox. `status` and `original` are the dialog's saved-order state.
function dialogGlue(world, rows, status, original) {
    const model = fakeModel(rows);
    const toasts = [];
    const recomputes = [];
    const label = { text: "stale" };
    const dlg = { _orderStatus: status, _originalLines: original || [] };
    const sandbox = { products: model, Edit: EP, dlg, Toast: { show: (m) => toasts.push(m) }, stockErrorLabel: label,
                      recomputeSubtotal: () => recomputes.push(model.rows.length),
                      InventoryStore: world.InventoryStore, StockBatchStore: world.StockBatchStore };
    const script = ["_lineItemArray", "_pickerLinesNow", "_pickerCtx", "_applyPicked"].map((n) => extractFunction("pages/OrderDetailDialog.qml", n)).join("\n")
        + "\nvar _pickerLookup = (" + literal(CODE, "readonly property var _pickerLookup", "{", "}") + ");"
        + "\nvar _pickerHooks = (" + literal(CODE, "readonly property var _pickerHooks", "{", "}") + ");";
    vm.createContext(sandbox);
    vm.runInContext(script, sandbox);
    dlg._pickerLinesNow = sandbox._pickerLinesNow;
    dlg._pickerCtx = sandbox._pickerCtx;
    dlg._pickerLookup = sandbox._pickerLookup;
    return { model, toasts, recomputes, label, dlg, apply: sandbox._applyPicked, hooks: sandbox._pickerHooks };
}
function viewOf(g, world, draft, extra) {
    return PM.build(Object.assign({ products: world.w.products, hooks: g.hooks, orderLines: g.dlg._pickerLinesNow(),
                                    draft: draft || {}, query: "", category: "All", inStockOnly: false }, extra || {}));
}

test("EOW-13 the real hooks, run against the real sheet model: hidden by the three store guards, sold out disabled, the pill counts the order's rows, a completed order frees its own units", () => {
    const world = fakeWorld();
    world.w.pendingMint.C = true; world.w.queuedRestock.D = true; world.w.syncState.E = "parked";
    const g = dialogGlue(world, [row("A", 2)], "pending");
    const v = viewOf(g, world, {});
    assert.deepEqual(plain(v.rows.map((r) => [r.productId, r.canAdd, r.maxQty])), [["A", true, 3], ["B", false, 0]]);
    assert.equal(v.hiddenCount, 3);
    assert.equal(v.rows[0].inOrderLabel, "In this order: 2 pcs");
    // the same product on a COMPLETED order that held 3 at completion: on-hand 5 + 3 - 2 now = 6
    const done = dialogGlue(fakeWorld(), [row("A", 2)], "completed", [{ productId: "A", quantity: 3, taxable: true, taxPercent: 5 }]);
    const w2 = fakeWorld();
    assert.equal(viewOf(done, w2, {}).rows.filter((r) => r.productId === "A")[0].maxQty, 6);
    // a pending order ignores that history
    const pend = dialogGlue(fakeWorld(), [row("A", 2)], "pending", [{ productId: "A", quantity: 3, taxable: true, taxPercent: 5 }]);
    assert.equal(viewOf(pend, w2, {}).rows.filter((r) => r.productId === "A")[0].maxQty, 3);
});

test("EOW-14 the real _applyPicked on a PENDING order: new rows get the current tax, a bump changes only the quantity, drift is clamped and toasted, one recompute per pick", () => {
    const world = fakeWorld();
    const g = dialogGlue(world, [row("A", 1, { price: 7.5, taxable: true, taxPercent: 18, discountType: "percent", discountValue: 10 })], "pending");
    const v = viewOf(g, world, PD.step(PD.step({}, "A", 2, 4), "C", 2, 9));
    assert.deepEqual(plain(v.canCommit), { ok: true, reason: "" });
    g.apply(PD.commitPlan(v.draft, g.dlg._pickerLinesNow()));
    assert.deepEqual(plain(g.model.rows[0]), plain(row("A", 3, { price: 7.5, taxable: true, taxPercent: 18, discountType: "percent", discountValue: 10 })), "bump: quantity only");
    assert.deepEqual(plain(g.model.rows[1]), { productId: "C", name: "Gamma", price: 5, quantity: 2, discountType: "flat", discountValue: 0, taxable: true, taxPercent: 12 });
    assert.deepEqual(g.recomputes, [2]);
    assert.equal(g.label.text, "");
    assert.deepEqual(g.toasts, []);
    // drift: A sold down to 3 elsewhere (the order already holds 3), E left the catalog
    world.w.products[0].stock = 3;
    world.w.products = world.w.products.filter((p) => p.productId !== "E");
    g.apply({ adds: [{ productId: "E", qty: 1 }], bumps: [{ productId: "A", qty: 1 }] });
    assert.deepEqual(plain(g.model.rows.map((r) => [r.productId, r.quantity])), [["A", 3], ["C", 2]]);
    assert.deepEqual(g.toasts, ["Alpha: out of stock (+1 more)"]);
    assert.equal(g.recomputes.length, 2, "still one recompute per pick, even when nothing was added");
});

test("EOW-15 the real _applyPicked on a COMPLETED order: a removed line returns at its BOOKED tax, a new product at the current tax, a bump is capped by on-hand plus the original units", () => {
    const world = fakeWorld();
    const original = [{ productId: "A", quantity: 3, taxable: true, taxPercent: 5 }, { productId: "C", quantity: 2, taxable: false, taxPercent: 0 }];
    // the order now holds only C (A was removed in this edit); A's current tax is 18, its booked tax is 5
    const g = dialogGlue(world, [row("C", 2, { taxable: false, taxPercent: 0 })], "completed", original);
    g.apply({ adds: [{ productId: "A", qty: 4 }, { productId: "D", qty: 1 }], bumps: [{ productId: "C", qty: 20 }] });
    assert.deepEqual(plain(g.model.rows.map((r) => [r.productId, r.quantity, r.taxable, r.taxPercent])),
        [["C", 11, false, 0], ["A", 4, true, 5], ["D", 1, false, 0]]);   // C: stock 9 + 2 held at completion = 11 now on the order
    assert.deepEqual(g.toasts, ["Gamma: only 9 of 20 added"]);
});

test("EOW-16 a row removed from the model is seen at once: the hooks and _applyPicked read the rows, never a copy", () => {
    const world = fakeWorld();
    const g = dialogGlue(world, [row("A", 2), row("C", 1)], "pending");
    assert.equal(g.hooks.inOrderQty("A"), 2);
    g.model.rows.splice(0, 1);                 // the delete button, before its deferred recompute has run
    assert.equal(g.hooks.inOrderQty("A"), 0);
    assert.equal(g.hooks.availableFor({ productId: "A", stock: 5 }), 5);
    g.apply({ adds: [{ productId: "A", qty: 1 }], bumps: [] });
    assert.deepEqual(plain(g.model.rows.map((r) => [r.productId, r.quantity])), [["C", 1], ["A", 1]]);
});
