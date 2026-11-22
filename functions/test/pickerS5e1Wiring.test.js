"use strict";
// Picker v2, slice S5e-1: the sheet's controls speak (TalkBack) and are big enough to hit. S5E1-01..11.
// Plan: docs/superpowers/plans/2026-11-22-product-picker-v2-s5e1-talkback-and-targets.md. Like the S5c wiring test these
// read the QML text (qmltestrunner cannot load Felgo) and RUN the real glue (the row's name binding, the chip's
// `spoken` and `choose`) in a sandbox against the real helper, so the glue is executed, not just read. They pin WIRING,
// not what Android does with it: whether TalkBack reads and acts is the on-device plan (checks 141 to 149).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, extractFunction } = require("./testSupport/qmlHelpers");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const noComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/(\s)\/\/ .*$/gm, "$1");
const ROW = noComments(read("qml/components/ProductPickerRow.qml"));
const CHIPS = noComments(read("qml/components/ChipScroller.qml"));
const SEARCH = noComments(read("qml/components/SearchField.qml"));
const BOTTOM = noComments(read("qml/components/BottomSheet.qml"));
const SP = load("PickerSpeech.js");

// The text from the first `open` after `head` to its matching `close`, both included.
function literal(src, head, open, close) {
    const at = src.indexOf(head);
    assert.ok(at >= 0, head + " not found");
    const start = src.indexOf(open, at);
    let depth = 0, i = start;
    for (; i < src.length; i++) { if (src[i] === open) depth++; else if (src[i] === close && --depth === 0) break; }
    return src.substring(start, i + 1);
}
// Every `head {` block of a QML text, braces included.
function blocks(src, head) {
    const out = [];
    let from = 0;
    for (;;) {
        const at = src.indexOf(head, from);
        if (at < 0) break;
        const b = literal(src.substring(at), head, "{", "}");
        out.push(b);
        from = at + head.length + b.length;
    }
    return out;
}
const run = (expr, box) => vm.runInNewContext("(" + expr + ")", box);

