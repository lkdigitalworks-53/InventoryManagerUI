"use strict";

// Atomic-ops AP2: qml/helper/AddProductPlan.js, the add-product ids in OperationKeys.js, FailureCause.forAddProduct and the
// DescribeItem label (design 2026-11-15-ap2-add-product-client-plan-design.md; contract: AP1 design section 9). The QML
// helpers run here with their REAL text (testSupport/qmlHelpers.js) and every plan is sent through the REAL server code
// (validateOperationRequest + applyOperation on the strict fake DB), so "the client plans what the server accepts" is
// proven, not assumed. tests/tst_AddProductPlan.qml carries the unit cases for CI's qmltestrunner.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const { strictDb, rowsOf } = require("./testSupport/strictDb");
const { load, plain, extractFunction, HELPER_DIR } = require("./testSupport/qmlHelpers");
const vm = require("node:vm");

const Keys = load("OperationKeys.js");
const AP = load("AddProductPlan.js");
const FC = load("FailureCause.js");
const DI = load("DescribeItem.js");

const T = "tenants/t1/";
const NOW = new Date("2026-06-15T12:00:00Z");
const ISO = "2026-06-15T12:00:00.000Z";
const NONCE = "1781000000000-abcdefabcdef";
const KEY = "addProduct:" + NONCE;
const QML_ROOT = path.join(HELPER_DIR, "..");

function input(over) {
    return Object.assign({
        key: KEY, name: "  Tomato ", sku: "TO-2026-001", category: "Veg", description: "Red", price: 20, unit: "kg",
        stock: 12, minStock: 2, sellingPrice: 30, taxable: true, taxPercent: 5, size: "1kg", unitCost: 18.5,
        supplier: { newName: "  Acme Farms " }, now: ISO, date: "2026-06-15"
    }, over || {});
}
const build = (over) => plain(AP.build(input(over)));
const seq = (values) => { let i = 0; return () => values[i++ % values.length]; };
const withCounter = (value, more) => strictDb(Object.assign({ [T + "counters/products"]: { value } }, more || {}));
async function apply(db, plan, extra) {
    const v = OL.validateOperationRequest({ requestId: plan.key, opType: plan.opType, clientTimestamp: "CT", ops: plan.ops });
    assert.equal(v.ok, true, "the server must accept the plan: " + JSON.stringify(v));
    return OL.applyOperation(db, Object.assign({
        tenantId: "t1", actorUid: "u-actor", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: { __transform: "serverTimestamp" }, now: NOW
    }, extra || {}));
}
const textsOf = (ops) => {
    const out = [];
    (function walk(v) {
        if (typeof v === "string") out.push(v);
        else if (Array.isArray(v)) v.forEach(walk);
        else if (v && typeof v === "object") Object.values(v).forEach(walk);
    })(ops.filter((o) => o.kind === "mutation").map((o) => o.after));
    return out;
};

// ---------------------------------------------------------------------------- keys

test("K-1 addProductNonce: the restock nonce (time + two padded draws), deterministic for a fixed random", () => {
    assert.equal(Keys.addProductNonce(1700000000123, seq([0, 0])), "1700000000123-000000000000");
    assert.equal(Keys.addProductNonce(1700000000123.9, seq([0.5, 0.25])), Keys.restockNonce(1700000000123.9, seq([0.5, 0.25])));
    assert.notEqual(Keys.addProductNonce(1, seq([0.1, 0.2])), Keys.addProductNonce(1, seq([0.1, 0.3])));
});

test("K-2 addProductKey accepts a plain token and refuses everything the server would or could mishandle", () => {
    assert.equal(Keys.addProductKey("a-b_c.1"), "addProduct:a-b_c.1");
    assert.equal(Keys.addProductKey("x".repeat(100)), "addProduct:" + "x".repeat(100));
    for (const bad of ["", "x".repeat(101), "a/b", "a~b", "a b", "a:b", "é", "a\n", null, undefined, 5, {}, []])
        assert.equal(Keys.addProductKey(bad), "", JSON.stringify(bad));
});

test("K-3 isAddProductKey: only a well-formed add key; a restock or completeOrder key is not one, and the reverse", () => {
    assert.equal(Keys.isAddProductKey(Keys.addProductKey("n1")), true);
    for (const bad of ["addProduct:", "addProduct:a/b", "addProduct:a~1", "restock:n1", "completeOrder:o1:1", "addproduct:x", " addProduct:x", "req-1-2", "", null, undefined, 7])
        assert.equal(Keys.isAddProductKey(bad), false, String(bad));
    assert.equal(Keys.isRestockKey(Keys.addProductKey("n1")), false);
    assert.equal(Keys.isAddProductKey(Keys.restockKey("n1")), false);
});

test("K-4 restockKey is unchanged by the shared nonce rule (regression)", () => {
    assert.equal(Keys.restockKey("a-b_c.1"), "restock:a-b_c.1");
    for (const bad of ["", "x".repeat(101), "a/b", "a~b", "a b", null, undefined, 5]) assert.equal(Keys.restockKey(bad), "");
});

test("K-5 a generated key passes the server's request-id rule for opType addProduct, and a restock key does not", () => {
    const key = Keys.addProductKey(Keys.addProductNonce(Date.now(), Math.random));
    const ops = [{ kind: "mint", counter: "product", bind: "p" }, { kind: "mutation", entity: "inventory", entityId: "{{p}}", action: "create", before: null, after: { productId: "{{p}}" } }];
    assert.equal(OL.validateOperationRequest({ requestId: key, opType: "addProduct", ops }).ok, true);
    const wrong = OL.validateOperationRequest({ requestId: Keys.restockKey("n1"), opType: "addProduct", ops });
    assert.equal(wrong.ok, false, "the server enforces the prefix");
});

