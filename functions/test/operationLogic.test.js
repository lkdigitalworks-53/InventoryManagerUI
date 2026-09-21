"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const OperationLogic = require("../lib/operationLogic");

const T = "tenants/t1/";

// Minimal Firestore double. Reads see the ORIGINAL store (writes only take
// effect on commit in real Firestore, and this module never reads after it
// writes); every set/delete is recorded so tests can assert on exactly what a
// transaction wrote, including "nothing".
function makeFakeDb(docs) {
    const store = Object.assign({}, docs || {});
    const writes = [];
    const reads = [];
    let transactions = 0;
    return {
        writes,
        reads,
        get transactions() { return transactions; },
        doc(path) { return { path }; },
        async runTransaction(fn) {
            transactions++;
            const txn = {
                async get(ref) {
                    reads.push(ref.path);
                    const has = Object.prototype.hasOwnProperty.call(store, ref.path);
                    return { exists: has, data: () => store[ref.path] };
                },
                set(ref, data, options) { writes.push({ type: "set", path: ref.path, data, options }); },
                delete(ref) { writes.push({ type: "delete", path: ref.path }); }
            };
            return fn(txn);
        }
    };
}

function params(ops, extra) {
    return Object.assign({
        tenantId: "t1", actorUid: "u1", actorRole: "owner", requestId: "completeOrder:o1:1",
        opType: "completeOrder", ops: ops, serverTimestamp: "SERVER_TS", clientTimestamp: "CLIENT_TS"
    }, extra || {});
}

function delta(entity, entityId, deltas, floors, clamps) {
    const collection = { inventory: "inventory", stock_batch: "stock_batches" }[entity];
    return { kind: "delta", entity, entityId, collection, deltas, floors: floors || {}, clamps: clamps || {} };
}

function mutation(entity, entityId, action, before, after) {
    const collection = { order: "orders", transaction: "transactions" }[entity];
    return { kind: "mutation", entity, entityId, collection, action, before, after };
}

// ---------------------------------------------------------------- validation

test("validateOperationRequest: accepts a valid mixed operation and derives per-op request ids", () => {
    const v = OperationLogic.validateOperationRequest({
        requestId: "completeOrder:o1:1", opType: "completeOrder", clientTimestamp: "CT",
        ops: [
            { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } },
            { kind: "mutation", entity: "order", entityId: "o1", action: "update", before: { a: 1 }, after: { a: 2 } }
        ]
    });
    assert.equal(v.ok, true);
    assert.equal(v.ops.length, 2);
    assert.equal(v.ops[0].kind, "delta");
    assert.equal(v.ops[0].requestId, "completeOrder:o1:1:0");
    assert.equal(v.ops[1].kind, "mutation");
    assert.equal(v.ops[1].collection, "orders");
    assert.equal(v.clientTimestamp, "CT");
});

test("validateOperationRequest: rejects bad envelopes with 400", () => {
    const V = OperationLogic.validateOperationRequest;
    const good = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 } };
    assert.deepEqual(V(undefined), { ok: false, status: 400, error: "missing-fields" });
    assert.deepEqual(V({ opType: "completeOrder", ops: [good] }), { ok: false, status: 400, error: "missing-fields" });
    assert.deepEqual(V({ requestId: "r" , ops: [good] }), { ok: false, status: 400, error: "missing-fields" });
    assert.deepEqual(V({ requestId: "r", opType: "wipeEverything", ops: [good] }),
        { ok: false, status: 400, error: "unsupported-op-type" });
    assert.deepEqual(V({ requestId: "r", opType: "completeOrder", ops: [] }),
        { ok: false, status: 400, error: "empty-operation" });
    assert.deepEqual(V({ requestId: "r", opType: "completeOrder" }),
        { ok: false, status: 400, error: "empty-operation" });
    assert.deepEqual(V({ requestId: "r", opType: "completeOrder", ops: new Array(OperationLogic.MAX_OPS + 1).fill(good) }),
        { ok: false, status: 400, error: "operation-too-large" });
});

test("validateOperationRequest: MAX_OPS is exactly 200 (mirrored by Gateway.maxOperationOps)", () => {
    assert.equal(OperationLogic.MAX_OPS, 200);
    const good = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 } };
    const v = OperationLogic.validateOperationRequest({
        requestId: "r", opType: "completeOrder", ops: new Array(200).fill(good) });
    assert.equal(v.ok, true);
});

