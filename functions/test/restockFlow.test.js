"use strict";

// Atomic-ops R4: qml/helper/RestockFlow.js (design 2026-11-02-r4-restock-wire-design.md). The helper runs
// here with its REAL text (testSupport/qmlHelpers.js). The end-to-end block feeds makeInput through
// RestockPlan.build, the REAL server code and RestockPlan.reflect, so "what the tap assembles is what the
// server accepts" is proven. tests/tst_RestockFlow.qml carries the same unit cases for CI's qmltestrunner.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const { TS, strictDb } = require("./testSupport/strictDb");
const { load, plain } = require("./testSupport/qmlHelpers");

const Keys = load("OperationKeys.js");
const RP = load("RestockPlan.js");
const RF = load("RestockFlow.js");

const T = "tenants/t1/";
const KEY = "restock:1781000000000-abc";
// Local-time constructor: localDate must read LOCAL parts whatever the machine's zone is.
const NOW = new Date(2026, 5, 15, 23, 59, 59, 900);
const SUPPLIERS = [{ supplierId: "SUP-001", name: "Acme Farms" }, { supplierId: "SUP-002", name: "Bolt & Co" }];
const PRODUCT = { productId: "p1", name: "Tomato", category: "Veg", price: 12.5 };

function args(over) {
    return Object.assign({ key: KEY, product: PRODUCT, qty: 5, unitCost: 10, reason: "weekly", party: "", suppliers: SUPPLIERS, now: NOW }, over || {});
}
const make = (over) => plain(RF.makeInput(args(over)));

// ---------------------------------------------------------------------------- key and date

test("F-1 newKey is a valid restock key and two draws in one millisecond differ", () => {
    const k = RF.newKey(1781000000000, () => 0.5);
    assert.equal(Keys.isRestockKey(k), true);
    let i = 0; const r = () => [0.1, 0.2, 0.3, 0.4][i++];
    assert.notEqual(RF.newKey(5, r), RF.newKey(5, r));
});

test("F-2 localDate pads month and day and uses local parts (not UTC)", () => {
    assert.equal(RF.localDate(new Date(2026, 0, 5, 0, 0, 1)), "2026-01-05");
    assert.equal(RF.localDate(new Date(2026, 11, 31, 23, 59, 59)), "2026-12-31");
    assert.equal(RF.localDate(NOW), "2026-06-15");
});

test("F-2b makeInput: the local date is read from the local parts even when UTC is already the next day", () => {
    // A device east of UTC at 01:00 local: the ISO text says 2026-06-14, the local calendar says 2026-06-15.
    const d = new Date(Date.UTC(2026, 5, 14, 23, 30));
    d.getFullYear = () => 2026; d.getMonth = () => 5; d.getDate = () => 15;
    const r = plain(RF.makeInput(args({ now: d })));
    assert.equal(r.input.now, "2026-06-14T23:30:00.000Z");
    assert.equal(r.input.date, "2026-06-15");
});

// ---------------------------------------------------------------------------- supplierFor (O1)

test("F-3 supplierFor: empty, null, undefined mean no supplier", () => {
    for (const p of ["", null, undefined]) assert.deepEqual(plain(RF.supplierFor(p, SUPPLIERS)), { ok: true, supplier: null });
});

test("F-4 supplierFor: a SUP- prefix is an id, known or not, trimmed", () => {
    assert.deepEqual(plain(RF.supplierFor("SUP-002", SUPPLIERS)), { ok: true, supplier: { id: "SUP-002" } });
    assert.deepEqual(plain(RF.supplierFor("  SUP-777 ", SUPPLIERS)), { ok: true, supplier: { id: "SUP-777" } });
    assert.deepEqual(plain(RF.supplierFor("SUP-001", [])), { ok: true, supplier: { id: "SUP-001" } });
});

test("F-5 supplierFor: a known name (case-insensitive, trimmed) is that supplier, an unknown name is new", () => {
    assert.deepEqual(plain(RF.supplierFor("acme FARMS", SUPPLIERS)), { ok: true, supplier: { id: "SUP-001" } });
    assert.deepEqual(plain(RF.supplierFor("  Bolt & Co  ", SUPPLIERS)), { ok: true, supplier: { id: "SUP-002" } });
    assert.deepEqual(plain(RF.supplierFor(" Newco ", SUPPLIERS)), { ok: true, supplier: { newName: "Newco" } });
});

test("F-6 supplierFor: whitespace-only is refused; junk supplier lists never throw", () => {
    assert.deepEqual(plain(RF.supplierFor("   ", SUPPLIERS)), { ok: false, reason: "bad-supplier" });
    for (const list of [undefined, null, "x", 5, [null, undefined, {}, { name: 5 }, { name: "Acme" }]])
        assert.deepEqual(plain(RF.supplierFor("Acme", list)), { ok: true, supplier: { newName: "Acme" } });
});