test("K-6 createdTxId and productAddedActId keep their prefixes and carry product and nonce", () => {
    assert.equal(Keys.createdTxId("PRD-007", "n1"), "tx-c-PRD-007-n1");
    assert.equal(Keys.createdTxId("{{prd}}", "n1"), "tx-c-{{prd}}-n1");
    assert.equal(Keys.productAddedActId("PRD-007", "n1"), "act-PRD-007-n1");
    assert.notEqual(Keys.createdTxId("PRD-007", "n1"), Keys.createdTxId("PRD-007", "n2"));
});

// ---------------------------------------------------------------------------- build: shape

test("B-1 new supplier + stock: eight ops, all mints first, tokens in the right places, nonce in both history ids", () => {
    const p = build();
    assert.equal(p.ok, true);
    assert.equal(p.key, KEY);
    assert.equal(p.opType, "addProduct");
    assert.deepEqual(p.at, { productMint: 0, supplierMint: 1, batchMint: 2, supplierCreate: 3, productCreate: 4, batchCreate: 5, created: 6, activity: 7 });
    assert.deepEqual(p.ops.map((o) => o.kind), ["mint", "mint", "mint", "mutation", "mutation", "mutation", "mutation", "mutation"]);
    assert.deepEqual(p.ops.slice(0, 3), [
        { kind: "mint", counter: "product", bind: "prd" }, { kind: "mint", counter: "supplier", bind: "sup" }, { kind: "mint", counter: "stock_batch", bind: "batch" }]);
    const [, , , sup, prd, bat, tx, act] = p.ops;
    assert.deepEqual([sup.entity, sup.entityId, sup.after.name], ["supplier", "{{sup}}", "Acme Farms"]);
    assert.deepEqual([prd.entity, prd.entityId, prd.after.productId, prd.after.supplierId, prd.after.name, prd.after.stock], ["inventory", "{{prd}}", "{{prd}}", "{{sup}}", "Tomato", 12]);
    assert.deepEqual([bat.entity, bat.entityId, bat.after.productId, bat.after.supplierId, bat.after.qtyReceived, bat.after.qtyRemaining, bat.after.unitCost, bat.after.note],
        ["stock_batch", "{{batch}}", "{{prd}}", "{{sup}}", 12, 12, 18.5, "Initial stock"]);
    assert.deepEqual([tx.entity, tx.entityId, tx.after.txId, tx.after.kind, tx.after.productId, tx.after.quantity, tx.after.total, tx.after.party],
        ["transaction", "tx-c-{{prd}}-" + NONCE, "tx-c-{{prd}}-" + NONCE, "created", "{{prd}}", 12, 222, "{{sup}}"]);
    assert.deepEqual([act.entity, act.entityId, act.after.id, act.after.kind, act.after.entityId], ["activity", "act-{{prd}}-" + NONCE, "act-{{prd}}-" + NONCE, "product_added", "{{prd}}"]);
    assert.equal(act.after.title, "Product added: Tomato");
    assert.equal(act.after.subtitle, "TO-2026-001 \u00b7 stock 12");
    for (const o of p.ops.filter((x) => x.kind === "mutation")) { assert.equal(o.action, "create"); assert.equal(o.before, null); }
    assert.equal(p.ops.some((o) => o.kind === "delta"), false, "the server derives the ledger row, the plan sends no delta or movements");
});

test("B-2 known supplier: no supplier mint or create, the id rides on product, batch and history", () => {
    const p = build({ supplier: { id: "SUP-009" } });
    assert.equal(p.ok, true);
    assert.deepEqual(p.at, { productMint: 0, supplierMint: -1, batchMint: 1, supplierCreate: -1, productCreate: 2, batchCreate: 3, created: 4, activity: 5 });
    const [, , prd, bat, tx] = p.ops;
    assert.equal(prd.after.supplierId, "SUP-009"); assert.equal(bat.after.supplierId, "SUP-009");
    assert.equal(tx.after.party, "SUP-009"); assert.equal(tx.after.snapshot.supplierId, "SUP-009"); assert.equal(tx.after.snapshot.party, "SUP-009");
});

test("B-3 no supplier (null or absent): empty ids and no party in the snapshot", () => {
    for (const supplier of [null, undefined]) {
        const p = build({ supplier });
        assert.equal(p.ok, true);
        const prd = p.ops[p.at.productCreate], tx = p.ops[p.at.created];
        assert.equal(prd.after.supplierId, ""); assert.equal(tx.after.party, ""); assert.equal(tx.after.snapshot.supplierId, "");
        assert.equal(Object.prototype.hasOwnProperty.call(tx.after.snapshot, "party"), false);
    }
});

test("B-4 stock 0: no batch mint, no batch doc, the created row and the feed row are still there", () => {
    const p = build({ stock: 0, supplier: null });
    assert.equal(p.ok, true);
    assert.deepEqual(p.at, { productMint: 0, supplierMint: -1, batchMint: -1, supplierCreate: -1, productCreate: 1, batchCreate: -1, created: 2, activity: 3 });
    assert.equal(p.ops.some((o) => o.entity === "stock_batch" || o.counter === "stock_batch"), false);
    assert.equal(p.ops[p.at.created].after.quantity, 0); assert.equal(p.ops[p.at.created].after.total, 0);
    assert.equal(p.ops[p.at.activity].after.subtitle, "TO-2026-001 \u00b7 stock 0");
});

