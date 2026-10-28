"use strict";

// The `mint` op of recordOperation (design 2026-10-28-r2-mint-engine-design.md, M1-M11).
// operationLogic.test.js is NOT edited by this slice: it passing unchanged is the evidence that an
// operation without a mint op behaves exactly as before.

const test = require("node:test");
const assert = require("node:assert/strict");
const OL = require("../lib/operationLogic");
const { TS, strictDb, pessimisticWrites, rowsOf } = require("./testSupport/strictDb");

const T = "tenants/t1/";
const NOW = new Date("2026-06-15T12:00:00Z");           // IST year 2026

function validated(body) {
    const v = OL.validateOperationRequest(body);
    assert.equal(v.ok, true, JSON.stringify(v));
    return v;
}
async function run(db, body, extra) {
    const v = validated(body);
    return OL.applyOperation(db, Object.assign({
        tenantId: "t1", actorUid: "u1", actorRole: "owner", requestId: v.requestId, opType: v.opType,
        ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: TS, now: NOW
    }, extra || {}));
}
const invalid = (body) => { const v = OL.validateOperationRequest(body); assert.equal(v.ok, false, "expected a rejection"); return v; };

const mint = (counter, bind) => ({ kind: "mint", counter: counter, bind: bind });
const create = (entity, entityId, after) => ({ kind: "mutation", entity, entityId, action: "create", before: null, after });
const body = (ops, id) => ({ requestId: "restock:dev1-" + (id || "a"), opType: "restock", clientTimestamp: "CT", ops });

// The restock shape from the design: new supplier + batch + stock delta + purchase doc.
function restockOps(opts) {
    const o = opts || {};
    const ops = [];
    if (o.newSupplier !== false) ops.push(mint("supplier", "sup"), create("supplier", "{{sup}}", { supplierId: "{{sup}}", name: "Acme" }));
    ops.push(mint("stock_batch", "batch"));
    ops.push(create("stock_batch", "{{batch}}", { batchId: "{{batch}}", productId: "p1", supplierId: o.newSupplier === false ? "SUP-009" : "{{sup}}", qtyRemaining: 5 }));
    ops.push({ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 5 }, movements: [{ kind: "receipt", qty: 5, reason: "restock" }] });
    ops.push(create("transaction", "tx-p-{{batch}}", { id: "tx-p-{{batch}}", batchId: "{{batch}}", note: "from {{batch}}" }));
    return ops;
}
const baseDocs = () => ({ [T + "inventory/p1"]: { stock: 10 } });
const paths = (db) => db.writes.map((w) => w.path).sort();

// ------------------------------------------------------------- validation

test("validate: a restock operation with two mints is accepted and the mint ops are normalised", () => {
    const v = validated(body(restockOps()));
    assert.equal(v.ops.length, 6);
    assert.deepEqual(v.ops[0], { kind: "mint", counter: "supplier", bind: "sup", entity: "supplier", collection: "suppliers" });
    assert.deepEqual(v.ops[2], { kind: "mint", counter: "stock_batch", bind: "batch", entity: "stock_batch", collection: "stock_batches" });
    assert.equal(v.ops[3].entityId, "{{batch}}");           // the template is kept; the transaction resolves it
});

test("validate: restock is an op type; its request id must start with restock:", () => {
    assert.ok(OL.OP_TYPES.indexOf("restock") >= 0 && OL.OP_TYPES.indexOf("completeOrder") >= 0);
    assert.equal(invalid({ requestId: "completeOrder:x", opType: "restock", ops: restockOps() }).error, "invalid-request-id");
    assert.equal(invalid({ requestId: "restock:x", opType: "restockk", ops: restockOps() }).error, "unsupported-op-type");
});

test("validate: unknown counter, product/order/staff are not registered yet (M1)", () => {
    for (const c of ["product", "order", "staff", "", "toString", undefined, 7]) {
        const r = invalid(body([mint(c, "x"), create("supplier", "{{x}}", {})]));
        assert.equal(r.error, "unknown-counter", String(c));
        assert.equal(r.opIndex, 0);
    }
});

