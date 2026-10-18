"use strict";

// P1 slice S1b: whole-record inventory mutations (recordMutation, recordMutationsBatch,
// recordOperation mutation ops) leave a server-derived ledger row, so no stock change
// can bypass the ledger. Runs against the STRICT fake (undefined fields, odd paths and
// read-after-write all throw), with the pessimistic serverTimestamp write count.

const test = require("node:test");
const assert = require("node:assert/strict");
const G = require("../lib/gatewayLogic");
const B = require("../lib/batchMutationLogic");
const O = require("../lib/operationLogic");
const M = require("../lib/movementLogic");
const { TS, strictDb, pessimisticWrites, rowsOf } = require("./testSupport/strictDb");

const T = "tenants/t1/";

// ── movementLogic: stockOf / deriveForMutation ──────────────────────────────
test("stockOf: a finite number, or 0 for anything else", () => {
    assert.equal(M.stockOf({ stock: 7 }), 7);
    assert.equal(M.stockOf({ stock: -2 }), -2);
    assert.equal(M.stockOf({ stock: 0 }), 0);
    for (const bad of [null, undefined, {}, { stock: "5" }, { stock: NaN }, { stock: Infinity }, { stock: -Infinity }, { stock: null }, 5, "x", []])
        assert.equal(M.stockOf(bad), 0);
});

test("deriveForMutation: create with stock is a receipt; create with 0 or no stock derives nothing", () => {
    assert.deepEqual(M.deriveForMutation("create", null, { stock: 5 }), [{ kind: "receipt", qty: 5, reason: "", valueAtCost: 0, derived: true }]);
    assert.deepEqual(M.deriveForMutation("create", null, { stock: 0 }), []);
    assert.deepEqual(M.deriveForMutation("create", null, { name: "x" }), []);
    assert.deepEqual(M.deriveForMutation("create", null, null), []);
});

test("deriveForMutation: a create with negative stock falls back to adjustment (receipt cannot go down)", () => {
    const r = M.deriveForMutation("create", null, { stock: -4 });
    assert.equal(r.length, 1);
    assert.equal(r[0].kind, "adjustment");
    assert.equal(r[0].qty, -4);
});

test("deriveForMutation: update is an adjustment by the difference; unchanged stock derives nothing", () => {
    assert.deepEqual(M.deriveForMutation("update", { stock: 5 }, { stock: 8 })[0], { kind: "adjustment", qty: 3, reason: "", valueAtCost: 0, derived: true });
    assert.equal(M.deriveForMutation("update", { stock: 5 }, { stock: 2 })[0].qty, -3);
    assert.deepEqual(M.deriveForMutation("update", { stock: 5, name: "a" }, { stock: 5, name: "b" }), []);
});

test("deriveForMutation: float noise derives nothing", () => {
    assert.deepEqual(M.deriveForMutation("update", { stock: 0.1 + 0.2 }, { stock: 0.3 }), []);
});

test("deriveForMutation: delete takes the whole stock out, even if `after` still carries stock", () => {
    assert.deepEqual(M.deriveForMutation("delete", { stock: 4 }, null)[0], { kind: "adjustment", qty: -4, reason: "", valueAtCost: 0, derived: true });
    assert.deepEqual(M.deriveForMutation("delete", { stock: 0 }, null), []);
    assert.equal(M.deriveForMutation("delete", { stock: 4 }, { stock: 4 })[0].qty, -4);
});

test("deriveForMutation: unknown / opening_balance actions behave as an update (adjustment)", () => {
    assert.equal(M.deriveForMutation("opening_balance", { stock: 1 }, { stock: 6 })[0].kind, "adjustment");
});

test("deriveForMutation: absent or non-numeric stock counts as 0 on either side", () => {
    assert.equal(M.deriveForMutation("update", { stock: "5" }, { stock: 5 })[0].qty, 5);
    assert.equal(M.deriveForMutation("update", { stock: 5 }, { name: "x" })[0].qty, -5);
    assert.equal(M.deriveForMutation("update", null, { stock: 3 })[0].qty, 3);
});

// ── applyMutation (recordMutation) ──────────────────────────────────────────
function mParams(overrides) {
    return Object.assign({ tenantId: "t1", actorUid: "u1", actorRole: "owner", entity: "inventory", entityId: "p1", action: "update",
        requestId: "req-m1", before: { stock: 5, name: "A" }, after: { stock: 8, name: "A" }, clientTimestamp: 9,
        collection: "inventory", serverTimestamp: TS }, overrides || {});
}

