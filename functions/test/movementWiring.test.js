"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const G = require("../lib/gatewayLogic");
const O = require("../lib/operationLogic");
const M = require("../lib/movementLogic");

const T = "tenants/t1/";

function makeDb(docs) {
    const store = Object.assign({}, docs || {});
    const writes = [];
    return {
        store, writes,
        doc(path) { return { path }; },
        async runTransaction(fn) {
            return fn({
                async get(ref) {
                    const has = Object.prototype.hasOwnProperty.call(store, ref.path);
                    return { exists: has, data: () => (has ? store[ref.path] : undefined) };
                },
                set(ref, data) { writes.push({ path: ref.path, data }); store[ref.path] = data; },
                delete(ref) { writes.push({ path: ref.path, deleted: true }); delete store[ref.path]; }
            });
        }
    };
}
const rowsOf = (db) => db.writes.filter((w) => w.path.indexOf("/stock_movements/") >= 0);

// ── validateDeltaRequest ────────────────────────────────────────────────────
function deltaBody(overrides) {
    return Object.assign({ entity: "inventory", entityId: "p1", requestId: "req-1",
        deltas: { stock: -3 }, movements: [{ kind: "loss", qty: -3, reason: "r", valueAtCost: 9 }] }, overrides || {});
}

test("validateDeltaRequest: accepts movements and returns them normalized", () => {
    const v = G.validateDeltaRequest(deltaBody());
    assert.equal(v.ok, true);
    assert.equal(v.movements.length, 1);
    assert.equal(v.movements[0].kind, "loss");
});

test("validateDeltaRequest: no movements field gives an empty list (backward compatible)", () => {
    const v = G.validateDeltaRequest(deltaBody({ movements: undefined }));
    assert.equal(v.ok, true);
    assert.deepEqual(v.movements, []);
});

test("validateDeltaRequest: movements need the inventory entity and a stock delta", () => {
    let v = G.validateDeltaRequest(deltaBody({ entity: "stock_batch", deltas: { qtyRemaining: -3 } }));
    assert.equal(v.error, "movements-require-inventory");
    v = G.validateDeltaRequest(deltaBody({ deltas: { price: 1 } }));
    assert.equal(v.error, "movements-require-stock-delta");
});

test("validateDeltaRequest: bad movement is rejected with 400 before any write", () => {
    const v = G.validateDeltaRequest(deltaBody({ movements: [{ kind: "nope", qty: -1 }] }));
    assert.equal(v.ok, false);
    assert.equal(v.status, 400);
    assert.equal(v.error, "invalid-movement-kind");
});

// ── closed generic write path ───────────────────────────────────────────────
test("stock_movement is no longer a client-writable entity on any endpoint", () => {
    assert.equal(G.ENTITY_COLLECTIONS.stock_movement, undefined);
    const m = G.validateMutationRequest({ entity: "stock_movement", entityId: "x", action: "create", requestId: "r" });
    assert.equal(m.error, "unsupported-entity");
    const d = G.validateDeltaRequest({ entity: "stock_movement", entityId: "x", requestId: "r", deltas: { qty: 1 } });
    assert.equal(d.error, "unsupported-entity");
    const o = O.validateOperationRequest({ requestId: "completeOrder:o1:1", opType: "completeOrder", ops: [
        { kind: "mutation", entity: "stock_movement", entityId: "x", action: "create", before: null, after: {} }] });
    assert.equal(o.error, "unsupported-entity");
});

// ── applyDelta ──────────────────────────────────────────────────────────────
function dParams(overrides) {
    const v = G.validateDeltaRequest(deltaBody());
    return Object.assign({ tenantId: "t1", actorUid: "u1", actorRole: "manager", entity: v.entity, entityId: v.entityId,
        requestId: v.requestId, deltas: v.deltas, floors: {}, clamps: {}, movements: v.movements,
        clientTimestamp: 5, collection: v.collection, serverTimestamp: "TS" }, overrides || {});
}

test("applyDelta: writes stock, audit entry and server-stamped movement row in ONE transaction", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const r = await G.applyDelta(db, dParams());
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"].stock, 7);
    assert.ok(db.store[T + "audit_log/req-1"]);
    const row = db.store[T + "stock_movements/req-1~m0"];
    assert.equal(row.productId, "p1");
    assert.equal(row.actorUid, "u1");
    assert.equal(row.actorRole, "manager");
    assert.equal(row.serverTimestamp, "TS");
    assert.equal(row.qty, -3);
    assert.equal(row.kind, "loss");
});

