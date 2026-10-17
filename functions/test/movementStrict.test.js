"use strict";

// PR #146 review sweep. The S1a wiring tests use an in-memory fake that accepts
// anything. REAL Firestore does not: it throws on an `undefined` field value, on
// a document path with an even/odd segment mismatch, and on a read after a write
// inside a transaction. These tests run the S1a write paths against a STRICT fake
// that enforces those three rules, so a ledger row that works in the fake but
// fails in production is caught here. Also pins the realistic write count under
// the pessimistic assumption that each serverTimestamp() counts as an extra write
// (spec D8 / operationLogic MAX_OPS comment: still unverified on real Firestore).

const test = require("node:test");
const assert = require("node:assert/strict");
const G = require("../lib/gatewayLogic");
const O = require("../lib/operationLogic");

const T = "tenants/t1/";
const TS = { __transform: "serverTimestamp" };

function findUndefined(value, path) {
    if (value === undefined) return path;
    if (value === null || typeof value !== "object" || value === TS) return null;
    for (const k of Object.keys(value)) {
        const hit = findUndefined(value[k], path + "." + k);
        if (hit) return hit;
    }
    return null;
}

function strictDb(docs) {
    const store = Object.assign({}, docs || {});
    const writes = [];
    return {
        store, writes,
        doc(path) {
            // tenants/{t}/{collection}/{id} = exactly 4 segments, none empty.
            const seg = path.split("/");
            if (seg.length % 2 !== 0 || seg.some((s) => s === "")) throw new Error("bad document path: " + path);
            return { path };
        },
        async runTransaction(fn) {
            let wrote = false;
            return fn({
                async get(ref) {
                    if (wrote) throw new Error("read after write: " + ref.path);
                    const has = Object.prototype.hasOwnProperty.call(store, ref.path);
                    return { exists: has, data: () => (has ? store[ref.path] : undefined) };
                },
                set(ref, data) {
                    const bad = findUndefined(data, "");
                    if (bad) throw new Error("undefined field value at " + ref.path + bad);
                    wrote = true;
                    writes.push({ path: ref.path, data });
                    store[ref.path] = data;
                },
                delete(ref) { wrote = true; writes.push({ path: ref.path, deleted: true }); delete store[ref.path]; }
            });
        }
    };
}

// Pessimistic count: every doc is one write, plus one more per serverTimestamp sentinel.
function pessimisticWrites(writes) {
    let n = 0;
    for (const w of writes) {
        n += 1;
        if (w.data) for (const k of Object.keys(w.data)) if (w.data[k] === TS) n += 1;
    }
    return n;
}

function dParams(overrides) {
    return Object.assign({ tenantId: "t1", actorUid: "u1", actorRole: "staff", entity: "inventory", entityId: "p1",
        requestId: "req-1", deltas: { stock: -3 }, floors: { stock: 0 }, clamps: {}, movements: [],
        clientTimestamp: null, collection: "inventory", serverTimestamp: TS }, overrides || {});
}

test("strict: recordDelta with a null clientTimestamp writes a row with no undefined field (derived and explicit)", async () => {
    let db = strictDb({ [T + "inventory/p1"]: { stock: 10 } });
    assert.equal((await G.applyDelta(db, dParams())).ok, true);
    assert.equal(db.store[T + "stock_movements/req-1~m0"].clientTimestamp, null);

    db = strictDb({ [T + "inventory/p1"]: { stock: 10 } });
    const explicit = [{ kind: "loss", qty: -3, reason: "", valueAtCost: 0, derived: false }];
    assert.equal((await G.applyDelta(db, dParams({ movements: explicit }))).ok, true);
    assert.equal(db.store[T + "stock_movements/req-1~m0"].derived, false);
});

test("strict: recordDelta rows land at a valid 4-segment path and the row id holds no '/'", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, dParams());
    const rowPaths = db.writes.map((w) => w.path).filter((p) => p.indexOf("/stock_movements/") >= 0);
    assert.equal(rowPaths.length, 1);
    assert.equal(rowPaths[0].split("/").length, 4);
});

