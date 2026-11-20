"use strict";
// Picker v2, slice S5c: 48 dp cart steppers, the Back route through the product sheet, the in-stock toggle repeat gate.
// S5C-01..12. Plan: docs/superpowers/plans/2026-11-20-product-picker-v2-s5c-touch-back-toggle.md. Like the S3/S4 wiring
// tests these read the QML text (qmltestrunner cannot load Felgo) and RUN the real function bodies of the sheet, the
// dialogs and BottomSheet's key handler in a sandbox against the real helpers, so the glue is executed, not just read.
// They pin WIRING, not painting: how it looks and whether Android delivers the key is what the on-device plan checks.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, extractFunction } = require("./testSupport/qmlHelpers");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const noComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "").replace(/(\s)\/\/ .*$/gm, "$1");
const SHEET = noComments(read("qml/components/ProductPickerSheet.qml"));
const BOTTOM = noComments(read("qml/components/BottomSheet.qml"));
const STEP = noComments(read("qml/components/CartStepper.qml"));
const NEW = noComments(read("qml/pages/NewOrderDialog.qml"));
const EDIT = noComments(read("qml/pages/OrderDetailDialog.qml"));
const MAIN = noComments(read("qml/Main.qml"));
const GD = load("PickerGuards.js");
const BR = load("BackRouter.js");

function literal(src, head, open, close) {
    const at = src.indexOf(head);
    assert.ok(at >= 0, head + " not found");
    const start = src.indexOf(open, at);
    let depth = 0, i = start;
    for (; i < src.length; i++) { if (src[i] === open) depth++; else if (src[i] === close && --depth === 0) break; }
    return src.substring(start, i + 1);
}
const fnText = (rel, name) => noComments(extractFunction(rel, name));

// A sheet double: the real handleBack / _toggleStockA11y text runs against it.
function sheetWorld(over) {
    const log = [];
    let t = 1000;
    const box = Object.assign({
        Guards: GD, _lastBackAt: 0, _lastToggleAt: 0,
        requestClose: () => log.push("requestClose"),            // handleBack calls the sheet's own requestClose() bare
        root: { _live: true, busy: false },
        discardConfirm: { visible: false, close: () => log.push("confirm.close") },
        Date: { now: () => t },
        _toggleStock: () => log.push("flip"),
    }, over || {});
    vm.createContext(box);
    vm.runInContext(fnText("components/ProductPickerSheet.qml", "handleBack"), box);
    vm.runInContext(fnText("components/ProductPickerSheet.qml", "_toggleStockA11y"), box);
    return { box, log, at: (ms) => { t = ms; } };
}