test("applyMutation: an inventory update that changes stock writes doc, audit and a derived adjustment row together", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 5, name: "A" } });
    const r = await G.applyMutation(db, mParams());
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"].stock, 8);
    assert.ok(db.store[T + "audit_log/req-m1"]);
    const row = db.store[T + "stock_movements/req-m1~m0"];
    assert.equal(row.kind, "adjustment");
    assert.equal(row.qty, 3);
    assert.equal(row.derived, true);
    assert.equal(row.productId, "p1");
    assert.equal(row.actorUid, "u1");
    assert.equal(row.actorRole, "owner");
    assert.equal(row.requestId, "req-m1");
    assert.equal(row.clientTimestamp, 9);
    assert.equal(row.serverTimestamp, TS);
    assert.equal(db.writes.length, 3);
});

test("applyMutation: create with stock is a receipt row; create with stock 0 writes no row", async () => {
    let db = strictDb({});
    await G.applyMutation(db, mParams({ action: "create", before: null, after: { stock: 12 } }));
    assert.equal(db.store[T + "stock_movements/req-m1~m0"].kind, "receipt");
    assert.equal(db.store[T + "stock_movements/req-m1~m0"].qty, 12);
    db = strictDb({});
    await G.applyMutation(db, mParams({ action: "create", before: null, after: { stock: 0 } }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutation: deleting a product that still has stock writes a -stock adjustment row", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 5, name: "A" } });
    const r = await G.applyMutation(db, mParams({ action: "delete", after: null,
        cleanupPrefix: "test/tenants/t1/products/p1/", cleanupEnvPrefix: "test" }));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"], undefined);
    assert.equal(db.store[T + "stock_movements/req-m1~m0"].qty, -5);
    assert.ok(db.store[T + "pending_cleanup/p1"], "the PH3 marker is still written beside the row");
});

test("applyMutation: deleting a product with 0 stock writes no row", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 0, name: "A" } });
    await G.applyMutation(db, mParams({ action: "delete", before: { stock: 0, name: "A" }, after: null,
        cleanupPrefix: "test/tenants/t1/products/p1/", cleanupEnvPrefix: "test" }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutation: an edit that does not touch stock writes no row", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 5, name: "A" } });
    await G.applyMutation(db, mParams({ after: { stock: 5, name: "B" } }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutation: other entities never derive rows, even if they carry a stock field", async () => {
    const db = strictDb({ [T + "orders/o1"]: { stock: 1 } });
    await G.applyMutation(db, mParams({ entity: "order", collection: "orders", entityId: "o1", before: { stock: 1 }, after: { stock: 9 } }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutation: a stale before (409 conflict) writes nothing, no row", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 6, name: "A" } });
    const r = await G.applyMutation(db, mParams());
    assert.equal(r.status, 409);
    assert.equal(db.writes.length, 0);
});

test("applyMutation: replay of the same requestId writes no second row", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 5, name: "A" } });
    await G.applyMutation(db, mParams());
    const n = db.writes.length;
    assert.equal((await G.applyMutation(db, mParams())).idempotentReplay, true);
    assert.equal(db.writes.length, n);
});

test("applyMutation: a string stock on the way in counts as 0 (the fix to a number is a receipt of the full amount)", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: "5", name: "A" } });
    await G.applyMutation(db, mParams({ before: { stock: "5", name: "A" }, after: { stock: 5, name: "A" } }));
    assert.equal(db.store[T + "stock_movements/req-m1~m0"].qty, 5);
});

// ── recordMutationsBatch ────────────────────────────────────────────────────
// Items as validateBatchMutationRequest normalizes them (clientTimestamp is never undefined there).
const nz = (it) => Object.assign({ clientTimestamp: null }, it);
const bItem = (entityId, over) => Object.assign({ entityId, action: "create", before: null, after: { stock: 1 } }, over || {});
const bBody = (items, over) => Object.assign({ entity: "inventory", requestId: "req-b1", items }, over || {});
function bParams(items, overrides) {
    return Object.assign({ tenantId: "t1", actorUid: "u1", actorRole: "manager", entity: "inventory", collection: "inventory",
        requestId: "req-b1", items: items.map(nz), serverTimestamp: TS }, overrides || {});
}

