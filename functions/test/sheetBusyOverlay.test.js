"use strict";

// AddProductDialog, AddStaffDialog and NewOrderDialog showed no full-sheet busy overlay while saving (found in the PR #190
// device test, logged in KNOWN-ISSUES). BottomSheet turns BusyOverlay on only when `busy` AND `busyMessage` is non-empty,
// and these three set `busy` and never a message. Each now declares a constant `busyMessage` at its root, as RestockDialog
// does. The overlay absorbs every tap and covers the whole sheet (error label included), so the other half of the fix is
// that EVERY answer path drops `busy` before it writes anything the user must read. The sheets import Felgo and cannot
// load under qmltestrunner, so their text is read here and the real handler bodies run in a sandbox.
//
//   SB-1  each of the three declares a usable message at its root (non-empty, short, no braces, distinct)
//   SB-2  BottomSheet's gate, evaluated with each sheet's real message: on exactly when busy and a message
//   SB-3  RATCHET: every QML file whose root is BottomSheet and that turns busy on declares a message
//   SB-4  AddProduct: validation returns before busy; the store callback drops busy FIRST, before any error text
//   SB-5  AddStaff handlers (real bodies, run): each answer drops busy and _provisioning; the error is shown after
//   SB-6  NewOrder handlers (real bodies, run): answer drops busy and closes/errs; a stray answer while idle is ignored
//   SB-7  seeded monkey over the NewOrder + AddStaff handlers: busy is never true after an answer, in any order
//   SB-8  the message survives every path: no sheet writes busyMessage at runtime (a constant cannot go stale)
//   SB-9  scanner sanity: RestockDialog, OrderDetailDialog, ImportPreviewDialog are found by the ratchet

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { extractFunction } = require("./testSupport/qmlHelpers");

const QML = path.join(__dirname, "..", "..", "qml");
const read = (rel) => fs.readFileSync(path.join(QML, rel), "utf8");
const SHEET = read("components/BottomSheet.qml");
const PRODUCT = "pages/AddProductDialog.qml";
const STAFF = "pages/AddStaffDialog.qml";
const ORDER = "pages/NewOrderDialog.qml";
const THREE = [PRODUCT, STAFF, ORDER];

const rootMessage = (src) => (src.match(/^    busyMessage: qsTr\("([^"]+)"\)\s*$/m) || [])[1];

function gateExpr() {
    const block = SHEET.substring(SHEET.indexOf("BusyOverlay {"));
    const expr = (block.match(/active: (.+)/) || [])[1];
    assert.ok(expr, "BottomSheet gate expression found");
    return expr;
}

function qmlFiles(dir) {
    const out = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...qmlFiles(p));
        else if (e.name.endsWith(".qml")) out.push(p);
    }
    return out;
}

// the one-line busy turn-on: `busy = true` or `dlg.busy = true`, or a binding `busy: <not false>`
const TURNS_BUSY = /(^|[^.\w])(dlg\.)?busy\s*=\s*true\b|^\s*busy:\s*(?!false\b)\S/m;

test("SB-1 each sheet declares a usable busyMessage at its root; the three are distinct", () => {
    const seen = new Set();
    for (const f of THREE) {
        const msg = rootMessage(read(f));
        assert.ok(msg && msg.trim().length > 0, f + ": message present at root");
        assert.ok(msg.length <= 60, f + ": fits the 260dp overlay text on two lines: " + msg.length);
        assert.doesNotMatch(msg, /[{}]/, f);
        assert.ok(!seen.has(msg), f + ": distinct message");
        seen.add(msg);
    }
    assert.equal(seen.size, 3);
});

test("SB-2 BottomSheet gate with each real message: overlay on exactly when busy and a message exist", () => {
    const expr = gateExpr();
    for (const f of THREE) {
        const msg = rootMessage(read(f));
        for (const busy of [true, false]) {
            for (const m of ["", msg]) {
                const got = vm.runInNewContext(expr, { root: { busy, busyMessage: m } });
                assert.equal(got, busy && m.length > 0, f + " busy=" + busy + " message=" + JSON.stringify(m));
            }
        }
        assert.equal(vm.runInNewContext(expr, { root: { busy: true, busyMessage: msg } }), true, f + ": saving shows overlay");
        assert.equal(vm.runInNewContext(expr, { root: { busy: false, busyMessage: msg } }), false, f + ": idle sheet shows none");
    }
});