test("applyDelta: no movements on an inventory stock delta derives ONE adjustment row from the applied delta", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const r = await G.applyDelta(db, dParams({ movements: [] }));
    assert.equal(r.ok, true);
    const rows = rowsOf(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].data.kind, "adjustment");
    assert.equal(rows[0].data.qty, -3);
    assert.equal(rows[0].data.derived, true);
    assert.equal(rows[0].data.productId, "p1");
    assert.equal(rows[0].data.actorUid, "u1");
});

test("applyDelta: derived row records the APPLIED delta after a clamp, not the requested one", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 1 } });
    const r = await G.applyDelta(db, dParams({ movements: [], clamps: { stock: 0 } }));   // asks -3, applies -1
    assert.equal(r.ok, true);
    assert.equal(rowsOf(db)[0].data.qty, -1);
});

test("applyDelta: a zero applied change derives no row; a non-inventory entity derives none", async () => {
    let db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, dParams({ movements: [], deltas: { stock: 0 } }));
    assert.equal(rowsOf(db).length, 0);
    db = makeDb({ [T + "stock_batches/b1"]: { qtyRemaining: 10 } });
    await G.applyDelta(db, dParams({ movements: [], entity: "stock_batch", entityId: "b1", collection: "stock_batches",
        deltas: { qtyRemaining: -1 } }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyDelta: an inventory delta on a field other than stock derives no row", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10, minStock: 2 } });
    await G.applyDelta(db, dParams({ movements: [], deltas: { minStock: 1 } }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyDelta: several movements, one per FIFO portion, must sum to the applied delta", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const movements = [{ kind: "sale", qty: -1, reason: "", valueAtCost: 1 },
                       { kind: "sale", qty: -2, reason: "", valueAtCost: 4 }];
    const r = await G.applyDelta(db, dParams({ movements: movements }));
    assert.equal(r.ok, true);
    assert.deepEqual(rowsOf(db).map((w) => w.path), [T + "stock_movements/req-1~m0", T + "stock_movements/req-1~m1"]);
});

test("applyDelta: a sum that disagrees with the applied delta writes NOTHING and returns 409", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const r = await G.applyDelta(db, dParams({ movements: [{ kind: "loss", qty: -1, reason: "", valueAtCost: 0 }] }));
    assert.equal(r.ok, false);
    assert.equal(r.status, 409);
    assert.equal(r.error, "movement-qty-mismatch");
    assert.equal(db.writes.length, 0);
});

test("applyDelta: a clamp that changes the applied delta makes the movements mismatch (rejected, nothing written)", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 1 } });
    const r = await G.applyDelta(db, dParams({ clamps: { stock: 0 } }));   // asks -3, clamp applies -1
    assert.equal(r.error, "movement-qty-mismatch");
    assert.equal(db.writes.length, 0);
});

test("applyDelta: a floor violation still wins and writes nothing", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 1 } });
    const r = await G.applyDelta(db, dParams({ floors: { stock: 0 } }));
    assert.equal(r.error, "insufficient-quantity");
    assert.equal(db.writes.length, 0);
});

test("applyDelta: retry with the same requestId is a replay and writes no second row", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, dParams());
    const before = db.writes.length;
    const again = await G.applyDelta(db, dParams());
    assert.equal(again.idempotentReplay, true);
    assert.equal(db.writes.length, before);
    assert.equal(db.store[T + "inventory/p1"].stock, 7);
});

test("applyDelta: missing product is 404 and writes nothing", async () => {
    const db = makeDb({});
    const r = await G.applyDelta(db, dParams());
    assert.equal(r.status, 404);
    assert.equal(db.writes.length, 0);
});

test("applyDelta: increasing kinds work (receipt +5)", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 1 } });
    const r = await G.applyDelta(db, dParams({ deltas: { stock: 5 }, movements: [{ kind: "receipt", qty: 5, reason: "", valueAtCost: 50 }] }));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"].stock, 6);
});
// ── operations ──────────────────────────────────────────────────────────────
const RID = "completeOrder:o1:1";
function opBody(ops) { return { requestId: RID, opType: "completeOrder", ops: ops, clientTimestamp: 7 }; }
function deltaOp(id, stockDelta, movements) {
    return { kind: "delta", entity: "inventory", entityId: id, deltas: { stock: stockDelta }, floors: { stock: 0 }, movements: movements };
}
function oParams(v) {
    return { tenantId: "t1", actorUid: "u1", actorRole: "staff", requestId: v.requestId, opType: v.opType, ops: v.ops,
             clientTimestamp: v.clientTimestamp, serverTimestamp: "TS" };
}

test("validateMutationRequest and a mutation op may not carry movements (server derives them)", () => {
    const m = G.validateMutationRequest({ entity: "inventory", entityId: "p1", action: "update", requestId: "r", before: {}, after: {}, movements: [] });
    assert.equal(m.error, "movements-not-supported");
    const v = O.validateOperationRequest(opBody([{ kind: "mutation", entity: "order", entityId: "o1", action: "update",
        before: {}, after: {}, movements: [] }]));
    assert.equal(v.error, "movements-not-supported");
    assert.equal(v.opIndex, 0);
});