test("B-5 no SKU: the feed subtitle is just the stock, like the client row always was", () => {
    const p = build({ sku: "   " });
    assert.equal(p.ops[p.at.activity].after.subtitle, "stock 12");
    assert.equal(p.ops[p.at.productCreate].after.sku, "");
});

test("B-6 fractional stock is kept exactly everywhere (the old path rounded it in the created row only)", () => {
    const p = build({ stock: 2.5, unitCost: 10 });
    assert.equal(p.ops[p.at.productCreate].after.stock, 2.5); assert.equal(p.ops[p.at.batchCreate].after.qtyReceived, 2.5);
    assert.equal(p.ops[p.at.created].after.quantity, 2.5); assert.equal(p.ops[p.at.created].after.total, 25);
});

test("B-7 total is rounded to 2 places; a huge cost that stays finite is kept as it is", () => {
    const p = build({ stock: 3, unitCost: 0.1, supplier: null });
    assert.equal(p.ops[p.at.created].after.total, 0.3);
    const huge = build({ stock: 1, unitCost: 1e308, supplier: null });
    assert.equal(huge.ok, true); assert.equal(huge.ops[huge.at.created].after.total, 1e308);
});

test("B-8 text is trimmed; description too; the input object is never changed", () => {
    const inp = input({ name: "  A  ", sku: " s ", category: " c ", unit: " u ", size: " z ", description: " d " });
    const copy = JSON.stringify(inp);
    const p = plain(AP.build(inp));
    assert.equal(JSON.stringify(inp), copy);
    const d = p.ops[p.at.productCreate].after;
    assert.deepEqual([d.name, d.sku, d.category, d.unit, d.size, d.description], ["A", "s", "c", "u", "z", "d"]);
    assert.deepEqual(d.photoIds, []);
});

test("B-9 the product doc has exactly the keys InventoryStore._newProductDoc sends (drift guard), same for the batch doc", () => {
    const run = (file, fn, args) => {
        const ctx = {};
        vm.runInNewContext(extractFunction(file, fn).replace("function " + fn, "var __f = function"), ctx);
        return ctx.__f.apply(null, args);
    };
    const legacy = run("model/InventoryStore.qml", "_newProductDoc", ["i", "n", "s", "c", 1, 1, 1, 1, false, 0, "", "u", "d", "x"]);
    const p = build();
    assert.deepEqual(Object.keys(p.ops[p.at.productCreate].after).sort(), Object.keys(legacy).sort());
    const legacyBatch = run("model/StockBatchStore.qml", "_buildBatchDoc", ["i", "p", "s", 1, 1, "n"]);
    assert.deepEqual(Object.keys(p.ops[p.at.batchCreate].after).sort(), Object.keys(legacyBatch).sort());
    // the created row: the 14 keys TransactionStore.recordCreated has always written
    const created = p.ops[p.at.created].after;
    assert.deepEqual(Object.keys(created).sort(), ["category", "date", "kind", "orderId", "party", "productId", "productName", "quantity", "snapshot", "timestamp", "total", "txId", "unitCost", "unitPrice"].sort());
    assert.deepEqual(Object.keys(created.snapshot).sort(), ["category", "description", "minStock", "party", "sellingPrice", "size", "sku", "supplierId", "taxable", "taxPercent", "unit"].sort());
});

// ---------------------------------------------------------------------------- build: refusals and limits