// Sheets that turn `busy` on and deliberately have NO overlay message. Each entry needs a reason; the test below fails when
// an entry goes stale (the sheet gained a message or stopped using busy), so this list can only shrink or be justified.
const NO_OVERLAY = {
    "pages/StuckWritesSheet.qml": "busy is a modal lock while the discard confirm is open (`busy: discardConfirm.opened`), not a wait: an overlay would cover the list the user is deciding on",
    "pages/ProfileSettingsDialog.qml": "busy is bound to AuthService.busy, which other flows also set; a message here is a wording and timing call, deferred (KNOWN-ISSUES)",
};

const hasMessage = (src) => /^    busyMessage:/m.test(src) || /\bbusyMessage\s*=/.test(src);

test("SB-3 RATCHET: every root-BottomSheet QML file that turns busy on declares a busyMessage, or is listed with a reason", () => {
    const offenders = [];
    for (const file of qmlFiles(QML)) {
        const src = fs.readFileSync(file, "utf8");
        if (!/^BottomSheet \{/m.test(src)) continue;
        if (!TURNS_BUSY.test(src)) continue;
        const rel = path.relative(QML, file).split(path.sep).join("/");
        if (!hasMessage(src) && !NO_OVERLAY[rel]) offenders.push(rel);
    }
    assert.deepEqual(offenders, [], "these sheets set busy but have no full-sheet overlay message: " + offenders.join(", "));
});

test("SB-3b the NO_OVERLAY list is not stale: each entry exists, is a root BottomSheet, turns busy on, has no message, and has a reason", () => {
    for (const [rel, reason] of Object.entries(NO_OVERLAY)) {
        const src = read(rel);
        assert.match(src, /^BottomSheet \{/m, rel + " is a root BottomSheet");
        assert.ok(TURNS_BUSY.test(src), rel + " still turns busy on");
        assert.ok(!hasMessage(src), rel + " now has a message: remove it from NO_OVERLAY");
        assert.ok(reason.length >= 40, rel + ": a real reason");
    }
});

test("SB-4 AddProduct: validation returns before busy; the store callback drops busy before it writes error text", () => {
    const body = extractFunction(PRODUCT, "trySubmit");
    const busyAt = body.indexOf("busy = true");
    const callAt = body.indexOf("InventoryStore.addProduct(");
    assert.equal((body.match(/busy = true/g) || []).length, 1, "one busy = true");
    assert.ok(busyAt > 0 && callAt > busyAt, "busy precedes the store call");
    const before = body.substring(0, busyAt);
    assert.match(before, /errs\.length > 0\) \{ errorLabel\.text = errs\.join\(" · "\); return \}/, "validation refuses before busy");
    const cb = body.substring(body.indexOf("function(ok, newId, refusal) {", callAt));
    const firstStatement = cb.substring(cb.indexOf("{") + 1).trim().split("\n")[0].trim();
    assert.equal(firstStatement, "busy = false", "callback's first statement drops busy, so the overlay never hides the refusal");
    assert.ok(cb.indexOf("busy = false") < cb.indexOf("errorLabel.text"), "busy dropped before the error text");
});

function runHandler(relPath, name, ctx) {
    const src = extractFunction(relPath, name);
    vm.runInNewContext("(" + src.replace(/^function /, "function ") + ")(" + (ctx.__args || "") + ")", ctx);
    return ctx;
}

const toastless = () => ({ __errors: [], __closed: 0 });

function staffCtx(extra) {
    const c = toastless();
    c.dlg = { _provisioning: true, busy: true, close() { c.__closed++; } };
    c.errorLabel = { text: "" };
    c.Toast = { show() {} };
    return Object.assign(c, extra || {});
}

test("SB-5 AddStaff handlers (real bodies): success closes, both failures show their error, all three drop busy first", () => {
    let c = staffCtx({ __args: '"Added"' });
    runHandler(STAFF, "onMemberOperationSucceeded", c);
    assert.equal(c.dlg.busy, false); assert.equal(c.dlg._provisioning, false); assert.equal(c.__closed, 1);

    c = staffCtx({ __args: '"weak password"' });
    runHandler(STAFF, "onAuthFailed", c);
    assert.equal(c.dlg.busy, false); assert.equal(c.dlg._provisioning, false);
    assert.equal(c.errorLabel.text, "weak password"); assert.equal(c.__closed, 0, "stays open on failure");

    c = staffCtx({ __args: '""' });
    runHandler(STAFF, "onAuthFailed", c);
    assert.equal(c.errorLabel.text, "Could not create staff login", "empty reason falls back to a readable text");

    c = staffCtx({ __args: '"ctx", "offline"' });
    runHandler(STAFF, "onErrorOccurred", c);
    assert.equal(c.dlg.busy, false); assert.equal(c.errorLabel.text, "offline");

    c = staffCtx({ __args: '"ctx", ""' });
    runHandler(STAFF, "onErrorOccurred", c);
    assert.equal(c.errorLabel.text, "Could not add staff");

    for (const n of ["onMemberOperationSucceeded", "onAuthFailed", "onErrorOccurred"]) {
        const b = extractFunction(STAFF, n);
        assert.ok(b.indexOf("dlg.busy = false") > 0, n + " drops busy");
        if (b.includes("errorLabel.text")) assert.ok(b.indexOf("dlg.busy = false") < b.indexOf("errorLabel.text"), n + ": busy before text");
    }
});

function orderCtx(busy, args) {
    const c = toastless();
    c.dlg = { busy, close() { c.__closed++; } };
    c.errorLabel = { text: "" };
    c.__args = args;
    return c;
}

test("SB-6 NewOrder handlers (real bodies): answers drop busy; a stray answer while idle changes nothing", () => {
    let c = orderCtx(true, '"o1"');
    runHandler(ORDER, "onOrderAdded", c);
    assert.equal(c.dlg.busy, false); assert.equal(c.__closed, 1);

    c = orderCtx(true, '"stock gone"');
    runHandler(ORDER, "onOrderCreationFailed", c);
    assert.equal(c.dlg.busy, false); assert.equal(c.errorLabel.text, "stock gone"); assert.equal(c.__closed, 0);

    c = orderCtx(true, '""');
    runHandler(ORDER, "onOrderCreationFailed", c);
    assert.equal(c.errorLabel.text, "Could not create order — try again");

    c = orderCtx(false, '"o9"');
    runHandler(ORDER, "onOrderAdded", c);
    assert.equal(c.__closed, 0, "idle sheet is not closed by a stray orderAdded");
    c = orderCtx(false, '"boom"');
    runHandler(ORDER, "onOrderCreationFailed", c);
    assert.equal(c.errorLabel.text, "", "idle sheet shows no stray error");
});

function lcg(seed) { let s = seed >>> 0; return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296); }

