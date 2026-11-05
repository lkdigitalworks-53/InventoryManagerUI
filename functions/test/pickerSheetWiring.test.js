"use strict";
// Picker v2, slice S2: source pins for the Felgo view layer, which qmltestrunner cannot load (Skill 83), plus the
// dormancy of the S2 files. WIRE-01..16. Plan: docs/superpowers/plans/2026-11-04-product-picker-v2-s2-sheet-component.md.
// These read the QML text, so they pin WIRING, not painting: what the on-device plan checks is how it looks.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("./testSupport/qmlHelpers");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const SHEET = read("qml/components/ProductPickerSheet.qml");
const ROW = read("qml/components/ProductPickerRow.qml");
const BOTTOM = read("qml/components/BottomSheet.qml");
const PM = load("PickerSheetModel.js");
const PD = load("PickerDraft.js");
const PG = load("PickerRowGeometry.js");

// Body of `<head> { ... }` by brace matching from the first "{" after the head.
function block(src, head) {
    const at = src.indexOf(head);
    assert.ok(at >= 0, head + " not found");
    const open = src.indexOf("{", at);
    let depth = 0, i = open;
    for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
    return src.substring(open + 1, i);
}
const noComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/(\s)\/\/ .*$/gm, "$1");

function walk(dir, out) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, e.name);
        if (e.isDirectory()) walk(full, out);
        else if (/\.qml$/.test(e.name)) out.push(full);
    }
    return out;
}
const ALL_QML = walk(path.join(ROOT, "qml"), []).map((f) => path.relative(ROOT, f).split(path.sep).join("/"));

test("WIRE-01 BottomSheet: both new properties are opt-in and off by default for every other sheet", () => {
    assert.match(BOTTOM, /property bool scrollBody: true/);
    assert.match(BOTTOM, /property bool guardClose: false/);
    assert.match(BOTTOM, /signal closeRequested\(\)/);
});

test("WIRE-02 BottomSheet: the two Bindings act only while scrollBody is false", () => {
    const bindings = BOTTOM.match(/Binding \{[^}]*\}/g) || [];
    assert.equal(bindings.length, 2);
    for (const b of bindings) assert.match(b, /when: !root\.scrollBody/);
    assert.ok(bindings.some((b) => /target: scroller; property: "contentHeight"; value: scroller\.availableHeight/.test(b)));
    assert.ok(bindings.some((b) => /target: bodyHolder; property: "height"; value: scroller\.availableHeight/.test(b)));
});

test("WIRE-03 BottomSheet: every close path goes through requestClose, busy first, and only guardClose asks the owner", () => {
    const fn = block(BOTTOM, "function requestClose()");
    assert.ok(fn.indexOf("if (busy) return") < fn.indexOf("closeRequested()"), "busy must be checked before asking");
    assert.match(fn, /if \(guardClose\) closeRequested\(\)\s*else close\(\)/);
    assert.match(BOTTOM, /closePolicy: \(busy \|\| guardClose\) \? QQC\.Popup\.NoAutoClose/);
    assert.match(BOTTOM, /onClicked: root\.requestClose\(\)/);
    assert.match(BOTTOM, /root\.secondaryClicked\(\); root\.requestClose\(\)/);
    // the Keys handlers must not accept the event when guardClose is false, so the Popup's own handling is unchanged
    assert.equal((BOTTOM.match(/event\.accepted = root\.guardClose/g) || []).length, 2);
    assert.match(BOTTOM, /MouseArea \{ anchors\.fill: parent; enabled: root\.guardClose; onClicked: root\.requestClose\(\) \}/);
});

test("WIRE-04 BottomSheet: nothing else in the app sets scrollBody or guardClose, and nothing overrides requestClose", () => {
    const users = ALL_QML.filter((f) => /\b(scrollBody|guardClose|requestClose)\b/.test(read(f)));
    assert.deepEqual(users, ["qml/components/BottomSheet.qml", "qml/components/ProductPickerSheet.qml"]);
});