test("validateOperationRequest: reports the failing op index for per-op errors", () => {
    const V = OperationLogic.validateOperationRequest;
    const good = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 } };
    const env = (bad) => ({ requestId: "r", opType: "completeOrder", ops: [good, bad] });

    assert.deepEqual(V(env({ kind: "teleport" })),
        { ok: false, status: 400, error: "unsupported-kind", opIndex: 1 });
    assert.deepEqual(V(env(null)),
        { ok: false, status: 400, error: "unsupported-kind", opIndex: 1 });
    assert.deepEqual(V(env({ kind: "delta", entity: "nope", entityId: "x", deltas: { a: 1 } })),
        { ok: false, status: 400, error: "unsupported-entity", opIndex: 1 });
    assert.deepEqual(V(env({ kind: "delta", entity: "inventory", entityId: "x", deltas: {} })),
        { ok: false, status: 400, error: "missing-deltas", opIndex: 1 });
    assert.deepEqual(V(env({ kind: "delta", entity: "inventory", entityId: "x", deltas: { a: "1" } })),
        { ok: false, status: 400, error: "invalid-delta-value", opIndex: 1 });
    assert.deepEqual(V(env({ kind: "mutation", entity: "order", entityId: "o", action: "explode" })),
        { ok: false, status: 400, error: "unsupported-action", opIndex: 1 });
    assert.deepEqual(V(env({ kind: "mutation", entity: "order", entityId: "", action: "update" })),
        { ok: false, status: 400, error: "missing-fields", opIndex: 1 });
});

// ------------------------------------------------------------------ applying

test("applyOperation: applies deltas and a mutation atomically, one transaction, full audit trail", async () => {
    const db = makeFakeDb({
        [T + "stock_batches/b1"]: { qtyRemaining: 10, unitCost: 5 },
        [T + "inventory/p1"]: { stock: 10, name: "Widget" },
        [T + "orders/o1"]: { status: "pending" }
    });
    const ops = [
        delta("stock_batch", "b1", { qtyRemaining: -1 }, { qtyRemaining: 0 }),
        delta("inventory", "p1", { stock: -1 }, { stock: 0 }),
        mutation("order", "o1", "update", { status: "pending" }, { status: "completed" }),
        mutation("transaction", "tx1", "create", null, { kind: "sale" })
    ];
    const r = await OperationLogic.applyOperation(db, params(ops));

    assert.equal(r.ok, true);
    assert.equal(db.transactions, 1);
    assert.deepEqual(r.results.map(x => [x.entity, x.entityId, x.kind]),
        [["stock_batch", "b1", "delta"], ["inventory", "p1", "delta"], ["order", "o1", "mutation"], ["transaction", "tx1", "mutation"]]);
    assert.deepEqual(r.results[0].after, { qtyRemaining: 9 });
    assert.deepEqual(r.results[1].after, { stock: 9 });

    const byPath = {};
    for (const w of db.writes) byPath[w.path] = w;
    assert.deepEqual(byPath[T + "stock_batches/b1"].data, { qtyRemaining: 9, unitCost: 5 });
    assert.deepEqual(byPath[T + "inventory/p1"].data, { stock: 9, name: "Widget" });
    assert.deepEqual(byPath[T + "orders/o1"].data, { status: "completed" });
    assert.deepEqual(byPath[T + "transactions/tx1"].data, { kind: "sale" });
    assert.deepEqual(byPath[T + "stock_batches/b1"].options, { merge: false });

    // 4 working docs + 4 per-op audit entries + 1 marker.
    assert.equal(db.writes.length, 9);
    const marker = byPath[T + "audit_log/completeOrder:o1:1"];
    assert.equal(marker.data.action, "operation");
    assert.equal(marker.data.opCount, 4);
    assert.equal(marker.data.entryId, "completeOrder:o1:1");
    assert.deepEqual(marker.data.results, r.results);
    const audit1 = byPath[T + "audit_log/completeOrder:o1:1:1"].data;
    assert.equal(audit1.action, "delta");
    assert.equal(audit1.operationId, "completeOrder:o1:1");
    assert.equal(audit1.opType, "completeOrder");
    assert.equal(audit1.opIndex, 1);
    assert.deepEqual(audit1.before, { stock: 10 });
    assert.deepEqual(audit1.after, { stock: 9 });
    assert.equal(audit1.actorUid, "u1");
    assert.equal(audit1.serverTimestamp, "SERVER_TS");
    assert.equal(byPath[T + "audit_log/completeOrder:o1:1:2"].data.action, "update");
});

