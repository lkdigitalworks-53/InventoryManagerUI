"use strict";

// Atomic-ops R3: qml/helper/RestockPlan.js + the restock ids in OperationKeys.js (design
// 2026-11-01-r3-restock-plan-design.md). The QML helpers run here with their REAL text (testSupport/
// qmlHelpers.js) and the plan is sent through the REAL server code (validateOperationRequest +
// applyOperation on the strict fake DB), so "the client plans what the server accepts" is proven, not
// assumed. tests/tst_RestockPlan.qml carries the same unit cases for CI's qmltestrunner.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const { TS, strictDb, rowsOf } = require("./testSupport/strictDb");
const { load, plain } = require("./testSupport/qmlHelpers");

const Keys = load("OperationKeys.js");
const RP = load("RestockPlan.js");

const T = "tenants/t1/";
const NOW = new Date("2026-06-15T12:00:00Z");
const ISO = "2026-06-15T12:00:00.000Z";
const KEY = "restock:1781000000000-abc";

function input(over) {
    return Object.assign({
        key: KEY, productId: "p1", productName: "Tomato", category: "Veg", qty: 5, unitCost: 12.5,
        reason: "  weekly  ", now: ISO, date: "2026-06-15", supplier: { newName: "  Acme Farms " }
    }, over || {});
}
const build = (over) => plain(RP.build(input(over)));
function seq(values) { let i = 0; return () => values[i++ % values.length]; }

// ---------------------------------------------------------------------------- keys

test("K-1 restockNonce: time + two padded 6-char draws, deterministic for a fixed random", () => {
    assert.equal(Keys.restockNonce(1700000000123, seq([0, 0])), "1700000000123-000000000000");
    assert.equal(Keys.restockNonce(1700000000123.9, seq([0.5, 0.25])), "1700000000123-i00000" + Math.floor(0.25 * 2176782336).toString(36).padStart(6, "0"));
    const a = Keys.restockNonce(1, seq([0.1, 0.2])), b = Keys.restockNonce(1, seq([0.1, 0.3]));
    assert.notEqual(a, b, "two taps in one millisecond with different draws must differ");
});

test("K-2 restockKey accepts a plain token and refuses everything the server would or could mishandle", () => {
    assert.equal(Keys.restockKey("a-b_c.1"), "restock:a-b_c.1");
    assert.equal(Keys.restockKey("x".repeat(100)), "restock:" + "x".repeat(100));
    for (const bad of ["", "x".repeat(101), "a/b", "a~b", "a b", "a:b", "é", "a\n", null, undefined, 5, {}, []])
        assert.equal(Keys.restockKey(bad), "", JSON.stringify(bad));
});

test("K-3 isRestockKey: only a well-formed restock key; a completeOrder key is not one", () => {
    assert.equal(Keys.isRestockKey(Keys.restockKey("n1")), true);
    for (const bad of ["restock:", "restock:a/b", "restock:a~1", "completeOrder:o1:1", "Restock:x", " restock:x", "req-1-2", "", null, undefined, 7])
        assert.equal(Keys.isRestockKey(bad), false, String(bad));
});

test("K-4 a generated key passes the server's request-id rule for opType restock", () => {
    const key = Keys.restockKey(Keys.restockNonce(Date.now(), Math.random));
    const v = OL.validateOperationRequest({ requestId: key, opType: "restock", ops: [{ kind: "mint", counter: "stock_batch", bind: "b" }, { kind: "mutation", entity: "stock_batch", entityId: "{{b}}", action: "create", before: null, after: { batchId: "{{b}}" } }] });
    assert.equal(v.ok, true, JSON.stringify(v));
});

test("K-5 purchaseTxId keeps the tx-p- prefix and is derived from the batch id", () => {
    assert.equal(Keys.purchaseTxId("BAT-2026-038"), "tx-p-BAT-2026-038");
    assert.equal(Keys.purchaseTxId("{{batch}}"), "tx-p-{{batch}}");
});

// ---------------------------------------------------------------------------- build: shape