test("R-1 every refusal reason, with the input that earns it", () => {
    const cases = [
        ["bad-key", { key: "restock:x" }], ["bad-key", { key: "" }], ["bad-key", { key: undefined }], ["bad-key", { key: "addProduct:a/b" }],
        ["bad-name", { name: "" }], ["bad-name", { name: "   " }], ["bad-name", { name: 5 }], ["bad-name", { name: null }],
        ["bad-price", { price: -1 }], ["bad-price", { price: NaN }], ["bad-price", { price: Infinity }], ["bad-price", { price: "5" }], ["bad-price", { sellingPrice: -0.01 }], ["bad-price", { sellingPrice: undefined }],
        ["bad-tax", { taxable: "yes" }], ["bad-tax", { taxable: undefined }], ["bad-tax", { taxPercent: -1 }], ["bad-tax", { taxPercent: 100.01 }], ["bad-tax", { taxPercent: NaN }], ["bad-tax", { taxPercent: "5" }],
        ["bad-stock", { stock: -1 }], ["bad-stock", { stock: NaN }], ["bad-stock", { stock: "12" }], ["bad-stock", { stock: Infinity }], ["bad-stock", { minStock: -1 }], ["bad-stock", { minStock: undefined }],
        ["bad-cost", { unitCost: -1 }], ["bad-cost", { unitCost: NaN }], ["bad-cost", { unitCost: "1" }], ["bad-cost", { unitCost: 1e308, stock: 5 }], ["bad-cost", { unitCost: 5, stock: 1e308 }],
        ["bad-supplier", { supplier: "Acme" }], ["bad-supplier", { supplier: 5 }], ["bad-supplier", { supplier: {} }], ["bad-supplier", { supplier: { id: "" } }], ["bad-supplier", { supplier: { newName: "  " } }],
        ["bad-supplier", { supplier: { id: 7 } }], ["bad-supplier", { supplier: { id: "SUP-{{prd}}" } }], ["bad-supplier", { supplier: { id: "a}}b" } }],
        ["bad-time", { now: "" }], ["bad-time", { now: 5 }], ["bad-time", { now: "{{{" }], ["bad-time", { now: "2026-06-15" }], ["bad-time", { now: "2026-06-15T12:00:00" }], ["bad-time", { now: "2026-06-15T12:00:00.0000Z" }], ["bad-time", { date: "15/06/2026" }], ["bad-time", { date: "2026-6-5" }], ["bad-time", { date: undefined }],
        // PR #201 sweep F1: the right SHAPE is not a real instant. Each of these matched the old regex and no Date can read it
        // (month 13, hour 25, 24:00, 31 February that rolls into March, zero month and day).
        ["bad-time", { now: "2026-13-45T10:00:00Z" }], ["bad-time", { now: "2026-06-15T25:61:61Z" }], ["bad-time", { now: "2026-06-15T24:00:00Z" }],
        ["bad-time", { now: "2026-02-31T10:00:00Z" }], ["bad-time", { now: "0000-00-00T00:00:00Z" }], ["bad-time", { now: "2026-06-15T12:60:00Z" }],
        ["bad-time", { date: "2026-13-45" }], ["bad-time", { date: "2026-02-31" }], ["bad-time", { date: "2026-02-29" }], ["bad-time", { date: "0000-00-00" }],
        ["bad-time", { date: "1900-02-29" }], ["bad-time", { date: "2026-04-31" }]
    ];
    for (const [reason, over] of cases) {
        const p = build(over);
        assert.deepEqual(p, { ok: false, reason: reason }, reason + " <- " + JSON.stringify(over));
    }
});

test("R-2 boundaries that are allowed: zero price, zero cost, zero min stock, tax 0 and 100, a tiny and a huge finite stock", () => {
    for (const over of [{ price: 0, sellingPrice: 0 }, { unitCost: 0 }, { minStock: 0 }, { taxPercent: 0 }, { taxPercent: 100 }, { stock: 1e-9 }, { stock: 1e15, unitCost: 1 }, { taxable: false }])
        assert.equal(build(over).ok, true, JSON.stringify(over));
});

test("R-6 time boundaries that ARE real are accepted: leap days, year ends, every ISO fraction length", () => {
    for (const now of ["2028-02-29T23:59:59Z", "2026-06-15T12:00:00.5Z", "2026-06-15T12:00:00.12Z", "2026-12-31T23:59:59.999Z", "1970-01-01T00:00:00Z", "2026-01-01T00:00:00.000Z"])
        assert.equal(build({ now }).ok, true, now);
    for (const date of ["2028-02-29", "2000-02-29", "2026-12-31", "2026-01-01", "2026-04-30", "2026-02-28"])
        assert.equal(build({ date }).ok, true, date);
    // the check must not depend on the caller's time zone or on `date` agreeing with `now` (a local date near midnight differs from the UTC one)
    assert.equal(build({ now: "2026-06-15T23:30:00.000Z", date: "2026-06-16" }).ok, true);
});

test("R-3 not an object: refused, never thrown", () => {
    for (const bad of [null, undefined, "x", 5, true, []]) assert.deepEqual(plain(AP.build(bad)), { ok: false, reason: "bad-key" }, String(bad));
});

test("R-4 a doc over Firestore's 1 MiB is refused before anything is queued; just under is accepted", () => {
    assert.deepEqual(build({ description: "x".repeat(1100000) }), { ok: false, reason: "too-large" });
    assert.equal(build({ description: "x".repeat(100000) }).ok, true);
});

test("R-5 refused input builds nothing (no ops, no at)", () => {
    const p = build({ name: "" });
    assert.deepEqual(Object.keys(p).sort(), ["ok", "reason"]);
});

test("B-10 feed text is cut, never refused: a 5000-character name and SKU still add; the caps hold; no lone surrogate", async () => {
    const p = build({ name: "n".repeat(5000), sku: "s".repeat(5000), supplier: null });
    assert.equal(p.ok, true);
    const act = p.ops[p.at.activity].after;
    assert.equal(act.title, "Product added: " + "n".repeat(150));
    assert.equal(act.subtitle, "s".repeat(100) + " \u00b7 stock 12");
    assert.equal(p.ops[p.at.productCreate].after.name.length, 5000, "the product itself is stored whole");
    assert.equal((await apply(withCounter(6), p)).ok, true);
    // an emoji (two UTF-16 halves) straddling the cut: the whole emoji goes, never half of it
    const e = build({ name: "a".repeat(149) + "\u{1F600}b", sku: "b".repeat(99) + "\u{1F600}", supplier: null }).ops;
    const a2 = e[e.length - 1].after;
    assert.equal(a2.title, "Product added: " + "a".repeat(149));
    assert.equal(a2.subtitle, "b".repeat(99) + " \u00b7 stock 12");
    assert.equal(build({ name: "a".repeat(149) + "\u{1F600}", supplier: null }).ops.slice(-1)[0].after.title, "Product added: " + "a".repeat(149), "cut exactly at 150 when the 150th unit is a high surrogate");
    assert.equal(build({ name: "a".repeat(148) + "\u{1F600}", supplier: null }).ops.slice(-1)[0].after.title, "Product added: " + "a".repeat(148) + "\u{1F600}", "an emoji that fits is kept");
});

