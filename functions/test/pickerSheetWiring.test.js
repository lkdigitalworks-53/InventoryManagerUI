"use strict";
// Picker v2, slice S2: source pins for the Felgo view layer, which qmltestrunner cannot load (Skill 83), plus the
// dormancy of the S2 files. WIRE-01..24. Plan: docs/superpowers/plans/2026-11-04-product-picker-v2-s2-sheet-component.md.
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
    assert.match(SHEET, /primaryEnabled: !_committed && _view !== null && _view\.canCommit\.ok/);
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
    for (const call of ["Model.build(", "Model.sameOrder(", "Model.sameList(", "Model.changedRows(", "Model.categories(", "Draft.step(", "Draft.setQty(", "Draft.commitPlan("])
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
    assert.match(SHEET, /function _later\(\) \{ if \(_live && !_committed\) Qt\.callLater\(rebuild, false\) \}/);
    assert.doesNotMatch(noComments(SHEET), /if \(opened\)|root\.opened/, "Popup.opened is true only after the slide-in: never gate on it");
});

test("WIRE-11 commit: latch first, re-read, stop unless the gate is ok, hand over the plan once, close without the discard question", () => {
    const body = block(SHEET, "onPrimaryClicked:");
    const at = (s) => body.indexOf(s);
    assert.ok(at("if (_committed) return") === body.indexOf("if (_committed)") && at("if (_committed) return") >= 0 && at("if (_committed) return") < at("rebuild(false)"),
        "a second tap during the fade-out must return before anything else");
    assert.ok(at("rebuild(false)") >= 0 && at("rebuild(false)") < at("canCommit.ok"), "rebuild must come before the gate");
    assert.ok(at("canCommit.ok") < at("Draft.commitPlan("), "the gate must come before the plan");
    assert.ok(at("Draft.commitPlan(") < at("_committed = true") && at("_committed = true") < at("root.committed(plan)"), "latch before the hand-over");
    assert.ok(at("root.committed(plan)") < at("root.close()"));
    assert.equal((body.match(/root\.committed\(plan\)/g) || []).length, 1);
    assert.doesNotMatch(body, /requestClose|closeRequested|discardConfirm/);
});