test("B-1 new supplier: seven ops, both mints first, tokens in the right places, receipt movement explicit", () => {
    const p = build();
    assert.equal(p.ok, true);
    assert.equal(p.key, KEY);
    assert.equal(p.opType, "restock");
    assert.deepEqual(p.at, { supplierMint: 0, batchMint: 1, supplierCreate: 2, batchCreate: 3, delta: 4, purchase: 5, activity: 6 });
    assert.deepEqual(p.ops.map((o) => o.kind), ["mint", "mint", "mutation", "mutation", "delta", "mutation", "mutation"]);
    assert.deepEqual(p.ops[0], { kind: "mint", counter: "supplier", bind: "sup" });
    assert.deepEqual(p.ops[1], { kind: "mint", counter: "stock_batch", bind: "batch" });
    assert.equal(p.ops[2].entityId, "{{sup}}");
    assert.equal(p.ops[2].after.name, "Acme Farms", "supplier name trimmed");
    assert.equal(p.ops[3].entityId, "{{batch}}");
    assert.equal(p.ops[3].after.supplierId, "{{sup}}");
    assert.deepEqual(p.ops[4], { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 5 }, floors: {}, clamps: {},
        movements: [{ kind: "receipt", qty: 5, reason: "weekly" }] });
    assert.equal(p.ops[5].entityId, "tx-p-{{batch}}");
    assert.equal(p.ops[5].after.party, "{{sup}}");
    for (const i of [2, 3, 5, 6]) { assert.equal(p.ops[i].action, "create"); assert.equal(p.ops[i].before, null); }
    // R5b: the feed row is last (after the delta whose stock it names), id from the batch, the new supplier's name shown
    assert.equal(p.ops[6].entity, "activity");
    assert.equal(p.ops[6].entityId, "act-{{batch}}");
    assert.deepEqual(p.ops[6].after, {
        id: "act-{{batch}}", kind: "product_restocked", title: "Restocked: Tomato",
        subtitle: "+5 · now {{$stock}} in stock · from Acme Farms · weekly", entityId: "p1", read: false, dismissed: false });
});

test("B-2 known supplier: five ops, no supplier mint or create, the id is used as typed", () => {
    const p = build({ supplier: { id: "SUP-009" } });
    assert.deepEqual(p.ops.map((o) => o.kind), ["mint", "mutation", "delta", "mutation", "mutation"]);
    assert.deepEqual(p.at, { supplierMint: -1, batchMint: 0, supplierCreate: -1, batchCreate: 1, delta: 2, purchase: 3, activity: 4 });
    assert.equal(p.ops[1].after.supplierId, "SUP-009");
    assert.equal(p.ops[3].after.party, "SUP-009");
    assert.equal(p.ops[4].after.subtitle, "+5 · now {{$stock}} in stock · weekly", "an id with no supplierName shows no supplier");
    assert.equal(build({ supplier: { id: "SUP-009" }, supplierName: "Acme Farms" }).ops[4].after.subtitle, "+5 · now {{$stock}} in stock · from Acme Farms · weekly");
});

test("B-3 no supplier (null or undefined): empty supplierId and party", () => {
    for (const s of [null, undefined]) {
        const p = build({ supplier: s });
        assert.equal(p.ok, true);
        assert.equal(p.ops.length, 5);
        assert.equal(p.ops[1].after.supplierId, "");
        assert.equal(p.ops[3].after.party, "");
    }
});

test("B-4 the three docs carry every field today's QML builders write, with today's values", () => {
    const p = build();
    assert.deepEqual(p.ops[2].after, { supplierId: "{{sup}}", name: "Acme Farms", contact: "", leadTimeDays: 0, terms: "", notes: "", createdAt: ISO, updatedAt: ISO });
    assert.deepEqual(p.ops[3].after, { batchId: "{{batch}}", productId: "p1", supplierId: "{{sup}}", qtyReceived: 5, qtyRemaining: 5, unitCost: 12.5,
        receivedDate: ISO, poId: "", note: "weekly", createdAt: ISO, updatedAt: ISO });
    assert.deepEqual(p.ops[5].after, { txId: "tx-p-{{batch}}", kind: "purchase", timestamp: ISO, date: "2026-06-15", productId: "p1", productName: "Tomato",
        category: "Veg", party: "{{sup}}", quantity: 5, unitCost: 12.5, unitPrice: 0, total: 62.5, orderId: "", reason: "weekly" });
});

test("B-5 free cost, fractional quantity, empty reason and non-string names are accepted and built", () => {
    const p = build({ unitCost: 0, qty: 2.5, reason: undefined, productName: undefined, category: 5 });
    assert.equal(p.ok, true);
    assert.equal(p.ops[5].after.total, 0);
    assert.equal(p.ops[5].after.productName, "");
    assert.equal(p.ops[5].after.category, "");
    assert.equal(p.ops[5].after.reason, "");
    assert.deepEqual(p.ops[4].movements, [{ kind: "receipt", qty: 2.5, reason: "" }]);
});

test("B-6 a reason longer than the movement limit is cut for the ledger row only (the doc keeps what was typed)", () => {
    const long = "r".repeat(600);
    const p = build({ reason: long });
    assert.equal(p.ok, true);
    assert.equal(p.ops[4].movements[0].reason.length, 500);
    assert.equal(p.ops[3].after.note.length, 600);
});

test("B-7 pure: the input is not changed and the same input gives the same plan", () => {
    const inp = input();
    const snapshot = JSON.stringify(inp);
    const a = plain(RP.build(inp)), b = plain(RP.build(inp));
    assert.equal(JSON.stringify(inp), snapshot);
    assert.deepEqual(a, b);
});

// ---------------------------------------------------------------------------- build: refusals

