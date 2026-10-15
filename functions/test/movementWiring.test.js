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