test("applyOperation: a replayed requestId is a no-op that returns the first results", async () => {
    const stored = [{ entity: "inventory", entityId: "p1", kind: "delta", after: { stock: 9 } }];
    const db = makeFakeDb({ [T + "audit_log/completeOrder:o1:1"]: { results: stored } });
    const r = await OperationLogic.applyOperation(db, params([delta("inventory", "p1", { stock: -1 })]));
    assert.deepEqual(r, { ok: true, idempotentReplay: true, results: stored });
    assert.equal(db.writes.length, 0);
});

test("applyOperation: two deltas on the same doc compose, and the doc is written once", async () => {
    const db = makeFakeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const r = await OperationLogic.applyOperation(db, params([
        delta("inventory", "p1", { stock: -3 }, { stock: 0 }),
        delta("inventory", "p1", { stock: -2 }, { stock: 0 })
    ]));
    assert.equal(r.ok, true);
    assert.deepEqual(r.results.map(x => x.after), [{ stock: 7 }, { stock: 5 }]);
    const docWrites = db.writes.filter(w => w.path === T + "inventory/p1");
    assert.equal(docWrites.length, 1);
    assert.deepEqual(docWrites[0].data, { stock: 5 });
    // The marker and the shared doc are each read exactly once.
    assert.deepEqual(db.reads, [T + "audit_log/completeOrder:o1:1", T + "inventory/p1"]);
});

test("applyOperation: landing exactly on the floor is allowed; one below is not", async () => {
    const at = makeFakeDb({ [T + "inventory/p1"]: { stock: 3 } });
    const ok = await OperationLogic.applyOperation(at, params([delta("inventory", "p1", { stock: -3 }, { stock: 0 })]));
    assert.equal(ok.ok, true);
    assert.deepEqual(ok.results[0].after, { stock: 0 });

    const below = makeFakeDb({ [T + "inventory/p1"]: { stock: 3 } });
    const bad = await OperationLogic.applyOperation(below, params([delta("inventory", "p1", { stock: -4 }, { stock: 0 })]));
    assert.equal(bad.ok, false);
    assert.equal(bad.error, "insufficient-quantity");
});

test("applyOperation: a floor violation rejects the WHOLE operation and writes nothing (no marker)", async () => {
    const db = makeFakeDb({
        [T + "stock_batches/b1"]: { qtyRemaining: 5 },
        [T + "inventory/p1"]: { stock: 0 }
    });
    const r = await OperationLogic.applyOperation(db, params([
        delta("stock_batch", "b1", { qtyRemaining: -1 }, { qtyRemaining: 0 }),
        delta("inventory", "p1", { stock: -1 }, { stock: 0 })
    ]));
    assert.deepEqual(r, { ok: false, status: 409, error: "insufficient-quantity",
                          opIndex: 1, field: "stock", current: 0 });
    assert.equal(db.writes.length, 0);
});

test("applyOperation: a rejected requestId can be retried later with a re-planned payload", async () => {
    const docs = { [T + "inventory/p1"]: { stock: 0 } };
    const db1 = makeFakeDb(docs);
    const first = await OperationLogic.applyOperation(db1, params([delta("inventory", "p1", { stock: -1 }, { stock: 0 })]));
    assert.equal(first.ok, false);
    assert.equal(db1.writes.length, 0);       // nothing (esp. no marker) left behind

    const db2 = makeFakeDb(docs);             // same server state, same requestId
    const second = await OperationLogic.applyOperation(db2, params([delta("inventory", "p1", { stock: -1 }, {}, { stock: 0 })]));
    assert.equal(second.ok, true);            // re-planned with clamp
    assert.deepEqual(second.results[0].after, { stock: 0 });
});

test("applyOperation: clamps instead of rejecting when the op asks for it", async () => {
    const db = makeFakeDb({ [T + "inventory/p1"]: { stock: 1 } });
    const r = await OperationLogic.applyOperation(db, params([delta("inventory", "p1", { stock: -3 }, {}, { stock: 0 })]));
    assert.equal(r.ok, true);
    assert.deepEqual(r.results[0].after, { stock: 0 });
});

test("applyOperation: a delta on a missing doc is a 404 naming the op, nothing written", async () => {
    const db = makeFakeDb({});
    const r = await OperationLogic.applyOperation(db, params([delta("inventory", "ghost", { stock: -1 })]));
    assert.deepEqual(r, { ok: false, status: 404, error: "not-found", opIndex: 0 });
    assert.equal(db.writes.length, 0);
});