test("S5C-01 neither order dialog has a 28 dp stepper any more: both use CartStepper", () => {
    assert.ok(!/AbstractButton\s*\{[^}]*dp\(28\)[^}]*"(remove|add|close)"/.test(NEW), "New Order still has a 28 dp stepper button");
    assert.ok(!/name:\s*"(remove|add|close)"/.test(NEW + EDIT), "an icon-only stepper button is still painted in a dialog");
    assert.equal((NEW.match(/CartStepper\s*\{/g) || []).length, 1);
    assert.equal((EDIT.match(/CartStepper\s*\{/g) || []).length, 1);
    assert.ok(!/QQC\.AbstractButton/.test(EDIT), "Edit Order still has a raw button");
});

test("S5C-02 New Order: the stepper is on its own row, not in the avatar and name row, and keeps the same two calls", () => {
    const cart = NEW.slice(NEW.indexOf("id: cartCol"));
    const topRow = literal(cart, "RowLayout {", "{", "}");
    assert.ok(topRow.includes("AvatarBadge") && !topRow.includes("CartStepper"), "the stepper is back in the name row");
    assert.ok(cart.indexOf("CartStepper") > cart.indexOf(topRow) + topRow.length, "the stepper row must come after the name row");
    const st = literal(cart, "CartStepper {", "{", "}");
    assert.match(st, /onDecrement: dlg\.changeQty\(index, -1\)/);
    assert.match(st, /onIncrement: dlg\.changeQty\(index, \+1\)/);
    assert.match(st, /itemName: modelData\.name/);
    assert.ok(!/removable/.test(st), "New Order never had a remove button on this row");
});

test("S5C-03 Edit Order: price field, stepper and remove sit in their own row under the ListCard, not in its trailing slot", () => {
    const card = literal(EDIT, "ListCard {", "{", "}");
    assert.ok(!card.includes("priceField") && !card.includes("CartStepper"), "controls are back in the ListCard");
    const after = EDIT.slice(EDIT.indexOf(card) + card.length);
    const row = literal(after, "RowLayout {", "{", "}");
    assert.ok(row.includes("id: priceField") && row.includes("CartStepper"), "the controls row is missing");
    assert.ok(after.indexOf(row) < after.indexOf("Per-line") || after.indexOf(row) < after.indexOf("Text {"), "the row sits straight under the card");
    const st = literal(row, "CartStepper {", "{", "}");
    assert.match(st, /removable: true/);
    assert.match(st, /value: model\.quantity/);
    assert.match(st, /itemName: model\.name/);
});

test("S5C-04 Edit Order handlers: minus lowers, minus at 1 removes the row and defers the recompute, remove removes, all on the same row index", () => {
    const st = literal(EDIT.slice(EDIT.indexOf("CartStepper {")), "CartStepper {", "{", "}");
    const dec = literal(st, "onDecrement:", "{", "}");
    const rem = st.slice(st.indexOf("onRemoveRequested:") + "onRemoveRequested:".length).trim().replace(/\}\s*$/, "").trim();
    const run = (body, qty) => {
        const calls = [];
        const box = {
            model: { quantity: qty }, row: { rowIdx: 3 },
            Qt: { callLater: (f) => calls.push("later") },
            dlg: { recomputeSubtotal: () => calls.push("recompute") },
            products: { setProperty: (i, k, v) => calls.push("set:" + i + ":" + k + ":" + v), remove: (i) => calls.push("remove:" + i) },
        };
        vm.createContext(box);
        vm.runInContext(body, box);
        return calls;
    };
    assert.deepEqual(run(dec, 3), ["set:3:quantity:2", "recompute"]);
    assert.deepEqual(run(dec, 2), ["set:3:quantity:1", "recompute"]);
    assert.deepEqual(run(dec, 1), ["later", "remove:3"]);
    assert.deepEqual(run(dec, 0), ["later", "remove:3"]);
    assert.deepEqual(run(rem, 5), ["later", "remove:3"]);
});

test("S5C-05 CartStepper: every button is a CSG.TARGET touch area, the frame is CSG.VISUAL, nothing is a literal 28", () => {
    assert.match(STEP, /import "\.\.\/helper\/CartStepperGeometry\.js" as CSG/);
    const btn = literal(STEP, "component StepButton:", "{", "}");
    assert.match(btn, /implicitWidth: dp\(CSG\.TARGET\)/);
    assert.match(btn, /implicitHeight: dp\(CSG\.TARGET\)/);
    assert.match(btn, /Layout\.preferredWidth: dp\(CSG\.TARGET\)/);
    assert.match(btn, /Layout\.preferredHeight: dp\(CSG\.TARGET\)/);
    assert.match(btn, /width: dp\(CSG\.VISUAL\); height: dp\(CSG\.VISUAL\)/);
    assert.ok(!/dp\(2[0-9]\)|dp\(3[0-9]\)|dp\(4[0-7]\)/.test(STEP), "a hard-coded size below 48 dp in CartStepper");
    assert.match(STEP, /Layout\.preferredWidth: dp\(CSG\.QTY_W\)/);
});