test("R-1 every refusal reason, each reachable, none builds ops", () => {
    const cases = [
        ["bad-key", { key: "" }], ["bad-key", { key: undefined }], ["bad-key", { key: "completeOrder:o:1" }], ["bad-key", { key: "restock:a/b" }],
        ["bad-product", { productId: "" }], ["bad-product", { productId: 7 }], ["bad-product", { productId: undefined }],
        ["bad-quantity", { qty: 0 }], ["bad-quantity", { qty: -1 }], ["bad-quantity", { qty: NaN }], ["bad-quantity", { qty: Infinity }], ["bad-quantity", { qty: "5" }], ["bad-quantity", { qty: undefined }],
        ["bad-cost", { unitCost: -0.01 }], ["bad-cost", { unitCost: NaN }], ["bad-cost", { unitCost: "1" }], ["bad-cost", { unitCost: undefined }], ["bad-cost", { unitCost: Infinity }], ["bad-cost", { unitCost: 1e308 }], ["bad-cost", { qty: 1e308, unitCost: 5 }], ["bad-cost", { qty: 1e200, unitCost: 1e200 }],
        ["bad-time", { now: "" }], ["bad-time", { now: undefined }], ["bad-time", { date: "2026-6-1" }], ["bad-time", { date: "15/06/2026" }], ["bad-time", { date: undefined }],
        ["bad-supplier", { supplier: {} }], ["bad-supplier", { supplier: { newName: "   " } }], ["bad-supplier", { supplier: { id: "" } }], ["bad-supplier", { supplier: "SUP-1" }], ["bad-supplier", { supplier: 5 }], ["bad-supplier", { supplier: { id: 5 } }],
    ];
    for (const [reason, over] of cases) {
        const p = plain(RP.build(input(over)));
        assert.deepEqual(p, { ok: false, reason: reason }, JSON.stringify(over) + " -> " + JSON.stringify(p));
    }
    for (const bad of [null, undefined, 5, "x", []]) assert.equal(RP.build(bad).ok, false, "input " + String(bad));
});

test("R-2 text equal to a bound token is refused in every user-typed position, for both tokens", () => {
    for (const tok of ["{{sup}}", "{{batch}}"]) {
        for (const over of [{ productName: "A" + tok }, { category: tok }, { reason: "x " + tok + " y" }, { supplier: { newName: tok } }, { supplier: { id: tok } }]) {
            assert.deepEqual(plain(RP.build(input(over))), { ok: false, reason: "reserved-text" }, JSON.stringify(over));
        }
    }
    // other brace text is left alone: the server only replaces names it bound
    assert.equal(RP.build(input({ reason: "{{other}} and {single}" })).ok, true);
});

test("R-3 the quantity refusal is the same one the stock-movement helper and the server make", () => {
    const SM = load("StockMovements.js");
    for (const qty of [0, -2, NaN]) {
        assert.equal(RP.build(input({ qty })).ok, false);
    }
    assert.equal(SM.validate("inventory", { stock: 5 }, {}, [SM.make("receipt", 5, "")]), "");
});

// ---------------------------------------------------------------------------- drift guard (QML source)

// Keys of the first object literal that follows `marker` after `function <fn>(` in a QML source.
function literalKeys(file, fn, marker) {
    const src = fs.readFileSync(path.join(__dirname, "..", "..", "qml", "model", file), "utf8");
    const f = src.indexOf("function " + fn + "(");
    assert.ok(f >= 0, fn + " not found in " + file);
    const m = src.indexOf(marker, f);
    assert.ok(m >= 0, marker + " not found after " + fn);
    let i = src.indexOf("{", m), depth = 0, end = i;
    for (; end < src.length; end++) { if (src[end] === "{") depth++; else if (src[end] === "}" && --depth === 0) break; }
    return src.substring(i + 1, end).split("\n").map((l) => /^\s*(\w+):/.exec(l)).filter(Boolean).map((x) => x[1]).sort();
}

test("D-1 drift guard: the plan's docs have exactly the keys the QML builders write today", () => {
    const p = build();
    const keys = (o) => Object.keys(o).sort();
    assert.deepEqual(keys(p.ops[2].after), literalKeys("SupplierStore.qml", "addSupplier", "var doc = {"));
    assert.deepEqual(keys(p.ops[3].after), literalKeys("StockBatchStore.qml", "_buildBatchDoc", "return {"));
    // R5b (P2): TransactionStore.recordPurchase is gone, the planner is the only builder of a purchase doc. The keys are
    // pinned here instead, in the order the old builder wrote them; readers of kind "purchase" rely on exactly these.
    assert.deepEqual(keys(p.ops[5].after), ["category", "date", "kind", "orderId", "party", "productId", "productName", "quantity",
        "reason", "timestamp", "total", "txId", "unitCost", "unitPrice"]);
});