test("S5E1-01 the row's spoken name is Speech.row over ten named row properties and the formatted price", () => {
    assert.match(ROW, /import "\.\.\/helper\/PickerSpeech\.js" as Speech/);
    assert.ok(!/Accessible\.name:\s*name \+ ", "/.test(ROW), "the old concatenation (no price, no quantity) is still there");
    const args = literal(ROW, "Accessible.name: Speech.row", "(", ")");
    const keys = ["name", "productId", "unit", "price", "pillLabel", "inOrderLabel", "qty", "atMax", "canAdd", "reasonText"];
    for (const k of keys) assert.match(args, new RegExp("\\b" + k + ": root\\." + k + "\\b"), "row property " + k + " is not passed as root." + k);
    assert.match(args, /InventoryStore\.formatCurrency\(root\.price\)/);
    assert.equal((args.match(/\broot\.\w+/g) || []).length, keys.length + 1, "an unexpected property is read in the binding");
});
test("S5E1-02 the name binding, run against a row double, says what Speech.row says for that row", () => {
    const args = literal(ROW, "Accessible.name: Speech.row", "(", ")");
    const mk = (over) => Object.assign({ name: "Basmati Rice", productId: "P-101", unit: "kg", price: 120, pillLabel: "8 kg left",
        inOrderLabel: "In this order: 1 kg", qty: 3, atMax: false, canAdd: true, reasonText: "" }, over);
    const world = (root) => ({ Speech: SP, root, InventoryStore: { formatCurrency: (n) => "Rs " + n.toFixed(2) } });
    assert.equal(run("Speech.row" + args, world(mk())), "Basmati Rice, P-101, Rs 120.00 per kg, 8 kg left, In this order: 1 kg, 3 selected");
    assert.equal(run("Speech.row" + args, world(mk({ canAdd: false, price: 0, pillLabel: "No price", reasonText: "No selling price", qty: 0, inOrderLabel: "" }))),
        "Basmati Rice, P-101, No price, No selling price");
});
test("S5E1-03 each chip is ONE accessible radio button: named, checked when selected, with a press action", () => {
    const chip = blocks(CHIPS, "delegate: Item")[0];
    assert.ok(chip, "the chip delegate is not an Item");
    assert.match(chip, /Accessible\.role: Accessible\.RadioButton/);
    assert.match(chip, /Accessible\.name: chip\.spoken/);
    assert.match(chip, /Accessible\.checked: chip\.isOn/);
    assert.match(chip, /Accessible\.onPressAction: chip\.choose\(\)/);
    assert.match(chip, /MouseArea\s*\{[^}]*onClicked: chip\.choose\(\)/s, "a tap and the press action must be the same code");
    assert.match(chip, /id: chipText[^}]*Accessible\.ignored: true/s, "the painted text is a second, silent stop for TalkBack");
});
test("S5E1-04 chip.spoken: the label, then the count after a comma only when there is one", () => {
    const expr = /readonly property string spoken:\s*([\s\S]*?)\n\s*\n/.exec(CHIPS)[1].trim();
    const say = (entry) => run(expr, { chip: { entry } });
    assert.equal(say({ label: "All" }), "All");
    assert.equal(say({ label: "Pending", count: 3 }), "Pending, 3");
    assert.equal(say({ label: "Completed", count: 0 }), "Completed, 0", "a zero count is still a count");
});
test("S5E1-05 chip.choose sets the selection first and then emits the index and the label", () => {
    const fn = noComments(extractFunction("components/ChipScroller.qml", "choose"));
    const log = [];
    const box = { index: 2, chip: { enabled: true, entry: { label: "Pending" } }, root: { selected: 0, chipSelected: (i, l) => log.push([i, l, box.root.selected]) } };
    vm.createContext(box);
    vm.runInContext(fn, box);
    vm.runInContext("choose()", box);
    assert.deepEqual(log, [[2, "Pending", 2]], "the signal must see the new selection, once");
});
test("S5E1-06 a chip is a 48 dp target around a pill of 32 dp or more, and the row grows with the pill instead of clipping it", () => {
    assert.match(CHIPS, /implicitHeight: Math\.max\(dp\(48\), _pillHeight \+ dp\(8\)\)/);
    assert.ok(!/implicitHeight: dp\(40\)/.test(CHIPS), "the old 40 dp row is back");
    assert.match(CHIPS, /readonly property real _pillHeight: Math\.max\(dp\(32\), lineMetrics\.height \+ dp\(12\)\)/);
    assert.match(CHIPS, /TextMetrics \{ id: lineMetrics; font\.pixelSize: sp\(Constants\.fsSmall\); font\.bold: true;/, "the measured font must be the chip's font");
    assert.match(CHIPS, /id: chipText[\s\S]*?font\.pixelSize: sp\(Constants\.fsSmall\)\s*font\.bold: true/);
    assert.match(CHIPS, /id: pill[\s\S]*?height: root\._pillHeight/);
    assert.match(CHIPS, /height: root\.implicitHeight/, "the chip's touch area is the row height");
    assert.match(CHIPS, /width: pill\.width/);
    // The sums, run: the row is never shorter than 48 and never shorter than the pill plus 4 on each side.
    const rowFor = (line) => Math.max(48, Math.max(32, line + 12) + 8);
    for (const line of [10, 14, 17, 29, 37, 44, 60]) assert.ok(rowFor(line) >= 48 && rowFor(line) >= Math.max(32, line + 12) + 8, "row too short for a line of " + line);
});
test("S5E1-07 every consumer of ChipScroller takes the new height as it is: none pins a height of its own", () => {
    const users = ["qml/pages/StockRegisterPage.qml", "qml/pages/InventoryPage.qml", "qml/pages/OrdersPage.qml", "qml/pages/SalesPage.qml", "qml/components/ProductPickerSheet.qml"];
    for (const rel of users) {
        const src = noComments(read(rel));
        const found = blocks(src, "ChipScroller {");
        assert.ok(found.length >= 1, rel + " no longer uses ChipScroller: update this list");
        for (const b of found) assert.ok(!/height|Height/.test(b), rel + " sets a height on its ChipScroller: it would clip or squash the 48 dp target");
    }
    // A new consumer must be looked at once: the list above is the whole list today.
    const all = [];
    (function walk(dir) {
        for (const e of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
            const rel = dir + "/" + e.name;
            if (e.isDirectory()) walk(rel);
            else if (e.name.endsWith(".qml") && /ChipScroller \{/.test(noComments(read(rel)))) all.push(rel);
        }
    })("qml");
    assert.deepEqual(all.sort(), users.slice().sort(), "ChipScroller has a new consumer: check its layout, then add it to this list");
});
test("S5E1-08 the search field's clear button is named and as tall as the 44 dp field, and the field is named", () => {
    const btn = blocks(SEARCH, "QQC.AbstractButton {");
    assert.equal(btn.length, 1);
    assert.match(btn[0], /Accessible\.role: Accessible\.Button/);
    assert.match(btn[0], /Accessible\.name: qsTr\("Clear search"\)/);
    assert.match(btn[0], /implicitWidth: dp\(44\)/);
    assert.match(btn[0], /implicitHeight: dp\(44\)/);
    assert.ok(!/dp\(28\)/.test(SEARCH), "the 28 dp button is back");
    assert.match(SEARCH, /implicitHeight: dp\(44\)/, "the button must not be taller than the field");
    assert.match(blocks(SEARCH, "QQC.TextField {")[0], /Accessible\.name: input\.placeholderText/);
    assert.match(SEARCH, /onClicked: \{ input\.text = ""; root\.cleared\(\) \}/, "the clear action is unchanged");
});
test("S5E1-09 the sheet's X is named, 48 dp, centred on a wrapper that keeps the header's 36 dp, and still asks the guard", () => {
    const wrap = blocks(BOTTOM, "Item {").find((b) => /Layout\.preferredWidth: dp\(36\)/.test(b) && /AbstractButton/.test(b));
    assert.ok(wrap, "the 36 dp wrapper around the X is gone: the header would grow");
    assert.match(wrap, /Layout\.preferredHeight: dp\(36\)/);
    const btn = blocks(wrap, "QQC.AbstractButton {")[0];
    assert.match(btn, /anchors\.centerIn: parent/);
    assert.match(btn, /implicitWidth: dp\(48\); implicitHeight: dp\(48\)/);
    assert.match(btn, /Accessible\.role: Accessible\.Button/);
    assert.match(btn, /Accessible\.name: qsTr\("Close"\)/);
    assert.match(btn, /onClicked: root\.requestClose\(\)/);
    assert.equal((BOTTOM.match(/implicitWidth: dp\(36\); implicitHeight: dp\(36\)/g) || []).length, 0, "a 36 dp button is back");
});
test("S5E1-10 no icon button of the picker's surface is unnamed: every AbstractButton block says its Accessible.name", () => {
    const files = {
        "ProductPickerRow": [ROW, 2], "SearchField": [SEARCH, 1], "BottomSheet": [BOTTOM, 1],
        "CartStepper": [noComments(read("qml/components/CartStepper.qml")), 1],
        "ProductPickerSheet": [noComments(read("qml/components/ProductPickerSheet.qml")), 0],
    };
    for (const [name, [src, expected]] of Object.entries(files)) {
        const found = blocks(src, "AbstractButton {");
        assert.equal(found.length, expected, name + " has " + found.length + " AbstractButton blocks, expected " + expected + ": a new one needs a name");
        for (const b of found) assert.match(b, /Accessible\.name:/, name + " has an unnamed button");
    }
});
test("S5E1-11 the in-stock row keeps its S2 and S5c accessibility wiring (the new work did not touch it)", () => {
    const sheet = noComments(read("qml/components/ProductPickerSheet.qml"));
    assert.match(sheet, /Accessible\.role: Accessible\.CheckBox/);
    assert.match(sheet, /Accessible\.onPressAction: root\._toggleStockA11y\(\)/);
    assert.match(sheet, /Accessible\.onToggleAction: root\._toggleStockA11y\(\)/);
    assert.match(sheet, /Accessible\.ignored: true/);
});
test("S5E1-12 chip.choose does nothing on a disabled chip (the stock register dims its period chips while a load runs)", () => {
    const fn = noComments(extractFunction("components/ChipScroller.qml", "choose"));
    const log = [];
    const mk = (enabled) => {
        const box = { index: 1, chip: { enabled, entry: { label: "Last 7 days" } }, root: { selected: 0, chipSelected: (i, l) => log.push([i, l]) } };
        vm.createContext(box);
        vm.runInContext(fn, box);
        return box;
    };
    const off = mk(false);
    vm.runInContext("choose()", off);
    vm.runInContext("choose()", off);
    assert.deepEqual(log, [], "a disabled chip emitted a selection");
    assert.equal(off.root.selected, 0, "a disabled chip changed the selection");
    // Anything that is not exactly an enabled chip is refused too (an undefined `enabled` must not select).
    for (const bad of [undefined, null, 0, ""]) {
        const b = mk(bad);
        vm.runInContext("choose()", b);
        assert.equal(b.root.selected, 0, "enabled=" + String(bad) + " selected");
    }
    const on = mk(true);
    vm.runInContext("choose()", on);
    assert.equal(on.root.selected, 1);
    assert.deepEqual(log, [[1, "Last 7 days"]]);
    // The guard is the FIRST statement, before the selection is set.
    assert.match(fn, /function choose\(\) \{\s*if \(!chip\.enabled\) return\s*root\.selected = index/);
    // The one consumer that dims its chips says so, so this guard has a reason to exist.
    assert.match(noComments(read("qml/pages/StockRegisterPage.qml")), /ChipScroller \{[^}]*enabled: !root\._busy/s);
});