test("validate: bind names", () => {
    for (const b of ["", "Sup", "1a", "a-b", "a b", "a".repeat(17), "{{x}}", undefined, null, 5, "é"])
        assert.equal(invalid(body([mint("supplier", b)])).error, "invalid-bind-name", String(b));
    assert.equal(OL.validateOperationRequest(body([mint("supplier", "a".repeat(16)), create("supplier", "SUP-1", {})])).ok, true);
    assert.equal(OL.validateOperationRequest(body([mint("supplier", "aB9")])).ok, true);
});

test("validate: duplicate bind names, and the 5-mint cap", () => {
    const dup = invalid(body([mint("supplier", "a"), mint("stock_batch", "a")]));
    assert.equal(dup.error, "duplicate-bind-name");
    assert.equal(dup.opIndex, 1);
    const five = ["a", "b", "c", "d", "e"].map((n) => mint("supplier", n));
    assert.equal(OL.validateOperationRequest(body(five)).ok, true);
    const six = invalid(body(five.concat([mint("supplier", "f")])));
    assert.equal(six.error, "too-many-mints");
    assert.equal(six.opIndex, 5);
});

test("validate: entityId placeholders are strict and create-only", () => {
    const ok = [mint("supplier", "sup")];
    assert.equal(invalid(body(ok.concat([create("supplier", "{{nope}}", {})]))).error, "unbound-placeholder");
    assert.equal(invalid(body(ok.concat([create("supplier", "{{sup", {})]))).error, "unbound-placeholder");
    assert.equal(invalid(body(ok.concat([create("supplier", "a}}b", {})]))).error, "unbound-placeholder");
    // declared by a LATER mint op = a client ordering bug
    const later = invalid(body([create("supplier", "{{sup}}", {}), mint("supplier", "sup")]));
    assert.equal(later.error, "unbound-placeholder");
    assert.equal(later.opIndex, 0);
    // a mint op does not bind itself to the op at its own index
    assert.equal(OL.validateOperationRequest(body([mint("supplier", "sup"), create("supplier", "{{sup}}", {})])).ok, true);
    // update / delete / delta entityIds never take placeholders
    for (const action of ["update", "delete"]) {
        const r = invalid(body(ok.concat([{ kind: "mutation", entity: "supplier", entityId: "{{sup}}", action, before: {}, after: {} }])));
        assert.equal(r.error, "placeholder-not-allowed", action);
    }
    const d = invalid(body(ok.concat([{ kind: "delta", entity: "inventory", entityId: "{{sup}}", deltas: { stock: 1 } }])));
    assert.equal(d.error, "placeholder-not-allowed");
    assert.equal(d.opIndex, 1);
});

test("validate: `after` strings: a later-declared name is rejected, unknown names are user text", () => {
    const later = invalid(body([create("supplier", "SUP-1", { x: "{{sup}}" }), mint("supplier", "sup")]));
    assert.equal(later.error, "unbound-placeholder");
    assert.equal(later.opIndex, 0);
    const nested = invalid(body([create("supplier", "SUP-1", { a: { b: [1, { c: "x {{sup}} y" }] } }), mint("supplier", "sup")]));
    assert.equal(nested.error, "unbound-placeholder");
    // user text that is not a declared name is accepted, whatever it looks like
    const text = ["{{x}}", "{{", "}}", "{{a b}}", "{{}}", "{{{sup2}}}", "a{{Z9}}"];
    for (const t of text)
        assert.equal(OL.validateOperationRequest(body([mint("supplier", "sup"), create("supplier", "SUP-1", { name: t })])).ok, true, t);
});

test("validate: no mint op = no placeholder scanning at all (byte compatibility)", () => {
    const withBraces = body([create("supplier", "a{{b}}", { x: "{{later}}" })]);
    const v = OL.validateOperationRequest(withBraces);
    assert.equal(v.ok, true);
    assert.equal(v.ops[0].entityId, "a{{b}}");
    assert.equal(OL.validateOperationRequest({ requestId: "completeOrder:o:1", opType: "completeOrder",
        ops: [{ kind: "mutation", entity: "order", entityId: "o{{1}}", action: "update", before: { a: 1 }, after: { a: "{{b}}" } }] }).ok, true);
});