// ---------------------------------------------------------------------------- typed text and the placeholder grammar (D-AP-12)

test("N-1 neutralisePlaceholders: one space inside every touching pair, nothing else changes", () => {
    const f = (s) => AP.neutralisePlaceholders(s);
    assert.equal(f("{{prd}}"), "{ {prd} }");
    assert.equal(f("{{$stock}}"), "{ {$stock} }");
    assert.equal(f("}}{{"), "} }{ {");
    assert.equal(f("{{{"), "{ { {");
    assert.equal(f("}}}"), "} } }");
    assert.equal(f("{{{{"), "{ { { {");
    for (const same of ["", "plain", "{", "}", "{ }", "} {", "a{b}c", "{x}", "100% {ok}", "\u0928\u092e\u0938\u094d\u0924\u0947", "😀{😀}"]) assert.equal(f(same), same, same);
    for (const s of ["{{", "}}", "{{{", "}}}", "x{{y}}z{{{w}}}", "{}{}{{}}", "{{}}"]) {
        const out = f(s);
        assert.equal(out.indexOf("{{") < 0 && out.indexOf("}}") < 0, true, s + " -> " + out);
        assert.equal(out.replace(/ /g, ""), s.replace(/ /g, ""), "only spaces are added: " + s);
    }
    assert.equal(f(undefined), ""); assert.equal(f(null), ""); assert.equal(f(5), "");
});

test("N-2 every typed string is neutralised in the plan: no brace pair survives outside the planner's own tokens", () => {
    const evil = "{{prd}}{{sup}}{{batch}}{{$stock}}}}{{";
    const p = build({ name: evil, sku: evil, category: evil, unit: evil, size: evil, description: evil, supplier: { newName: evil } });
    assert.equal(p.ok, true);
    const own = /\{\{(prd|sup|batch)\}\}/g;
    for (const s of textsOf(p.ops)) {
        const rest = s.replace(own, "");
        assert.equal(rest.indexOf("{{") < 0 && rest.indexOf("}}") < 0, true, s);
    }
});

test("N-3 through the real server: a name typed {{prd}}, {{$stock}} or }}{{ is stored with the one-space change, never as an id, a stock token or a 400", async () => {
    for (const name of ["{{prd}}", "{{$stock}}", "}}{{", "{{batch}} and {{sup}}"]) {
        const db = withCounter(6);
        const r = await apply(db, plain(AP.build(input({ name, sku: name, supplier: { newName: name } }))));
        assert.equal(r.ok, true, name + " " + JSON.stringify(r));
        const inv = db.store[T + "inventory/PRD-007"];
        assert.equal(inv.name, AP.neutralisePlaceholders(name));
        assert.equal(inv.productId, "PRD-007");
        assert.equal(db.store[T + "suppliers/SUP-001"].name, AP.neutralisePlaceholders(name));
        const act = db.store[T + "activity_log/act-PRD-007-" + NONCE];
        assert.equal(act.title, "Product added: " + AP.neutralisePlaceholders(name));
    }
});

test("N-4 an ordinary name with a single brace is stored byte-identical", async () => {
    const db = withCounter(6);
    const r = await apply(db, plain(AP.build(input({ name: "Rod {10mm}", supplier: null }))));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/PRD-007"].name, "Rod {10mm}");
});

// ---------------------------------------------------------------------------- the real server: apply, reflect, replay

test("S-1 the plan is accepted and applied: every doc lands under the real ids, one derived receipt row", async () => {
    const db = withCounter(6);
    const r = await apply(db, build());
    assert.equal(r.ok, true, JSON.stringify(r));
    assert.equal(db.store[T + "inventory/PRD-007"].supplierId, "SUP-001");
    assert.equal(db.store[T + "stock_batches/BAT-2026-001"].productId, "PRD-007");
    assert.equal(db.store[T + "transactions/tx-c-PRD-007-" + NONCE].productId, "PRD-007");
    assert.equal(db.store[T + "transactions/tx-c-PRD-007-" + NONCE].snapshot.supplierId, "SUP-001");
    assert.equal(db.store[T + "transactions/tx-c-PRD-007-" + NONCE].party, "SUP-001");
    const act = db.store[T + "activity_log/act-PRD-007-" + NONCE];
    assert.deepEqual([act.kind, act.entityId, act.actorUid, act.timestamp], ["product_added", "PRD-007", "u-actor", ISO]);
    const rows = rowsOf(db);
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].data.kind, rows[0].data.qty, rows[0].data.productId], ["receipt", 12, "PRD-007"]);
});

test("S-2 reflect reads the live answer back into plain docs", async () => {
    const db = withCounter(6);
    const r = await apply(db, build());
    const x = plain(AP.reflect(r.results));
    assert.equal(x.ok, true, JSON.stringify(x));
    assert.deepEqual([x.productId, x.stock, x.batchId, x.supplierId], ["PRD-007", 12, "BAT-2026-001", "SUP-001"]);
    assert.equal(x.product.name, "Tomato"); assert.equal(x.batch.batchId, "BAT-2026-001"); assert.equal(x.supplier.name, "Acme Farms");
    assert.equal(x.created.txId, "tx-c-PRD-007-" + NONCE); assert.equal(x.activity.id, "act-PRD-007-" + NONCE);
    assert.equal(typeof x.activity.timestamp, "string");
});