test("F-7 supplierFor: a number is treated as a name (legacy callers passed anything)", () => {
    assert.deepEqual(plain(RF.supplierFor(42, SUPPLIERS)), { ok: true, supplier: { newName: "42" } });
});

// ---------------------------------------------------------------------------- makeInput

test("F-8 makeInput: assembles the planner input; now and date come from ONE Date (O4)", () => {
    const r = make();
    assert.equal(r.ok, true);
    assert.deepEqual(r.input, {
        key: KEY, productId: "p1", productName: "Tomato", category: "Veg", qty: 5, unitCost: 10, reason: "weekly",
        now: NOW.toISOString(), date: "2026-06-15", supplier: null
    });
    // 23:59:59.9 local: the ISO text and the local date describe the same instant.
    assert.equal(new Date(r.input.now).getTime(), NOW.getTime());
});

test("F-9 makeInput: a unit cost that is not a number falls back to the product cost, then 0", () => {
    assert.equal(make({ unitCost: undefined }).input.unitCost, 12.5);
    assert.equal(make({ unitCost: NaN }).input.unitCost, 12.5);
    assert.equal(make({ unitCost: "7" }).input.unitCost, 12.5, "a string is not a number here (the dialog parses first)");
    assert.equal(make({ unitCost: undefined, product: Object.assign({}, PRODUCT, { price: "x" }) }).input.unitCost, 0);
    assert.equal(make({ unitCost: 0 }).input.unitCost, 0, "an explicit zero cost is kept");
    assert.equal(RF.makeInput(args({ unitCost: Infinity })).input.unitCost, Infinity, "left for the planner to refuse");
});

test("F-10 makeInput: refusals for a missing product, a bad Date and a bad supplier", () => {
    assert.deepEqual(plain(RF.makeInput(args({ product: null }))), { ok: false, reason: "bad-product" });
    assert.deepEqual(plain(RF.makeInput(args({ product: "x" }))), { ok: false, reason: "bad-product" });
    assert.deepEqual(plain(RF.makeInput(undefined)), { ok: false, reason: "bad-product" });
    for (const now of [undefined, null, 5, "2026-06-15", new Date(NaN)])
        assert.deepEqual(plain(RF.makeInput(args({ now }))), { ok: false, reason: "bad-time" });
    assert.deepEqual(plain(RF.makeInput(args({ party: "  " }))), { ok: false, reason: "bad-supplier" });
});

test("F-11 makeInput resolves the supplier from the list it is given", () => {
    assert.deepEqual(make({ party: "acme farms" }).input.supplier, { id: "SUP-001" });
    assert.deepEqual(make({ party: "Zed" }).input.supplier, { newName: "Zed" });
});

// ---------------------------------------------------------------------------- classify

test("F-12 classify: applied / queued / rejected for every Gateway.recordOperation shape", () => {
    assert.equal(RF.classify({ ok: true, results: [], idempotentReplay: false }), "applied");
    assert.equal(RF.classify({ ok: true, results: [], idempotentReplay: true }), "applied");
    assert.equal(RF.classify({ ok: true, queued: true, requestId: KEY }), "queued");
    assert.equal(RF.classify({ ok: false, pending: true, error: "timeout", requestId: KEY }), "queued");
    assert.equal(RF.classify({ ok: false, error: "conflict", opIndex: 2 }), "rejected");
    assert.equal(RF.classify({ ok: false, error: "discarded", discarded: true }), "rejected");
    assert.equal(RF.classify({ ok: false, error: "bad-request" }), "rejected");
});

test("F-13 classify: anything unreadable is rejected, never applied", () => {
    for (const bad of [undefined, null, 0, "ok", [], {}, { ok: "yes" }, { ok: 1, results: [] }, { pending: true }])
        assert.equal(RF.classify(bad), bad && bad.pending === true && bad.ok === undefined ? "queued" : "rejected", JSON.stringify(bad));
});

// ---------------------------------------------------------------------------- refusalText

