"use strict";

// AddProductDialog's Save tap (atomic-ops AP3b, design 2026-11-20-ap3b-add-product-dialog-design.md).
//
// The dialog imports the Felgo chain and cannot be loaded under qmltestrunner, so the REAL body of `trySubmit()` and
// `_useTypedParty()` is cut out of qml/pages/AddProductDialog.qml and run here in a vm sandbox with fake controls and stores (same
// technique as restockDialogConfirm.test.js). The helpers (AddProductFlow, RestockFlow) are the real files.
//
//   SB-1..2    happy path; validation errors send nothing and never raise the busy overlay
//   SB-3..6    every answer: refused (with and without text), queued, unconfirmed, applied with a photo
//   SB-7..8    the supplier: picked row, typed new name, a name typed but never "Use"d
//   SB-9..11   failure handling: a throw before the answer, a throw after it, values captured at the tap
//   SB-12..13  the "Use" button
//   SB-14..16  source shape: no lenient parsers, no mint-before-add, argument order against the real store, dead signal gone

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, plain, extractFunction } = require("./testSupport/qmlHelpers");

const FILE = "pages/AddProductDialog.qml";
const ROOT = path.join(__dirname, "..", "..");
const DLG = fs.readFileSync(path.join(ROOT, "qml", FILE), "utf8");
const SUBMIT = extractFunction(FILE, "trySubmit");
const USE = extractFunction(FILE, "_useTypedParty");
const AF = load("AddProductFlow.js");
const RF = load("RestockFlow.js");

function rig(over) {
    const log = { toasts: [], closed: 0, calls: [], warns: [], categories: [], photos: [], refreshed: [], busyTrace: [] };
    let busy = false;
    const ctx = {
        dlg: { _supplierIds: ["", "SUP-1", "SUP-2"], _newSupplierName: "", _addPartyOpen: true, close() { log.closed++; }, _refreshSuppliers(id) { log.refreshed.push(id); } },
        pendingPhotoSource: "",
        nameField: { text: "Tomato" }, skuField: { text: "TO-1" }, sizeField: { text: "" }, descField: { text: "Red" },
        categoryCombo: { currentText: "Veg", currentIndex: 0 }, unitCombo: { currentText: "Kg" }, taxableCombo: { currentIndex: 0 },
        priceField: { text: "20" }, sellingPriceField: { text: "30" }, priceRow: { isMarkupSelected: false },
        stockField: { text: "5" }, minStockField: { text: "2" }, taxPercentField: { text: "0" }, addPartyField: { text: "" }, partyCombo: { currentIndex: 0 },
        errorLabel: { text: "" },
        AddProductFlow: AF, RestockFlow: RF,
        SupplierStore: { suppliers: [{ supplierId: "SUP-1", name: "Acme Farms" }] },
        CategoryStore: { setLastUsed(c) { log.categories.push(c); } },
        StorageService: { addProductPhoto(id, src) { log.photos.push([id, src]); return ctx._photoResult || { ok: true }; } },
        InventoryStore: {
            addProduct() { log.calls.push(Array.from(arguments)); if (ctx._onCall) ctx._onCall(Array.from(arguments)); },
            addDoneMessage(status, skipped) { return AF.doneText(status, skipped); }
        },
        Toast: { show(m) { if (ctx._toastThrows) throw new Error("toast"); log.toasts.push(m); } },
        console: { warn() { log.warns.push(Array.from(arguments)); } }
    };
    Object.defineProperty(ctx, "busy", { get() { return busy; }, set(v) { busy = v; log.busyTrace.push(v); }, enumerable: true });
    for (const k of Object.keys(over || {})) { if (over[k] === undefined) delete ctx[k]; else ctx[k] = over[k]; }
    vm.createContext(ctx);
    vm.runInContext(SUBMIT + "\n" + USE, ctx);
    return { ctx, log, tap: () => ctx.trySubmit(), answer: (...a) => log.calls[0][14](...a) };
}

// ---------------------------------------------------------------------------- SB-1, SB-2

test("SB-1 happy path: busy while waiting, the exact arguments, then toast, last-used category and close", () => {
    const r = rig();
    r.tap();
    assert.equal(r.ctx.busy, true);
    assert.equal(r.log.calls.length, 1);
    assert.deepEqual(r.log.calls[0].slice(0, 14), ["Tomato", "TO-1", "Veg", "Red", 20, "Kg", 5, 2, 30, false, 0, "", 20, ""]);
    assert.equal(r.log.calls[0].length, 15);
    r.answer(true, "PRD-001", undefined, "applied");
    assert.equal(r.ctx.busy, false);
    assert.deepEqual(r.log.toasts, ["Product added"]);
    assert.deepEqual(r.log.categories, ["Veg"]);
    assert.equal(r.log.closed, 1);
    assert.equal(r.ctx.errorLabel.text, "");
});

