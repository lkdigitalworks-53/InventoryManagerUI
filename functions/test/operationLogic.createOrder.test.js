"use strict";

// NO1: a new order is ONE operation (opType "createOrder"): a `mint` of the order id and ONE create of the order doc, both in one
// transaction. Server half only; nothing in the app sends it yet (design 2026-11-21-create-order-atomic-operation-design.md,
// D-NO-1..8). The real server code runs on the strict fake DB.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const OL = require("../lib/operationLogic");
const R = require("../lib/counterRegistry");
const ML = require("../lib/movementLogic");
const Gateway = require("../lib/gatewayLogic");
const { TS, strictDb, pessimisticWrites, rowsOf } = require("./testSupport/strictDb");

const T = "tenants/t1/";
const NOW = new Date("2026-06-15T12:00:00Z");

const mint = (counter, bind) => ({ kind: "mint", counter, bind });
const create = (entity, entityId, after) => ({ kind: "mutation", entity, entityId, action: "create", before: null, after });
// The order doc as OrdersStore._normalizeOrder shapes it (the planner, NO2, is the shape authority; D-NO-5).
const orderDoc = (over) => Object.assign({
    orderId: "{{ord}}", customer: "Asha", items: 2, subtotal: 100, discount: 0, tax: 5, taxBreakdown: [], total: 105,
    status: "pending", date: "2026-06-15", notes: "", email: "", phone: "", orderChannel: "", staffId: "",
    updatedAt: "2026-06-15T12:00:00.000Z", adjustments: [],
    products: [{ productId: "PRD-001", name: "Tomato", price: 50, quantity: 2, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }]
}, over || {});
const orderOps = (docOver) => [mint("order", "ord"), create("order", "{{ord}}", orderDoc(docOver))];
const body = (ops, id, opType) => ({ requestId: (opType || "createOrder") + ":dev1-" + (id || "a"), opType: opType || "createOrder", clientTimestamp: "CT", ops });
const validated = (b) => { const v = OL.validateOperationRequest(b); assert.equal(v.ok, true, JSON.stringify(v)); return v; };
const invalid = (b) => { const v = OL.validateOperationRequest(b); assert.equal(v.ok, false, "expected a rejection"); return v; };
async function run(db, b, extra) {
    const v = validated(b);
    return OL.applyOperation(db, Object.assign({
        tenantId: "t1", actorUid: "u-actor", actorRole: "staff", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: TS, now: NOW }, extra || {}));
}
const withCounter = (value, more) => strictDb(Object.assign({ [T + "counters/orders"]: { value } }, more || {}));
// The engine rolls back whatever the validator lets through (defence in depth, PR #208 review: checkCreateOrder now refuses extra ops).
// Validated as a completeOrder (no shape rules), applied as a createOrder: proves the APPLY layer on its own.
async function runUnchecked(db, ops, id) {
    const v = validated(body(ops, id, "completeOrder"));
    return OL.applyOperation(db, { tenantId: "t1", actorUid: "u-actor", actorRole: "staff", requestId: "createOrder:dev1-" + (id || "a"),
        opType: "createOrder", ops: v.ops, clientTimestamp: "CT", serverTimestamp: TS, now: NOW });
}

// ------------------------------------------------------------------ registry and op type

test("R-1 the order counter: id space, doc and format are those of OrdersStore.nextOrderId, whatever the year", () => {
    for (const year of ["2026", "2027", "1999"])
        assert.deepEqual(R.describe("order", year), { key: "order", entity: "order", collection: "orders", counterName: "orders", prefix: "ORD-" });
    assert.equal(R.isKnownCounter("order"), true);
    assert.equal(R.formatId("ORD-", 7), "ORD-007");
    assert.equal(R.formatId("ORD-", 1000), "ORD-1000");
    assert.equal(R.numberOf("ORD-", "ORD-042"), 42);
    assert.equal(R.numberOf("ORD-", "ORD-x1"), null);
    assert.equal(R.numberOf("ORD-", "PRD-001"), null);
    assert.equal(Gateway.ENTITY_COLLECTIONS.order, R.describe("order", "2026").collection, "the gateway's entity map lands in the same collection");
});