test("WIRE-05 the sheet is a BottomSheet with the picker settings", () => {
    assert.match(SHEET, /\nBottomSheet \{\s*\n\s*id: root/);
    assert.match(SHEET, /scrollBody: false/);
    assert.match(SHEET, /guardClose: true/);
    assert.match(SHEET, /focus: true/);
    assert.match(SHEET, /primaryAction: qsTr\("Add to order"\)/);
    assert.match(SHEET, /primaryEnabled: _view !== null && _view\.canCommit\.ok/);
});

test("WIRE-06 the list is a ListView over a ListModel, never a Repeater or a ScrollView", () => {
    const code = noComments(SHEET);
    assert.match(code, /ListModel \{ id: listModel \}/);
    assert.match(code, /ListView \{\s*\n\s*id: list/);
    assert.match(code, /model: listModel/);
    assert.doesNotMatch(code, /Repeater|ScrollView/);
});

test("WIRE-07 the row asks for exactly the roles the view model produces, and reads no implicit index or modelData", () => {
    const required = [...ROW.matchAll(/^\s*required property (\w+) (\w+)$/gm)].map((m) => m[2]).sort();
    const sample = PM.build({
        products: [{ productId: "A", name: "n", stock: 3 }],
        hooks: { hasPendingMint: () => false, unsyncedState: () => "", availableFor: (p) => p.stock },
        orderLines: [], draft: {}, query: "", category: "All", inStockOnly: false
    });
    assert.deepEqual(required, Object.keys(sample.rows[0]).sort());
    assert.doesNotMatch(noComments(ROW), /\bindex\b|\bmodelData\b/);
    // The row's own `enabled` would clash with Item.enabled: the role is canAdd.
    assert.doesNotMatch(ROW, /required property bool enabled/);
});

test("WIRE-08 the sheet decides nothing itself: it calls the tested helpers for rows, steps, typing, plan and categories", () => {
    for (const call of ["Model.build(", "Model.sameOrder(", "Model.categories(", "Draft.step(", "Draft.setQty(", "Draft.commitPlan("])
        assert.ok(SHEET.includes(call), "missing " + call);
    assert.match(SHEET, /import "\.\.\/helper\/PickerDraft\.js" as Draft/);
    assert.match(SHEET, /import "\.\.\/helper\/PickerSheetModel\.js" as Model/);
    assert.doesNotMatch(noComments(SHEET), /ProductSearch|ProductPickability/);
});

test("WIRE-09 the sheet knows no store: only formatCurrency is read, everything else comes in as a property", () => {
    const code = noComments(SHEET);
    assert.doesNotMatch(code, /StockBatchStore|OutboxStore|OrdersStore|DataModel|AuthStore|StorageService/);
    const stores = [...code.matchAll(/InventoryStore\.(\w+)/g)].map((m) => m[1]);
    assert.deepEqual([...new Set(stores)], ["formatCurrency"]);
    for (const p of ["property var products", "property var hooks", "property var orderLines", "property int revision", "signal committed(var plan)"])
        assert.ok(SHEET.includes(p), "missing " + p);
});

test("WIRE-10 live refresh: every external input schedules one coalesced rebuild", () => {
    for (const h of ["onProductsChanged", "onHooksChanged", "onOrderLinesChanged", "onRevisionChanged"])
        assert.match(SHEET, new RegExp(h + ": _later\\(\\)"));
    assert.match(SHEET, /function _later\(\) \{ if \(opened\) Qt\.callLater\(rebuild, false\) \}/);
    assert.match(SHEET, /onOpened: rebuild\(true\)/);
});

test("WIRE-11 commit: re-read first, stop unless the gate is ok, hand over the plan, close without the discard question", () => {
    const body = block(SHEET, "onPrimaryClicked:");
    const at = (s) => body.indexOf(s);
    assert.ok(at("rebuild(false)") >= 0 && at("rebuild(false)") < at("canCommit.ok"), "rebuild must come before the gate");
    assert.ok(at("canCommit.ok") < at("Draft.commitPlan("), "the gate must come before the plan");
    assert.ok(at("Draft.commitPlan(") < at("root.committed(plan)") && at("root.committed(plan)") < at("root.close()"));
    assert.doesNotMatch(body, /requestClose|closeRequested|discardConfirm/);
});

test("WIRE-12 closing: no question for an empty draft, a Discard question with a danger button for a drafted one, a clean reset after", () => {
    const body = block(SHEET, "onCloseRequested:");
    assert.match(body, /if \(n <= 0\) \{ root\.close\(\); return \}/);
    assert.match(body, /discardConfirm\.ask\(/);
    assert.match(body, /onConfirm: function\(\) \{ root\.close\(\) \}/);
    assert.match(SHEET, /ConfirmDialog \{ id: discardConfirm \}/);
    const reset = block(SHEET, "onClosed:");
    for (const s of ["_draft = ({})", '_query = ""', '_category = "All"', "_inStockOnly = false", "listModel.clear()", "_view = null"])
        assert.ok(reset.includes(s), "onClosed does not reset " + s);
});

test("WIRE-13 the row: targets sized by the geometry, digits only and six at most, asks instead of editing", () => {
    const code = noComments(ROW);
    assert.match(code, /import "\.\.\/helper\/PickerRowGeometry\.js" as Geo/);
    assert.match(code, /Geo\.layout\(width, dp\(1\), maxQty, _fontScale\)/);
    assert.match(code, /implicitWidth: root\._geo\.minus/);
    assert.match(code, /implicitHeight: root\._geo\.minus/);
    assert.match(code, /implicitWidth: root\._geo\.plus/);
    assert.match(code, /implicitHeight: root\._geo\.fieldHeight/);
    assert.match(code, /inputMethodHints: Qt\.ImhDigitsOnly/);
    assert.match(code, new RegExp("maximumLength: " + PD.MAX_DIGITS + "\\b"));
    assert.match(code, new RegExp("\\[0-9\\]\\{0," + PD.MAX_DIGITS + "\\}"));
    assert.match(code, /signal stepRequested\(string productId, int delta, int maxQty\)/);
    assert.match(code, /signal qtyTyped\(string productId, string text, int maxQty\)/);
    assert.doesNotMatch(code, /Draft|PickerDraft|Store\.(?!formatCurrency)/);
});

test("WIRE-14 the row and the geometry agree with the draft on how many digits a quantity may have", () => {
    assert.equal(PG.MAX_DIGITS, PD.MAX_DIGITS);
});

test("WIRE-15 dormant: only the S2 files and their tests mention the new component and helper names", () => {
    const allowed = new Set([
        "qml/components/ProductPickerSheet.qml", "qml/components/ProductPickerRow.qml",
        "qml/helper/PickerSheetModel.js", "qml/helper/PickerRowGeometry.js",
    ]);
    const names = /ProductPickerSheet|ProductPickerRow|PickerSheetModel|PickerRowGeometry/;
    const offenders = ALL_QML.concat(["main.cpp", "CMakeLists.txt"]).concat(
        fs.readdirSync(path.join(ROOT, "qml", "helper")).filter((n) => n.endsWith(".js")).map((n) => "qml/helper/" + n))
        .filter((f, i, a) => a.indexOf(f) === i && fs.existsSync(path.join(ROOT, f)))
        .filter((f) => !allowed.has(f))
        .filter((f) => names.test(read(f)));
    assert.deepEqual(offenders, []);
});

test("WIRE-16 the new and changed QML files are balanced: braces, parentheses and brackets", () => {
    for (const f of ["qml/components/ProductPickerSheet.qml", "qml/components/ProductPickerRow.qml", "qml/components/BottomSheet.qml",
                     "qml/helper/PickerSheetModel.js", "qml/helper/PickerRowGeometry.js"]) {
        // drop strings, regex literals used here and comments, then count
        const src = noComments(read(f)).replace(/"(?:\\.|[^"\\])*"/g, '""').replace(/\/\[[^\n]*?\/(?=\s*\})/g, "");
        for (const [open, close] of [["{", "}"], ["(", ")"], ["[", "]"]]) {
            const o = src.split(open).length - 1, c = src.split(close).length - 1;
            assert.equal(o, c, f + ": " + open + close + " unbalanced (" + o + " vs " + c + ")");
        }
    }
});