test("D-2 R5b (P2): TransactionStore no longer has recordPurchase and nothing in qml/ or tests/ calls it", () => {
    const root = path.join(__dirname, "..", "..");
    assert.doesNotMatch(fs.readFileSync(path.join(root, "qml", "model", "TransactionStore.qml"), "utf8"), /function recordPurchase\(/);
    const hits = [];
    const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).forEach((e) => {
        const f = path.join(dir, e.name);
        if (e.isDirectory()) walk(f);
        else if (/\.(qml|js)$/.test(e.name) && /\.recordPurchase\(/.test(fs.readFileSync(f, "utf8"))) hits.push(path.relative(root, f));
    });
    walk(path.join(root, "qml")); walk(path.join(root, "tests"));
    assert.deepEqual(hits, []);
});

// ---------------------------------------------------------------------------- client plan -> real server

function bodyOf(plan, extra) {
    return Object.assign({ requestId: plan.key, opType: plan.opType, clientTimestamp: "CT", ops: plan.ops }, extra || {});
}
async function send(db, plan, extra) {
    const v = OL.validateOperationRequest(bodyOf(plan));
    if (!v.ok) return { validation: v };
    const r = await OL.applyOperation(db, Object.assign({
        tenantId: "t1", actorUid: "u1", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: TS, now: NOW }, extra || {}));
    return { validation: v, result: r };
}
const baseDb = () => strictDb({ [T + "inventory/p1"]: { productId: "p1", name: "Tomato", stock: 10 } });

test("S-1 a new-supplier restock is accepted by the server and every doc is created once", async () => {
    const plan = plain(RP.build(input()));
    const db = baseDb();
    const { validation, result } = await send(db, plan);
    assert.equal(validation.ok, true, JSON.stringify(validation));
    assert.equal(result.ok, true, JSON.stringify(result));
    assert.equal(db.store[T + "inventory/p1"].stock, 15);
    const sup = db.store[T + "suppliers/SUP-001"], bat = db.store[T + "stock_batches/BAT-2026-001"], tx = db.store[T + "transactions/tx-p-BAT-2026-001"];
    assert.equal(sup.supplierId, "SUP-001"); assert.equal(sup.name, "Acme Farms");
    assert.equal(bat.batchId, "BAT-2026-001"); assert.equal(bat.supplierId, "SUP-001"); assert.equal(bat.qtyRemaining, 5); assert.equal(bat.productId, "p1");
    assert.equal(tx.txId, "tx-p-BAT-2026-001"); assert.equal(tx.party, "SUP-001"); assert.equal(tx.total, 62.5);
    assert.equal(db.store[T + "counters/suppliers"].value, 1);
    assert.equal(db.store[T + "counters/stockBatches-2026"].value, 1);
    const rows = rowsOf(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].data.kind, "receipt"); assert.equal(rows[0].data.qty, 5); assert.equal(rows[0].data.derived, false);
    assert.ok(db.store[T + "audit_log/" + KEY], "marker written");
    // 4 working docs + inventory + 4 audit rows... : counted by path, not by number
    const paths = db.writes.map((w) => w.path);
    assert.equal(new Set(paths).size, paths.length, "no doc written twice");
});

test("S-2 reflect reads the server's answer back into exactly the stored docs", async () => {
    const plan = plain(RP.build(input()));
    const db = baseDb();
    const { result } = await send(db, plan);
    const out = plain(RP.reflect(result.results));
    assert.equal(out.ok, true, JSON.stringify(out));
    assert.equal(out.productId, "p1"); assert.equal(out.stock, 15); assert.equal(out.batchId, "BAT-2026-001"); assert.equal(out.supplierId, "SUP-001");
    assert.deepEqual(out.batch, db.store[T + "stock_batches/BAT-2026-001"]);
    assert.deepEqual(out.supplier, db.store[T + "suppliers/SUP-001"]);
    assert.deepEqual(out.purchase, db.store[T + "transactions/tx-p-BAT-2026-001"]);
});

test("S-3 known supplier and no supplier: accepted, no supplier doc, reflect says supplier null", async () => {
    for (const [sup, expect] of [[{ id: "SUP-009" }, "SUP-009"], [null, ""]]) {
        const plan = plain(RP.build(input({ supplier: sup })));
        const db = baseDb();
        const { result } = await send(db, plan);
        assert.equal(result.ok, true, JSON.stringify(result));
        const out = plain(RP.reflect(result.results));
        assert.equal(out.ok, true);
        assert.equal(out.supplier, null);
        assert.equal(out.supplierId, expect);
        assert.equal(Object.keys(db.store).filter((k) => k.indexOf("/suppliers/") > 0).length, 0);
        assert.equal(db.store[T + "counters/suppliers"], undefined, "no supplier counter touched");
    }
});

test("S-4 the same key sent again is a replay: nothing new is written and reflect gives the same answer", async () => {
    const plan = plain(RP.build(input()));
    const db = baseDb();
    const first = await send(db, plan);
    const writes = db.writes.length;
    const second = await send(db, plan);
    assert.equal(second.result.ok, true);
    assert.equal(second.result.idempotentReplay, true);
    assert.equal(db.writes.length, writes);
    assert.deepEqual(plain(RP.reflect(second.result.results)), plain(RP.reflect(first.result.results)));
    assert.equal(db.store[T + "inventory/p1"].stock, 15, "stock applied once");
});