test("R-2 the other counters did not move (supplier, stock_batch and product keep their exact registry entries)", () => {
    assert.deepEqual(R.describe("supplier", "2026"), { key: "supplier", entity: "supplier", collection: "suppliers", counterName: "suppliers", prefix: "SUP-" });
    assert.deepEqual(R.describe("stock_batch", "2027"), { key: "stock_batch", entity: "stock_batch", collection: "stock_batches", counterName: "stockBatches-2027", prefix: "BAT-2027-" });
    assert.deepEqual(R.describe("product", "2026"), { key: "product", entity: "inventory", collection: "inventory", counterName: "products", prefix: "PRD-" });
    for (const unregistered of ["staff", "customer", "orders", "Order", "ORDER", ""]) assert.equal(R.isKnownCounter(unregistered), false, unregistered);
});

test("V-1 createOrder is an operation type; its request id must carry the createOrder: namespace; the older types are untouched", () => {
    assert.ok(OL.OP_TYPES.indexOf("createOrder") >= 0);
    assert.deepEqual(OL.OP_TYPES.slice(0, 3), ["completeOrder", "restock", "addProduct"]);
    assert.equal(invalid({ requestId: "completeOrder:x", opType: "createOrder", ops: orderOps() }).error, "invalid-request-id");
    assert.equal(invalid({ requestId: "createOrder:a~b", opType: "createOrder", ops: orderOps() }).error, "invalid-request-id");
    assert.equal(invalid({ requestId: "createorder:x", opType: "createorder", ops: orderOps() }).error, "unsupported-op-type");
    assert.equal(invalid({ requestId: "createOrders:x", opType: "createOrders", ops: orderOps() }).error, "unsupported-op-type");
    assert.equal(invalid({ requestId: "createOrder:", opType: "createOrder", ops: [] }).error, "empty-operation");
});

// ------------------------------------------------------------------ validation

test("V-2 the full operation is accepted and kept as a template (the id token is not resolved yet)", () => {
    const v = validated(body(orderOps()));
    assert.equal(v.opType, "createOrder");
    assert.deepEqual(v.ops.map((o) => o.kind), ["mint", "mutation"]);
    assert.equal(v.ops[0].entity, "order");
    assert.equal(v.ops[0].collection, "orders");
    assert.equal(v.ops[1].entityId, "{{ord}}");
    assert.equal(v.ops[1].after.orderId, "{{ord}}");
});

test("V-3 an order with no lines and a zero total is accepted (the planner decides what an order is; D-NO-5)", () => {
    validated(body(orderOps({ products: [], items: 0, subtotal: 0, total: 0 })));
});

test("V-4 the minted id can only be an ORDER id: the entity of the create must match the counter's entity", () => {
    for (const entity of ["inventory", "supplier", "stock_batch", "transaction"]) {
        const v = invalid(body([mint("order", "ord"), create(entity, "{{ord}}", { a: 1 })]));
        assert.equal(v.error, "placeholder-entity-mismatch", entity);
        assert.equal(v.opIndex, 1);
    }
    // and the other way: an order id from another counter
    const v = invalid(body([mint("product", "ord"), create("order", "{{ord}}", orderDoc())]));
    assert.equal(v.error, "placeholder-entity-mismatch");
});

test("V-5 a minted order number nobody uses is refused (it would burn a number and leave a marker for nothing)", () => {
    assert.equal(invalid(body([mint("order", "ord"), create("order", "ORD-500", orderDoc({ orderId: "ORD-500" }))])).error, "unused-mint");
    assert.equal(invalid(body([mint("order", "ord")])).error, "unused-mint");
});