test("validateOperationRequest: write budget = 2 per op + 1 marker + one movement row per inventory op", () => {
    const inv = (n) => Array.from({ length: n }, (_, i) => deltaOp("p" + i, -1, undefined));
    assert.equal(O.validateOperationRequest(opBody(inv(166))).ok, true);            // 332 + 1 + 166 = 499
    const over = O.validateOperationRequest(opBody(inv(167)));                       // 334 + 1 + 167 = 502
    assert.equal(over.ok, false);
    assert.equal(over.error, "operation-too-large");
});

// Why the app never sees `operation-too-large` for an order (P1 S1b review, D-1 follow-up).
// The only sender of operations is qml/helper/CompletionPlan.js. It sends at most MAX_OPS ops, and every
// inventory op comes with the order op and at least one stock_batch op (FIFO or repair), so it sends at most
// (MAX_OPS - 1) / 2 inventory ops. This pins that the server budget accepts that largest shape. If MAX_OPS or the
// budget moves, this fails first, instead of the app showing a server rejection for a plain big order.
test("write budget accepts the largest order the client planner can send, and refuses a shape it cannot", () => {
    const batch = (i) => ({ kind: "delta", entity: "stock_batch", entityId: "b" + i, deltas: { qtyRemaining: -1 } });
    const order = { kind: "mutation", entity: "order", entityId: "o1", action: "update", before: {}, after: {} };
    const shape = (inv, batches) => [
        ...Array.from({ length: inv }, (_, i) => deltaOp("p" + i, -1, undefined)),
        ...Array.from({ length: batches }, (_, i) => batch(i)), order];
    assert.equal(O.MAX_OPS, 200);
    const maxInv = Math.floor((O.MAX_OPS - 1) / 2);
    assert.equal(maxInv, 99);
    assert.ok(2 * O.MAX_OPS + 1 + maxInv <= M.MAX_TXN_WRITES, "the budget formula holds for the planner's bound");
    const ok = O.validateOperationRequest(opBody(shape(99, 100)));                   // 200 ops: 401 + 99 = 500
    assert.equal(ok.ok, true, ok.error);
    const over = O.validateOperationRequest(opBody(shape(100, 99)));                 // 200 ops: 401 + 100 = 501 (planner cannot build it)
    assert.equal(over.error, "operation-too-large");
    assert.equal(O.validateOperationRequest(opBody(shape(99, 101))).error, "operation-too-large");   // 201 ops: MAX_OPS
});

test("validateOperationRequest: explicit movements count toward the write budget", () => {
    const two = [{ kind: "sale", qty: -1 }, { kind: "sale", qty: -1 }];
    const ops = (n) => Array.from({ length: n }, (_, i) => deltaOp("p" + i, -2, two));
    assert.equal(O.validateOperationRequest(opBody(ops(124))).ok, true);             // 4*124 + 1 = 497
    const over = O.validateOperationRequest(opBody(ops(125)));                       // 4*125 + 1 = 501
    assert.equal(over.error, "operation-too-large");
});

test("validateOperationRequest: a non-inventory op costs no movement row (200 stock_batch ops = 401 writes, ok)", () => {
    const ops = Array.from({ length: 200 }, (_, i) => ({ kind: "delta", entity: "stock_batch", entityId: "b" + i, deltas: { qtyRemaining: -1 } }));
    assert.equal(O.validateOperationRequest(opBody(ops)).ok, true);
});

test("validateOperationRequest: a bad movement reports the op index", () => {
    const v = O.validateOperationRequest(opBody([deltaOp("p1", -1, [{ kind: "sale", qty: -1 }]), deltaOp("p2", -1, [{ kind: "x", qty: -1 }])]));
    assert.equal(v.error, "invalid-movement-kind");
    assert.equal(v.opIndex, 1);
});