test("WIRE-12 closing: no question for an empty draft or a committed sheet, a Discard question with a danger button for a drafted one, a clean reset after", () => {
    const body = block(SHEET, "onCloseRequested:");
    assert.ok(body.indexOf("if (_committed) return") >= 0 && body.indexOf("if (_committed) return") < body.indexOf("discardConfirm.ask("), "a committed sheet must not ask");
    assert.match(body, /if \(n <= 0\) \{ root\.close\(\); return \}/);
    assert.match(body, /discardConfirm\.ask\(/);
    assert.match(body, /onConfirm: function\(\) \{ root\.close\(\) \}/);
    assert.match(SHEET, /ConfirmDialog \{ id: discardConfirm \}/);
    assert.match(SHEET, /onClosed: _reset\(\)/);
    const reset = block(SHEET, "function _reset()");
    for (const s of ["_committed = false", "_draft = ({})", '_query = ""', '_category = "All"', "_inStockOnly = false", "listModel.clear()", "_ids = []", "_rows = []", "_view = null"])
        assert.ok(reset.includes(s), "_reset does not reset " + s);
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

test("WIRE-15 only the S2 files and, since S3 and S4, the two order dialogs mention the new component and helper names", () => {
    const allowed = new Set([
        "qml/components/ProductPickerSheet.qml", "qml/components/ProductPickerRow.qml",
        "qml/helper/PickerSheetModel.js", "qml/helper/PickerRowGeometry.js",
        "qml/pages/NewOrderDialog.qml",   // S3, on purpose
        "qml/pages/OrderDetailDialog.qml",   // S4, on purpose
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

test("WIRE-17 refresh cost: the chips array is replaced only when the categories changed, and only changed rows are set", () => {
    const rebuild = block(SHEET, "function rebuild(resetScroll)");
    assert.match(rebuild, /var chipList = Model\.categories\(products\)/);
    assert.match(rebuild, /if \(!Model\.sameList\(_chips, chipList\)\) _chips = chipList/);
    assert.doesNotMatch(rebuild, /_chips = Model\.categories/);
    const sync = block(SHEET, "function _syncList(rows, resetScroll)");
    assert.match(sync, /Model\.changedRows\(_rows, rows\)/);
    assert.match(sync, /listModel\.set\(changed\[i\], rows\[changed\[i\]\]\)/);
    assert.doesNotMatch(sync, /listModel\.set\(i, rows\[i\]\)/, "every row must not be set on every refresh");
    // _rows follows the list in both branches (in place and rebuilt whole) and is cleared with it
    assert.equal((sync.match(/_rows = rows/g) || []).length, 2);
});

test("WIRE-18 the in-stock toggle: the tap and both accessibility actions use one function", () => {
    assert.match(SHEET, /function _toggleStock\(\) \{ stockToggle\.checked = !stockToggle\.checked; _inStockOnly = stockToggle\.checked; rebuild\(true\) \}/);
    const toggle = block(SHEET, "Rectangle {\n            id: stockToggle");
    assert.match(toggle, /Accessible\.onPressAction: root\._toggleStock\(\)/);
    assert.match(toggle, /Accessible\.onToggleAction: root\._toggleStock\(\)/);
    assert.match(toggle, /onClicked: root\._toggleStock\(\)/);
    assert.equal((noComments(SHEET).match(/_inStockOnly = stockToggle\.checked/g) || []).length, 1, "one place changes the filter");
});

test("WIRE-19 every open starts clean, including a reopen during the fade-out of a committed or discarded sheet", () => {
    const c = block(SHEET, "Connections {");
    assert.match(c, /target: root/);
    assert.match(c, /function onAboutToShow\(\) \{ root\._reset\(\); root\._live = true; root\.rebuild\(true\) \}/);
    assert.match(c, /function onAboutToHide\(\) \{ root\._live = false \}/);
    assert.match(SHEET, /property bool _committed: false/);
});

test("WIRE-20 search: the query is taken at once, the list is rebuilt after a pause, Clear search rebuilds at once, close cancels the timer", () => {
    assert.match(SHEET, /Timer \{ id: searchDebounce; interval: 150; onTriggered: if \(root\._live\) root\.rebuild\(true\) \}/);
    const field = block(SHEET, "SearchField {");
    assert.match(field, /onTextChanged: \{ root\._query = text; searchDebounce\.restart\(\) \}/);
    assert.doesNotMatch(field, /rebuild\(/, "a key must not rebuild the list directly");
    assert.match(SHEET, /onClicked: \{ searchField\.text = ""; searchDebounce\.stop\(\); root\.rebuild\(true\) \}/);
    const reset = block(SHEET, "function _reset()");
    assert.ok(reset.indexOf('searchField.text = ""') >= 0 && reset.indexOf("searchDebounce.stop()") > reset.indexOf('searchField.text = ""'), "the timer must be stopped after the field is cleared");
    assert.equal((noComments(SHEET).match(/searchDebounce\.restart\(\)/g) || []).length, 1);
});

test("WIRE-21 the row names the unit next to the price and in the quantity field's name, and reads no removed role", () => {
    assert.match(ROW, /qsTr\("%1 \/ %2"\)\.arg\(InventoryStore\.formatCurrency\(root\.price\)\)\.arg\(root\.unit\)/);
    assert.match(ROW, /Accessible\.name: qsTr\("Quantity of %1, in %2"\)\.arg\(root\.name\)\.arg\(root\.unit\)/);
    for (const role of ["available", "inOrder", "reason"])
        assert.doesNotMatch(ROW, new RegExp("required property \\w+ " + role + "$", "m"), role + " is a dead role again");
});

test("WIRE-22 the list is built before the slide-in, through a Connections (a derived onAboutToShow would replace BottomSheet's slide-up)", () => {
    const code = noComments(SHEET);
    assert.doesNotMatch(code, /^\s*onAboutToShow:/m, "a handler here replaces BottomSheet's own");
    assert.doesNotMatch(code, /^\s*onAboutToHide:/m);
    assert.match(BOTTOM, /onAboutToShow: \{/, "the base handler this sheet must not replace");
    assert.match(code, /onOpened: \{ if \(_view === null\) \{ _live = true; rebuild\(true\) \} \}/, "fallback: never a blank sheet");
    assert.match(code, /property bool _live: false/);
    assert.match(block(SHEET, "function _reset()"), /_live = false/);
});

test("WIRE-23 rebuild is a no-op unless the sheet is live and has not handed its plan over (late refresh, late debounce)", () => {
    const body = block(SHEET, "function rebuild(resetScroll)");
    assert.match(body.trim().split("\n")[0], /if \(!_live \|\| _committed\) return/);
    const commit = block(SHEET, "onPrimaryClicked:");
    assert.ok(commit.indexOf("rebuild(false)") >= 0 && commit.indexOf("rebuild(false)") < commit.indexOf("_committed = true"),
        "the commit path re-reads while live, before the latch is set");
});

test("WIRE-24 the in-stock switch only paints: not focusable, hidden from accessibility, so the row is the one control", () => {
    const toggle = block(SHEET, "id: stockToggle");
    const sw = block(toggle.substring(toggle.indexOf("QQC.Switch")), "QQC.Switch {");
    assert.match(sw, /focusPolicy: Qt\.NoFocus/);
    assert.match(sw, /Accessible\.ignored: true/);
    assert.doesNotMatch(sw, /onToggled|onClicked/, "the switch never changes the filter itself");
});