test("V-6 placeholders are for creates only: an update or delete of an order named {{ord}} is refused", () => {
    for (const action of ["update", "delete"]) {
        const op = { kind: "mutation", entity: "order", entityId: "{{ord}}", action, before: { a: 1 }, after: action === "delete" ? null : { a: 2 } };
        assert.equal(invalid(body([mint("order", "ord"), op])).error, "placeholder-not-allowed", action);
    }
});

test("V-7 braces left in an id are never legal; an undeclared name is refused, a later-declared name is refused", () => {
    assert.equal(invalid(body([mint("order", "ord"), create("order", "{{nope}}", orderDoc())])).error, "unbound-placeholder");
    assert.equal(invalid(body([create("order", "{{ord}}", orderDoc()), mint("order", "ord")])).error, "unbound-placeholder");
});

test("S-1 (D-NO-5b, was gap K-4) the order id is the BARE token: a composite id, a literal id and a missing mint are invalid-order", () => {
    const composite = invalid(body([mint("order", "ord"), create("order", "X-{{ord}}", orderDoc({ orderId: "X-{{ord}}" }))]));
    assert.deepEqual([composite.error, composite.opIndex], ["invalid-order", 1]);
    const tail = invalid(body([mint("order", "ord"), create("order", "{{ord}}-1", orderDoc({ orderId: "{{ord}}-1" }))]));
    assert.deepEqual([tail.error, tail.opIndex], ["invalid-order", 1]);
    // the id alone is wrong while the doc names the bare token (a different line of the check than the doc's own orderId)
    for (const id of ["X-{{ord}}", "{{ord}}-1", " {{ord}}"]) {
        const v = invalid(body([mint("order", "ord"), create("order", id, orderDoc({ orderId: "{{ord}}" }))]));
        assert.deepEqual([v.error, v.opIndex], ["invalid-order", 1], id);
    }
    const literal = invalid(body([create("order", "ORD-500", orderDoc({ orderId: "ORD-500" }))]));
    assert.deepEqual([literal.error, literal.opIndex], ["invalid-order", 0], "no mint: the id space is the counter's");
});

test("V-8 mint rules hold: duplicate bind name, bad bind name, unknown counter, too many mints", () => {
    assert.equal(invalid(body([mint("order", "ord"), mint("order", "ord"), create("order", "{{ord}}", orderDoc())])).error, "duplicate-bind-name");
    assert.equal(invalid(body([mint("order", "Ord!"), create("order", "{{Ord!}}", orderDoc())])).error, "invalid-bind-name");
    assert.equal(invalid(body([mint("orders", "ord"), create("order", "{{ord}}", orderDoc())])).error, "unknown-counter");
    const six = [1, 2, 3, 4, 5, 6].map((i) => mint("order", "o" + i));
    assert.equal(invalid(body(six.concat([create("order", "{{o1}}", orderDoc())]))).error, "too-many-mints");
});

test("V-9 no feed row: the activity entity is not available to createOrder (a new order writes none today; D-NO-4)", () => {
    const act = create("activity", "act-{{ord}}", { id: "act-{{ord}}", kind: "product_added", title: "t", subtitle: "", entityId: "{{ord}}", read: false, dismissed: false });
    assert.equal(invalid(body(orderOps().concat([act]))).error, "unsupported-entity");
    assert.deepEqual(OL.OPERATION_ONLY_ENTITIES.activity.opTypes, ["restock", "addProduct"], "createOrder is not in the feed's op type list");
});

test("V-10 an order delete or a product delete cannot ride in a createOrder (the product delete is refused for every op type)", () => {
    const del = { kind: "mutation", entity: "inventory", entityId: "PRD-001", action: "delete", before: { a: 1 }, after: null };
    assert.equal(invalid(body(orderOps().concat([del]))).error, "cascade-delete-not-allowed");
});