test("S5C-06 CartStepper: three buttons, each with a spoken name, the remove one hidden unless removable and unframed, no model touched", () => {
    const names = [...STEP.matchAll(/text: root\.itemName === "" \? qsTr\("([^"]+)"\) : qsTr\("([^"]+%1)"\)\.arg\(root\.itemName\)/g)];
    assert.deepEqual(names.map((m) => m[1]), ["Decrease quantity", "Increase quantity", "Remove item"]);
    assert.deepEqual(names.map((m) => m[2]), ["Decrease quantity of %1", "Increase quantity of %1", "Remove %1"]);
    assert.match(STEP, /Accessible\.name: text/);
    assert.match(STEP, /Accessible\.role: Accessible\.Button/);
    const rem = STEP.slice(STEP.lastIndexOf("StepButton {"));
    assert.match(rem, /visible: root\.removable/);
    assert.match(rem, /framed: false/);
    assert.match(STEP, /property bool removable: false/);
    assert.ok(!/products\.|InventoryStore|OrdersStore|DataModel/.test(STEP), "CartStepper must not touch a model");
    assert.match(STEP, /onClicked: root\.decrement\(\)/);
    assert.match(STEP, /onClicked: root\.increment\(\)/);
    assert.match(STEP, /onClicked: root\.removeRequested\(\)/);
});

test("S5C-07 handleBack: not up -> false and untouched; up and idle -> closes once; busy -> swallowed; question open -> dismissed", () => {
    let w = sheetWorld({ root: { _live: false, busy: false } });
    assert.equal(w.box.handleBack(), false);
    assert.equal(w.box._lastBackAt, 0, "a pass must not start the repeat window");
    w = sheetWorld();
    assert.equal(w.box.handleBack(), true);
    assert.deepEqual(w.log, ["requestClose"]);
    w = sheetWorld({ root: { _live: true, busy: true }, requestClose: () => assert.fail("busy sheet closed") });
    assert.equal(w.box.handleBack(), true);
    assert.deepEqual(w.log, []);
    w = sheetWorld({ discardConfirm: { visible: true, close: () => w.log.push("confirm.close") } });
    assert.equal(w.box.handleBack(), true);
    assert.deepEqual(w.log, ["confirm.close"]);
});

test("S5C-08 handleBack: one press seen by both routes asks once and never dismisses its own question; a later press does", () => {
    const w = sheetWorld();
    w.at(5000);
    assert.equal(w.box.handleBack(), true);          // route 1 (key handler) asks
    w.box.discardConfirm.visible = true;             // the question is now up
    w.at(5030);
    assert.equal(w.box.handleBack(), true);          // route 2 (global router), same press: dropped, still consumed
    assert.deepEqual(w.log, ["requestClose"], "the same press must not dismiss the question it just asked");
    w.at(5600);
    assert.equal(w.box.handleBack(), true);          // a real second press answers it: keep picking
    assert.deepEqual(w.log, ["requestClose", "confirm.close"]);
});

test("S5C-09 handleBack: the repeat window is read through Guards, so a clock that jumps back never swallows a press", () => {
    const w = sheetWorld();
    w.at(9000);
    w.box.handleBack();
    w.at(100);                                       // clock went backwards
    w.box.handleBack();
    assert.deepEqual(w.log, ["requestClose", "requestClose"]);
    assert.match(fnText("components/ProductPickerSheet.qml", "handleBack"), /Guards\.isRepeat\(_lastBackAt, now, Guards\.BACK_REPEAT_MS\)/);
});

test("S5C-10 in-stock toggle: two accessibility actions for one gesture flip once; a later one flips again", () => {
    const w = sheetWorld();
    w.at(2000);
    w.box._toggleStockA11y();                        // pressAction
    w.at(2020);
    w.box._toggleStockA11y();                        // toggleAction of the same double tap
    assert.deepEqual(w.log, ["flip"]);
    w.at(2400);
    w.box._toggleStockA11y();
    assert.deepEqual(w.log, ["flip", "flip"]);
    // a touch tap is not gated: it calls _toggleStock directly
    assert.match(SHEET, /onClicked: root\._toggleStock\(\)/);
});

