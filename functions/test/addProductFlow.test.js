"use strict";

// Atomic-ops AP3a: qml/helper/AddProductFlow.js (design 2026-11-16-ap3a-add-product-wire-design.md). The helper runs
// here with its REAL text (testSupport/qmlHelpers.js); every input it builds goes through the REAL planner and the REAL server
// code, so "the flow builds what the planner and the server accept" is proven. tests/tst_AddProductFlow.qml carries the unit
// cases for CI's qmltestrunner.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const { strictDb } = require("./testSupport/strictDb");
const { load, plain, HELPER_DIR } = require("./testSupport/qmlHelpers");

const Keys = load("OperationKeys.js");
const AP = load("AddProductPlan.js");
const AF = load("AddProductFlow.js");
const RF = load("RestockFlow.js");

const NOW = new Date("2026-06-15T12:00:00Z");
const KEY = "addProduct:1781000000000-abcdefabcdef";
const SUPPLIERS = [{ supplierId: "SUP-009", name: "Acme Farms" }];
const seq = (values) => { let i = 0; return () => values[i++ % values.length]; };

function args(over) {
    return Object.assign({
        key: KEY, name: "Tomato", sku: "TO-1", category: "Veg", unit: "kg", size: "", description: "Red", price: 20, sellingPrice: 30,
        taxable: true, taxPercent: 5, stock: 12, minStock: 2, unitCost: 18, party: "", suppliers: SUPPLIERS, now: NOW
    }, over || {});
}
const make = (over) => plain(AF.makeInput(args(over)));

async function serve(plan) {
    const v = OL.validateOperationRequest({ requestId: plan.key, opType: plan.opType, clientTimestamp: "CT", ops: plan.ops });
    assert.equal(v.ok, true, "the server must accept the plan: " + JSON.stringify(v));
    return OL.applyOperation(strictDb({}), { tenantId: "t1", actorUid: "u", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: { __transform: "serverTimestamp" }, now: NOW });
}

// ---------------------------------------------------------------------------- newKey

test("F-1 newKey: an add key from the time and two draws, deterministic for a fixed random; a bad nonce gives ''", () => {
    const k = AF.newKey(1700000000123, seq([0, 0]));
    assert.equal(k, "addProduct:1700000000123-000000000000");
    assert.equal(Keys.isAddProductKey(k), true);
    assert.equal(AF.newKey(1700000000123, seq([0, 0])), k, "same inputs, same key");
    assert.notEqual(AF.newKey(1700000000124, seq([0, 0])), k);
    assert.equal(Keys.isRestockKey(k), false, "never a restock key");
    assert.equal(AF.newKey(NaN, seq([0, 0])) === "" || Keys.isAddProductKey(AF.newKey(NaN, seq([0, 0]))), true);
});

// ---------------------------------------------------------------------------- makeInput: defaults

test("F-2 makeInput: the defaults the old addProduct had (selling price = price, cost = price, tax 0, reorder 0, taxable boolean)", () => {
    const r = make({ sellingPrice: undefined, unitCost: undefined, taxPercent: undefined, minStock: undefined, taxable: undefined });
    assert.equal(r.ok, true);
    assert.equal(r.input.sellingPrice, 20);
    assert.equal(r.input.unitCost, 20);
    assert.equal(r.input.taxPercent, 0);
    assert.equal(r.input.minStock, 0);
    assert.equal(r.input.taxable, false);
    assert.equal(make({ sellingPrice: null }).input.sellingPrice, 20);
    assert.equal(make({ sellingPrice: 0 }).input.sellingPrice, 0, "an explicit 0 is kept, not defaulted");
    assert.equal(make({ unitCost: 0 }).input.unitCost, 0, "a free batch is a real case");
    assert.equal(make({ unitCost: NaN }).input.unitCost, 20);
    assert.equal(make({ taxPercent: NaN }).input.taxPercent, 0);
    assert.equal(make({ taxable: 1 }).input.taxable, true);
});

test("F-3 makeInput: price that is not a number gives a cost of 0 (the planner then refuses the price itself)", () => {
    const r = make({ price: undefined, unitCost: undefined, sellingPrice: undefined });
    assert.equal(r.ok, true);
    assert.equal(r.input.unitCost, 0);
    assert.equal(plain(AP.build(r.input)).reason, "bad-price");
});