test("F-14 refusalText: every RestockPlan reason has its own text, the unknown ones name the code", () => {
    const src = fs.readFileSync(path.join(__dirname, "..", "..", "qml", "helper", "RestockPlan.js"), "utf8");
    const reasons = [...new Set([...src.matchAll(/_refuse\("([a-z-]+)"\)/g)].map((m) => m[1]))];
    assert.ok(reasons.length >= 8, "drift guard found the planner's reasons: " + reasons.join(","));
    for (const r of ["bad-quantity", "bad-cost", "bad-supplier", "too-large", "reserved-text"]) {
        assert.ok(reasons.includes(r), r + " is a planner reason");
        assert.doesNotMatch(RF.refusalText(r), /report/i, r + " has person-facing text");
    }
    for (const r of reasons) assert.ok(RF.refusalText(r).length > 0);
    for (const r of ["bad-key", "bad-product", "bad-time"]) assert.match(RF.refusalText(r), new RegExp(r), "app bugs name the code");
    assert.match(RF.refusalText(undefined), /undefined/);
});

test("F-15 refusalText bad-quantity equals the text the dialogs always showed", () => {
    assert.equal(RF.refusalText("bad-quantity"), "Quantity must be greater than zero");
});

// ---------------------------------------------------------------------------- activityText

function outcome(over) {
    return Object.assign({ ok: true, productId: "p1", stock: 15, batchId: "BAT-2026-001", supplierId: "SUP-001",
        batch: { qtyReceived: 5, note: "weekly" }, purchase: { productName: "Tomato" } }, over || {});
}

test("F-16 activityText keeps the wording the old restock wrote", () => {
    assert.deepEqual(plain(RF.activityText(outcome(), "Acme Farms")),
        { title: "Restocked: Tomato", subtitle: "+5 · now 15 in stock · from Acme Farms · weekly" });
});

test("F-17 activityText leaves out the supplier and the reason when empty", () => {
    assert.equal(RF.activityText(outcome({ batch: { qtyReceived: 2.5, note: "" } }), "").subtitle, "+2.5 · now 15 in stock");
});

test("F-18 activityText never throws on a thin outcome", () => {
    assert.deepEqual(plain(RF.activityText({ stock: 3 }, "")), { title: "Restocked: ", subtitle: "+0 · now 3 in stock" });
});

// ---------------------------------------------------------------------------- end to end against the real server

async function send(db, plan) {
    const v = OL.validateOperationRequest({ requestId: plan.key, opType: plan.opType, clientTimestamp: "CT", ops: plan.ops });
    if (!v.ok) return { validation: v };
    const r = await OL.applyOperation(db, { tenantId: "t1", actorUid: "u1", actorRole: "owner", requestId: v.requestId,
        opType: v.opType, ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: TS, now: NOW });
    return { validation: v, result: r };
}
const baseDb = () => strictDb({ [T + "inventory/p1"]: { productId: "p1", name: "Tomato", stock: 10 } });

test("E-1 a tap's input -> plan -> server -> reflect -> activity text, for known, new and no supplier", async () => {
    for (const [party, expectSupplier, expectName] of [["acme farms", "SUP-001", "Acme Farms"], ["Newco", "SUP-001", "Newco"], ["", "", ""]]) {
        const made = RF.makeInput(args({ party, suppliers: party === "acme farms" ? SUPPLIERS : [] }));
        assert.equal(made.ok, true);
        const plan = plain(RP.build(made.input));
        assert.equal(plan.ok, true, JSON.stringify(plan));
        const db = baseDb();
        if (party === "acme farms") db.store[T + "suppliers/SUP-001"] = Object.assign({ supplierId: "SUP-001" }, { name: "Acme Farms" });
        const { validation, result } = await send(db, plan);
        assert.equal(validation.ok, true, JSON.stringify(validation));
        assert.equal(result.ok, true, JSON.stringify(result));
        assert.equal(RF.classify({ ok: true, results: result.results }), "applied");
        const out = plain(RP.reflect(result.results));
        assert.equal(out.ok, true, JSON.stringify(out));
        assert.equal(out.supplierId, expectSupplier);
        const text = plain(RF.activityText(out, expectName));
        assert.equal(text.title, "Restocked: Tomato");
        assert.equal(text.subtitle, "+5 · now 15 in stock" + (expectName ? " · from " + expectName : "") + " · weekly");
        assert.equal(db.store[T + "inventory/p1"].stock, 15);
    }
});

test("E-2 the same key sent twice is a replay: stock moves once, the answer carries the first result", async () => {
    const plan = plain(RP.build(RF.makeInput(args({ party: "Newco", suppliers: [] })).input));
    const db = baseDb();
    const first = await send(db, plan);
    const again = await send(db, plan);
    assert.equal(first.result.ok, true);
    assert.equal(again.result.ok, true);
    assert.equal(again.result.idempotentReplay, true);
    assert.equal(db.store[T + "inventory/p1"].stock, 15, "applied once");
    assert.deepEqual(plain(RP.reflect(again.result.results)).batchId, plain(RP.reflect(first.result.results)).batchId);
});