test("applyOperation: writes a movement row per op movement, carrying the operation context", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 }, [T + "inventory/p2"]: { stock: 5 } });
    const v = O.validateOperationRequest(opBody([
        deltaOp("p1", -3, [{ kind: "sale", qty: -1, valueAtCost: 2 }, { kind: "sale", qty: -2, valueAtCost: 6 }]),
        deltaOp("p2", -1, undefined)]));
    const r = await O.applyOperation(db, oParams(v));
    assert.equal(r.ok, true);
    // op 0: two explicit rows; op 1: no movements sent, so one server-derived row.
    assert.deepEqual(rowsOf(db).map((w) => w.path),
        [T + "stock_movements/completeOrder:o1:1~0~m0", T + "stock_movements/completeOrder:o1:1~0~m1", T + "stock_movements/completeOrder:o1:1~1~m0"]);
    assert.equal(db.store[T + "stock_movements/completeOrder:o1:1~0~m0"].derived, false);
    assert.equal(db.store[T + "stock_movements/completeOrder:o1:1~1~m0"].derived, true);
    const row = db.store[T + "stock_movements/completeOrder:o1:1~0~m1"];
    assert.equal(row.productId, "p1");
    assert.equal(row.operationId, RID);
    assert.equal(row.opType, "completeOrder");
    assert.equal(row.opIndex, 0);
    assert.equal(row.actorRole, "staff");
    assert.equal(db.store[T + "inventory/p1"].stock, 7);
});

test("applyOperation: a movement/stock mismatch on any op rejects the WHOLE operation, nothing written", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 }, [T + "inventory/p2"]: { stock: 5 } });
    const v = O.validateOperationRequest(opBody([
        deltaOp("p1", -3, [{ kind: "sale", qty: -3 }]),
        deltaOp("p2", -2, [{ kind: "sale", qty: -1 }])]));
    const r = await O.applyOperation(db, oParams(v));
    assert.equal(r.ok, false);
    assert.equal(r.error, "movement-qty-mismatch");
    assert.equal(r.opIndex, 1);
    assert.equal(db.writes.length, 0);
});

test("applyOperation: replay of the same requestId writes no second set of rows", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const v = O.validateOperationRequest(opBody([deltaOp("p1", -3, [{ kind: "sale", qty: -3 }])]));
    await O.applyOperation(db, oParams(v));
    const n = db.writes.length;
    const again = await O.applyOperation(db, oParams(v));
    assert.equal(again.idempotentReplay, true);
    assert.equal(db.writes.length, n);
});

test("applyOperation: an inventory delta op with no movements derives a \"sale\" row for completeOrder", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const v = O.validateOperationRequest(opBody([deltaOp("p1", -3, undefined)]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    const rows = rowsOf(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].data.kind, "sale");
    assert.equal(rows[0].data.qty, -3);
    assert.equal(rows[0].data.derived, true);
    assert.equal(rows[0].data.opType, "completeOrder");
});

test("applyOperation: a derived default that contradicts the direction falls back to adjustment", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const v = O.validateOperationRequest(opBody([{ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: 4 } }]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.equal(rowsOf(db)[0].data.kind, "adjustment");
});

test("applyOperation: non-inventory delta ops and mutation ops write no movement rows", async () => {
    const db = makeDb({ [T + "stock_batches/b1"]: { qtyRemaining: 5 }, [T + "orders/o1"]: { status: "pending" } });
    const v = O.validateOperationRequest(opBody([
        { kind: "delta", entity: "stock_batch", entityId: "b1", deltas: { qtyRemaining: -1 } },
        { kind: "mutation", entity: "order", entityId: "o1", action: "update", before: { status: "pending" }, after: { status: "done" } }]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.equal(rowsOf(db).length, 0);
});

test("applyOperation: the largest accepted operations stay within the Firestore write ceiling", async () => {
    // 166 inventory ops (each derives a row): 166 docs + 166 audits + 166 rows + 1 marker = 499.
    let docs = {}; let ops = [];
    for (let i = 0; i < 166; i++) { docs[T + "inventory/p" + i] = { stock: 5 }; ops.push(deltaOp("p" + i, -1, undefined)); }
    let db = makeDb(docs);
    assert.equal((await O.applyOperation(db, oParams(O.validateOperationRequest(opBody(ops))))).ok, true);
    assert.equal(db.writes.length, 499);
    // 200 stock_batch ops: 401 writes, no rows.
    docs = {}; ops = [];
    for (let i = 0; i < 200; i++) { docs[T + "stock_batches/b" + i] = { qtyRemaining: 5 }; ops.push({ kind: "delta", entity: "stock_batch", entityId: "b" + i, deltas: { qtyRemaining: -1 } }); }
    db = makeDb(docs);
    assert.equal((await O.applyOperation(db, oParams(O.validateOperationRequest(opBody(ops))))).ok, true);
    assert.equal(db.writes.length, 401);
});

test("applyOperation: movement on a later op carries THAT op's index in id and row", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 }, [T + "inventory/p2"]: { stock: 5 } });
    const v = O.validateOperationRequest(opBody([deltaOp("p1", -1, undefined), deltaOp("p2", -2, [{ kind: "loss", qty: -2 }])]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    const row = db.store[T + "stock_movements/completeOrder:o1:1~1~m0"];
    assert.ok(row);
    assert.equal(row.opIndex, 1);
    assert.equal(row.productId, "p2");
});