test("validate: a mint-only operation, and ops that are neither mint, delta nor mutation, still behave", () => {
    assert.equal(OL.validateOperationRequest(body([mint("supplier", "a")])).ok, true);
    assert.equal(invalid(body([mint("supplier", "a"), { kind: "teleport" }])).error, "unsupported-kind");
    assert.equal(invalid(body([mint("supplier", "a"), null])).error, "unsupported-kind");
    assert.equal(invalid(body([mint("supplier", "a"), create("nope", "x", {})])).error, "unsupported-entity");
    assert.equal(invalid(body([mint("supplier", "a"), create("supplier", "a/b", {})])).error, "invalid-entity-id");
});

test("validate: write budget counts a mint op as ONE write and no audit row (M8)", () => {
    // base 1 (marker) + 9 inventory ops carrying 50 movements (2 + 50 each) + 10 plain inventory ops (2 + 1 each)
    const heavy = () => ({ kind: "delta", entity: "inventory", entityId: "p", deltas: { stock: 50 },
        movements: Array.from({ length: 50 }, () => ({ kind: "receipt", qty: 1 })) });
    const plain = () => ({ kind: "delta", entity: "inventory", entityId: "q", deltas: { stock: 1 } });
    const work = [];
    for (let i = 0; i < 9; i++) work.push(heavy());
    for (let i = 0; i < 10; i++) work.push(plain());                  // 1 + 468 + 30 = 499
    assert.equal(OL.validateOperationRequest(body(work.concat([mint("supplier", "a")]))).ok, true);               // 500
    const over = invalid(body(work.concat([mint("supplier", "a"), mint("supplier", "b")])));                       // 501
    assert.equal(over.error, "operation-too-large");
    assert.equal(over.opIndex, undefined);
});

// ------------------------------------------------------------- apply: happy path

test("apply: restock mints supplier + batch, creates every doc, writes both counters, results line up with ops", async () => {
    const db = strictDb(baseDocs());
    const r = await run(db, body(restockOps()));
    assert.equal(r.ok, true);
    assert.deepEqual(r.results[0], { kind: "mint", counter: "supplier", bind: "sup", id: "SUP-001" });
    assert.deepEqual(r.results[2], { kind: "mint", counter: "stock_batch", bind: "batch", id: "BAT-2026-001" });
    assert.equal(r.results.length, 6);
    assert.equal(r.results[1].entityId, "SUP-001");
    assert.deepEqual(r.results[3].after, { batchId: "BAT-2026-001", productId: "p1", supplierId: "SUP-001", qtyRemaining: 5 });
    assert.equal(r.results[5].entityId, "tx-p-BAT-2026-001");
    assert.deepEqual(r.results[5].after, { id: "tx-p-BAT-2026-001", batchId: "BAT-2026-001", note: "from BAT-2026-001" });

    assert.deepEqual(db.store[T + "counters/suppliers"], { value: 1 });
    assert.deepEqual(db.store[T + "counters/stockBatches-2026"], { value: 1 });
    assert.deepEqual(db.store[T + "suppliers/SUP-001"], { supplierId: "SUP-001", name: "Acme" });
    assert.equal(db.store[T + "stock_batches/BAT-2026-001"].supplierId, "SUP-001");
    assert.deepEqual(db.store[T + "inventory/p1"], { stock: 15 });
    assert.ok(db.store[T + "transactions/tx-p-BAT-2026-001"]);

    // audit rows only for non-mint ops, keyed by the REQUEST index (the mint indexes are simply skipped)
    const audits = paths(db).filter((p) => p.indexOf("/audit_log/") > 0);
    assert.deepEqual(audits, ["restock:dev1-a", "restock:dev1-a~1", "restock:dev1-a~3", "restock:dev1-a~4", "restock:dev1-a~5"]
        .map((id) => T + "audit_log/" + id));
    const marker = db.store[T + "audit_log/restock:dev1-a"];
    assert.equal(marker.opCount, 6);
    assert.equal(marker.opType, "restock");
    assert.deepEqual(marker.results, r.results);
    assert.equal(db.store[T + "audit_log/restock:dev1-a~3"].after.batchId, "BAT-2026-001");   // audit carries the RESOLVED doc
    const rows = rowsOf(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].data.kind, "receipt");
    assert.equal(pessimisticWrites(db.writes), db.writes.length + db.writes.filter((w) => w.data && Object.values(w.data).includes(TS)).length);
});

