"use strict";

// Atomic-ops R5a (design 2026-11-10-r5a-restock-dialog-design.md): the restock dialog's typed NEW supplier joins the
// operation instead of being created before it, plus field limits and their texts.
//
//   S-1..S-8    supplierFor with structured parties ({ id }, { newName }) and the unchanged string forms
//   P-1..P-3    partyFor (what the dialog hands to InventoryStore.restock) and newPartyChoice (the "Use" button)
//   L-1..L-6    limits: reason, supplier name, unit cost; their texts; the pins to the server's own constants
//   E-1..E-4    end to end through RestockPlan and the REAL server code: the typed name is created INSIDE the
//               transaction, a refused restock leaves no supplier and burns no number
//   D-1..D-8    the real bodies of RestockDialog's `_useTypedParty` and `_confirm` run in a vm with fake collaborators
//   G-1..G-6    source guards on the dialog and AuthTextField
//   M-1         seeded monkey over the whole tap path
//
// tests/tst_RestockFlow.qml carries the helper cases for CI's qmltestrunner.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const OL = require("../lib/operationLogic");
const MovementLogic = require("../lib/movementLogic");
const { TS, strictDb } = require("./testSupport/strictDb");
const { load, plain, extractFunction } = require("./testSupport/qmlHelpers");

const RF = load("RestockFlow.js");
const RP = load("RestockPlan.js");
const SM = load("StockMovements.js");

const T = "tenants/t1/";
const KEY = "restock:1781000000000-abc";
const NOW = new Date(2026, 5, 15, 12, 0, 0, 0);
const SUPPLIERS = [{ supplierId: "SUP-001", name: "Acme Farms" }, { supplierId: "SUP-002", name: "Bolt & Co" }];
const PRODUCT = { productId: "p1", name: "Tomato", category: "Veg", price: 12.5 };
const args = (over) => Object.assign({ key: KEY, product: PRODUCT, qty: 5, unitCost: 10, reason: "weekly", party: "", suppliers: SUPPLIERS, now: NOW }, over || {});
const make = (over) => plain(RF.makeInput(args(over)));
const sup = (party, list) => plain(RF.supplierFor(party, list === undefined ? SUPPLIERS : list));

// ---------------------------------------------------------------------------- supplierFor

test("S-1 { newName }: trimmed, and a new name stays a new name", () => {
    assert.deepEqual(sup({ newName: "  Newco  " }), { ok: true, supplier: { newName: "Newco" } });
});

test("S-2 { newName } that matches a known supplier (any case, any padding) is that supplier, not a duplicate", () => {
    assert.deepEqual(sup({ newName: "acme farms" }), { ok: true, supplier: { id: "SUP-001" } });
    assert.deepEqual(sup({ newName: "  BOLT & CO " }), { ok: true, supplier: { id: "SUP-002" } });
});

test("S-3 { newName } starting with SUP- is a NAME (the plain string form would read it as an id)", () => {
    assert.deepEqual(sup({ newName: "SUP-Foo" }), { ok: true, supplier: { newName: "SUP-Foo" } });
    assert.deepEqual(sup("SUP-Foo"), { ok: true, supplier: { id: "SUP-Foo" } }, "string form unchanged (R4-D5)");
});