test("S5C-11 BottomSheet Back key: not guarded -> not accepted, nothing; guarded -> requestClose, or backRequested when the owner routes it", () => {
    assert.match(BOTTOM, /property bool routesBack: false/);
    assert.match(BOTTOM, /signal backRequested\(\)/);
    const src = BOTTOM.slice(BOTTOM.indexOf("Keys.onBackPressed:") + "Keys.onBackPressed:".length);
    const body = literal(src, "function(event)", "{", "}");
    const make = (guard, routes) => {
        const log = [];
        const root = { guardClose: guard, routesBack: routes, requestClose: () => log.push("requestClose"), backRequested: () => log.push("backRequested") };
        const event = { accepted: undefined };
        new vm.Script("(function(root, event) " + body + ")").runInNewContext({})(root, event);
        return { log, accepted: event.accepted };
    };
    assert.deepEqual(make(false, false), { log: [], accepted: false });
    assert.deepEqual(make(false, true), { log: [], accepted: false });
    assert.deepEqual(make(true, false), { log: ["requestClose"], accepted: true });
    assert.deepEqual(make(true, true), { log: ["backRequested"], accepted: true });
});

test("S5C-12 the sheet routes Back to handleBack and is the only guardClose user; both dialogs answer consumeBack through it", () => {
    assert.match(SHEET, /guardClose: true/);
    assert.match(SHEET, /routesBack: true/);
    assert.match(SHEET, /onBackRequested: handleBack\(\)/);
    const users = [];
    (function walk(dir) {
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, e.name);
            if (e.isDirectory()) walk(full);
            else if (/\.qml$/.test(e.name) && /guardClose:\s*true/.test(noComments(fs.readFileSync(full, "utf8")))) users.push(path.relative(ROOT, full).split(path.sep).join("/"));
        }
    })(path.join(ROOT, "qml"));
    assert.deepEqual(users, ["qml/components/ProductPickerSheet.qml"], "a new guardClose sheet must also decide what Back does (routesBack)");
    for (const [name, src] of [["NewOrderDialog", NEW], ["OrderDetailDialog", EDIT]]) {
        assert.match(src, /\n    function consumeBack\(\) \{ return picker\.handleBack\(\) \}\n/, name + " lacks consumeBack at the root");
        assert.ok(src.indexOf("function consumeBack") < src.indexOf("ProductPickerSheet {"), name + ": consumeBack is declared at the root next to the sheet");
    }
});

test("S5C-13 end to end through the real router: Back with the sheet up and a draft never closes the dialog under it", () => {
    for (const [file, name] of [["pages/NewOrderDialog.qml", "NewOrderDialog"], ["pages/OrderDetailDialog.qml", "OrderDetailDialog"]]) {
        for (const pickerUp of [true, false]) {
            const picked = [];
            const picker = { handleBack: () => { picked.push("asked"); return pickerUp } };
            const box = { picker };
            vm.createContext(box);
            vm.runInContext("var consumeBack = " + fnText(file, "consumeBack").replace(/^function consumeBack/, "function"), box);
            let closed = 0;
            const dialog = { opened: true, close: () => { closed += 1 }, consumeBack: box.consumeBack };
            const other = { opened: false, close: () => assert.fail("a closed dialog was closed") };
            assert.equal(BR.route([other, dialog]), pickerUp ? "consumed" : "closed", name);
            assert.equal(closed, pickerUp ? 0 : 1, name + ": sheet up must keep the dialog open, sheet down must close it as before");
            assert.deepEqual(picked, ["asked"]);
        }
    }
});

test("S5C-14 Main.qml: Back goes through BackRouter over the one dialog list, and no loop of its own closes a dialog", () => {
    assert.match(MAIN, /import "helper\/BackRouter\.js" as BackRouter/);
    const body = noComments(extractFunction("Main.qml", "_handleBack"));
    assert.match(body, /if \(BackRouter\.route\(_allDialogs\(\)\) !== "none"\) return/);
    assert.ok(!/\.close\(\)/.test(body.slice(0, body.indexOf("accessBlockedPage"))), "_handleBack closes a dialog itself again");
    assert.ok(body.indexOf("BackRouter.route") < body.indexOf("accessBlockedPage.visible"), "dialogs stay first");
});