test("V-11 monkey: 600 random single-field corruptions never throw and never let a template-less or unbound op through as ok with braces", () => {
    let seed = 11;
    const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
    const junk = [null, undefined, 0, -1, 1.5, "", " ", "{{", "}}", "{{ord}}", "{{x}}", "a/b", "..", [], {}, true, "x".repeat(300), "\u0000", NaN];
    for (let i = 0; i < 600; i++) {
        const ops = JSON.parse(JSON.stringify(orderOps()));
        const target = ops[rnd(2)];
        const keys = Object.keys(target);
        const key = keys[rnd(keys.length)];
        const j = junk[rnd(junk.length)];
        if (j === undefined) delete target[key]; else target[key] = j;
        let v;
        assert.doesNotThrow(() => { v = OL.validateOperationRequest(body(ops, "m" + i)); }, "case " + i);
        assert.equal(typeof v.ok, "boolean");
        if (v.ok) for (const op of v.ops) if (op.kind === "mutation") assert.ok(op.entityId.indexOf("{{") < 0 || /^\{\{ord\}\}$/.test(op.entityId), "case " + i + " " + op.entityId);
    }
});

test("V-12 REGRESSION: completeOrder, restock and addProduct requests validate exactly as before", () => {
    const delta = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } };
    assert.equal(OL.validateOperationRequest({ requestId: "completeOrder:o1:1", opType: "completeOrder", ops: [delta] }).ok, true);
    assert.equal(OL.validateOperationRequest({ requestId: "restock:r1", opType: "restock", ops: [Object.assign({}, delta, { deltas: { stock: 3 } })] }).ok, true);
    assert.equal(OL.validateOperationRequest({ requestId: "completeOrder:o1:1", opType: "createOrder", ops: [delta] }).error, "invalid-request-id");
});

// ------------------------------------------------------------------ apply

test("B-1 one operation: the order lands under the real id, the counter moves once, the marker holds the answer", async () => {
    const db = withCounter(12);
    const r = await run(db, body(orderOps()));
    assert.equal(r.ok, true, JSON.stringify(r));
    const stored = db.store[T + "orders/ORD-013"];
    assert.equal(stored.orderId, "ORD-013", "the token inside the doc is replaced by the minted id");
    assert.equal(stored.customer, "Asha");
    assert.equal(stored.status, "pending");
    assert.deepEqual(stored.products[0].productId, "PRD-001");
    assert.deepEqual(db.store[T + "counters/orders"], { value: 13 });
    const marker = db.store[T + "audit_log/createOrder:dev1-a"];
    assert.equal(marker.opType, "createOrder");
    assert.equal(marker.opCount, 2);
    assert.deepEqual(marker.results[0], { kind: "mint", counter: "order", bind: "ord", id: "ORD-013" });
    assert.deepEqual(r.results[0], marker.results[0]);
    assert.equal(r.results[1].entity, "order");
    assert.equal(r.results[1].entityId, "ORD-013");
    assert.equal(r.results[1].after.orderId, "ORD-013");
});

test("B-2 exactly the expected docs are written: the order, its audit row, the counter and the marker. No ledger row, no feed row", async () => {
    const db = withCounter(12);
    await run(db, body(orderOps()));
    const paths = db.writes.map((w) => w.path.replace(T, "")).sort();
    assert.deepEqual(paths, ["audit_log/createOrder:dev1-a", "audit_log/createOrder:dev1-a~1", "counters/orders", "orders/ORD-013"].sort());
    assert.equal(rowsOf(db).length, 0, "an order is not a stock movement");
    assert.equal(paths.some((p) => p.indexOf("activity_log/") === 0), false);
    assert.ok(pessimisticWrites(db.writes) <= ML.MAX_TXN_WRITES);
    const audit = db.store[T + "audit_log/createOrder:dev1-a~1"];
    assert.deepEqual([audit.action, audit.entity, audit.entityId, audit.opType, audit.opIndex, audit.operationId, audit.actorRole], ["create", "order", "ORD-013", "createOrder", 1, "createOrder:dev1-a", "staff"]);
    assert.equal(audit.before, null);
});