test("SB-2 a refused form sends nothing, never raises busy, and lists every problem", () => {
    const r = rig({ nameField: { text: "" }, priceField: { text: "1e3" }, stockField: { text: "2.5" } });
    r.tap();
    assert.equal(r.log.calls.length, 0);
    assert.deepEqual(r.log.busyTrace, [], "the busy overlay was never touched");
    assert.equal(r.ctx.errorLabel.text, "Enter a valid product name \u00b7 Enter a valid cost \u00b7 Enter the opening stock as a whole number (0 if none)");
    assert.equal(r.log.closed, 0);
    r.ctx.nameField.text = "Tomato"; r.ctx.priceField.text = "20"; r.ctx.stockField.text = "2";
    r.tap();
    assert.equal(r.ctx.errorLabel.text, "", "a good form clears the old message");
    assert.equal(r.log.calls.length, 1);
});

// ---------------------------------------------------------------------------- SB-3..6 answers

test("SB-3 refused by the store: its text shows, the sheet stays open and usable; without text the generic one", () => {
    const r = rig();
    r.tap(); r.answer(false, "", "Adding a product needs an internet connection. Connect and try again");
    assert.equal(r.ctx.errorLabel.text, "Adding a product needs an internet connection. Connect and try again");
    assert.equal(r.ctx.busy, false);
    assert.equal(r.log.closed, 0);
    assert.deepEqual(r.log.toasts, []);
    const q = rig(); q.tap(); q.answer(false, "", undefined);
    assert.equal(q.ctx.errorLabel.text, "Could not add product \u2014 try again");
    assert.equal(q.log.categories.length, 0, "a failed add does not set the last-used category");
});

test("SB-4 queued: saved wording, closes; a picked photo is reported as not attached", () => {
    const r = rig({ pendingPhotoSource: "file:///p.jpg" });
    r.tap(); r.answer(true, "", undefined, "queued");
    assert.deepEqual(r.log.toasts, [AF.doneText("queued", true)]);
    assert.deepEqual(r.log.photos, []);
    assert.equal(r.log.closed, 1);
    const n = rig(); n.tap(); n.answer(true, "", undefined, "queued");
    assert.deepEqual(n.log.toasts, [AF.doneText("queued", false)]);
});

test("SB-5 unconfirmed: the check-the-list wording, closes, no photo", () => {
    const r = rig({ pendingPhotoSource: "file:///p.jpg" });
    r.tap(); r.answer(true, "", undefined, "unconfirmed");
    assert.deepEqual(r.log.toasts, [AF.doneText("unconfirmed", true)]);
    assert.equal(r.log.closed, 1);
    assert.deepEqual(r.log.photos, []);
});

test("SB-6 applied with a photo: queued for the NEW id; a refused photo queue says so in the toast", () => {
    const r = rig({ pendingPhotoSource: "file:///p.jpg" });
    r.tap(); r.answer(true, "PRD-007", undefined, "applied");
    assert.deepEqual(r.log.photos, [["PRD-007", "file:///p.jpg"]]);
    assert.deepEqual(r.log.toasts, ["Product added"]);
    const bad = rig({ pendingPhotoSource: "file:///p.jpg", _photoResult: { ok: false, error: "queue-full" } });
    bad.tap(); bad.answer(true, "PRD-007", undefined, "applied");
    assert.deepEqual(bad.log.toasts, [AF.doneText("applied", true)]);
    assert.equal(bad.log.warns.length, 1);
    const noId = rig({ pendingPhotoSource: "file:///p.jpg" });
    noId.tap(); noId.answer(true, "", undefined, "applied");
    assert.deepEqual(noId.log.photos, [], "no id, no photo");
    assert.deepEqual(noId.log.toasts, [AF.doneText("applied", true)]);
});

// ---------------------------------------------------------------------------- SB-7, SB-8 supplier

test("SB-7 the supplier the store receives: nothing, the picked id, or the typed new name", () => {
    const party = (over) => { const r = rig(over); r.tap(); return plain(r.log.calls[0][11]); };
    assert.equal(party(), "");
    assert.equal(party({ partyCombo: { currentIndex: 2 } }), "SUP-2");
    assert.deepEqual(party({ dlg: { _supplierIds: ["", "SUP-1"], _newSupplierName: "Zed", close() {} } }), { newName: "Zed" });
    assert.equal(party({ partyCombo: { currentIndex: 7 } }), "", "an out-of-range pick is no supplier");
});