test("apply: an existing counter continues from its value; one supplier mint, existing supplier reused", async () => {
    const db = strictDb(Object.assign(baseDocs(), { [T + "counters/stockBatches-2026"]: { value: 6 } }));
    const r = await run(db, body(restockOps({ newSupplier: false })));
    assert.equal(r.ok, true);
    assert.equal(r.results[0].id, "BAT-2026-007");
    assert.deepEqual(db.store[T + "counters/stockBatches-2026"], { value: 7 });
    assert.equal(db.store[T + "counters/suppliers"], undefined);          // untouched, never created
    assert.equal(db.store[T + "stock_batches/BAT-2026-007"].supplierId, "SUP-009");
});

test("apply: two mints on one counter get consecutive numbers and ONE counter write; a counter read happens once", async () => {
    const db = strictDb({ [T + "counters/suppliers"]: { value: 4 } });
    const ops = [mint("supplier", "a"), mint("supplier", "b"), create("supplier", "{{a}}", { id: "{{a}}" }), create("supplier", "{{b}}", { id: "{{b}}" })];
    const r = await run(db, body(ops));
    assert.equal(r.ok, true);
    assert.deepEqual([r.results[0].id, r.results[1].id], ["SUP-005", "SUP-006"]);
    assert.deepEqual(db.store[T + "counters/suppliers"], { value: 6 });
    assert.equal(db.writes.filter((w) => w.path === T + "counters/suppliers").length, 1);
});

test("apply: no document is read twice (collision probes are shared with the create op)", async () => {
    const reads = [];
    const db = strictDb(baseDocs());
    const orig = db.runTransaction.bind(db);
    db.runTransaction = (fn) => orig((txn) => fn({ get: (ref) => { reads.push(ref.path); return txn.get(ref); }, set: txn.set, delete: txn.delete }));
    await run(db, body(restockOps()));
    assert.equal(new Set(reads).size, reads.length, reads.join(", "));
    assert.ok(reads.indexOf(T + "suppliers/SUP-001") >= 0 && reads.indexOf(T + "counters/suppliers") >= 0);
});

test("apply: batch counters are per IST year (M3); Dec 31 18:30 UTC is already next year", async () => {
    const db = strictDb(baseDocs());
    const r = await run(db, body(restockOps({ newSupplier: false })), { now: new Date("2026-12-31T18:30:00Z") });
    assert.equal(r.results[0].id, "BAT-2027-001");
    assert.deepEqual(db.store[T + "counters/stockBatches-2027"], { value: 1 });
    assert.equal(db.store[T + "counters/stockBatches-2026"], undefined);
});

test("apply: `now` defaults to the real clock when the caller passes none", async () => {
    const db = strictDb(baseDocs());
    const v = validated(body(restockOps({ newSupplier: false })));
    const r = await OL.applyOperation(db, { tenantId: "t1", actorUid: "u1", actorRole: "owner", requestId: v.requestId,
        opType: v.opType, ops: v.ops, clientTimestamp: "CT", serverTimestamp: TS });
    assert.equal(r.ok, true);
    assert.match(r.results[0].id, /^BAT-20[0-9]{2}-001$/);
});