test("B-3 a retry of the same request id is a replay: the first answer, no second order, the counter does not move", async () => {
    const db = withCounter(12);
    const b = body(orderOps());
    const first = await run(db, b);
    const snapshot = JSON.stringify(db.store);
    const writes = db.writes.length;
    const again = await run(db, b);
    assert.equal(again.ok, true);
    assert.equal(again.idempotentReplay, true);
    assert.deepEqual(again.results, first.results);
    assert.equal(JSON.stringify(db.store), snapshot);
    assert.equal(db.writes.length, writes);
});

test("B-4 a replay after the order was edited still answers the FIRST result and never touches the edited doc", async () => {
    const db = withCounter(12);
    const b = body(orderOps());
    await run(db, b);
    db.store[T + "orders/ORD-013"] = Object.assign({}, db.store[T + "orders/ORD-013"], { status: "completed" });
    const again = await run(db, b);
    assert.equal(again.idempotentReplay, true);
    assert.equal(again.results[1].after.status, "pending", "the answer is the first one");
    assert.equal(db.store[T + "orders/ORD-013"].status, "completed", "the later edit is untouched");
});

test("B-5 the counter is behind the data: the mint skips an occupied id and never overwrites it", async () => {
    const taken = { orderId: "ORD-013", customer: "Existing" };
    const db = withCounter(12, { [T + "orders/ORD-013"]: taken });
    const r = await run(db, body(orderOps()));
    assert.equal(r.ok, true, JSON.stringify(r));
    assert.equal(r.results[0].id, "ORD-014");
    assert.deepEqual(db.store[T + "orders/ORD-013"], taken);
    assert.equal(db.store[T + "orders/ORD-014"].orderId, "ORD-014");
    assert.deepEqual(db.store[T + "counters/orders"], { value: 14 });
});

test("B-6 the counter is far behind the data (imported orders): ONE jump to the highest id, not a walk", async () => {
    const more = {};
    for (let n = 13; n <= 60; n++) more[T + "orders/ORD-" + String(n).padStart(3, "0")] = { orderId: "ORD-" + n };
    const db = withCounter(12, more);
    const r = await run(db, body(orderOps()));
    assert.equal(r.ok, true, JSON.stringify(r));
    assert.equal(r.results[0].id, "ORD-061");
});

test("B-7 no usable counter doc: the seed is the highest ORD- number among the order ids (numeric, junk ignored)", async () => {
    const ord = (id) => ({ [T + "orders/" + id]: { orderId: id } });
    const db = strictDb(Object.assign({ [T + "counters/orders"]: { value: "oops" } },
        ord("ORD-004"), ord("ORD-999"), ord("ORD-1000"), ord("ORD-x1"), ord("INV-99999"), ord("ORD-12345678901234567890")));
    const r = await run(db, body(orderOps()));
    assert.equal(r.results[0].id, "ORD-1001", "1000 is a bigger number than 999 although it sorts lower");
    assert.deepEqual(db.store[T + "counters/orders"], { value: 1001 });
    assert.equal((await run(strictDb({}), body(orderOps()))).results[0].id, "ORD-001");
    for (const bad of [-1, 1.5, NaN, null, 1e12, {}]) {
        const d = strictDb({ [T + "counters/orders"]: { value: bad }, [T + "orders/ORD-020"]: { orderId: "ORD-020" } });
        assert.equal((await run(d, body(orderOps()))).results[0].id, "ORD-021", "damaged value " + String(bad));
    }
});

test("B-8 a healthy counter never lists the orders collection (a shop with thousands of orders pays nothing per order)", async () => {
    const db = withCounter(12);
    await run(db, body(orderOps()));
    assert.deepEqual(db.listCalls, []);
    const stale = withCounter(12, { [T + "orders/ORD-013"]: { orderId: "ORD-013" } });
    await run(stale, body(orderOps(), "b"));
    assert.equal(stale.listCalls.length, 1, "only a collision lists, once");
});

test("B-9 the number is padded to three digits and never truncated: 999 -> ORD-1000", async () => {
    assert.equal((await run(withCounter(999), body(orderOps()))).results[0].id, "ORD-1000");
    assert.equal((await run(withCounter(0), body(orderOps()))).results[0].id, "ORD-001");
});