test("S-5 a second restock with a new key mints the NEXT ids, no gap, stock adds up", async () => {
    const db = baseDb();
    await send(db, plain(RP.build(input())));
    const second = await send(db, plain(RP.build(input({ key: "restock:second", supplier: { id: "SUP-001" }, qty: 3 }))));
    assert.equal(second.result.ok, true);
    const out = plain(RP.reflect(second.result.results));
    assert.equal(out.batchId, "BAT-2026-002");
    assert.equal(out.stock, 18);
    assert.equal(db.store[T + "counters/stockBatches-2026"].value, 2);
    assert.equal(db.store[T + "counters/suppliers"].value, 1, "known supplier: the supplier counter did not move");
});

test("S-6 a product that does not exist is rejected 404, nothing written, no number burned", async () => {
    const db = strictDb({});
    const { result } = await send(db, plain(RP.build(input())));
    assert.equal(result.ok, false);
    assert.equal(result.status, 404);
    assert.equal(result.error, "not-found");
    assert.deepEqual(db.writes, []);
});

test("S-7 the write count stays far under the budget (six ops)", async () => {
    const db = baseDb();
    await send(db, plain(RP.build(input())));
    assert.ok(db.writes.length < 20, String(db.writes.length));
});

// ---------------------------------------------------------------------------- review F1/F2 (PR #181 sweep)

test("R-4 a total that overflows is refused, a large finite one is built and stored as a number (design T12)", async () => {
    // F1: 5 * 1e308 is Infinity; JSON would store null in the purchase doc and break every ledger sum.
    for (const over of [{ unitCost: 1e308 }, { qty: 1e308, unitCost: 5 }, { qty: 1e200, unitCost: 1e200 }])
        assert.deepEqual(plain(RP.build(input(over))), { ok: false, reason: "bad-cost" }, JSON.stringify(over));
    // the biggest honest case still works end to end: the server stores a finite total, reflect returns it
    const plan = plain(RP.build(input({ qty: 1e6, unitCost: 1e9 })));
    assert.equal(plan.ok, true);
    assert.equal(plan.ops[plan.at.purchase].after.total, 1e15);
    const db = baseDb();
    const { result } = await send(db, plan);
    assert.equal(result.ok, true, JSON.stringify(result));
    const out = plain(RP.reflect(result.results));
    assert.equal(out.purchase.total, 1e15);
    assert.equal(typeof out.purchase.total, "number");
    // zero cost with a huge quantity has a finite total (0) and is not refused by this check
    assert.equal(RP.build(input({ qty: 1e300, unitCost: 0 })).ok, true);
    // the check is on the product, so it never changes an ordinary plan
    for (const v of [{}, { unitCost: 0 }, { qty: 2.5 }, { unitCost: 0.1 + 0.2 }]) assert.equal(RP.build(input(v)).ok, true, JSON.stringify(v));
});

test("R-5 a doc over the Firestore size limit is refused before anything is queued, in every doc and every typed field (design T11)", async () => {
    const big = "x".repeat(1100000);       // 1.05 MiB of ASCII: over the 1 MiB limit on its own
    const cases = [
        { reason: big }, { productName: big }, { category: big }, { supplier: { newName: big } },
        // the new-supplier doc is the only one that carries the name, the other two carry the id token
    ];
    for (const over of cases)
        assert.deepEqual(plain(RP.build(input(over))), { ok: false, reason: "too-large" }, Object.keys(over)[0]);
    // a known supplier id as big text: the batch and purchase docs carry it
    assert.deepEqual(plain(RP.build(input({ supplier: { id: big } }))), { ok: false, reason: "too-large" });
    // big but legal text (200 KB in three docs) is built, accepted by the server and read back exactly
    const ok200 = "y".repeat(200000);
    const plan = plain(RP.build(input({ reason: ok200 })));
    assert.equal(plan.ok, true);
    const db = baseDb();
    const { result } = await send(db, plan);
    assert.equal(result.ok, true, JSON.stringify(result).slice(0, 300));
    const out = plain(RP.reflect(result.results));
    assert.equal(out.ok, true);
    assert.equal(out.batch.note.length, 200000);
    assert.equal(plan.ops[plan.at.delta].movements[0].reason.length, 500, "the ledger row still carries only 500 characters");
    // multi-byte text counts in BYTES: 400k three-byte characters (1.2 MB) is over, 400k ASCII is under
    assert.equal(RP.build(input({ reason: "\u65e5".repeat(400000) })).reason, "too-large");
    assert.equal(RP.build(input({ reason: "z".repeat(400000) })).ok, true);
});