test("SB-7 seeded monkey: after ANY answer busy is false; a tap-answer-answer storm never leaves the overlay up", () => {
    for (let seed = 1; seed <= 200; seed++) {
        const rnd = lcg(seed);
        const order = orderCtx(false, "");
        const staff = staffCtx();
        staff.dlg.busy = false; staff.dlg._provisioning = false;
        for (let step = 0; step < 40; step++) {
            const r = rnd();
            if (r < 0.2) { order.dlg.busy = true; }
            else if (r < 0.4) { staff.dlg.busy = true; staff.dlg._provisioning = true; }
            else if (r < 0.55) { order.__args = '"o"'; runHandler(ORDER, "onOrderAdded", order); assert.equal(order.dlg.busy, false, "seed " + seed); }
            else if (r < 0.7) { order.__args = r < 0.62 ? '""' : '"x"'; runHandler(ORDER, "onOrderCreationFailed", order); assert.equal(order.dlg.busy, false, "seed " + seed); }
            else if (r < 0.8) { staff.__args = '"m"'; runHandler(STAFF, "onMemberOperationSucceeded", staff); assert.equal(staff.dlg.busy, false, "seed " + seed); }
            else if (r < 0.9) { staff.__args = r < 0.85 ? '""' : '"bad"'; runHandler(STAFF, "onAuthFailed", staff); assert.equal(staff.dlg.busy, false, "seed " + seed); }
            else { staff.__args = '"c", "e"'; runHandler(STAFF, "onErrorOccurred", staff); assert.equal(staff.dlg.busy, false, "seed " + seed); }
        }
    }
});

test("SB-8 no sheet writes busyMessage at runtime: the constant cannot be left stale or empty", () => {
    for (const f of THREE) {
        assert.doesNotMatch(read(f), /\bbusyMessage\s*=/, f);
        assert.equal((read(f).match(/^    busyMessage:/gm) || []).length, 1, f + ": declared once");
    }
});

test("SB-9 sanity: the ratchet's scanner finds the three sheets that already had a message, and the BottomSheet root", () => {
    for (const f of ["pages/RestockDialog.qml", "pages/OrderDetailDialog.qml", "pages/ImportPreviewDialog.qml", ...THREE]) {
        const src = read(f);
        assert.match(src, /^BottomSheet \{/m, f + " is a root BottomSheet");
        assert.ok(TURNS_BUSY.test(src), f + " turns busy on (scanner sees it)");
    }
    assert.ok(!TURNS_BUSY.test("busy = false\n dlg.busy = false\n busy: false"), "turn-off lines are not turn-ons");
    assert.ok(TURNS_BUSY.test("    busy: someBinding"), "a binding counts as a turn-on");
    assert.ok(TURNS_BUSY.test("x\n    dlg.busy = true"), "dlg.busy = true counts");
});