test("E-3 refusals made before anything is queued: every planner refusal reaches a person-facing text", () => {
    const cases = [[{ qty: 0 }, "bad-quantity"], [{ qty: -1 }, "bad-quantity"], [{ unitCost: -1 }, "bad-cost"],
        [{ unitCost: Infinity }, "bad-cost"], [{ qty: 1e308, unitCost: 5 }, "bad-cost"], [{ reason: "{{batch}}" }, "reserved-text"],
        // R5a: the tap's own limit (500 characters) now stops a long reason first; the planner's size check stays as the
        // backstop, so it is reached here with a product name that is huge (existing data, not typed in the dialog).
        [{ product: Object.assign({}, PRODUCT, { name: "x".repeat(1100000) }) }, "too-large"]];
    for (const [over, reason] of cases) {
        const made = RF.makeInput(args(over));
        assert.equal(made.ok, true);
        const plan = plain(RP.build(made.input));
        assert.equal(plan.ok, false);
        assert.equal(plan.reason, reason, JSON.stringify(Object.keys(over)));
        assert.ok(RF.refusalText(plan.reason).length > 0);
    }
});

// ---------------------------------------------------------------------------- seeded monkey

test("M-1 monkey: 600 random taps never throw; a made input is either planned or refused with a known text", () => {
    let seed = 7;
    const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    const parties = ["", null, undefined, "  ", "SUP-001", "SUP-9", "acme farms", "New {{sup}}", "x".repeat(300), 42, "Bolt & Co"];
    const nums = [0, 1, 2.5, -1, NaN, Infinity, 1e308, "5", null, undefined, 9999];
    const reasons = ["", "a", "  b  ", "{{batch}}", "x".repeat(900), undefined, null];
    for (let i = 0; i < 600; ++i) {
        const made = RF.makeInput(args({ party: pick(parties), qty: pick(nums), unitCost: pick(nums), reason: pick(reasons) }));
        if (!made.ok) { assert.ok(RF.refusalText(made.reason).length > 0); continue; }
        const plan = RP.build(made.input);
        if (!plan.ok) assert.ok(RF.refusalText(plan.reason).length > 0);
        else assert.equal(Keys.isRestockKey(plan.key), true);
    }
});

// ---------------------------------------------------------------------------------- review D-2: the cost field's text

test("D2-1 costFromText: blank / not-a-string = NaN (not given); a number is itself; junk = -1; never a silent 0", () => {
    for (const blank of ["", "   ", undefined, null, 12, {}, []]) assert.ok(Number.isNaN(RF.costFromText(blank)), String(blank));
    assert.equal(RF.costFromText("0"), 0, "a typed zero is a free sample and stays 0");
    assert.equal(RF.costFromText("0.0"), 0);
    assert.equal(RF.costFromText(" 7.25 "), 7.25);
    assert.equal(RF.costFromText("1e2"), 100);
    assert.equal(RF.costFromText("-3"), -3, "a negative is passed on so the plan can refuse it");
    for (const junk of ["abc", "12abc", "1,5", "Infinity", "-Infinity", "1e999", "NaN", "--1", "1.2.3"]) assert.equal(RF.costFromText(junk), -1, junk);
});

test("D2-2 end to end: what costFromText yields is booked, defaulted or refused by the REAL plan", () => {
    const build = (text) => {
        const m = RF.makeInput(args({ unitCost: RF.costFromText(text) }));
        assert.equal(m.ok, true);
        return plain(RP.build(m.input));
    };
    const costOf = (r) => r.ops.find((o) => o.entity === "stock_batch").after.unitCost;
    assert.equal(build("").ok, true);
    assert.equal(costOf(build("")), 12.5, "blank books the product's recorded cost, not 0");
    assert.equal(costOf(build("0")), 0);
    assert.equal(costOf(build("9.5")), 9.5);
    for (const bad of ["-3", "abc", "1,5", "Infinity", "1e999"]) {
        const r = build(bad);
        assert.equal(r.ok, false, bad);
        assert.equal(r.reason, "bad-cost", bad);
        assert.equal(RF.refusalText(r.reason), "Unit cost is not a valid amount");
    }
});

test("D2-3 the dialog hands the cost text to costFromText and no longer coerces a bad cost to 0", () => {
    const src = fs.readFileSync(path.join(__dirname, "..", "..", "qml", "pages", "RestockDialog.qml"), "utf8");
    assert.ok(src.includes("RestockFlow.costFromText(unitCostField.text)"));
    assert.ok(!/unitCost\s*=\s*0\b/.test(src), "no 'unitCost = 0' fallback may come back");
    assert.ok(!src.includes("parseFloat(unitCostField.text)"));
});