test("R-6 the size check sits exactly at the edge the shared helper uses (one character under passes, one over is refused)", () => {
    const DL = load("DocLimits.js");
    // the reason sits in the batch doc and the purchase doc alike, so the larger of the two decides
    const p0 = plain(RP.build(input({ reason: "", supplier: null })));
    const base = Math.max.apply(null, p0.ops.filter((o) => o.after).map((o) => DL.docBytes(o.after)));
    const edge = DL.LIMIT_BYTES - base;
    assert.ok(edge > 1000000 && edge < DL.LIMIT_BYTES, String(edge));
    assert.equal(RP.build(input({ reason: "a".repeat(edge), supplier: null })).ok, true);
    assert.deepEqual(plain(RP.build(input({ reason: "a".repeat(edge + 1), supplier: null }))), { ok: false, reason: "too-large" });
});

// ---------------------------------------------------------------------------- reflect: refusals

async function goodResults() {
    const db = baseDb();
    const { result } = await send(db, plain(RP.build(input())));
    return plain(result.results);
}
const clone = (v) => JSON.parse(JSON.stringify(v));

test("F-1 reflect refuses anything that is not exactly one restock answer", async () => {
    const good = await goodResults();
    const sw = (pred, mod) => good.map((r) => pred(r) ? mod(r) : r);
    const after = (extra) => (r) => Object.assign({}, r, { after: Object.assign({}, r.after, extra) });
    // name: [expected detail, results]. The detail is asserted too, so each check is pinned on its own.
    const cases = {
        "not a list": ["not-a-list", null], "object": ["not-a-list", {}], "string": ["not-a-list", "x"], "empty": ["no-batch-mint", []],
        "null entry": ["entry-0", [null, ...good.slice(1)]],
        "unknown kind": ["kind-0", sw((r) => r.bind === "sup", () => ({ kind: "zap" }))],
        "mint without id": ["mint-id", sw((r) => r.bind === "batch", () => ({ kind: "mint", bind: "batch", counter: "stock_batch", id: "" }))],
        "supplier mint without id": ["mint-id", sw((r) => r.bind === "sup", () => ({ kind: "mint", bind: "sup", counter: "supplier", id: "" }))],
        "no batch mint": ["no-batch-mint", good.filter((r) => r.bind !== "batch")],
        "no delta": ["shape", good.filter((r) => r.kind !== "delta")],
        "two deltas": ["shape", [...good, good.find((r) => r.kind === "delta")]],
        "delta stock not a number": ["delta", sw((r) => r.kind === "delta", (r) => Object.assign({}, r, { after: { stock: "15" } }))],
        "delta wrong entity": ["delta", sw((r) => r.kind === "delta", (r) => Object.assign({}, r, { entity: "order" }))],
        "no batch doc": ["shape", good.filter((r) => r.entity !== "stock_batch")],
        "batch id differs from mint": ["batch-doc", sw((r) => r.entity === "stock_batch", after({ batchId: "BAT-2026-099" }))],
        "batch of another product": ["batch-doc", sw((r) => r.entity === "stock_batch", after({ productId: "p2" }))],
        "no purchase": ["shape", good.filter((r) => r.entity !== "transaction")],
        "purchase id differs": ["purchase-doc", sw((r) => r.entity === "transaction", after({ txId: "tx-p-other" }))],
        "supplier minted but no doc": ["supplier-doc", good.filter((r) => r.entity !== "supplier")],
        "supplier doc differs": ["supplier-doc", sw((r) => r.entity === "supplier", after({ supplierId: "SUP-099" }))],
        "batch not carrying the minted supplier": ["supplier-doc", sw((r) => r.entity === "stock_batch", after({ supplierId: "SUP-099" }))],
        "supplier doc without a mint": ["supplier-without-mint", good.filter((r) => r.bind !== "sup")],
        "unknown mutation entity": ["mutation", sw((r) => r.entity === "supplier", (r) => Object.assign({}, r, { entity: "order" }))],
        "mutation without after": ["mutation", sw((r) => r.entity === "supplier", (r) => Object.assign({}, r, { after: null }))],
        "two purchases": ["shape", [...good, good.find((r) => r.entity === "transaction")]],
        "two batches": ["shape", [...good, good.find((r) => r.entity === "stock_batch")]],
        "two suppliers": ["supplier-doc", [...good, good.find((r) => r.entity === "supplier")]],
    };
    for (const name in cases) {
        const out = plain(RP.reflect(clone(cases[name][1])));
        assert.equal(out.ok, false, name + " -> " + JSON.stringify(out));
        assert.equal(out.reason, "malformed-results", name);
        assert.equal(out.detail, cases[name][0], name);
    }
    assert.equal(RP.reflect(clone(good)).ok, true, "the untouched answer still passes");
});

test("F-2 a completeOrder-shaped answer is not mistaken for a restock", () => {
    const completion = [
        { entity: "stock_batch", entityId: "B1", kind: "delta", after: { qtyRemaining: 1 } },
        { entity: "inventory", entityId: "p1", kind: "delta", after: { stock: 4 } },
        { entity: "order", entityId: "o1", kind: "mutation", after: { orderId: "o1" } },
    ];
    assert.equal(RP.reflect(completion).ok, false);
});