test("apply: an unused bind still consumes its number; a mint-only operation is valid", async () => {
    const db = strictDb({});
    const r = await run(db, body([mint("supplier", "a")]));
    assert.equal(r.ok, true);
    assert.deepEqual(r.results, [{ kind: "mint", counter: "supplier", bind: "a", id: "SUP-001" }]);
    assert.deepEqual(db.store[T + "counters/suppliers"], { value: 1 });
    assert.deepEqual(paths(db), [T + "audit_log/restock:dev1-a", T + "counters/suppliers"]);
});

test("apply: a second operation continues the sequence (counter written by the first is read by the second)", async () => {
    const db = strictDb(baseDocs());
    const a = await run(db, body(restockOps({ newSupplier: false }), "a"));
    const b = await run(db, body(restockOps({ newSupplier: false }), "b"));
    assert.deepEqual([a.results[0].id, b.results[0].id], ["BAT-2026-001", "BAT-2026-002"]);
});

// ------------------------------------------------------------- apply: seed, damage, collisions

test("apply: missing counter is seeded from the highest NUMERIC id, ignoring junk and other prefixes (M4)", async () => {
    const db = strictDb({
        [T + "suppliers/SUP-003"]: {}, [T + "suppliers/SUP-010"]: {}, [T + "suppliers/SUP-1000"]: {},
        [T + "suppliers/SUP-abc"]: {}, [T + "suppliers/SUP-12x"]: {}, [T + "suppliers/OTHER-5000"]: {},
        [T + "suppliers/SUP-999"]: {}
    });
    const r = await run(db, body([mint("supplier", "s"), create("supplier", "{{s}}", { id: "{{s}}" })]));
    assert.equal(r.results[0].id, "SUP-1001");
    assert.deepEqual(db.store[T + "counters/suppliers"], { value: 1001 });
    assert.deepEqual(db.listCalls, [T.slice(0, -1) + "/suppliers"]);
});

test("apply: a batch counter seeds only from ids of ITS year", async () => {
    const db = strictDb({ ...baseDocs(), [T + "stock_batches/BAT-2025-050"]: {}, [T + "stock_batches/BAT-2026-004"]: {} });
    const r = await run(db, body(restockOps({ newSupplier: false })));
    assert.equal(r.results[0].id, "BAT-2026-005");
});

test("apply: no listing when the counter doc is usable (the list runs once per counter lifetime)", async () => {
    const db = strictDb({ ...baseDocs(), [T + "counters/stockBatches-2026"]: { value: 0 } });
    await run(db, body(restockOps({ newSupplier: false })));
    assert.deepEqual(db.listCalls, []);
});

test("apply: a damaged counter doc is re-seeded from the ids, not trusted (string, float, negative, null, missing field)", async () => {
    const damaged = [{ value: "abc" }, { value: 3.5 }, { value: -4 }, { value: null }, {}, { value: NaN }, { value: "7" }];
    for (const doc of damaged) {
        const db = strictDb({ ...baseDocs(), [T + "counters/stockBatches-2026"]: doc, [T + "stock_batches/BAT-2026-009"]: {} });
        const r = await run(db, body(restockOps({ newSupplier: false })));
        assert.equal(r.results[0].id, "BAT-2026-010", JSON.stringify(doc));
        assert.deepEqual(db.store[T + "counters/stockBatches-2026"], { value: 10 });
    }
});

test("apply: a counter that lags the data skips occupied ids and ends on a free one (M5)", async () => {
    const db = strictDb({ ...baseDocs(), [T + "counters/stockBatches-2026"]: { value: 1 },
        [T + "stock_batches/BAT-2026-002"]: {}, [T + "stock_batches/BAT-2026-003"]: {} });
    const r = await run(db, body(restockOps({ newSupplier: false })));
    assert.equal(r.results[0].id, "BAT-2026-004");
    assert.deepEqual(db.store[T + "counters/stockBatches-2026"], { value: 4 });
});