test("SB-8 a name typed in the new-supplier field but never sent with Use is refused, nothing is sent", () => {
    const r = rig({ addPartyField: { text: "Zed" } });
    r.tap();
    assert.equal(r.log.calls.length, 0);
    assert.equal(r.ctx.errorLabel.text, "You typed a new supplier name. Tap Use to add it, or clear the field");
    assert.deepEqual(r.log.busyTrace, []);
});

// ---------------------------------------------------------------------------- SB-9..11 failures

test("SB-9 a throw BEFORE the answer (the PR #183 bug class): busy is reset, the person is told, the sheet stays open", () => {
    const r = rig();
    r.ctx._onCall = () => { throw new Error("boom"); };
    r.tap();
    assert.equal(r.ctx.busy, false);
    assert.deepEqual(r.log.toasts, ["Something went wrong. Check the product list before adding again"]);
    assert.equal(r.log.closed, 0);
    assert.equal(r.log.warns.length, 1);
    const f = rig({ AddProductFlow: { fromForm() { throw new Error("form"); } } });
    f.tap();
    assert.equal(f.ctx.busy, false);
    assert.deepEqual(f.log.toasts, ["Something went wrong. Check the product list before adding again"]);
});

test("SB-10 a throw AFTER the answer: the callback already settled it, so no second message and busy is off", () => {
    const r = rig();
    r.ctx._onCall = (args) => { r.ctx._toastThrows = true; args[14](true, "PRD-1", undefined, "applied"); };
    r.tap();
    assert.equal(r.ctx.busy, false);
    assert.deepEqual(r.log.toasts, []);
    assert.equal(r.log.warns.length, 1);
    const sync = rig();
    sync.ctx._onCall = (args) => args[14](false, "", "No");
    sync.tap();
    assert.equal(sync.ctx.errorLabel.text, "No", "an answer that arrives inside the call is handled the same way");
    assert.equal(sync.ctx.busy, false);
});

test("SB-11 values are captured at the tap: editing the sheet while the add is in flight changes nothing", () => {
    const r = rig();
    r.tap();
    r.ctx.categoryCombo.currentText = "Fruit"; r.ctx.nameField.text = "Other";
    r.answer(true, "PRD-1", undefined, "applied");
    assert.deepEqual(r.log.categories, ["Veg"], "the category booked is the one that was added");
});

// ---------------------------------------------------------------------------- SB-12, SB-13 Use

test("SB-12 Use with a new name holds it, clears the field and closes the row; nothing is created", () => {
    const r = rig({ addPartyField: { text: "  Zed Traders " } });
    r.ctx._useTypedParty();
    assert.equal(r.ctx.dlg._newSupplierName, "Zed Traders");
    assert.equal(r.ctx.partyCombo.currentIndex, 0);
    assert.equal(r.ctx.addPartyField.text, "");
    assert.equal(r.ctx.dlg._addPartyOpen, false);
    assert.deepEqual(r.log.refreshed, []);
    assert.deepEqual(r.log.toasts, []);
});

test("SB-13 Use with a known name selects that row (any case), empty does nothing, too long is refused", () => {
    const known = rig({ addPartyField: { text: "ACME farms" } });
    known.ctx.dlg._newSupplierName = "Old";
    known.ctx._useTypedParty();
    assert.equal(known.ctx.dlg._newSupplierName, "");
    assert.deepEqual(known.log.refreshed, ["SUP-1"]);
    const none = rig({ addPartyField: { text: "   " } });
    none.ctx._useTypedParty();
    assert.equal(none.ctx.dlg._addPartyOpen, true);
    assert.deepEqual(none.log.toasts, []);
    const long = rig({ addPartyField: { text: "x".repeat(101) } });
    long.ctx._useTypedParty();
    assert.deepEqual(long.log.toasts, [RF.refusalText("supplier-too-long")]);
    assert.equal(long.ctx.dlg._newSupplierName, "");
    assert.equal(long.ctx.dlg._addPartyOpen, true, "the row stays open so the name can be fixed");
});

// ---------------------------------------------------------------------------- SB-14..16 source shape

