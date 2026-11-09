"use strict";

// RestockDialog's Confirm tap (PR #183 device test: Confirm did nothing).
//
// The dialog imports the Felgo chain and cannot be loaded under qmltestrunner, so the REAL body of
// `_confirm()` is cut out of qml/pages/RestockDialog.qml and run here in a vm sandbox with fake stores
// (same technique as restockSurface.test.js). The fakes are the dialog's collaborators; nothing of the
// function under test is stubbed.
//
//   CF-1..4    the answers: applied, queued, refused with and without text
//   CF-5..6    guards: already busy, not owner/admin
//   CF-7..9    what is handed to InventoryStore.restock: supplier, cost, reason
//   CF-10      inputs are captured at the tap, not re-read when the answer arrives
//   CF-11..15  failure handling: the original bug, a throw before/after the answer, a throw in the answer path
//   CF-16..17  the source shape around the function

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, extractFunction } = require("./testSupport/qmlHelpers");

const FILE = "pages/RestockDialog.qml";
const SRC = extractFunction(FILE, "_confirm");
const FLOW = load("RestockFlow.js");

// One dialog: its fields, its stores, a log of everything the person would see or the app would do.
function rig(over) {
    const log = { toasts: [], confirmed: [], closed: 0, restockCalls: [], warns: [] };
    const ctx = {
        busy: false,
        productId: "p1",
        dlg: { _supplierIds: ["", "SUP-1", "SUP-2"], close() { log.closed++; } },
        qtyField: { value: 10 },
        unitCostField: { text: "12.5" },
        reasonField: { text: "  weekly  " },
        partyCombo: { currentIndex: 0 },
        AuthStore: { canManageInventory: true },
        Toast: { show(m) { log.toasts.push(m); } },
        RestockFlow: FLOW,
        InventoryStore: { restock() { log.restockCalls.push(Array.from(arguments)); } },
        restockConfirmed(pid, qty) { log.confirmed.push([pid, qty]); },
        console: { warn() { log.warns.push(Array.from(arguments)); } }
    };
    for (const k of Object.keys(over || {})) {
        if (over[k] === undefined) delete ctx[k]; else ctx[k] = over[k];
    }
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    return { ctx, log, tap: () => ctx._confirm(), answer: (...a) => log.restockCalls[0][5](...a) };
}

// ------------------------------------------------------------------ the answers

test("CF-1 applied: busy during the call, then +N toast, signal, close", () => {
    const r = rig();
    r.tap();
    assert.equal(r.ctx.busy, true, "busy while waiting");
    assert.equal(r.log.restockCalls.length, 1);
    assert.deepEqual(r.log.restockCalls[0].slice(0, 5), ["p1", 10, "", 12.5, "weekly"]);
    r.answer(true, false);
    assert.equal(r.ctx.busy, false);
    assert.deepEqual(r.log.confirmed, [["p1", 10]]);
    assert.deepEqual(r.log.toasts, ["Restocked +10 units"]);
    assert.equal(r.log.closed, 1);
});

test("CF-2 queued: saved wording, still closes and signals", () => {
    const r = rig();
    r.tap();
    r.answer(true, true);
    assert.deepEqual(r.log.toasts, ["Restock saved. Stock updates when it syncs"]);
    assert.deepEqual(r.log.confirmed, [["p1", 10]]);
    assert.equal(r.log.closed, 1);
    assert.equal(r.ctx.busy, false);
});

test("CF-3 refused with a cause: that text is shown, the sheet stays open and usable", () => {
    const r = rig();
    r.tap();
    r.answer(false, false, "Unit cost is not a valid amount");
    assert.deepEqual(r.log.toasts, ["Unit cost is not a valid amount"]);
    assert.equal(r.log.closed, 0);
    assert.deepEqual(r.log.confirmed, []);
    assert.equal(r.ctx.busy, false);
});

test("CF-4 refused without a cause: the generic try-again text", () => {
    const r = rig();
    r.tap();
    r.answer(false, false);
    assert.deepEqual(r.log.toasts, ["Could not restock — try again"]);
    assert.equal(r.log.closed, 0);
});

// ------------------------------------------------------------------ guards

test("CF-5 a tap while busy does nothing (double-tap)", () => {
    const r = rig({ busy: true });
    r.tap();
    assert.equal(r.log.restockCalls.length, 0);
    assert.deepEqual(r.log.toasts, []);
    assert.equal(r.ctx.busy, true, "left as it was");
});

test("CF-5b two taps before the answer make one restock", () => {
    const r = rig();
    r.tap();
    r.tap();
    assert.equal(r.log.restockCalls.length, 1);
});

test("CF-6 a role without inventory rights is refused before anything is read or sent", () => {
    const r = rig({ AuthStore: { canManageInventory: false } });
    r.tap();
    assert.deepEqual(r.log.toasts, ["Only owner/admin can restock products"]);
    assert.equal(r.log.restockCalls.length, 0);
    assert.equal(r.ctx.busy, false);
});

// ------------------------------------------------------------------ what restock receives

test("CF-7 supplier: index 0 is none, index N is the Nth id", () => {
    const none = rig(); none.tap();
    assert.equal(none.log.restockCalls[0][2], "");
    const two = rig({ partyCombo: { currentIndex: 2 } }); two.tap();
    assert.equal(two.log.restockCalls[0][2], "SUP-2");
});