test("B-10 two operations in a row hand out two different ids; each keeps its own marker and order", async () => {
    const db = withCounter(12);
    const a = await run(db, body(orderOps({ customer: "A" }), "a"));
    const b = await run(db, body(orderOps({ customer: "B" }), "b"));
    assert.deepEqual([a.results[0].id, b.results[0].id], ["ORD-013", "ORD-014"]);
    assert.equal(db.store[T + "orders/ORD-013"].customer, "A");
    assert.equal(db.store[T + "orders/ORD-014"].customer, "B");
    assert.deepEqual(db.store[T + "counters/orders"], { value: 14 });
});

test("B-11 a client-style mint and the server mint on ONE counter doc never hand out the same id (the bulk import still mints from the client)", async () => {
    const db = withCounter(12);
    db.store[T + "counters/orders"] = { value: 20 };               // the import minted ORD-013..020 over REST
    db.store[T + "orders/ORD-020"] = { orderId: "ORD-020" };       // and wrote the last one
    const r = await run(db, body(orderOps()));
    assert.equal(r.results[0].id, "ORD-021");
});

test("B-12 ATOMIC: a rejected operation leaves NO trace and burns no number; the retry after the fix gets the SAME id", async () => {
    const blocker = { txId: "tx-x" };
    const db = withCounter(12, { [T + "transactions/tx-x"]: blocker });
    const r = await runUnchecked(db, orderOps().concat([create("transaction", "tx-x", { txId: "tx-x" })]));
    assert.equal(r.ok, false);
    assert.equal(r.status, 409);
    assert.equal(r.error, "conflict");
    assert.equal(r.opIndex, 2);
    assert.equal(db.writes.length, 0, "no order, audit, counter or marker");
    assert.deepEqual(db.store[T + "counters/orders"], { value: 12 });
    assert.equal(db.store[T + "orders/ORD-013"], undefined);
    delete db.store[T + "transactions/tx-x"];
    const retry = await run(db, body(orderOps()));
    assert.equal(retry.ok, true, JSON.stringify(retry));
    assert.equal(retry.results[0].id, "ORD-013");
});

test("B-13 a literal order id that already exists is a conflict (409), never an overwrite", async () => {
    const old = { orderId: "ORD-005", customer: "Old" };
    const db = strictDb({ [T + "orders/ORD-005"]: old });
    const r = await runUnchecked(db, [create("order", "ORD-005", orderDoc({ orderId: "ORD-005" }))]);
    assert.equal(r.status, 409);
    assert.equal(db.writes.length, 0);
    assert.deepEqual(db.store[T + "orders/ORD-005"], old);
});

test("B-14 the order number does not depend on the year (a December 31 order after IST midnight still uses counters/orders)", async () => {
    const db = withCounter(12);
    const r = await run(db, body(orderOps()), { now: new Date("2026-12-31T20:00:00Z") });
    assert.equal(r.results[0].id, "ORD-013");
    assert.deepEqual(db.store[T + "counters/orders"], { value: 13 });
});

test("B-15 the stored doc keeps every field the client sent (the server adds nothing and drops nothing)", async () => {
    const db = withCounter(12);
    const sent = orderDoc({ customer: "Zoë 名前", notes: "a \"quoted\" note", discount: 3.5, taxBreakdown: [{ percent: 5, amount: 5 }] });
    await run(db, body([mint("order", "ord"), create("order", "{{ord}}", sent)]));
    assert.deepEqual(db.store[T + "orders/ORD-013"], Object.assign({}, sent, { orderId: "ORD-013" }));
});

test("B-16 typed text with braces inside an order doc is substituted by the engine (documented gap K-2: the planner, NO2, must neutralise it)", async () => {
    const db = withCounter(12);
    await run(db, body([mint("order", "ord"), create("order", "{{ord}}", orderDoc({ customer: "{{ord}}", notes: "see {{other}}" }))]));
    const o = db.store[T + "orders/ORD-013"];
    assert.equal(o.customer, "ORD-013", "a bound name typed by a person becomes the id");
    assert.equal(o.notes, "see {{other}}", "an unbound name stays as typed");
});