test("S-4 { newName } empty, blank or over 100 characters is refused; exactly 100 is accepted", () => {
    assert.deepEqual(sup({ newName: "" }), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(sup({ newName: " \t " }), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(sup({ newName: "x".repeat(101) }), { ok: false, reason: "supplier-too-long" });
    assert.equal(sup({ newName: "x".repeat(100) }).ok, true);
    assert.equal(sup({ newName: " " + "x".repeat(100) + " " }).ok, true, "measured after trimming");
});

test("S-5 { id }: trimmed, kept as given; empty or missing is refused", () => {
    assert.deepEqual(sup({ id: " SUP-9 " }), { ok: true, supplier: { id: "SUP-9" } });
    assert.deepEqual(sup({ id: "" }), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(sup({}), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(sup({ id: 5 }), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(sup({ newName: 5 }), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(sup([]), { ok: false, reason: "bad-supplier" });
});

test("S-6 { newName } takes precedence when both are present (the name is what the person typed)", () => {
    assert.deepEqual(sup({ newName: "Newco", id: "SUP-001" }), { ok: true, supplier: { newName: "Newco" } });
});

test("S-7 the string forms are unchanged (R4-D5) and a string name is now length-checked too", () => {
    for (const p of ["", null, undefined]) assert.deepEqual(sup(p), { ok: true, supplier: null });
    assert.deepEqual(sup("   "), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(sup("acme farms"), { ok: true, supplier: { id: "SUP-001" } });
    assert.deepEqual(sup(" Newco "), { ok: true, supplier: { newName: "Newco" } });
    assert.deepEqual(sup("y".repeat(101)), { ok: false, reason: "supplier-too-long" });
});

test("S-8 a bad supplier list never throws and never matches", () => {
    for (const list of [undefined, null, "x", 5, [null, 5, {}, { name: "Newco" }, { supplierId: "", name: "Newco" }, { supplierId: "S", name: 5 }]])
        assert.deepEqual(sup({ newName: "Newco" }, list), { ok: true, supplier: { newName: "Newco" } });
});

// ---------------------------------------------------------------------------- partyFor, newPartyChoice

test("P-1 partyFor: a typed new name wins over the picker, trimmed", () => {
    assert.deepEqual(plain(RF.partyFor("  Newco ", 2, ["", "SUP-1", "SUP-2"])), { newName: "Newco" });
});

test("P-2 partyFor: no typed name -> the picked id, or \"\" for the placeholder and for anything out of range", () => {
    const ids = ["", "SUP-1", "SUP-2"];
    assert.equal(RF.partyFor("", 0, ids), "");
    assert.equal(RF.partyFor("   ", 1, ids), "SUP-1", "blank typed text is not a name");
    assert.equal(RF.partyFor(undefined, 2, ids), "SUP-2");
    for (const idx of [-1, 3, 99, NaN, 1.5, "1", null, undefined]) assert.equal(RF.partyFor("", idx, ids), "", String(idx));
    assert.equal(RF.partyFor("", 0, ["X", "SUP-1"]), "", "index 0 is the placeholder whatever the list holds there");
    assert.equal(RF.partyFor("", 1, undefined), "");
    assert.equal(RF.partyFor("", 1, ["", 7]), "", "a non-string id entry is not an id");
});

test("P-3 newPartyChoice: none, invalid, existing (canonical name), new", () => {
    assert.deepEqual(plain(RF.newPartyChoice("", SUPPLIERS)), { kind: "none" });
    assert.deepEqual(plain(RF.newPartyChoice("   ", SUPPLIERS)), { kind: "none" });
    assert.deepEqual(plain(RF.newPartyChoice(undefined, SUPPLIERS)), { kind: "none" });
    assert.deepEqual(plain(RF.newPartyChoice("x".repeat(101), SUPPLIERS)), { kind: "invalid", message: RF.refusalText("supplier-too-long") });
    assert.deepEqual(plain(RF.newPartyChoice("  acme FARMS ", SUPPLIERS)), { kind: "existing", id: "SUP-001", name: "Acme Farms" });
    assert.deepEqual(plain(RF.newPartyChoice(" Newco ", SUPPLIERS)), { kind: "new", name: "Newco" });
    assert.deepEqual(plain(RF.newPartyChoice("SUP-Foo", [])), { kind: "new", name: "SUP-Foo" });
    assert.deepEqual(plain(RF.newPartyChoice("Newco", undefined)), { kind: "new", name: "Newco" });
});

// ---------------------------------------------------------------------------- limits

test("L-1 reason: 500 characters pass, 501 are refused with their own reason; measured trimmed", () => {
    assert.equal(make({ reason: "r".repeat(500) }).ok, true);
    assert.deepEqual(make({ reason: "r".repeat(501) }), { ok: false, reason: "reason-too-long" });
    assert.equal(make({ reason: "  " + "r".repeat(500) + "  " }).ok, true);
    assert.equal(make({ reason: undefined }).ok, true);
    assert.equal(make({ reason: null }).ok, true);
});

test("L-2 unit cost: exactly 1e9 passes, above it is refused, NaN still falls back, Infinity is left for the planner", () => {
    assert.equal(make({ unitCost: 1e9 }).ok, true);
    assert.deepEqual(make({ unitCost: 1e9 + 1 }), { ok: false, reason: "cost-too-large" });
    assert.deepEqual(make({ unitCost: 1e300 }), { ok: false, reason: "cost-too-large" });
    assert.equal(make({ unitCost: NaN }).input.unitCost, 12.5);
    assert.equal(RF.makeInput(args({ unitCost: Infinity })).ok, true);
    assert.equal(plain(RP.build(RF.makeInput(args({ unitCost: Infinity })).input)).reason, "bad-cost");
});

test("L-3 every refusal reason the tap can produce has its own non-empty text, and the texts differ", () => {
    const reasons = ["bad-quantity", "bad-cost", "cost-too-large", "bad-supplier", "supplier-too-long", "reason-too-long", "too-large", "reserved-text"];
    const texts = reasons.map((r) => RF.refusalText(r));
    for (const t of texts) assert.ok(t.length > 0 && t.indexOf("report") < 0, t);
    assert.equal(new Set(texts).size, reasons.length, "no two reasons share a text");
    assert.match(RF.refusalText("something-new"), /Please report this/, "an unknown reason is reported, not hidden");
});

test("L-4 the limit texts name the limit", () => {
    assert.match(RF.refusalText("reason-too-long"), /500/);
    assert.match(RF.refusalText("supplier-too-long"), /100/);
    assert.match(RF.refusalText("cost-too-large"), /1000000000/);
    assert.match(RF.refusalText("cost-too-large"), /too large/);
});

test("L-5 the reason limit IS the server's movement-reason limit (they can drift only by failing this test)", () => {
    assert.equal(RF.MAX_REASON, MovementLogic.MAX_REASON);
    assert.equal(RF.MAX_REASON, SM.MAX_REASON);
});

test("L-6 the 500-character reason is whole in ALL three docs (it used to be cut in the ledger row only)", () => {
    const reason = "r".repeat(500);
    const plan = plain(RP.build(RF.makeInput(args({ reason })).input));
    assert.equal(plan.ok, true);
    const delta = plan.ops.find((o) => o.kind === "delta");
    const batch = plan.ops.find((o) => o.entity === "stock_batch");
    const purchase = plan.ops.find((o) => o.entity === "transaction");
    assert.equal(delta.movements[0].reason, reason);
    assert.equal(batch.after.note, reason);
    assert.equal(purchase.after.reason, reason);
});

test("L-7 the cost ceiling keeps qty * cost finite at the largest quantity the dialog allows", () => {
    assert.ok(Number.isFinite(9999 * RF.MAX_UNIT_COST));
});

// ---------------------------------------------------------------------------- end to end, real server

async function send(db, plan) {
    const v = OL.validateOperationRequest({ requestId: plan.key, opType: plan.opType, clientTimestamp: "CT", ops: plan.ops });
    if (!v.ok) return { validation: v };
    const r = await OL.applyOperation(db, { tenantId: "t1", actorUid: "u1", actorRole: "owner", requestId: v.requestId,
        opType: v.opType, ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: TS, now: NOW });
    return { validation: v, result: r };
}
const baseDb = () => strictDb({ [T + "inventory/p1"]: { productId: "p1", name: "Tomato", stock: 10 }, [T + "counters/suppliers"]: { value: 4 } });

test("E-1 a typed new supplier is created INSIDE the transaction: minted id, supplier doc, batch and purchase carry it", async () => {
    const party = RF.partyFor("Newco", 0, ["", "SUP-001"]);
    const plan = plain(RP.build(RF.makeInput(args({ party })).input));
    assert.equal(plan.ok, true, JSON.stringify(plan));
    const db = baseDb();
    const { result } = await send(db, plan);
    assert.equal(result.ok, true, JSON.stringify(result));
    const out = plain(RP.reflect(result.results));
    assert.equal(out.ok, true, JSON.stringify(out));
    assert.match(out.supplierId, /^SUP-/);
    assert.equal(out.supplier.name, "Newco");
    assert.equal(db.store[T + "suppliers/" + out.supplierId].name, "Newco");
    assert.equal(out.batch.supplierId, out.supplierId);
    assert.equal(out.purchase.party, out.supplierId);
    assert.equal(db.store[T + "inventory/p1"].stock, 15);
});

test("E-2 a name starting with SUP- typed as a new supplier becomes a real supplier, not a dangling id", async () => {
    const plan = plain(RP.build(RF.makeInput(args({ party: { newName: "SUP-Foo" } })).input));
    assert.equal(plan.ok, true, JSON.stringify(plan));
    const db = baseDb();
    const { result } = await send(db, plan);
    assert.equal(result.ok, true, JSON.stringify(result));
    const out = plain(RP.reflect(result.results));
    assert.notEqual(out.supplierId, "SUP-Foo");
    assert.equal(db.store[T + "suppliers/" + out.supplierId].name, "SUP-Foo");
});

test("E-3 the P1 defect, closed: a refused restock leaves NO supplier and burns NO number", async () => {
    const plan = plain(RP.build(RF.makeInput(args({ party: { newName: "Ghost" } })).input));
    const db = baseDb();
    delete db.store[T + "inventory/p1"];                       // the product vanished: the delta answers 404
    const before = JSON.stringify(db.store);
    const { result } = await send(db, plan);
    assert.equal(result.ok, false);
    assert.equal(result.error, "not-found");
    assert.equal(JSON.stringify(db.store), before, "not one write: no supplier doc, counter untouched, no marker");
    assert.equal(db.store[T + "counters/suppliers"].value, 4);
});

test("E-4 the same key sent twice creates the supplier once", async () => {
    const plan = plain(RP.build(RF.makeInput(args({ party: { newName: "Newco" } })).input));
    const db = baseDb();
    const first = await send(db, plan);
    const again = await send(db, plan);
    assert.equal(again.result.idempotentReplay, true);
    const names = Object.keys(db.store).filter((k) => k.indexOf(T + "suppliers/") === 0);
    assert.equal(names.length, 1);
    assert.equal(plain(RP.reflect(again.result.results)).supplierId, plain(RP.reflect(first.result.results)).supplierId);
});

// ---------------------------------------------------------------------------- the dialog's real bodies

const DIALOG_FILE = "pages/RestockDialog.qml";
const USE_SRC = extractFunction(DIALOG_FILE, "_useTypedParty");
const CONFIRM_SRC = extractFunction(DIALOG_FILE, "_confirm");

function useRig(over) {
    const log = { toasts: [], refreshed: [] };
    const ctx = {
        dlg: { _newSupplierName: "OLD", _addPartyOpen: true, _refreshSuppliers(id) { log.refreshed.push(id); } },
        addPartyField: { text: "" },
        partyCombo: { currentIndex: 2 },
        SupplierStore: { suppliers: SUPPLIERS },
        RestockFlow: RF,
        Toast: { show(m) { log.toasts.push(m); } }
    };
    for (const k of Object.keys(over || {})) ctx[k] = over[k];
    vm.createContext(ctx);
    vm.runInContext(USE_SRC, ctx);
    return { ctx, log, tap: () => ctx._useTypedParty() };
}

test("D-1 'Use' with a new name: nothing is created, the name is held, the row closes, the combo goes to the placeholder", () => {
    const r = useRig({ addPartyField: { text: "  Newco " } });
    r.tap();
    assert.equal(r.ctx.dlg._newSupplierName, "Newco");
    assert.equal(r.ctx.partyCombo.currentIndex, 0);
    assert.equal(r.ctx.addPartyField.text, "");
    assert.equal(r.ctx.dlg._addPartyOpen, false);
    assert.deepEqual(r.log.refreshed, [], "no picker rebuild: the supplier does not exist yet");
    assert.deepEqual(r.log.toasts, []);
});

test("D-2 'Use' with a known name (any case): that row is picked, no new name is held, nothing is created", () => {
    const r = useRig({ addPartyField: { text: "BOLT & co" } });
    r.tap();
    assert.equal(r.ctx.dlg._newSupplierName, "");
    assert.deepEqual(r.log.refreshed, ["SUP-002"]);
    assert.equal(r.ctx.dlg._addPartyOpen, false);
    assert.equal(r.ctx.addPartyField.text, "");
});

test("D-3 'Use' with empty text does nothing at all (the row stays open, the old choice stays)", () => {
    const r = useRig({ addPartyField: { text: "   " } });
    r.tap();
    assert.equal(r.ctx.dlg._newSupplierName, "OLD");
    assert.equal(r.ctx.dlg._addPartyOpen, true);
    assert.equal(r.ctx.partyCombo.currentIndex, 2);
    assert.deepEqual(r.log.toasts, []);
});

test("D-4 'Use' with an over-long name: the person is told, nothing changes", () => {
    const r = useRig({ addPartyField: { text: "x".repeat(101) } });
    r.tap();
    assert.deepEqual(r.log.toasts, [RF.refusalText("supplier-too-long")]);
    assert.equal(r.ctx.dlg._newSupplierName, "OLD");
    assert.equal(r.ctx.dlg._addPartyOpen, true);
});

// The Confirm tap with a pending name: reuse the exact harness of restockDialogConfirm.test.js, reduced.
function confirmRig(over) {
    const calls = [];
    const ctx = {
        busy: false, productId: "p1",
        dlg: { _supplierIds: ["", "SUP-1", "SUP-2"], _newSupplierName: "", close() {} },
        qtyField: { value: 10 }, unitCostField: { text: "12.5" }, reasonField: { text: "w" },
        partyCombo: { currentIndex: 0 },
        AuthStore: { canManageInventory: true }, Toast: { show() {} }, RestockFlow: RF,
        InventoryStore: { restock() { calls.push(Array.from(arguments)); } },
        restockConfirmed() {}, console: { warn() {} }
    };
    for (const k of Object.keys(over || {})) ctx[k] = over[k];
    vm.createContext(ctx);
    vm.runInContext(CONFIRM_SRC, ctx);
    return { ctx, calls, tap: () => ctx._confirm() };
}

test("D-5 Confirm with a pending new name sends { newName } as the party (the picker is ignored)", () => {
    const r = confirmRig({ dlg: { _supplierIds: ["", "SUP-1"], _newSupplierName: "Newco", close() {} }, partyCombo: { currentIndex: 1 } });
    r.tap();
    assert.deepEqual(plain(r.calls[0][2]), { newName: "Newco" });
});

test("D-6 Confirm with no pending name sends the picked id, or \"\" for the placeholder", () => {
    const a = confirmRig({ partyCombo: { currentIndex: 2 } }); a.tap();
    assert.equal(a.calls[0][2], "SUP-2");
    const b = confirmRig(); b.tap();
    assert.equal(b.calls[0][2], "");
});

test("D-7 the whole tap, dialog -> InventoryStore-shaped call -> plan -> real server: a pending name ends as a real supplier", async () => {
    const r = confirmRig({ dlg: { _supplierIds: [""], _newSupplierName: "Dialog Co", close() {} } });
    r.tap();
    const [pid, qty, party, cost, reason] = r.calls[0];
    assert.equal(pid, "p1");
    const made = RF.makeInput(args({ qty, unitCost: cost, reason, party, suppliers: [] }));
    assert.equal(made.ok, true);
    const plan = plain(RP.build(made.input));
    const db = baseDb();
    const { result } = await send(db, plan);
    assert.equal(result.ok, true, JSON.stringify(result));
    assert.equal(plain(RP.reflect(result.results)).supplier.name, "Dialog Co");
});

test("D-8 a supplier that appeared meanwhile (another device synced it) is matched at the tap, not duplicated", () => {
    const made = RF.makeInput(args({ party: RF.partyFor("acme farms", 0, [""]), suppliers: SUPPLIERS }));
    assert.deepEqual(plain(made.input.supplier), { id: "SUP-001" });
});

// ---------------------------------------------------------------------------- source guards

const DIALOG = fs.readFileSync(path.join(__dirname, "..", "..", "qml", DIALOG_FILE), "utf8");
const FIELD = fs.readFileSync(path.join(__dirname, "..", "..", "qml", "components", "AuthTextField.qml"), "utf8");

test("G-1 the dialog no longer creates a supplier by itself: no SupplierStore.addSupplier call is left", () => {
    assert.equal((DIALOG.match(/SupplierStore\.addSupplier\b/g) || []).length, 0);
    assert.equal((DIALOG.match(/SupplierStore\.addSupplierWithId/g) || []).length, 0);
    assert.equal((DIALOG.match(/Gateway\./g) || []).length, 0, "the dialog writes nothing itself");
});

test("G-2 the 'Use' button runs _useTypedParty and no second copy of that logic is inline", () => {
    assert.match(DIALOG, /onClicked:\s*dlg\._useTypedParty\(\)/);
    assert.equal((DIALOG.match(/function _useTypedParty\(/g) || []).length, 1);
    assert.equal((DIALOG.match(/newPartyChoice\(/g) || []).length, 1);
    assert.equal((DIALOG.match(/text:\s*qsTr\("Save"\)/g) || []).length, 0, "the old 'Save' label (it saved a supplier) is gone");
});

test("G-3 a user pick in the combo clears the typed name; the display shows the pending name", () => {
    const combo = DIALOG.slice(DIALOG.indexOf("id: partyCombo"), DIALOG.indexOf("id: addPartyToggle"));
    assert.match(combo, /onActivated:\s*dlg\._newSupplierName\s*=\s*""/);
    assert.match(combo, /displayText:\s*dlg\._newSupplierName\.length\s*>\s*0/);
});

test("G-4 openFor clears a typed name left from the last time the sheet was open", () => {
    const body = extractFunction(DIALOG_FILE, "openFor");
    assert.match(body, /_newSupplierName\s*=\s*""/);
});

test("G-5 both free-text fields are length-limited from the helper's constants; AuthTextField forwards maxLength", () => {
    assert.match(DIALOG, /id: addPartyField[\s\S]{0,300}maxLength:\s*RestockFlow\.MAX_SUPPLIER_NAME/);
    assert.match(DIALOG, /id: reasonField[\s\S]{0,300}maxLength:\s*RestockFlow\.MAX_REASON/);
    assert.match(FIELD, /property alias maxLength:\s*input\.maxLength/);
});

test("G-6 the hint under the row says the supplier is created with the restock (it is not created yet)", () => {
    assert.match(DIALOG, /visible:\s*dlg\._newSupplierName\.length\s*>\s*0/);
    assert.match(DIALOG, /will be added as a new supplier when you confirm this restock/);
});

// ---------------------------------------------------------------------------- seeded monkey

test("M-1 monkey: 600 random dialog states never throw; whatever is built is planned or refused with a known text", () => {
    let seed = 11;
    const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    const names = ["", "  ", "Newco", "acme farms", " BOLT & CO ", "SUP-Foo", "SUP-001", "{{sup}}", "x".repeat(100), "x".repeat(101), "é".repeat(60), "a/b", undefined, 5];
    const idxs = [0, 1, 2, 3, -1, 99, NaN, undefined];
    const costs = [NaN, 0, 7.5, -1, 1e9, 1e9 + 1, 1e308, Infinity];
    const reasons = ["", "w", "r".repeat(500), "r".repeat(501), "{{batch}}", undefined];
    const known = new Set(["bad-quantity", "bad-cost", "cost-too-large", "bad-supplier", "supplier-too-long", "reason-too-long", "too-large", "reserved-text"]);
    let planned = 0, refused = 0;
    for (let i = 0; i < 600; i++) {
        const party = RF.partyFor(pick(names), pick(idxs), ["", "SUP-001", "SUP-002"]);
        const made = plain(RF.makeInput(args({ party, unitCost: pick(costs), reason: pick(reasons), qty: pick([1, 5, 9999, 0]) })));
        if (!made.ok) { assert.ok(known.has(made.reason), made.reason); assert.ok(RF.refusalText(made.reason).length > 0); refused++; continue; }
        const plan = plain(RP.build(made.input));
        if (plan.ok) {
            const v = OL.validateOperationRequest({ requestId: plan.key, opType: plan.opType, ops: plan.ops });
            assert.equal(v.ok, true, JSON.stringify(v));      // whatever the tap plans, the real server validator accepts
            planned++;
        } else { assert.ok(known.has(plan.reason), plan.reason); refused++; }
    }
    assert.ok(planned > 50 && refused > 50, planned + "/" + refused);
});