test("CF-8 cost text: blank is not-given, a number is itself, junk and negatives reach the plan as refusals", () => {
    const cost = (text) => { const r = rig({ unitCostField: { text } }); r.tap(); return r.log.restockCalls[0][3]; };
    assert.ok(Number.isNaN(cost("")));
    assert.ok(Number.isNaN(cost("   ")));
    assert.equal(cost("0"), 0, "a typed 0 stays 0 (free sample)");
    assert.equal(cost(" 7.5 "), 7.5);
    assert.equal(cost("abc"), -1);
    assert.equal(cost("-3"), -3);
    assert.equal(cost("1,5"), -1);
});

test("CF-9 reason is trimmed", () => {
    const r = rig({ reasonField: { text: "\t emergency \n" } });
    r.tap();
    assert.equal(r.log.restockCalls[0][4], "emergency");
});

// ------------------------------------------------------------------ captured at the tap

test("CF-10 product and quantity are the ones tapped, even if the fields change before the answer", () => {
    const r = rig();
    r.tap();
    r.ctx.qtyField.value = 99;
    r.ctx.productId = "p2";
    r.answer(true, false);
    assert.deepEqual(r.log.confirmed, [["p1", 10]]);
    assert.deepEqual(r.log.toasts, ["Restocked +10 units"]);
});

// ------------------------------------------------------------------ failures

test("CF-11 the original bug: an unresolved helper name is shown and logged, nothing is left busy", () => {
    // RestockFlow undefined in the sandbox = ReferenceError, exactly what a missing `import ... as RestockFlow` gives.
    const r = rig({ RestockFlow: undefined });
    r.tap();
    assert.deepEqual(r.log.toasts, ["Something went wrong. Check the stock before trying again"]);
    assert.equal(r.log.restockCalls.length, 0);
    assert.equal(r.ctx.busy, false);
    assert.equal(r.log.closed, 0);
    assert.equal(r.log.warns.length, 1);
    assert.match(String(r.log.warns[0][1]), /RestockFlow is not defined/);
});

test("CF-12 restock throws before answering: busy cleared, one honest message, no success claim", () => {
    const r = rig({ InventoryStore: { restock() { throw new Error("boom"); } } });
    r.tap();
    assert.equal(r.ctx.busy, false);
    assert.deepEqual(r.log.toasts, ["Something went wrong. Check the stock before trying again"]);
    assert.deepEqual(r.log.confirmed, []);
    assert.equal(r.log.closed, 0);
    assert.equal(r.log.warns.length, 1);
});

test("CF-13 restock answers and THEN throws (queued, then a drain error): one success message, no second one", () => {
    const store = { restock() { const cb = arguments[5]; cb(true, true); throw new Error("drain failed"); } };
    const r = rig({ InventoryStore: store });
    r.tap();
    assert.deepEqual(r.log.toasts, ["Restock saved. Stock updates when it syncs"]);
    assert.equal(r.log.closed, 1);
    assert.equal(r.ctx.busy, false);
    assert.equal(r.log.warns.length, 1, "still logged");
});

test("CF-14 the answer path itself throws inside restock (Toast fails): not reported a second time, busy clear", () => {
    let n = 0;
    const r = rig({
        Toast: { show() { n++; if (n === 1) throw new Error("toast failed"); } },
        InventoryStore: { restock() { arguments[5](true, false); } }   // answers synchronously, as Gateway does when not awaiting
    });
    r.tap();
    assert.equal(r.ctx.busy, false);
    assert.equal(n, 1, "no 'Something went wrong' on top of a settled restock");
    assert.equal(r.log.warns.length, 1, "logged");
});

test("CF-15 a late answer after a throw still settles the sheet", () => {
    // restock registered its waiter, then threw; the answer arrives afterwards.
    let saved;
    const r = rig({ InventoryStore: { restock() { saved = arguments[5]; throw new Error("late"); } } });
    r.tap();
    assert.equal(r.ctx.busy, false, "cleared by the catch");
    saved(true, false);
    assert.deepEqual(r.log.toasts, ["Something went wrong. Check the stock before trying again", "Restocked +10 units"]);
    assert.equal(r.log.closed, 1);
});

// ------------------------------------------------------------------ source shape

const DIALOG = fs.readFileSync(path.join(__dirname, "..", "..", "qml", FILE), "utf8");

test("CF-16 the Confirm signal runs _confirm, and no second inline copy of the logic is left", () => {
    assert.match(DIALOG, /^\s*onPrimaryClicked:\s*dlg\._confirm\(\)\s*$/m);
    assert.equal((DIALOG.match(/InventoryStore\.restock\(/g) || []).length, 1, "one call site");
    assert.equal((DIALOG.match(/function _confirm\(/g) || []).length, 1);
});

test("CF-17 the sandbox's collaborators are exactly the free names _confirm uses", () => {
    // If _confirm starts using a new store or field, this fails and the rig above must learn it. Otherwise a
    // missing fake would make CF-11 style ReferenceErrors pass for the wrong reason.
    const body = SRC.replace(/\/\/[^\n]*/g, "").replace(/"(?:\\.|[^"\\\n])*"/g, '""');
    const used = new Set();
    for (const m of body.matchAll(/(?<![\w.$])([A-Za-z_$][\w$]*)(?=\s*[.(=\s,)\]]|$)/g)) used.add(m[1]);
    const KEYWORDS = new Set(["function", "if", "return", "var", "try", "catch", "true", "false", "e", "ok", "queued", "refusal", "settled", "pid", "qty", "supplierId", "unitCost"]);
    const free = [...used].filter((n) => !KEYWORDS.has(n)).sort();
    const known = ["AuthStore", "InventoryStore", "RestockFlow", "Toast", "busy", "console", "dlg", "partyCombo", "productId", "qtyField", "reasonField", "restockConfirmed", "unitCostField", "_confirm"].sort();
    assert.deepEqual(free, known);
});