// ------------------------------------------------------------------ documented gaps and source pins

test("S-2 (D-NO-5b, was gap K-1) the order doc must be a plain object that names itself: a missing, null, array, string or number doc, no orderId, another orderId", () => {
    const bad = (after) => invalid(body([mint("order", "ord"), { kind: "mutation", entity: "order", entityId: "{{ord}}", action: "create", before: null, after }]));
    for (const after of [undefined, null, [], [1], "x", 7, true, {}, { x: 1 }, { orderId: "ORD-001" }, { orderId: "{{other}}" }, { orderId: 1 }, { orderId: "" }, { orderid: "{{ord}}" }]) {
        const v = bad(after);
        assert.deepEqual([v.error, v.opIndex], ["invalid-order", 1], JSON.stringify(after));
    }
    // the fields themselves stay the planner's: a bare doc that only names itself is accepted
    validated(body([mint("order", "ord"), create("order", "{{ord}}", { orderId: "{{ord}}" })]));
});

test("S-3 (D-NO-5b, was gap K-3) nothing rides along: a stock delta, a second order, a second mint, a transaction row are invalid-order at the first extra op", () => {
    const delta = { kind: "delta", entity: "inventory", entityId: "PRD-001", deltas: { stock: -1 }, floors: { stock: 0 } };
    const v1 = invalid(body(orderOps().concat([delta])));
    assert.deepEqual([v1.error, v1.opIndex], ["invalid-order", 2]);
    const v2 = invalid(body(orderOps().concat([create("transaction", "tx-1", { txId: "tx-1" })])));
    assert.deepEqual([v2.error, v2.opIndex], ["invalid-order", 2]);
    const v3 = invalid(body([mint("order", "a"), mint("order", "b"), create("order", "{{a}}", orderDoc({ orderId: "{{a}}" })), create("order", "{{b}}", orderDoc({ orderId: "{{b}}" }))]));
    assert.equal(v3.error, "invalid-order");
    const v4 = invalid(body([delta, mint("order", "ord"), create("order", "{{ord}}", orderDoc())]));
    assert.equal(v4.error, "invalid-order");
});

test("S-4 (D-NO-5b) the first op must be the ORDER mint and the second a create with no before: another counter, a before doc, a non-create are invalid-order or placeholder errors, never accepted", () => {
    const other = invalid(body([mint("supplier", "s"), create("supplier", "{{s}}", { supplierId: "{{s}}" })]));
    assert.deepEqual([other.error, other.opIndex], ["invalid-order", 0], "another counter's operation is not a createOrder");
    const withBefore = invalid(body([mint("order", "ord"), { kind: "mutation", entity: "order", entityId: "{{ord}}", action: "create", before: { a: 1 }, after: orderDoc() }]));
    assert.deepEqual([withBefore.error, withBefore.opIndex], ["invalid-order", 1]);
    assert.equal(invalid(body([mint("order", "ord"), create("order", "{{ord}}", orderDoc()), mint("order", "x")])).error, "unused-mint", "the older rule keeps its precedence");
});