test("applyOperation: a stale mutation `before` is a CAS conflict carrying the server's current doc", async () => {
    const db = makeFakeDb({
        [T + "inventory/p1"]: { stock: 10 },
        [T + "orders/o1"]: { status: "completed" }
    });
    const r = await OperationLogic.applyOperation(db, params([
        delta("inventory", "p1", { stock: -1 }, { stock: 0 }),
        mutation("order", "o1", "update", { status: "pending" }, { status: "completed" })
    ]));
    assert.deepEqual(r, { ok: false, status: 409, error: "conflict", conflict: true,
                          opIndex: 1, current: { status: "completed" } });
    assert.equal(db.writes.length, 0);
});

test("applyOperation: create expects a missing doc (before: null); creating over an existing doc conflicts", async () => {
    const dbFree = makeFakeDb({});
    const ok = await OperationLogic.applyOperation(dbFree, params([mutation("transaction", "tx1", "create", null, { k: 1 })]));
    assert.equal(ok.ok, true);

    const dbTaken = makeFakeDb({ [T + "transactions/tx1"]: { k: 0 } });
    const bad = await OperationLogic.applyOperation(dbTaken, params([mutation("transaction", "tx1", "create", null, { k: 1 })]));
    assert.equal(bad.ok, false);
    assert.equal(bad.status, 409);
    assert.equal(dbTaken.writes.length, 0);
});

test("applyOperation: a later op sees an earlier op's effect (create then delta on the same doc)", async () => {
    const db = makeFakeDb({});
    const r = await OperationLogic.applyOperation(db, params([
        mutation("order", "o9", "create", null, { qty: 5 }),
        { kind: "delta", entity: "order", entityId: "o9", collection: "orders", deltas: { qty: 2 }, floors: {}, clamps: {} }
    ]));
    assert.equal(r.ok, true);
    assert.deepEqual(r.results[1].after, { qty: 7 });
    assert.deepEqual(db.writes.find(w => w.path === T + "orders/o9").data, { qty: 7 });
});

test("applyOperation: delete removes an existing doc; deleting a doc that never existed writes nothing for it", async () => {
    const db = makeFakeDb({ [T + "orders/o1"]: { a: 1 } });
    const r = await OperationLogic.applyOperation(db, params([
        mutation("order", "o1", "delete", { a: 1 }, null),
        mutation("order", "o2", "delete", null, null)
    ]));
    assert.equal(r.ok, true);
    assert.deepEqual(r.results.map(x => x.after), [null, null]);
    assert.deepEqual(db.writes.filter(w => w.type === "delete").map(w => w.path), [T + "orders/o1"]);
    assert.equal(db.writes.some(w => w.path === T + "orders/o2"), false);
});

test("applyOperation: create-then-delete in one operation leaves no working doc behind", async () => {
    const db = makeFakeDb({});
    const r = await OperationLogic.applyOperation(db, params([
        mutation("order", "o5", "create", null, { a: 1 }),
        mutation("order", "o5", "delete", { a: 1 }, null)
    ]));
    assert.equal(r.ok, true);
    assert.equal(db.writes.some(w => w.path === T + "orders/o5"), false);
});

test("applyOperation: a mutation with a null `after` (non-delete) stores an empty doc", async () => {
    const db = makeFakeDb({ [T + "orders/o1"]: { a: 1 } });
    const r = await OperationLogic.applyOperation(db, params([mutation("order", "o1", "update", { a: 1 }, null)]));
    assert.equal(r.ok, true);
    assert.deepEqual(r.results[0].after, {});
    assert.deepEqual(db.writes.find(w => w.path === T + "orders/o1").data, {});
});

test("applyOperation: a full 200-op operation stays under Firestore's write ceiling (401 writes)", async () => {
    const docs = {};
    const ops = [];
    for (let i = 0; i < OperationLogic.MAX_OPS; i++) {
        docs[T + "inventory/p" + i] = { stock: 5 };
        ops.push(delta("inventory", "p" + i, { stock: -1 }, { stock: 0 }));
    }
    const db = makeFakeDb(docs);
    const r = await OperationLogic.applyOperation(db, params(ops));
    assert.equal(r.ok, true);
    assert.equal(db.writes.length, 401);
    assert.ok(db.writes.length < 500);
});

test("opAuditId: derives stable per-op ids from the request id", () => {
    assert.equal(OperationLogic.opAuditId("completeOrder:o1:1", 3), "completeOrder:o1:1:3");
});