test("S-3 reflect: no supplier and known supplier; stock 0 gives batchId \"\" and batch null", async () => {
    let r = await apply(withCounter(6), build({ supplier: null }));
    let x = plain(AP.reflect(r.results));
    assert.equal(x.ok, true); assert.equal(x.supplierId, ""); assert.equal(x.supplier, null);
    r = await apply(withCounter(6), build({ supplier: { id: "SUP-009" }, stock: 0 }));
    x = plain(AP.reflect(r.results));
    assert.equal(x.ok, true); assert.deepEqual([x.supplierId, x.batchId, x.batch, x.stock], ["SUP-009", "", null, 0]);
});

test("S-4 a replay (same key) answers with the same results and the same ids, writes nothing, and reflects the same", async () => {
    const db = withCounter(6);
    const plan = build();
    const first = await apply(db, plan);
    const before = db.writes.length;
    const again = await apply(db, plan);
    assert.equal(again.ok, true, JSON.stringify(again));
    assert.equal(db.writes.length, before, "a replay writes nothing");
    assert.deepEqual(plain(AP.reflect(again.results)), plain(AP.reflect(first.results)));
});

test("S-5 K-2 of AP1 closed: a product number handed out twice no longer ends in a 409, the history rows get different ids", async () => {
    const db = withCounter(6);
    const a = await apply(db, build({ supplier: null }));
    assert.equal(a.ok, true);
    // the top product is deleted, the counter is damaged back; its history rows stay (nothing deletes them)
    delete db.store[T + "inventory/PRD-007"];
    db.store[T + "counters/products"] = { value: 6 };
    const key2 = Keys.addProductKey(Keys.addProductNonce(1781000000001, seq([0.2, 0.3])));
    const b = await apply(db, build({ key: key2, supplier: null }));
    assert.equal(b.ok, true, JSON.stringify(b));
    const rb = plain(AP.reflect(b.results));
    assert.equal(rb.ok, true);
    assert.equal(rb.productId, "PRD-007");
    assert.notEqual(rb.created.txId, "tx-c-PRD-007-" + NONCE);
    assert.ok(db.store[T + "transactions/tx-c-PRD-007-" + NONCE] && db.store[T + "transactions/" + rb.created.txId], "both history rows exist");
});

test("S-6 two adds in a row get two products, two batches, two feed rows", async () => {
    const db = withCounter(6);
    const a = await apply(db, build({ supplier: null }));
    const b = await apply(db, build({ key: Keys.addProductKey("second"), supplier: null }));
    assert.equal(a.ok && b.ok, true);
    assert.ok(db.store[T + "inventory/PRD-007"] && db.store[T + "inventory/PRD-008"]);
    assert.deepEqual(db.store[T + "counters/products"], { value: 8 });
});

test("S-7 the plan is accepted for every combination of supplier (none, known, new) and stock (0, fraction, 12)", async () => {
    for (const supplier of [null, { id: "SUP-009" }, { newName: "New Co" }])
        for (const stock of [0, 2.5, 12]) {
            const r = await apply(withCounter(6), build({ supplier, stock }));
            assert.equal(r.ok, true, JSON.stringify({ supplier, stock, r }));
            assert.equal(plain(AP.reflect(r.results)).ok, true);
        }
});

test("S-8 stock 0 derives no ledger row; stock > 0 derives exactly one receipt", async () => {
    let db = withCounter(6);
    await apply(db, build({ stock: 0, supplier: null }));
    assert.equal(rowsOf(db).length, 0);
    db = withCounter(6);
    await apply(db, build({ stock: 7, supplier: null }));
    assert.deepEqual(rowsOf(db).map((w) => [w.data.kind, w.data.qty]), [["receipt", 7]]);
});

// ---------------------------------------------------------------------------- reflect: refusals

async function good() { return plain((await apply(withCounter(6), build())).results); }