test("strict: a rejected recordDelta (mismatch, floor) throws nothing and writes nothing", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 2 } });
    const bad = [{ kind: "loss", qty: -1, reason: "", valueAtCost: 0, derived: false }];
    const r1 = await G.applyDelta(db, dParams({ movements: bad }));
    assert.equal(r1.status, 409);
    const r2 = await G.applyDelta(db, dParams({ requestId: "req-2" }));
    assert.equal(r2.error, "insufficient-quantity");
    assert.equal(db.writes.length, 0);
});

function opParams(requestId, ops) {
    const v = O.validateOperationRequest({ requestId: requestId, opType: "completeOrder", ops: ops, clientTimestamp: null });
    assert.equal(v.ok, true);
    return { tenantId: "t1", actorUid: "u1", actorRole: "staff", requestId: v.requestId, opType: v.opType,
             ops: v.ops, clientTimestamp: v.clientTimestamp, serverTimestamp: TS };
}
const dop = (id, d, mv) => ({ kind: "delta", entity: "inventory", entityId: id, deltas: { stock: d }, floors: { stock: 0 }, movements: mv });

test("strict: recordOperation (derived + explicit rows, null clientTimestamp) has no undefined field and reads before writes", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 10 }, [T + "inventory/p2"]: { stock: 5 } });
    const r = await O.applyOperation(db, opParams("completeOrder:o1:1", [
        dop("p1", -3, [{ kind: "sale", qty: -3 }]), dop("p2", -1, undefined)]));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "stock_movements/completeOrder:o1:1~1~m0"].clientTimestamp, null);
});

test("strict: the SAME product in two ops of one operation chains: rows sum to the whole stock change", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 10 } });
    const r = await O.applyOperation(db, opParams("completeOrder:o2:1", [dop("p1", -3, undefined), dop("p1", -2, undefined)]));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"].stock, 5);
    const a = db.store[T + "stock_movements/completeOrder:o2:1~0~m0"];
    const b = db.store[T + "stock_movements/completeOrder:o2:1~1~m0"];
    assert.equal(a.qty + b.qty, -5);
    assert.equal(a.kind, "sale");
    assert.equal(b.kind, "sale");
});

test("strict: second op on the same product still sees the floor after the first (no oversell, nothing written)", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 4 } });
    const r = await O.applyOperation(db, opParams("completeOrder:o3:1", [dop("p1", -3, undefined), dop("p1", -3, undefined)]));
    assert.equal(r.error, "insufficient-quantity");
    assert.equal(r.opIndex, 1);
    assert.equal(db.writes.length, 0);
});

test("pessimistic count: a realistic 30-line completeOrder stays far below 500 even if each serverTimestamp counts as a write", async () => {
    const docs = {}; const ops = [];
    for (let i = 0; i < 30; i++) { docs[T + "inventory/p" + i] = { stock: 5 }; ops.push(dop("p" + i, -1, undefined)); }
    const db = strictDb(docs);
    assert.equal((await O.applyOperation(db, opParams("completeOrder:big:1", ops))).ok, true);
    assert.equal(db.writes.length, 30 + 30 + 30 + 1);
    assert.ok(pessimisticWrites(db.writes) <= 500, "pessimistic writes = " + pessimisticWrites(db.writes));
});

test("pessimistic count: the PINNED maximum (166 inventory ops) WOULD exceed 500 if transforms count -- documents the open assumption", async () => {
    const docs = {}; const ops = [];
    for (let i = 0; i < 166; i++) { docs[T + "inventory/p" + i] = { stock: 5 }; ops.push(dop("p" + i, -1, undefined)); }
    const db = strictDb(docs);
    assert.equal((await O.applyOperation(db, opParams("completeOrder:max:1", ops))).ok, true);
    assert.equal(db.writes.length, 499);
    // If this ever fails because the budget formula changed, re-read operationLogic's MAX_OPS comment:
    // the 500 ceiling and "does serverTimestamp() cost an extra write" are still UNVERIFIED on real Firestore.
    assert.ok(pessimisticWrites(db.writes) > 500);
});