test("F-4 makeInput: values the planner must judge pass through unchanged (never clipped or fixed here)", () => {
    const r = make({ stock: -1, minStock: NaN, price: -5, taxPercent: 101 });
    assert.equal(r.ok, true);
    assert.deepEqual([r.input.stock, r.input.price, r.input.taxPercent], [-1, -5, 101]);
    assert.ok(Number.isNaN(r.input.minStock) || r.input.minStock === null, "NaN reorder level is the planner's to refuse");
});

test("F-5 makeInput: ONE Date gives the ISO instant and the local day (a tap at 23:59:59.9 cannot get two days)", () => {
    const d = new Date(2026, 5, 15, 23, 59, 59, 900);
    const r = make({ now: d });
    assert.equal(r.input.now, d.toISOString());
    assert.equal(r.input.date, "2026-06-15", "the LOCAL day, whatever the UTC day is");
    assert.equal(r.input.date, RF.localDate(d));
});

test("F-6 makeInput: a missing, string, NaN or non-Date time is bad-time; nothing else is checked first", () => {
    for (const now of [undefined, null, "2026-06-15T12:00:00Z", 1781000000000, new Date("nope"), {}]) {
        assert.deepEqual(make({ now }), { ok: false, reason: "bad-time" }, String(now));
    }
    assert.deepEqual(plain(AF.makeInput(undefined)), { ok: false, reason: "bad-time" });
    assert.deepEqual(plain(AF.makeInput(null)), { ok: false, reason: "bad-time" });
});

// ---------------------------------------------------------------------------- makeInput: supplier

test("F-7 makeInput supplier: '' / null / undefined = none; an id kept; a known name (any case) = that supplier; a new name = create", () => {
    for (const party of ["", null, undefined]) assert.equal(make({ party }).input.supplier, null, String(party));
    assert.deepEqual(make({ party: "SUP-009" }).input.supplier, { id: "SUP-009" });
    assert.deepEqual(make({ party: "SUP-404" }).input.supplier, { id: "SUP-404" }, "an id is kept as typed, known or not");
    assert.deepEqual(make({ party: " acme farms " }).input.supplier, { id: "SUP-009" }, "case and edge space do not make a second supplier");
    assert.deepEqual(make({ party: "Newco" }).input.supplier, { newName: "Newco" });
    assert.deepEqual(make({ party: { id: "SUP-009" } }).input.supplier, { id: "SUP-009" });
    assert.deepEqual(make({ party: { newName: "SUP-looking name" } }).input.supplier, { newName: "SUP-looking name" }, "a structured name is always a name");
});