test("F-1 reflect refuses anything that is not exactly one add answer", async () => {
    const g = await good();
    const at = (pred) => g.findIndex(pred);
    const iInv = at((r) => r.entity === "inventory"), iBat = at((r) => r.entity === "stock_batch"), iSup = at((r) => r.entity === "supplier");
    const iTx = at((r) => r.entity === "transaction"), iAct = at((r) => r.entity === "activity");
    const iPrd = at((r) => r.kind === "mint" && r.bind === "prd"), iBm = at((r) => r.kind === "mint" && r.bind === "batch"), iSm = at((r) => r.kind === "mint" && r.bind === "sup");
    const clone = () => JSON.parse(JSON.stringify(g));
    const cases = {
        "not-a-list": null, "entry-null": (r) => { r[1] = null; }, "entry-string": (r) => { r[0] = "x"; },
        "unknown kind": (r) => { r.push({ kind: "delta", entity: "inventory", entityId: "p", after: { stock: 1 } }); },
        "mint without id": (r) => { delete r[iPrd].id; }, "mint with empty id": (r) => { r[iPrd].id = ""; }, "mint of an unknown bind": (r) => { r[iPrd].bind = "zzz"; },
        "mint twice": (r) => { r.unshift(Object.assign({}, r[iPrd])); },
        "no product mint": (r) => { r.splice(iPrd, 1); },
        "mutation without after": (r) => { delete r[iInv].after; }, "mutation of an unknown entity": (r) => { r[iInv].entity = "order"; },
        "two inventory docs": (r) => { r.push(Object.assign({}, r[iInv])); },
        "no inventory doc": (r) => { r.splice(iInv, 1); },
        "no created row": (r) => { r.splice(iTx, 1); }, "no feed row": (r) => { r.splice(iAct, 1); }, "two feed rows": (r) => { r.push(Object.assign({}, r[iAct])); },
        "product id differs from the mint": (r) => { r[iInv].after.productId = "PRD-999"; },
        "stock not a number": (r) => { r[iInv].after.stock = "12"; }, "negative stock": (r) => { r[iInv].after.stock = -1; },
        "stock > 0 but no batch mint": (r) => { r.splice(iBm, 1); }, "stock > 0 but no batch doc": (r) => { r.splice(iBat, 1); },
        "batch id differs": (r) => { r[iBat].after.batchId = "BAT-X"; }, "batch of another product": (r) => { r[iBat].after.productId = "PRD-999"; },
        "batch qty differs": (r) => { r[iBat].after.qtyReceived = 11; }, "batch remaining differs": (r) => { r[iBat].after.qtyRemaining = 11; },
        "supplier mint without a doc": (r) => { r.splice(iSup, 1); }, "supplier doc id differs": (r) => { r[iSup].after.supplierId = "SUP-999"; },
        "product does not carry the supplier": (r) => { r[iInv].after.supplierId = ""; }, "batch does not carry the supplier": (r) => { r[iBat].after.supplierId = ""; },
        "supplier doc without a mint": (r) => { r.splice(iSm, 1); },
        "created id without the product": (r) => { r[iTx].after.txId = "tx-c-PRD-999-n"; }, "created kind differs": (r) => { r[iTx].after.kind = "purchase"; },
        "created of another product": (r) => { r[iTx].after.productId = "PRD-999"; },
        "feed id without the product": (r) => { r[iAct].after.id = "act-PRD-999-n"; }, "feed kind differs": (r) => { r[iAct].after.kind = "product_restocked"; },
        "feed of another product": (r) => { r[iAct].after.entityId = "PRD-999"; }, "feed without a timestamp": (r) => { delete r[iAct].after.timestamp; },
        "the two nonces differ": (r) => { r[iAct].after.id = r[iAct].after.id + "x"; }
    };
    for (const [label, mutate] of Object.entries(cases)) {
        const r = label === "not-a-list" ? null : clone();
        if (r) mutate(r);
        const x = plain(AP.reflect(r));
        assert.equal(x.ok, false, label);
        assert.equal(x.reason, "malformed-results", label);
        assert.equal(typeof x.detail, "string", label);
    }
    assert.equal(iInv >= 0 && iBat >= 0 && iSup >= 0 && iTx >= 0 && iAct >= 0 && iPrd >= 0 && iBm >= 0 && iSm >= 0, true);
});

test("F-2 reflect: a batch (or batch mint) with stock 0 is refused", async () => {
    const g = plain((await apply(withCounter(6), build({ supplier: null }))).results);
    const zero = JSON.parse(JSON.stringify(g)); zero.find((r) => r.entity === "inventory").after.stock = 0;
    assert.equal(plain(AP.reflect(zero)).detail, "batch-without-stock");
    const zero2 = JSON.parse(JSON.stringify(g)).filter((r) => r.entity !== "stock_batch"); zero2.find((r) => r.entity === "inventory").after.stock = 0;
    assert.equal(plain(AP.reflect(zero2)).detail, "batch-without-stock", "the batch mint alone is still too much");
});

test("F-3 a result the server could only send for a restock is refused as an add answer", () => {
    assert.equal(plain(AP.reflect([{ kind: "mint", bind: "batch", id: "B1" }, { kind: "delta", entity: "inventory", entityId: "p", after: { stock: 1 } }])).ok, false);
});

// ---------------------------------------------------------------------------- monkey tests (seeded, reproducible)

function prng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }

test("M-1 monkey: 3000 random inputs never throw; an accepted plan always passes the real validator and has no stray brace pair", () => {
    const rnd = prng(20261115);
    const junk = [undefined, null, "", " ", "x", "{{prd}}", "{{$stock}}", "}}{{", "{{{", "é", "😀", "a".repeat(300), 0, -1, 1, 2.5, 1e308, -1e308, NaN, Infinity, true, false, {}, [], { id: "S" }, { newName: "N" }, { newName: "{{sup}}" }, { id: "" },
        // time-shaped values, so `now` and `date` are reached with near misses and with real ones (F1)
        "2026-13-45T10:00:00Z", "2026-02-31", "2026-06-15T12:00:00.000Z", "2026-06-16", "2026-06-15T24:00:00Z"];
    const pick = () => junk[Math.floor(rnd() * junk.length)];
    const reasons = new Set(["bad-key", "bad-name", "bad-price", "bad-tax", "bad-stock", "bad-cost", "bad-supplier", "bad-time", "too-large"]);
    let accepted = 0, refused = 0;
    for (let i = 0; i < 3000; ++i) {
        const inp = input();
        for (const k of Object.keys(inp)) if (rnd() < 0.3) inp[k] = pick();
        const p = plain(AP.build(inp));
        if (p.ok) {
            accepted++;
            const v = OL.validateOperationRequest({ requestId: p.key, opType: p.opType, ops: p.ops });
            assert.equal(v.ok, true, JSON.stringify({ inp, v }));
            // F1 invariant: whatever got through holds a real instant and a real calendar day (an invalid Date would throw here)
            const stamp = p.ops[p.at.created].after.timestamp, day = p.ops[p.at.created].after.date;
            assert.equal(new Date(stamp).toISOString().slice(0, 19), stamp.slice(0, 19), "real instant: " + stamp);
            assert.equal(new Date(day + "T00:00:00Z").toISOString().slice(0, 10), day, "real day: " + day);
            for (const s of textsOf(p.ops)) {
                const rest = s.replace(/\{\{(prd|sup|batch)\}\}/g, "");
                assert.equal(rest.indexOf("{{") < 0 && rest.indexOf("}}") < 0, true, s);
            }
        } else {
            refused++;
            assert.equal(reasons.has(p.reason), true, JSON.stringify(p));
        }
    }
    assert.ok(accepted > 50 && refused > 50, "the monkey must reach both sides: " + accepted + "/" + refused);
});