// ---------------------------------------------------------------------------- seeded monkey

function prng(seed) { let s = seed >>> 0; return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; }; }

test("M-1 seeded monkey (400 inputs): a plan is either refused with a known reason or accepted by the server, and what comes back is exactly what was stored", async () => {
    const rnd = prng(20261101);
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    const REASONS = new Set(["bad-key", "bad-product", "bad-quantity", "bad-cost", "bad-supplier", "bad-time", "reserved-text", "too-large"]);
    // Mostly valid values, a few hostile ones each, so the accepted path is exercised as hard as the refusals.
    const okTexts = ["", "Tomato", "  padded  ", "日本語", "emoji 🍅", "a/b", "x~y", "q\"uote'", "{single}", "{{other}}", "}}{{", "\n", "r".repeat(700), "<b>x</b>", "\\\\"];
    const badTexts = ["{{sup}}", "a{{batch}}b"];
    const texts = okTexts.concat(okTexts, okTexts, badTexts);
    const goodQty = [1, 2, 5, 2.5, 0.001, 1e6, 3, 7], badQty = [0, -1, NaN, Infinity, "3", undefined, null];
    const goodCost = [0, 1, 12.5, 0.1 + 0.2, 1e9, 3, 99.99], badCost = [-1, NaN, "2", undefined];
    const goodSup = [null, undefined, { id: "SUP-001" }, { id: "SUP-002" }, { newName: "Acme" }, { newName: "Acme 2" }, { newName: "x" }, { newName: pick }, { newName: pick }], badSup = [{ newName: " " }, {}, "x", { id: "{{sup}}" }];
    const quantities = goodQty.concat(goodQty, goodQty, goodQty, badQty);
    const costs = goodCost.concat(goodCost, goodCost, goodCost, badCost);
    const suppliers = goodSup.concat(goodSup, goodSup, goodSup, badSup);
    const stats = { refused: 0, applied: 0, rejectedByServer: 0 };
    for (let n = 0; n < 400; n++) {
        const inp = input({
            key: rnd() < 0.03 ? pick(["", "x", "completeOrder:o:1", "restock:a/b"]) : Keys.restockKey(Keys.restockNonce(1700000000000 + n, rnd)),
            productId: rnd() < 0.03 ? pick(["", 5, undefined]) : "p1",
            productName: pick(texts), category: pick(texts), reason: pick(texts),
            qty: pick(quantities), unitCost: pick(costs),
            supplier: pick(suppliers),
            now: rnd() < 0.03 ? "" : ISO, date: rnd() < 0.03 ? "bad" : "2026-06-15",
        });
        if (inp.supplier && typeof inp.supplier.newName === "function") inp.supplier = { newName: pick(texts) };
        const plan = plain(RP.build(inp));
        if (!plan.ok) { assert.ok(REASONS.has(plan.reason), plan.reason); stats.refused++; continue; }
        const db = baseDb();
        const { validation, result } = await send(db, plan);
        assert.equal(validation.ok, true, "server refused a plan the client built: " + JSON.stringify(validation) + " for " + JSON.stringify(inp));
        if (!result.ok) { stats.rejectedByServer++; assert.fail("server rejected a valid plan: " + JSON.stringify(result) + " for " + JSON.stringify(inp)); }
        const out = plain(RP.reflect(result.results));
        assert.equal(out.ok, true, JSON.stringify(out));
        assert.equal(out.stock, 10 + inp.qty);
        assert.equal(db.store[T + "inventory/p1"].stock, 10 + inp.qty);
        assert.deepEqual(out.batch, db.store[T + "stock_batches/" + out.batchId]);
        assert.deepEqual(out.purchase, db.store[T + "transactions/tx-p-" + out.batchId]);
        assert.equal(out.purchase.productName, typeof inp.productName === "string" ? inp.productName : "");
        assert.equal(out.batch.note, String(inp.reason).trim());
        assert.equal(out.batch.qtyReceived, inp.qty);
        if (out.supplier) { assert.deepEqual(out.supplier, db.store[T + "suppliers/" + out.supplierId]); assert.equal(out.supplier.name, inp.supplier.newName.trim()); }
        assert.equal(rowsOf(db).length, 1);
        assert.equal(rowsOf(db)[0].data.qty, inp.qty);
        stats.applied++;
    }
    assert.ok(stats.applied > 150 && stats.refused > 15, JSON.stringify(stats));
});

// ---------------------------------------------------------------------------- R5b: the feed row inside the operation

const RFLOW = load("RestockFlow.js");
const SUBTITLE_TOKEN = "{{$stock}}";