test("apply: 20 occupied ids are skipped, the 21st occupied one gives 409 mint-exhausted with zero writes", async () => {
    const taken = (n) => { const d = { ...baseDocs(), [T + "counters/stockBatches-2026"]: { value: 0 } }; for (let i = 1; i <= n; i++) d[T + "stock_batches/BAT-2026-" + String(i).padStart(3, "0")] = {}; return d; };
    const okDb = strictDb(taken(20));
    const ok = await run(okDb, body(restockOps({ newSupplier: false })));
    assert.equal(ok.results[0].id, "BAT-2026-021");
    const badDb = strictDb(taken(21));
    const bad = await run(badDb, body(restockOps({ newSupplier: false })));
    assert.deepEqual(bad, { ok: false, status: 409, error: "mint-exhausted", opIndex: 0 });
    assert.deepEqual(badDb.writes, []);
    assert.equal(OL.MAX_MINT_SKIPS, 20);
});

// ------------------------------------------------------------- apply: rejection burns nothing, replay mints nothing

test("apply: any rejection after the mint writes NOTHING and burns no number (M10)", async () => {
    const rejects = [
        // stale `before` on an update that follows the mint
        { ops: [mint("supplier", "s"), create("supplier", "{{s}}", { id: "{{s}}" }),
                { kind: "mutation", entity: "transaction", entityId: "t9", action: "update", before: { v: 1 }, after: { v: 2 } }],
          docs: { [T + "transactions/t9"]: { v: 99 } }, status: 409, error: "conflict", opIndex: 2 },
        // delta floor
        { ops: [mint("supplier", "s"), { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -50 }, floors: { stock: 0 } }],
          docs: baseDocs(), status: 409, error: "insufficient-quantity", opIndex: 1 },
        // missing product
        { ops: [mint("supplier", "s"), { kind: "delta", entity: "inventory", entityId: "ghost", deltas: { stock: 1 } }],
          docs: {}, status: 404, error: "not-found", opIndex: 1 },
        // create over an existing doc that is NOT a minted id
        { ops: [mint("supplier", "s"), create("supplier", "SUP-900", { x: 1 })],
          docs: { [T + "suppliers/SUP-900"]: { x: 0 } }, status: 409, error: "conflict", opIndex: 1 }
    ];
    for (const c of rejects) {
        const db = strictDb(Object.assign({ [T + "counters/suppliers"]: { value: 4 } }, c.docs));
        const r = await run(db, body(c.ops));
        assert.equal(r.ok, false);
        assert.equal(r.status, c.status);
        assert.equal(r.error, c.error);
        assert.equal(r.opIndex, c.opIndex);
        assert.deepEqual(db.writes, [], c.error);
        assert.deepEqual(db.store[T + "counters/suppliers"], { value: 4 });
    }
});

test("apply: the retried operation after a rejection gets the SAME number (nothing was burned)", async () => {
    const ops = () => [mint("supplier", "s"), create("supplier", "{{s}}", { id: "{{s}}" }),
        { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -50 }, floors: { stock: 0 } }];
    const db = strictDb({ ...baseDocs(), [T + "counters/suppliers"]: { value: 4 } });
    assert.equal((await run(db, body(ops()))).ok, false);
    db.store[T + "inventory/p1"] = { stock: 100 };
    const r = await run(db, body(ops()));
    assert.equal(r.ok, true);
    assert.equal(r.results[0].id, "SUP-005");
});

test("apply: a replay returns the first result, mints nothing, even after the counter moved on", async () => {
    const db = strictDb(baseDocs());
    const first = await run(db, body(restockOps({ newSupplier: false }), "a"));
    await run(db, body(restockOps({ newSupplier: false }), "b"));          // counter now at 2
    const writesBefore = db.writes.length;
    const again = await run(db, body(restockOps({ newSupplier: false }), "a"));
    assert.equal(again.idempotentReplay, true);
    assert.deepEqual(again.results, first.results);
    assert.equal(again.results[0].id, "BAT-2026-001");
    assert.equal(db.writes.length, writesBefore);
    assert.deepEqual(db.store[T + "counters/stockBatches-2026"], { value: 2 });
});