test("M-2 monkey: reflect never throws on 3000 randomly damaged answers and refuses every damaged one it can detect", async () => {
    const g = plain((await apply(withCounter(6), build())).results);
    const rnd = prng(424242);
    const damage = [(v) => undefined, (v) => null, (v) => "x", (v) => -1, (v) => ({}), (v) => [], (v) => v + "z", (v) => !v];
    let refused = 0;
    for (let i = 0; i < 3000; ++i) {
        const r = JSON.parse(JSON.stringify(g));
        const e = r[Math.floor(rnd() * r.length)];
        const keys = Object.keys(e).concat(e.after ? Object.keys(e.after).map((k) => "after." + k) : []);
        const k = keys[Math.floor(rnd() * keys.length)];
        const f = damage[Math.floor(rnd() * damage.length)];
        if (k.indexOf("after.") === 0) e.after[k.slice(6)] = f(e.after[k.slice(6)]); else e[k] = f(e[k]);
        const x = plain(AP.reflect(r));
        assert.equal(typeof x.ok, "boolean");
        if (!x.ok) { refused++; assert.equal(x.reason, "malformed-results"); }
    }
    assert.ok(refused > 500, "refused " + refused);
    for (const bad of [undefined, 5, "x", {}, [[]], [null], [{}], [{ kind: "mint" }]]) assert.equal(plain(AP.reflect(bad)).ok, false);
});

// ---------------------------------------------------------------------------- FailureCause and DescribeItem

test("C-1 forAddProduct: person-facing texts for conflict, mint-exhausted, request-id-in-use; app bugs for what an add can never meet", () => {
    const f = (code, name) => plain(FC.forAddProduct({ error: code }, name));
    assert.deepEqual([f("conflict", "Tomato").kind, f("conflict", "Tomato").text.indexOf("Tomato: ")], ["conflict", 0]);
    assert.ok(f("conflict", "").text.indexOf("Nothing was added") > 0);
    assert.equal(f("conflict", "").text.indexOf("Tomato"), -1);
    assert.equal(f("mint-exhausted").kind, "limit"); assert.ok(f("mint-exhausted").text.indexOf("product number") > 0);
    assert.equal(f("request-id-in-use").kind, "duplicate");
    for (const code of ["not-found", "insufficient-quantity", "operation-too-large", "invalid-activity", "unbound-placeholder"]) {
        assert.equal(f(code).kind, "bug", code); assert.ok(f(code).text.indexOf("(" + code + ")") > 0, code);
    }
    assert.equal(plain(FC.forAddProduct(null, "")).kind, "unknown");
    assert.equal(plain(FC.forAddProduct({ error: "<b>x</b>" }, "")).text, "The server rejected this change");
});

test("C-2 forAddProduct answers every code the server has with a non-empty text (drift guard lives in failureCauseCodes.test.js C-2)", () => {
    for (const code of ["conflict", "mint-exhausted", "request-id-in-use", "not-found", "x"]) assert.ok(plain(FC.forAddProduct({ error: code }, "P")).text.length > 0);
});

test("D-1 DescribeItem labels an add by the typed product name, never by a mint", () => {
    const p = build();
    assert.deepEqual(plain(DI.describe({ opType: "addProduct", ops: p.ops })), { title: "Add product", detail: "Tomato" });
    assert.deepEqual(plain(DI.describe({ opType: "addProduct", ops: [{ kind: "mint", counter: "product", bind: "prd" }] })), { title: "Add product", detail: "" });
    assert.deepEqual(plain(DI.describe({ opType: "addProduct", ops: [null, 5, { entity: "inventory", action: "create" }] })), { title: "Add product", detail: "" });
    assert.equal(plain(DI.describe({ opType: "restock", ops: [] })).title, "Restock");
    assert.equal(plain(DI.describe({ opType: "mystery", ops: [] })).title, "Multi-step change");
});

// ---------------------------------------------------------------------------- dormancy guard

test("G-1 dormant: nothing but the helper, its tests and the docs refers to the add-product plan or its keys", () => {
    const hits = [];
    (function walk(dir) {
        for (const f of fs.readdirSync(dir, { withFileTypes: true })) {
            const p = path.join(dir, f.name);
            if (f.isDirectory()) walk(p);
            else if (/\.(qml|js)$/.test(f.name) && !/AddProductPlan\.js$|OperationKeys\.js$|FailureCause\.js$/.test(f.name)
                     && /AddProductPlan|addProductKey|addProductNonce|forAddProduct/.test(fs.readFileSync(p, "utf8"))) hits.push(path.relative(QML_ROOT, p));
        }
    })(QML_ROOT);
    assert.deepEqual(hits, [], "AP3 wires it; until then nothing calls it");
});