test("AC-1 the activity text is cut, never refused: product 150, supplier 100, reason 500, no split emoji", () => {
    const big = build({ productName: "N".repeat(5000), reason: "R".repeat(500), supplier: { id: "SUP-1" }, supplierName: "S".repeat(5000) });
    assert.equal(big.ok, true);
    const a = big.ops[big.at.activity].after;
    assert.equal(a.title, "Restocked: " + "N".repeat(150));
    assert.equal(a.subtitle, "+5 · now " + SUBTITLE_TOKEN + " in stock · from " + "S".repeat(100) + " · " + "R".repeat(500));
    assert.ok(a.title.length <= 200 && a.subtitle.length <= 1000);
    // the cut lands inside a surrogate pair: the whole emoji is dropped, never half of it
    const emoji = build({ productName: "a".repeat(149) + "😀 tail" }).ops[6].after.title;
    assert.equal(emoji, "Restocked: " + "a".repeat(149));
    assert.doesNotMatch(emoji, /[\uD800-\uDBFF]$/);
    // exactly at the limit is kept whole
    assert.equal(build({ productName: "n".repeat(150) }).ops[6].after.title, "Restocked: " + "n".repeat(150));
});

test("AC-2 the stock token is reserved text in every typed position, including the supplier's display name", () => {
    for (const over of [{ productName: "a " + SUBTITLE_TOKEN }, { category: SUBTITLE_TOKEN }, { reason: SUBTITLE_TOKEN }, { supplier: { newName: SUBTITLE_TOKEN } },
                        { supplier: { id: SUBTITLE_TOKEN } }, { supplier: { id: "SUP-1" }, supplierName: "x" + SUBTITLE_TOKEN }])
        assert.deepEqual(plain(RP.build(input(over))), { ok: false, reason: "reserved-text" }, JSON.stringify(over));
    assert.equal(RP.build(input({ reason: "{{$other}} {{stock}} $stock" })).ok, true, "look-alikes are plain text");
});

test("AC-3 plan -> real server -> reflect: the feed row is stamped by the server and the same text the old client built", async () => {
    const plan = plain(RP.build(input()));
    const db = baseDb();
    const { result } = await send(db, plan);
    assert.equal(result.ok, true, JSON.stringify(result));
    const out = plain(RP.reflect(plain(result.results)));
    assert.equal(out.ok, true, JSON.stringify(out));
    assert.equal(out.activity.id, "act-BAT-2026-001");
    assert.equal(out.activity.actorUid, "u1");
    assert.equal(out.activity.timestamp, ISO);
    assert.equal(db.store[T + "activity_log/act-BAT-2026-001"].subtitle, out.activity.subtitle);
    // parity with the legacy builder (still used for an answer that carries no feed row)
    const legacy = plain(RFLOW.activityText(out, "Acme Farms"));
    assert.equal(out.activity.title, legacy.title);
    assert.equal(out.activity.subtitle, legacy.subtitle);
});

test("AC-4 reflect: a legacy answer (no feed row) is still one restock, activity null; a damaged feed row is refused", async () => {
    const { result } = await send(baseDb(), plain(RP.build(input())));
    const full = plain(result.results);
    const legacy = full.filter((r) => r.entity !== "activity");
    const ok = plain(RP.reflect(legacy));
    assert.equal(ok.ok, true);
    assert.equal(ok.activity, null);
    const withAct = (patch) => full.map((r) => (r.entity === "activity" ? Object.assign({}, r, { after: Object.assign({}, r.after, patch) }) : r));
    for (const patch of [{ id: "act-other" }, { kind: "order" }, { entityId: "p2" }, { timestamp: undefined }, { timestamp: 5 }])
        assert.deepEqual(plain(RP.reflect(withAct(patch))), { ok: false, reason: "malformed-results", detail: "activity-doc" }, JSON.stringify(patch));
    const twice = full.concat([full.find((r) => r.entity === "activity")]);
    assert.deepEqual(plain(RP.reflect(twice)), { ok: false, reason: "malformed-results", detail: "shape" });
});

test("AC-5 monkey: whatever text is typed, a plan the planner builds is ALWAYS accepted by the server's validator", () => {
    let seed = 1112;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
    const pieces = ["", " ", "a", "Tomato", "{{x}}", "{{", "}}", SUBTITLE_TOKEN, "{{sup}}", "{{batch}}", "😀", "é", "x".repeat(300), "y".repeat(2000), "\n", "📦".repeat(90)];
    const word = () => { let s = ""; for (let n = Math.floor(rnd() * 4); n >= 0; n--) s += pieces[Math.floor(rnd() * pieces.length)]; return s; };
    let built = 0;
    for (let i = 0; i < 2000; i++) {
        const sup = [null, { id: "SUP-1" }, { newName: word() }][Math.floor(rnd() * 3)];
        const p = RP.build(input({ productName: word(), category: word(), reason: word().substring(0, 500), supplier: sup, supplierName: word() }));
        if (!p.ok) continue;
        built++;
        const v = OL.validateOperationRequest({ requestId: KEY, opType: "restock", clientTimestamp: "c", ops: plain(p.ops) });
        assert.equal(v.ok, true, JSON.stringify(v) + " for " + JSON.stringify(p.ops[p.at.activity]));
    }
    assert.ok(built > 100, "the monkey builds plans: " + built);
});