test("validateBatchMutationRequest: movements are not supported; cap is 150 (150 ok, 151 rejected)", () => {
    assert.equal(B.validateBatchMutationRequest(bBody([bItem("p1")], { movements: [] })).error, "movements-not-supported");
    assert.equal(B.MAX_BATCH_SIZE, 150);
    const items = (n) => Array.from({ length: n }, (_, i) => bItem("p" + i));
    assert.equal(B.validateBatchMutationRequest(bBody(items(150))).ok, true);
    assert.equal(B.validateBatchMutationRequest(bBody(items(151))).error, "batch-too-large");
});

test("applyMutationsBatch: one derived row per stock-changing inventory item, id from the item's audit id", async () => {
    const db = strictDb({ [T + "inventory/p2"]: { stock: 4 } });
    const r = await B.applyMutationsBatch(db, bParams([
        { entityId: "p1", action: "create", before: null, after: { stock: 10 }, clientTimestamp: 1 },
        { entityId: "p2", action: "update", before: { stock: 4 }, after: { stock: 1 }, clientTimestamp: 2 },
        { entityId: "p3", action: "create", before: null, after: { stock: 0 }, clientTimestamp: 3 }]));
    assert.equal(r.ok, true);
    assert.deepEqual(rowsOf(db).map((w) => w.path), [T + "stock_movements/req-b1:p1~m0", T + "stock_movements/req-b1:p2~m0"]);
    assert.equal(db.store[T + "stock_movements/req-b1:p1~m0"].kind, "receipt");
    assert.equal(db.store[T + "stock_movements/req-b1:p2~m0"].qty, -3);
    assert.equal(db.store[T + "stock_movements/req-b1:p2~m0"].productId, "p2");
    assert.equal(db.store[T + "stock_movements/req-b1:p2~m0"].clientTimestamp, 2);
    assert.equal(db.store[T + "stock_movements/req-b1:p2~m0"].requestId, "req-b1");
});

test("applyMutationsBatch: a batch delete of a product with stock derives -stock (validator rejects cascade deletes, so call apply directly)", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 6 } });
    await B.applyMutationsBatch(db, bParams([{ entityId: "p1", action: "delete", before: { stock: 6 }, after: null }]));
    assert.equal(db.store[T + "stock_movements/req-b1:p1~m0"].qty, -6);
});

test("applyMutationsBatch: any conflict rejects the whole batch with zero writes", async () => {
    const db = strictDb({ [T + "inventory/p2"]: { stock: 99 } });
    const r = await B.applyMutationsBatch(db, bParams([
        { entityId: "p1", action: "create", before: null, after: { stock: 10 } },
        { entityId: "p2", action: "update", before: { stock: 4 }, after: { stock: 1 } }]));
    assert.equal(r.status, 409);
    assert.equal(db.writes.length, 0);
});

test("applyMutationsBatch: replay writes no second set of rows; a partly-overlapping batch writes only the new item's row", async () => {
    const db = strictDb({});
    const first = [{ entityId: "p1", action: "create", before: null, after: { stock: 10 } }];
    await B.applyMutationsBatch(db, bParams(first));
    const n = db.writes.length;
    await B.applyMutationsBatch(db, bParams(first));
    assert.equal(db.writes.length, n);
    await B.applyMutationsBatch(db, bParams(first.concat([{ entityId: "p2", action: "create", before: null, after: { stock: 2 } }])));
    assert.equal(rowsOf(db).length, 2);
});

test("applyMutationsBatch: non-inventory batches derive nothing", async () => {
    const db = strictDb({});
    await B.applyMutationsBatch(db, bParams([{ entityId: "o1", action: "create", before: null, after: { stock: 3 } }], { entity: "order", collection: "orders" }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutationsBatch: a full 150-item inventory batch is 450 docs; pessimistic serverTimestamp count 750 pinned as the D-1 exposure", async () => {
    const items = Array.from({ length: 150 }, (_, i) => ({ entityId: "p" + i, action: "create", before: null, after: { stock: 1 } }));
    const db = strictDb({});
    assert.equal((await B.applyMutationsBatch(db, bParams(items))).ok, true);
    assert.equal(db.writes.length, 450);
    // Pessimistic reading (each serverTimestamp = +1): audit + row carry one each => 5 per item.
    // That would be 750 > 500. UNVERIFIED on real Firestore (D-1); this pin records the exposure so
    // the dev deploy check (150-row import) settles it instead of an assumption.
    assert.equal(pessimisticWrites(db.writes), 750);
});

// ── recordOperation mutation ops ────────────────────────────────────────────
const RID = "completeOrder:o1:1";
const opBody = (ops) => ({ requestId: RID, opType: "completeOrder", ops: ops, clientTimestamp: 7 });
const oParams = (v) => ({ tenantId: "t1", actorUid: "u1", actorRole: "staff", requestId: v.requestId, opType: v.opType, ops: v.ops,
    clientTimestamp: v.clientTimestamp, serverTimestamp: TS });
const mutOp = (id, before, after, action) => ({ kind: "mutation", entity: "inventory", entityId: id, action: action || "update", before, after });

test("applyOperation: an inventory mutation op that changes stock derives an adjustment row with the op context", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 5 } });
    const v = O.validateOperationRequest(opBody([mutOp("p1", { stock: 5 }, { stock: 2 })]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    const row = db.store[T + "stock_movements/completeOrder:o1:1~0~m0"];
    assert.equal(row.kind, "adjustment");
    assert.equal(row.qty, -3);
    assert.equal(row.derived, true);
    assert.equal(row.operationId, RID);
    assert.equal(row.opType, "completeOrder");
    assert.equal(row.opIndex, 0);
});