test("apply: a marker without results is still not a replay (request-id-in-use is unchanged)", async () => {
    const db = strictDb({ ...baseDocs(), [T + "audit_log/restock:dev1-a"]: { action: "update" } });
    const r = await run(db, body(restockOps({ newSupplier: false }), "a"));
    assert.deepEqual(r, { ok: false, status: 409, error: "request-id-in-use" });
});

test("apply: a restock whose receipt movement does not add up to the delta is 409 movement-qty-mismatch and burns nothing", async () => {
    const ops = restockOps({ newSupplier: false });
    ops[2] = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 5 }, movements: [{ kind: "receipt", qty: 4 }] };
    const db = strictDb({ ...baseDocs(), [T + "counters/stockBatches-2026"]: { value: 3 } });
    const r = await run(db, body(ops));
    assert.deepEqual(r, { ok: false, status: 409, error: "movement-qty-mismatch", opIndex: 2, field: "stock", current: 10 });
    assert.deepEqual(db.writes, []);
    assert.deepEqual(db.store[T + "counters/stockBatches-2026"], { value: 3 });
});

test("apply: a restock delta WITHOUT a movement derives `adjustment`, which is why the client must send receipt (M9)", async () => {
    const ops = restockOps({ newSupplier: false });
    ops[2] = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 5 } };
    const db = strictDb(baseDocs());
    assert.equal((await run(db, body(ops))).ok, true);
    assert.equal(rowsOf(db)[0].data.kind, "adjustment");
});

// ------------------------------------------------------------- apply: substitution rules

test("apply: substitution reaches nested objects and arrays, leaves keys, numbers, booleans, null and `before` alone", async () => {
    const db = strictDb({ [T + "transactions/t9"]: { ref: "{{b}}" } });
    const ops = [mint("supplier", "b"),
        create("supplier", "{{b}}", { "{{b}}": 1, n: 5, ok: true, nil: null, list: ["{{b}}", 3, { deep: "x-{{b}}-y-{{b}}" }], obj: { a: { b: "{{b}}" } } }),
        // `before` equals the stored doc literally: it must NOT be substituted or the CAS would fail
        { kind: "mutation", entity: "transaction", entityId: "t9", action: "update", before: { ref: "{{b}}" }, after: { ref: "{{b}}", note: "ok" } }];
    const r = await run(db, body(ops));
    assert.equal(r.ok, true);
    assert.deepEqual(db.store[T + "suppliers/SUP-001"],
        { "{{b}}": 1, n: 5, ok: true, nil: null, list: ["SUP-001", 3, { deep: "x-SUP-001-y-SUP-001" }], obj: { a: { b: "SUP-001" } } });
    assert.deepEqual(db.store[T + "transactions/t9"], { ref: "SUP-001", note: "ok" });   // `after` IS substituted
});

test("apply: user text stays as typed unless it names a bound id; delta entityIds are never touched", async () => {
    const db = strictDb(baseDocs());
    const ops = [mint("supplier", "s"), create("supplier", "{{s}}", { name: "{{x}} and {{ s }} and {{S}} and {{s", note: "{{s}}" }),
        { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 1 } }];
    await run(db, body(ops));
    assert.deepEqual(db.store[T + "suppliers/SUP-001"], { name: "{{x}} and {{ s }} and {{S}} and {{s", note: "SUP-001" });
});

test("apply: non-plain values pass through; replacement stops at depth 16 (cap)", async () => {
    const nest = (k, leaf) => { let o = { leaf: leaf }; for (let i = 0; i < k; i++) o = { a: o }; return o; };
    const holderAt = (doc, k) => { let o = doc; for (let i = 0; i < k; i++) o = o.a; return o.leaf; };
    const when = new Date(0);
    const db = strictDb({});
    const r = await run(db, body([mint("supplier", "s"),
        create("supplier", "{{s}}", { when: when, d15: nest(14, "{{s}}"), d16: nest(15, "{{s}}") })]));
    assert.equal(r.ok, true);
    const doc = db.store[T + "suppliers/SUP-001"];
    assert.equal(doc.when, when);                      // a Date is not a plain object: returned untouched
    // `after` is depth 0, so nest(k) puts the container holding the leaf at depth 1 + k.
    assert.equal(holderAt(doc.d15, 14), "SUP-001");    // holder at depth 15: its strings are replaced
    assert.equal(holderAt(doc.d16, 15), "{{s}}");      // holder at depth 16 (MAX_SUBST_DEPTH): not entered, stays literal
});