test("SB-14 the dialog never mints a supplier before the add, never reads a number with the lenient parsers, and has no dead signal", () => {
    assert.doesNotMatch(DLG, /SupplierStore\.addSupplier/);
    assert.doesNotMatch(DLG, /parseFloat\(|parseInt\(/);
    assert.doesNotMatch(DLG, /productCreated/);
    assert.doesNotMatch(DLG, /getSellingPrice/);
    assert.match(DLG, /import "\.\.\/helper\/AddProductFlow\.js" as AddProductFlow/);
    assert.match(DLG, /import "\.\.\/helper\/RestockFlow\.js" as RestockFlow/);
    assert.match(DLG, /text: qsTr\("Use"\)[\s\S]{0,220}onClicked: dlg\._useTypedParty\(\)/);
    assert.match(DLG, /onActivated: dlg\._newSupplierName = ""/);
    assert.match(DLG, /dlg\._newSupplierName = ""\n\s+advToggle\.open = true/, "the sheet forgets a held name every time it opens");
    for (const [field, limit] of [["nameField", "MAX_NAME"], ["skuField", "MAX_SKU"], ["sizeField", "MAX_SIZE"], ["descField", "MAX_DESCRIPTION"]])
        assert.match(DLG, new RegExp("id: " + field + "[\\s\\S]{0,260}maximumLength: AddProductFlow\\." + limit));
    assert.match(DLG, /id: addPartyField[\s\S]{0,200}maximumLength: RestockFlow\.MAX_SUPPLIER_NAME/);
    assert.match(DLG, /AddProductFlow\.priceSummary\(priceField\.text, sellingPriceField\.text, false\)/);
    assert.match(DLG, /AddProductFlow\.priceSummary\(priceField\.text, sellingPriceField\.text, true\)/);
});

test("SB-15 the call the dialog makes matches InventoryStore.addProduct's real parameter list, in order", () => {
    const store = fs.readFileSync(path.join(ROOT, "qml", "model", "InventoryStore.qml"), "utf8");
    const m = /function addProduct\(([^)]*)\)/.exec(store);
    const params = m[1].split(",").map((p) => p.trim());
    assert.deepEqual(params, ["name", "sku", "category", "description", "price", "unit", "stock", "minStock", "sellingPrice", "taxable", "taxPercent", "party", "unitCost", "size", "callback"]);
    const r = rig(); r.tap();
    const a = r.log.calls[0];
    assert.equal(a.length, params.length);
    const named = Object.fromEntries(params.map((p, i) => [p, a[i]]));
    assert.equal(named.name, "Tomato"); assert.equal(named.price, 20); assert.equal(named.sellingPrice, 30); assert.equal(named.stock, 5);
    assert.equal(named.minStock, 2); assert.equal(named.unitCost, 20); assert.equal(named.size, ""); assert.equal(typeof named.callback, "function");
});

test("SB-16 the sheet shows what Save will read: the stock fields take digits only and the reorder hint is the real default", () => {
    assert.match(DLG, /id: stockField[\s\S]{0,420}inputMethodHints: Qt\.ImhDigitsOnly/);
    assert.match(DLG, /id: minStockField[\s\S]{0,420}placeholderText: "0"/);
    assert.doesNotMatch(DLG, /id: minStockField[\s\S]{0,420}placeholderText: "2"/);
});

// ---------------------------------------------------------------------------- SB-17, SB-18 review sweep 1 of PR 207

test("SB-17 a throw in a side effect after the answer never skips the toast or the close (a second tap would add a SECOND product)", () => {
    const cat = rig({ CategoryStore: { setLastUsed() { throw new Error("cat"); } } });
    cat.tap(); cat.answer(true, "PRD-1", undefined, "applied");
    assert.deepEqual(cat.log.toasts, ["Product added"]);
    assert.equal(cat.log.closed, 1);
    assert.equal(cat.ctx.busy, false);
    assert.equal(cat.log.warns.length, 1);

    const photo = rig({ pendingPhotoSource: "file:///p.jpg", StorageService: { addProductPhoto() { throw new Error("queue"); } } });
    photo.tap(); photo.answer(true, "PRD-1", undefined, "applied");
    assert.deepEqual(photo.log.toasts, [AF.doneText("applied", true)], "the toast says the photo was not added");
    assert.equal(photo.log.closed, 1);
    assert.equal(photo.log.warns.length, 1);

    const late = rig();
    late.tap();
    late.ctx._toastThrows = true;
    assert.throws(() => late.answer(true, "PRD-1", undefined, "applied"), /toast/, "the throw still surfaces (nothing is swallowed)");
    assert.equal(late.log.closed, 1, "but the sheet is closed");
    assert.equal(late.ctx.busy, false);
});

test("SB-18 source shape: the new-supplier label is translatable as ONE string, and the close is in a finally", () => {
    assert.match(DLG, /qsTr\("New: %1"\)\.arg\(dlg\._newSupplierName\)/);
    assert.doesNotMatch(DLG, /qsTr\("New: "\)\s*\+/);
    assert.match(SUBMIT, /finally\s*\{\s*dlg\.close\(\)\s*\}/);
});