test("applyOperation: an inventory mutation op that does not change stock derives nothing", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 5, name: "a" } });
    const v = O.validateOperationRequest(opBody([mutOp("p1", { stock: 5, name: "a" }, { stock: 5, name: "b" })]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.equal(rowsOf(db).length, 0);
});

test("applyOperation: an inventory delete mutation op takes the stock out as a derived row", async () => {
    const db = strictDb({ [T + "inventory/p9"]: { stock: 3 } });
    // validate refuses a cascade delete of a product (PH3), so build the validated body for a non-cascade
    // case by hand: apply directly with the same shape validateOperationRequest produces.
    const ops = [{ kind: "mutation", entity: "inventory", collection: "inventory", entityId: "p9", action: "delete",
        before: { stock: 3 }, after: null, requestId: RID + "~0", clientTimestamp: null }];
    const r = await O.applyOperation(db, { tenantId: "t1", actorUid: "u1", actorRole: "owner", requestId: RID, opType: "completeOrder",
        ops: ops, clientTimestamp: 7, serverTimestamp: TS });
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "stock_movements/completeOrder:o1:1~0~m0"].qty, -3);
});

test("applyOperation: a non-inventory mutation op derives nothing", async () => {
    const db = strictDb({ [T + "orders/o1"]: { stock: 1 } });
    const v = O.validateOperationRequest(opBody([{ kind: "mutation", entity: "order", entityId: "o1", action: "update", before: { stock: 1 }, after: { stock: 9 } }]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.equal(rowsOf(db).length, 0);
});

test("applyOperation: a stale before on an inventory mutation op rejects the whole operation, no rows", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 9 } });
    const v = O.validateOperationRequest(opBody([mutOp("p1", { stock: 5 }, { stock: 2 })]));
    const r = await O.applyOperation(db, oParams(v));
    assert.equal(r.status, 409);
    assert.equal(db.writes.length, 0);
});

test("applyOperation: two mutation ops on the same product each derive their own step (running state, not the stored doc)", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 5 } });
    const v = O.validateOperationRequest(opBody([mutOp("p1", { stock: 5 }, { stock: 4 }), mutOp("p1", { stock: 4 }, { stock: 1 })]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.equal(db.store[T + "stock_movements/completeOrder:o1:1~0~m0"].qty, -1);
    assert.equal(db.store[T + "stock_movements/completeOrder:o1:1~1~m0"].qty, -3);
});

test("applyOperation: 166 inventory mutation ops stay at 499 writes (3 per op + 1 marker)", async () => {
    const docs = {}; const ops = [];
    for (let i = 0; i < 166; i++) { docs[T + "inventory/p" + i] = { stock: 5 }; ops.push(mutOp("p" + i, { stock: 5 }, { stock: 4 })); }
    const db = strictDb(docs);
    const v = O.validateOperationRequest(opBody(ops));
    assert.equal(v.ok, true);
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.equal(db.writes.length, 3 * 166 + 1, "doc + audit + row per op, plus the operation marker");
});

test("validateOperationRequest: 167 inventory ops are refused by the write budget (the conservative 1-row-per-op rule)", () => {
    const ops = []; for (let i = 0; i < 167; i++) ops.push(mutOp("p" + i, { stock: 5 }, { stock: 4 }));
    assert.equal(O.validateOperationRequest(opBody(ops)).error, "operation-too-large");
});