test("apply: hand-built ops (no validation) are defended at run time", async () => {
    const hand = (ops) => OL.applyOperation(strictDb(baseDocs()), { tenantId: "t1", actorUid: "u", actorRole: "owner", requestId: "restock:x",
        opType: "restock", ops, clientTimestamp: null, serverTimestamp: TS, now: NOW });
    const sup = { kind: "mint", counter: "supplier", bind: "s", entity: "supplier", collection: "suppliers" };
    const mk = (entityId) => ({ kind: "mutation", entity: "supplier", collection: "suppliers", entityId, action: "create", before: null, after: {} });
    assert.deepEqual(await hand([{ kind: "mint", counter: "nope", bind: "s" }, mk("{{s}}")]), { ok: false, status: 400, error: "unknown-counter", opIndex: 0 });
    assert.deepEqual(await hand([sup, mk("{{zzz}}")]), { ok: false, status: 400, error: "unbound-placeholder", opIndex: 1 });
    assert.deepEqual(await hand([sup, mk("{{s}}/x")]), { ok: false, status: 400, error: "invalid-entity-id", opIndex: 1 });
});

// ------------------------------------------------------------- monkey

test("monkey: 300 seeded runs over random counter state, occupied ids and hostile text keep every invariant", async () => {
    let seed = 20261028;
    const rnd = (n) => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed % n; };
    const junk = ["{{a}}", "{{b}}", "{{", "}}", "x{{c}}y", "{{}}", "", "SUP-001", "{{a}}{{b}}", "é{{a}}"];
    let accepted = 0, rejected = 0;
    for (let iter = 0; iter < 300; iter++) {
        const docs = {};
        const occupied = new Set();
        for (let i = 0; i < rnd(8); i++) { const n = 1 + rnd(40); occupied.add(n); docs[T + "suppliers/" + "SUP-" + String(n).padStart(3, "0")] = { pre: true }; }
        const mode = rnd(4);
        if (mode === 1) docs[T + "counters/suppliers"] = { value: rnd(45) };
        if (mode === 2) docs[T + "counters/suppliers"] = { value: ["x", -1, 2.5, null][rnd(4)] };
        const db = strictDb(docs);
        const nMints = 1 + rnd(3);
        const ops = [];
        const binds = ["a", "b", "c"].slice(0, nMints);
        for (const b of binds) ops.push(mint("supplier", b));
        for (const b of binds) ops.push(create("supplier", "{{" + b + "}}", { id: "{{" + b + "}}", name: junk[rnd(junk.length)], tags: [junk[rnd(junk.length)]] }));
        const before = Object.assign({}, db.store);
        const r = await run(db, body(ops, "m" + iter));
        if (!r.ok) {
            rejected++;
            assert.equal(r.error, "mint-exhausted");
            assert.deepEqual(db.writes, []);
            continue;
        }
        accepted++;
        const ids = r.results.filter((x) => x.kind === "mint").map((x) => x.id);
        assert.equal(new Set(ids).size, ids.length);
        for (const id of ids) {
            assert.equal(Object.prototype.hasOwnProperty.call(before, T + "suppliers/" + id), false, "reissued " + id);
            assert.ok(db.store[T + "suppliers/" + id]);
            assert.equal(db.store[T + "suppliers/" + id].id, id);
        }
        const last = Math.max(...ids.map((x) => parseInt(x.substring(4), 10)));
        assert.equal(db.store[T + "counters/suppliers"].value, last);
        const replay = await run(db, body(ops, "m" + iter));
        assert.equal(replay.idempotentReplay, true);
        assert.deepEqual(replay.results, r.results);
    }
    assert.ok(accepted > 250 && rejected <= 50, accepted + "/" + rejected);
});