test("S-5 (D-NO-5b) monkey: 1500 corruptions of a valid operation; a request is accepted ONLY when the independent oracle agrees it is exactly mint + one bare-token order create", () => {
    let seed = 20261121;
    const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
    const junk = [undefined, null, 0, 7, "", "x", "{{ord}}", "ORD-001", "{{other}}", [], {}, { orderId: "{{ord}}" }, true];
    const oracle = (ops) => Array.isArray(ops) && ops.length === 2 && ops[0] && ops[1]
        && ops[0].kind === "mint" && ops[0].counter === "order" && typeof ops[0].bind === "string"
        && ops[1].kind === "mutation" && ops[1].entity === "order" && ops[1].action === "create" && (ops[1].before === null || ops[1].before === undefined)
        && ops[1].entityId === "{{" + ops[0].bind + "}}" && ops[1].after && typeof ops[1].after === "object" && !Array.isArray(ops[1].after)
        && ops[1].after.orderId === ops[1].entityId;
    let accepted = 0;
    for (let n = 0; n < 1500; n++) {
        const ops = JSON.parse(JSON.stringify(orderOps()));
        for (let k = 0, hits = 1 + rnd(3); k < hits; k++) {
            const which = rnd(6);
            const op = ops[rnd(ops.length)];
            if (which === 0) op[["kind", "counter", "bind", "entity", "entityId", "action", "before", "after"][rnd(8)]] = junk[rnd(junk.length)];
            else if (which === 1 && ops[1].after && typeof ops[1].after === "object") ops[1].after.orderId = junk[rnd(junk.length)];
            else if (which === 2) ops.push(JSON.parse(JSON.stringify(ops[rnd(ops.length)])));
            else if (which === 3) ops.splice(rnd(ops.length), 1);
            else if (which === 4) ops.reverse();
            else ops[1].after = junk[rnd(junk.length)];
        }
        let v;
        assert.doesNotThrow(() => { v = OL.validateOperationRequest(body(ops, "m" + n)); }, JSON.stringify(ops));
        if (v.ok) { accepted++; assert.equal(!!oracle(ops), true, "accepted but not a valid createOrder: " + JSON.stringify(ops)); }
    }
    assert.ok(accepted > 0, "the monkey must also hit accepted shapes, or the oracle check proves nothing");
});

test("G-1 wiring (NO3a replaced the dormancy guard): the helpers, OrderFlow, OrdersStore and DataModel name createOrder; no page or dialog does, and the two that send and route it say so", () => {
    const root = path.join(__dirname, "..", "..", "qml");
    const hits = [];
    (function walk(dir) {
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            const p = path.join(dir, e.name);
            if (e.isDirectory()) walk(p);
            else if (/\.(qml|js)$/.test(e.name) && fs.readFileSync(p, "utf8").indexOf("createOrder") >= 0) hits.push(path.relative(root, p).split(path.sep).join("/"));
        }
    })(root);
    assert.deepEqual(hits.sort(), ["helper/DescribeItem.js", "helper/OperationKeys.js", "helper/OrderFlow.js", "helper/OrderPlan.js", "model/DataModel.qml", "model/OrdersStore.qml"]);
    const read = (f) => fs.readFileSync(path.join(root, f), "utf8");
    assert.match(read("model/OrdersStore.qml"), /Gateway\.recordOperation\("createOrder", plan\.ops, plan\.key, \{ awaitServer: true \}/);
    assert.match(read("model/DataModel.qml"), /opType === "createOrder"\) dataModel\._autoApproveNewOrder\(OrdersStore\.onCreateOrderApplied\(requestId, results, replay\)\)/);
    assert.match(read("model/DataModel.qml"), /opType === "createOrder"\) \{\s*var orderFailure = OrdersStore\.onCreateOrderRejected\(requestId, rejection\)/);
});

test("G-2 source pins: the order counter, the op type list and the feed's op types are where the design says", () => {
    const reg = fs.readFileSync(path.join(__dirname, "..", "lib", "counterRegistry.js"), "utf8");
    assert.match(reg, /order: \{\s*entity: "order",\s*collection: "orders",\s*counterName: function \(\) \{ return "orders"; \},\s*prefix: function \(\) \{ return "ORD-"; \}/);
    const ol = fs.readFileSync(path.join(__dirname, "..", "lib", "operationLogic.js"), "utf8");
    assert.match(ol, /const OP_TYPES = \["completeOrder", "restock", "addProduct", "createOrder"\];/);
    assert.match(ol, /const ACTIVITY_KIND_BY_OPTYPE = \{ restock: "product_restocked", addProduct: "product_added" \};/);
});
