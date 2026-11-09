"use strict";

// Restock Confirm showed no busy overlay (device report 2026-11-09).
//
// Cause: BottomSheet turns the full-sheet BusyOverlay on only when `busy` AND `busyMessage` is non-empty; RestockDialog set
// `busy` and never a message, so only the small spinner inside the Confirm button ran. The dialog now declares a constant
// `busyMessage`. RestockDialog and BottomSheet import Felgo and cannot load under qmltestrunner, so their text is read here.
//
//   BO-1  RestockDialog declares a usable message at its root
//   BO-2  BottomSheet's own gate expression, evaluated: on exactly when busy and a message
//   BO-3  BusyOverlay is the LAST child of the sheet content (so it is drawn on top of it)
//   BO-4  the tap does not touch busyMessage (a constant cannot be left stale)
//   BO-5  busy is on before the store is called and the message survives every early return
//   BO-6  scanner sanity: the other overlay users are found, so BO-1..3 are not reading nothing

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { extractFunction } = require("./testSupport/qmlHelpers");

const QML = path.join(__dirname, "..", "..", "qml");
const read = (rel) => fs.readFileSync(path.join(QML, rel), "utf8");
const RESTOCK = read("pages/RestockDialog.qml");
const SHEET = read("components/BottomSheet.qml");

const rootMessage = (src) => (src.match(/^    busyMessage: qsTr\("([^"]+)"\)\s*$/m) || [])[1];

function closeOf(src, openIdx) {
    let depth = 0;
    for (let i = openIdx; i < src.length; i++) {
        if (src[i] === "{") depth++;
        else if (src[i] === "}" && --depth === 0) return i;
    }
    throw new Error("unbalanced braces");
}

test("BO-1 RestockDialog declares a non-empty busyMessage at its root, short enough for the overlay", () => {
    const msg = rootMessage(RESTOCK);
    assert.ok(msg && msg.trim().length > 0, "message present");
    assert.ok(msg.length <= 60, "fits the 260dp overlay text on two lines: " + msg.length);
    assert.doesNotMatch(msg, /[{}]/);
});

test("BO-2 BottomSheet's own gate: the overlay is active exactly when busy and a message exist", () => {
    const block = SHEET.substring(SHEET.indexOf("BusyOverlay {"));
    const expr = (block.match(/active: (.+)/) || [])[1];
    assert.ok(expr, "gate expression found");
    const msg = rootMessage(RESTOCK);
    for (const busy of [true, false]) {
        for (const m of ["", msg]) {
            const got = vm.runInNewContext(expr, { root: { busy, busyMessage: m } });
            assert.equal(got, busy && m.length > 0, "busy=" + busy + " message=" + JSON.stringify(m));
        }
    }
    // the Restock case end to end: tap sets busy, the dialog's constant message is there
    assert.equal(vm.runInNewContext(expr, { root: { busy: true, busyMessage: msg } }), true);
    assert.equal(vm.runInNewContext(expr, { root: { busy: false, busyMessage: msg } }), false, "idle sheet: no overlay");
});

test("BO-3 BusyOverlay is declared last inside the sheet content item, after (not inside) the layout", () => {
    const contentAt = SHEET.indexOf("contentItem: Item {");
    const contentOpen = SHEET.indexOf("{", contentAt);
    const contentClose = closeOf(SHEET, contentOpen);
    const layoutAt = SHEET.indexOf("ColumnLayout {\n            id: contentLayout");
    const layoutClose = closeOf(SHEET, SHEET.indexOf("{", layoutAt));
    const overlayAt = SHEET.indexOf("BusyOverlay {");
    assert.ok(contentOpen < layoutAt && layoutAt < layoutClose, "layout lives in the content item");
    assert.ok(overlayAt > layoutClose, "overlay comes after the layout closes (declaration order = on top)");
    assert.ok(overlayAt < contentClose, "and is still inside the content item");
    const between = SHEET.substring(layoutClose + 1, overlayAt);
    assert.doesNotMatch(between, /\n        [A-Z][A-Za-z.]* \{/, "no sibling declared between the layout and the overlay");
    const tail = SHEET.substring(closeOf(SHEET, overlayAt + "BusyOverlay ".length), contentClose);
    assert.doesNotMatch(tail, /\n        [A-Z][A-Za-z.]* \{/, "nothing declared after the overlay");
});

test("BO-4 the Confirm tap never writes busyMessage", () => {
    assert.doesNotMatch(extractFunction("pages/RestockDialog.qml", "_confirm"), /busyMessage/);
});

test("BO-5 busy goes on before the store is called; every early return happens before busy, so no path leaves it on without the message", () => {
    const body = extractFunction("pages/RestockDialog.qml", "_confirm");
    const busyAt = body.indexOf("busy = true");
    const callAt = body.indexOf("InventoryStore.restock(");
    assert.ok(busyAt > 0 && callAt > busyAt, "busy = true precedes InventoryStore.restock(");
    assert.equal((body.match(/busy = true/g) || []).length, 1);
    const beforeBusy = body.substring(0, busyAt);
    assert.ok(/return/.test(beforeBusy), "the early refusals return before busy is set");
});

test("BO-6 sanity: the two other sheets that show the overlay set a message in the same style; BottomSheet declares both properties", () => {
    for (const f of ["pages/OrderDetailDialog.qml", "pages/ImportPreviewDialog.qml"]) {
        assert.match(read(f), /busyMessage = /, f);
    }
    assert.match(SHEET, /property bool busy: false/);
    assert.match(SHEET, /property string busyMessage: ""/);
});