test("F-8 makeInput supplier: blank, over-long and malformed parties are refused with RestockFlow's reasons", () => {
    assert.deepEqual(make({ party: "   " }), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(make({ party: { newName: "   " } }), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(make({ party: {} }), { ok: false, reason: "bad-supplier" });
    assert.deepEqual(make({ party: "x".repeat(RF.MAX_SUPPLIER_NAME + 1) }), { ok: false, reason: "supplier-too-long" });
    assert.equal(make({ party: "x".repeat(RF.MAX_SUPPLIER_NAME) }).ok, true, "the limit itself is allowed");
    assert.equal(make({ party: "x", suppliers: undefined }).ok, true, "no supplier list is an empty list");
});

// ---------------------------------------------------------------------------- the flow builds what the planner and the server accept

test("F-9 every combination of supplier (none, known, new) and stock (0, 1, 12) builds, plans and is accepted by the real server", async () => {
    for (const party of ["", "SUP-009", "Newco"]) {
        for (const stock of [0, 1, 12]) {
            const made = AF.makeInput(args({ party, stock }));
            assert.equal(made.ok, true);
            const plan = plain(AP.build(made.input));
            assert.equal(plan.ok, true, party + "/" + stock + ": " + JSON.stringify(plan));
            const r = await serve(plan);
            assert.equal(r.ok, true, party + "/" + stock + ": " + JSON.stringify(r));
            const out = plain(AP.reflect(plain(r.results)));
            assert.equal(out.ok, true, JSON.stringify(out));
            assert.equal(out.stock, stock);
            assert.equal(out.batch !== null, stock > 0);
            assert.equal(out.supplier !== null, party === "Newco");
        }
    }
});

test("F-10 the old call shapes still build: positional dialog values and the DataModel route's undefined optionals", async () => {
    const dialogLike = AF.makeInput(args({ party: "SUP-009", sellingPrice: 120, unitCost: 100, price: 100, size: "M", description: "" }));
    assert.equal(plain(AP.build(dialogLike.input)).ok, true);
    const routeLike = AF.makeInput(args({ party: undefined, unitCost: undefined, size: undefined, sellingPrice: undefined, minStock: 0 }));
    const plan = plain(AP.build(routeLike.input));
    assert.equal(plan.ok, true);
    assert.equal((await serve(plan)).ok, true);
});

// ---------------------------------------------------------------------------- refusal texts

test("F-11 refusalText: every reason the planner or makeInput can give has its own person-facing text, or is a deliberate app-bug text", () => {
    const planSrc = fs.readFileSync(path.join(HELPER_DIR, "AddProductPlan.js"), "utf8");
    const reasons = new Set([...planSrc.matchAll(/_refuse\("([a-z-]+)"\)/g)].map((m) => m[1]));
    for (const r of ["supplier-too-long"]) reasons.add(r);
    assert.ok(reasons.size >= 9, "the planner's reasons were found: " + [...reasons].join(","));
    const appBug = new Set(["bad-key", "bad-time", "too-large"]);   // bad-time and bad-key cannot happen from the app; too-large is worded by the store
    for (const reason of reasons) {
        const text = AF.refusalText(reason);
        assert.ok(typeof text === "string" && text.length > 10, reason);
        if (appBug.has(reason)) assert.match(text, /Please report this/, reason + " is an app problem");
        else assert.doesNotMatch(text, /report this/i, reason + " is something the person can fix");
        assert.doesNotMatch(text, /\{\{|undefined|null/, reason);
    }
    const fixable = [...reasons].filter((r) => !appBug.has(r));
    assert.equal(new Set(fixable.map((r) => AF.refusalText(r))).size, fixable.length, "no two fixable reasons share one text");
    assert.match(AF.refusalText("something-new"), /something-new/);
    assert.match(AF.refusalText(undefined), /Please report this/);
});

// ---------------------------------------------------------------------------- classify and the fixed texts

test("F-12 classify is RestockFlow's: applied, queued and rejected for every shape of answer", () => {
    for (const res of [{ ok: true, results: [] }, { ok: true, queued: true }, { ok: false, pending: true }, { ok: false, error: "conflict" }, null, undefined, "x", 7, {}]) {
        assert.equal(AF.classify(res), RF.classify(res), JSON.stringify(res));
    }
    assert.equal(AF.classify({ ok: true, results: [] }), "applied");
    assert.equal(AF.classify({ ok: false, pending: true }), "queued");
    assert.equal(AF.classify({ ok: false, error: "x" }), "rejected");
});

test("F-13 the fixed texts: distinct, plain, and the unconfirmed text never claims 'nothing was added' nor offers a plain retry", () => {
    const texts = [AF.OFFLINE_TEXT, AF.QUEUED_TEXT, AF.UNCONFIRMED_TEXT, AF.DISCARDED_TEXT];
    assert.equal(new Set(texts).size, 4);
    for (const t of texts) assert.ok(t.length > 20 && !/\{\{|undefined/.test(t));
    assert.doesNotMatch(AF.UNCONFIRMED_TEXT, /nothing was added|try again/i);
    assert.match(AF.UNCONFIRMED_TEXT, /Check the product list/);
    assert.match(AF.OFFLINE_TEXT, /needs an internet connection/);
    assert.match(AF.DISCARDED_TEXT, /nothing was added/i);
    assert.match(AF.supplierPendingText('A "b"'), /A "b"/);
});

// ---------------------------------------------------------------------------- the supplier clash covers an add

test("F-14 queuedNewSupplierClash sees a queued ADD that creates the name, and a queued restock, and still ignores other op types", () => {
    const addItem = (name) => ({ opType: "addProduct", ops: [{ kind: "mint", counter: "product", bind: "prd" },
        { kind: "mutation", entity: "supplier", action: "create", after: { name } }] });
    const restockItem = (name) => ({ opType: "restock", ops: [{ kind: "mutation", entity: "supplier", action: "create", after: { name } }] });
    assert.equal(RF.queuedNewSupplierClash("acme", [addItem("Acme")]), true);
    assert.equal(RF.queuedNewSupplierClash(" ACME ", [restockItem("Acme")]), true);
    assert.equal(RF.queuedNewSupplierClash("acme", [addItem("Other")]), false);
    assert.equal(RF.queuedNewSupplierClash("acme", [{ opType: "completeOrder", ops: addItem("Acme").ops }]), false);
    assert.equal(RF.queuedNewSupplierClash("acme", [{ opType: "addProduct", ops: [{ kind: "mutation", entity: "inventory", action: "create", after: { name: "Acme" } }] }]), false, "a PRODUCT called Acme is not a supplier");
    assert.equal(RF.queuedNewSupplierClash("acme", [{ opType: "addProduct", ops: "junk" }, null, 5]), false);
    assert.equal(RF.queuedNewSupplierClash("", [addItem("")]), false);
});

test("F-15 the clash check works on a REAL planned add (not only a hand-made item)", () => {
    const plan = plain(AP.build(AF.makeInput(args({ party: "Newco" })).input));
    assert.equal(RF.queuedNewSupplierClash("newco", [{ opType: plan.opType, ops: plan.ops }]), true);
    const none = plain(AP.build(AF.makeInput(args({ party: "SUP-009" })).input));
    assert.equal(RF.queuedNewSupplierClash("acme farms", [{ opType: none.opType, ops: none.ops }]), false, "a known supplier creates nothing");
});

// ---------------------------------------------------------------------------- monkey

test("M-1 monkey: 3000 random tap values never throw; an accepted plan always passes the real validator", () => {
    let seed = 17;
    const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
    const pick = (a) => a[rnd(a.length)];
    // Mostly sane values with the occasional hostile one, so both the accepted and the refused side are reached.
    const pickMostly = (good, hostile) => (rnd(10) < 8 ? pick(good) : pick(hostile));
    const num = () => pickMostly([0, 1, 2.5, 12, 100], [1e9, 1e308, -1, -0, NaN, Infinity, undefined, null, "5", "x"]);
    const text = () => pickMostly(["Tomato", "TO-1", "Red", "", "é"], [" ", "{{prd}}", "}}{{", "a".repeat(200), "😀", undefined, null, 7]);
    const parties = ["", undefined, null, "SUP-009", "acme farms", "Newco", { id: "SUP-009" }, { newName: "Z" }, { newName: "" }, 7, {}, "x".repeat(150)];
    const times = [NOW, NOW, NOW, new Date(2026, 0, 1, 0, 0, 0), new Date("x"), "now", undefined];
    let accepted = 0, refused = 0;
    for (let i = 0; i < 3000; ++i) {
        const a = { key: rnd(40) === 0 ? "bad" : KEY, name: text(), sku: text(), category: text(), unit: text(), size: text(), description: text(),
            price: num(), sellingPrice: num(), taxable: pick([true, true, false, 1, 0, undefined]), taxPercent: pickMostly([0, 5, 18, 100], [101, -1, NaN, "x", undefined]),
            stock: num(), minStock: num(), unitCost: num(), party: pickMostly(["", "SUP-009", "Newco", { newName: "Z" }], parties), suppliers: SUPPLIERS,
            now: pickMostly([NOW], times) };
        let made, plan;
        assert.doesNotThrow(() => { made = AF.makeInput(a); plan = made.ok ? plain(AP.build(made.input)) : made; }, JSON.stringify(a));
        assert.equal(typeof plan.ok, "boolean");
        if (!plan.ok) { refused++; assert.ok(typeof AF.refusalText(plan.reason) === "string"); continue; }
        accepted++;
        const v = OL.validateOperationRequest({ requestId: plan.key, opType: plan.opType, clientTimestamp: "CT", ops: plan.ops });
        assert.equal(v.ok, true, JSON.stringify(v) + " " + JSON.stringify(a));
    }
    assert.ok(accepted > 100 && refused > 100, "both sides reached: " + accepted + "/" + refused);
});

test("G-1 the flow is pure: no store, singleton, clock or random source is read (a source guard)", () => {
    const src = fs.readFileSync(path.join(HELPER_DIR, "AddProductFlow.js"), "utf8");
    const code = src.split("\n").filter((l) => !/^\s*\/\//.test(l)).join("\n");
    for (const bad of [/\bInventoryStore\b/, /\bSupplierStore\b/, /\bGateway\b/, /\bAuthService\b/, /Date\.now\(/, /new Date\(/, /Math\.random/, /console\./]) {
        assert.doesNotMatch(code, bad, String(bad));
    }
});
