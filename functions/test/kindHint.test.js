"use strict";

// P1 S2d-2: the KIND HINT on recordDelta (design docs/superpowers/specs/2026-11-18-p1-s2d2-derived-kind-hint-design.md).
// A clamped deduction (completeImportedOrder) cannot carry explicit movements: the applied quantity is only known on the
// server, so an explicit row next to a clamp that bites is a 409 and the deduction would be lost. The client may instead
// name the KIND of the server-derived row. These tests run the REAL validators, the REAL applyDelta over the strict fake
// (undefined fields, odd paths and read-after-write throw) and the REAL handler wiring.
//   KH-1..2  the hint list and its validator     KH-3..6  recordDelta request validation
//   KH-7..14 applyDelta rows                     KH-15..17 other endpoints refuse a hint (no silent no-op)
//   KH-18..19 handler pass-through               KH-20 monkey, 4000 random calls against the strict fake
//   KH-21..22 review sweep 1 of PR #205 (negative stock under a clamp; `kindHint: null`)

const test = require("node:test");
const assert = require("node:assert/strict");
const G = require("../lib/gatewayLogic");
const B = require("../lib/batchMutationLogic");
const O = require("../lib/operationLogic");
const M = require("../lib/movementLogic");
const { TS, strictDb, rowsOf } = require("./testSupport/strictDb");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");

const T = "tenants/t1/";

function deltaBody(overrides) {
    return Object.assign({ entity: "inventory", entityId: "p1", requestId: "req-1", deltas: { stock: -3 }, clamps: { stock: 0 }, kindHint: "sale" },
        overrides || {});
}
function dParams(overrides) {
    const v = G.validateDeltaRequest(deltaBody());
    assert.equal(v.ok, true);
    return Object.assign({ tenantId: "t1", actorUid: "u1", actorRole: "manager", entity: v.entity, entityId: v.entityId, requestId: v.requestId,
        deltas: v.deltas, floors: {}, clamps: v.clamps, movements: v.movements, kindHint: v.kindHint, clientTimestamp: 5,
        collection: v.collection, serverTimestamp: TS }, overrides || {});
}
const rowList = (db) => rowsOf(db).map((w) => w.data);

// ── the list ────────────────────────────────────────────────────────────────
test("KH-1 HINT_KINDS is the kinds that need neither a reason nor a stamped value: receipt, sales_return, sale, adjustment", () => {
    assert.deepEqual(M.HINT_KINDS, ["receipt", "sales_return", "sale", "adjustment"]);
    for (const k of M.MOVEMENT_KINDS) {
        const barred = M.REASON_REQUIRED.indexOf(k) >= 0 || M.VALUE_KINDS.indexOf(k) >= 0;
        assert.equal(M.HINT_KINDS.indexOf(k) >= 0, !barred, k + (barred ? " must not be hintable (policy bypass)" : " must be hintable"));
    }
});

test("KH-2 validateKindHint: none is fine; a listed name is kept; everything else is invalid-kind-hint (400)", () => {
    assert.deepEqual(M.validateKindHint(undefined), { ok: true, kindHint: undefined });
    assert.deepEqual(M.validateKindHint(null), { ok: true, kindHint: undefined });
    for (const k of M.HINT_KINDS) assert.deepEqual(M.validateKindHint(k), { ok: true, kindHint: k });
    for (const bad of ["loss", "theft", "destroyed", "write_off", "gift", "free_sample", "", " sale", "SALE", "sale ", "toString", "__proto__",
        "constructor", "hasOwnProperty", 5, 0, true, false, {}, [], ["sale"], { kind: "sale" }, () => "sale"]) {
        assert.deepEqual(M.validateKindHint(bad), { ok: false, status: 400, error: "invalid-kind-hint" }, String(bad));
    }
});

// ── recordDelta request ─────────────────────────────────────────────────────
test("KH-3 validateDeltaRequest keeps a valid hint; no hint and null give undefined (old clients unchanged)", () => {
    assert.equal(G.validateDeltaRequest(deltaBody()).kindHint, "sale");
    assert.equal(G.validateDeltaRequest(deltaBody({ kindHint: undefined })).kindHint, undefined);
    assert.equal(G.validateDeltaRequest(deltaBody({ kindHint: null })).kindHint, undefined);
    const noField = deltaBody(); delete noField.kindHint;
    const v = G.validateDeltaRequest(noField);
    assert.equal(v.ok, true);
    assert.equal(v.kindHint, undefined);
    assert.deepEqual(v.movements, []);
});

test("KH-4 every value outside the list is a 400 invalid-kind-hint, nothing else", () => {
    for (const bad of ["loss", "gift", "free_sample", "", "Sale", "bogus", "__proto__", 7, true, {}, []]) {
        const v = G.validateDeltaRequest(deltaBody({ kindHint: bad }));
        assert.equal(v.ok, false, String(bad));
        assert.equal(v.status, 400);
        assert.equal(v.error, "invalid-kind-hint", String(bad));
    }
});

test("KH-5 a hint never travels with explicit movements; a bad movement is still reported first", () => {
    let v = G.validateDeltaRequest(deltaBody({ clamps: {}, movements: [{ kind: "sale", qty: -3 }] }));
    assert.deepEqual([v.ok, v.status, v.error], [false, 400, "kind-hint-with-movements"]);
    v = G.validateDeltaRequest(deltaBody({ clamps: {}, movements: [{ kind: "nope", qty: -3 }], kindHint: "sale" }));
    assert.equal(v.error, "invalid-movement-kind", "the movement problem wins");
    v = G.validateDeltaRequest(deltaBody({ clamps: {}, movements: [{ kind: "sale", qty: -3 }], kindHint: "loss" }));
    assert.equal(v.error, "invalid-kind-hint", "a bad name is reported before the combination");
    v = G.validateDeltaRequest(deltaBody({ clamps: {}, movements: [{ kind: "sale", qty: -3 }], kindHint: undefined }));
    assert.equal(v.ok, true, "explicit movements alone are untouched");
});

test("KH-6 a hint needs the inventory entity and a stock delta", () => {
    let v = G.validateDeltaRequest(deltaBody({ entity: "stock_batch", deltas: { qtyRemaining: -3 }, clamps: {} }));
    assert.equal(v.error, "invalid-kind-hint");
    v = G.validateDeltaRequest(deltaBody({ deltas: { minStock: 1 }, clamps: {} }));
    assert.equal(v.error, "invalid-kind-hint");
    v = G.validateDeltaRequest(deltaBody({ entity: "order", entityId: "o1", deltas: { stock: -1 }, clamps: {} }));
    assert.equal(v.error, "invalid-kind-hint");
    assert.equal(G.validateDeltaRequest(deltaBody({ deltas: { stock: -3, minStock: 1 } })).ok, true, "stock next to another field is fine");
});

// ── applyDelta ──────────────────────────────────────────────────────────────
test("KH-7 THE FIX: a clamped deduction with hint sale writes ONE derived `sale` row of the APPLIED quantity", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 1, name: "A", price: 40 } });
    const r = await G.applyDelta(db, dParams());            // asks -3, only 1 is there: applies -1
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"].stock, 0);
    const rows = rowList(db);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].kind, "sale");
    assert.equal(rows[0].qty, -1, "what moved, not what was asked");
    assert.equal(rows[0].derived, true, "still server-derived: no reason, no value");
    assert.equal(rows[0].reason, "");
    assert.equal(rows[0].valueAtCost, 0, "sale is not a stamped kind, whatever the product costs");
    assert.deepEqual(db.store[T + "audit_log/req-1"].after, { stock: 0 }, "the clamp stays visible in audit_log");
    assert.deepEqual(db.store[T + "audit_log/req-1"].before, { stock: 1 });
});

test("KH-8 without a clamp the whole quantity is the sale row; without a hint it stays the old `adjustment` (default unchanged)", async () => {
    let db = strictDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, dParams({ clamps: {} }));
    assert.deepEqual([rowList(db)[0].kind, rowList(db)[0].qty], ["sale", -3]);
    db = strictDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, dParams({ kindHint: undefined }));
    assert.deepEqual([rowList(db)[0].kind, rowList(db)[0].derived], ["adjustment", true]);
});

test("KH-9 a hint that contradicts the direction of what was applied degrades to `adjustment`, the stock change is never refused", async () => {
    let db = strictDb({ [T + "inventory/p1"]: { stock: 4 } });
    let r = await G.applyDelta(db, dParams({ deltas: { stock: 5 }, clamps: {}, kindHint: "sale" }));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"].stock, 9);
    assert.deepEqual([rowList(db)[0].kind, rowList(db)[0].qty], ["adjustment", 5]);
    db = strictDb({ [T + "inventory/p1"]: { stock: 4 } });
    r = await G.applyDelta(db, dParams({ deltas: { stock: -2 }, clamps: {}, kindHint: "receipt" }));
    assert.equal(r.ok, true);
    assert.deepEqual([rowList(db)[0].kind, rowList(db)[0].qty], ["adjustment", -2]);
});

test("KH-10 the other listed hints: receipt and sales_return on an increase, adjustment either way", async () => {
    for (const [hint, delta, kind] of [["receipt", 2, "receipt"], ["sales_return", 2, "sales_return"], ["adjustment", 2, "adjustment"],
        ["adjustment", -2, "adjustment"], ["sale", -2, "sale"]]) {
        const db = strictDb({ [T + "inventory/p1"]: { stock: 4 } });
        await G.applyDelta(db, dParams({ deltas: { stock: delta }, clamps: {}, kindHint: hint }));
        assert.equal(rowList(db)[0].kind, kind, hint + " " + delta);
    }
});

test("KH-11 a clamp that applies nothing (stock already 0) writes no row, but the audit entry exists", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 0 } });
    const r = await G.applyDelta(db, dParams());
    assert.equal(r.ok, true);
    assert.equal(rowList(db).length, 0);
    assert.ok(db.store[T + "audit_log/req-1"]);
});

test("KH-12 explicit movements still win over a stray hint passed to applyDelta (the validator forbids the pair; this is the backstop)", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, dParams({ clamps: {}, movements: [{ kind: "loss", qty: -3, reason: "spoiled", valueAtCost: 0, derived: false }] }));
    assert.deepEqual([rowList(db)[0].kind, rowList(db)[0].derived], ["loss", false]);
});

test("KH-13 a replay of the same requestId writes no second row and no second stock change", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, dParams({ clamps: {} }));
    const n = db.writes.length;
    const again = await G.applyDelta(db, dParams({ clamps: {} }));
    assert.equal(again.idempotentReplay, true);
    assert.equal(db.writes.length, n);
    assert.equal(db.store[T + "inventory/p1"].stock, 7);
});

test("KH-14 the full pipeline, imported-order case: validate -> apply, shortfall of 3 on a stock of 2 leaves one sale row of -2", async () => {
    const db = strictDb({ [T + "inventory/p1"]: { stock: 2, name: "Shirt", price: 100 } });
    const v = G.validateDeltaRequest({ entity: "inventory", entityId: "p1", requestId: "imp-1", deltas: { stock: -5 }, floors: {}, clamps: { stock: 0 }, kindHint: "sale" });
    assert.equal(v.ok, true);
    const r = await G.applyDelta(db, { tenantId: "t1", actorUid: "u1", actorRole: "owner", entity: v.entity, entityId: v.entityId, requestId: v.requestId,
        deltas: v.deltas, floors: v.floors, clamps: v.clamps, movements: v.movements, kindHint: v.kindHint, clientTimestamp: 1, collection: v.collection, serverTimestamp: TS });
    assert.deepEqual(r, { ok: true, after: { stock: 0 } });
    const rows = rowList(db);
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].kind, rows[0].qty, rows[0].productName], ["sale", -2, "Shirt"]);
});

// ── other endpoints refuse a hint ───────────────────────────────────────────
test("KH-15 recordMutation refuses a hint (400 kind-hint-not-supported), null included: it would be a silent no-op", () => {
    const base = { entity: "inventory", entityId: "p1", action: "update", requestId: "r1", before: { stock: 1 }, after: { stock: 2 } };
    assert.equal(G.validateMutationRequest(base).ok, true);
    for (const hint of ["sale", "loss", null, 5, ""]) {
        const v = G.validateMutationRequest(Object.assign({}, base, { kindHint: hint }));
        assert.deepEqual([v.ok, v.status, v.error], [false, 400, "kind-hint-not-supported"], String(hint));
    }
});

test("KH-16 recordMutationsBatch refuses a hint on the request", () => {
    const base = { entity: "inventory", requestId: "batch-1", items: [{ entityId: "p1", action: "update", before: { stock: 1 }, after: { stock: 2 } }] };
    assert.equal(B.validateBatchMutationRequest(base).ok, true);
    const v = B.validateBatchMutationRequest(Object.assign({}, base, { kindHint: "sale" }));
    assert.deepEqual([v.ok, v.status, v.error], [false, 400, "kind-hint-not-supported"]);
});

test("KH-17 recordOperation refuses a hint on a delta op and on a mutation op, with the op index; the operation's own typing is untouched", () => {
    const op = (extra) => Object.assign({ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } }, extra || {});
    const req = (ops) => ({ requestId: "completeOrder:o1:1", opType: "completeOrder", clientTimestamp: "c", ops });
    assert.equal(O.validateOperationRequest(req([op()])).ok, true);
    let v = O.validateOperationRequest(req([op(), op({ entityId: "p2", kindHint: "sale" })]));
    assert.deepEqual([v.ok, v.status, v.error, v.opIndex], [false, 400, "kind-hint-not-supported", 1]);
    v = O.validateOperationRequest(req([op({ kindHint: "bogus" })]));
    assert.deepEqual([v.error, v.opIndex], ["invalid-kind-hint", 0], "a bad name is still reported as a bad name");
    v = O.validateOperationRequest(req([{ kind: "mutation", entity: "inventory", entityId: "p1", action: "update", before: { stock: 1 }, after: { stock: 2 }, kindHint: "sale" }]));
    assert.deepEqual([v.ok, v.error, v.opIndex], [false, "kind-hint-not-supported", 0]);
});

// ── handler ─────────────────────────────────────────────────────────────────
const { handlers, mockState } = installMocks();
const bodyFor = (overrides) => Object.assign({ env: "test", clientTimestamp: 12345 }, deltaBody(), overrides || {});

test("KH-18 recordDelta forwards the validated hint to applyDelta; an old client's request carries none", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyDeltaResult = { ok: true, after: { stock: 0 } };
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: bodyFor() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(mockState.lastApplyDeltaParams.kindHint, "sale");
    assert.deepEqual(mockState.lastApplyDeltaParams.clamps, { stock: 0 });
    const old = bodyFor(); delete old.kindHint;
    await handlers.recordDelta(mockReq({ body: old }), mockRes());
    assert.equal(mockState.lastApplyDeltaParams.kindHint, undefined);
});

test("KH-19 recordDelta: a bad hint or a hint next to movements is a 400 and applyDelta is never called", async () => {
    for (const [overrides, error] of [[{ kindHint: "loss" }, "invalid-kind-hint"], [{ kindHint: 5 }, "invalid-kind-hint"],
        [{ clamps: {}, movements: [{ kind: "sale", qty: -3 }] }, "kind-hint-with-movements"], [{ entity: "stock_batch", deltas: { qtyRemaining: -1 }, clamps: {} }, "invalid-kind-hint"]]) {
        seedHappyPathAuth(mockState);
        mockState.lastApplyDeltaParams = null;
        const res = mockRes();
        await handlers.recordDelta(mockReq({ body: bodyFor(overrides) }), res);
        assert.equal(res.statusCode, 400, error);
        assert.equal(jsonBody(res).error, error);
        assert.equal(mockState.lastApplyDeltaParams, null, "nothing written");
    }
});

// ── monkey ──────────────────────────────────────────────────────────────────
function rng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }

test("KH-20 monkey: 4000 random clamped / floored / hinted deltas keep the ledger equal to the applied change", async () => {
    const rnd = rng(20261118);
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    const hints = [undefined, undefined, "sale", "receipt", "sales_return", "adjustment"];
    for (let n = 0; n < 4000; n++) {
        const stock = pick([0, 0, 1, 2, 5, 10, 2.5, 0.5, 100]);
        const delta = pick([-1, -2, -3, -10, -2.5, -0.25, 1, 3, 7.5]);
        const hint = pick(hints);
        const clamp = rnd() < 0.5;
        const db = strictDb({ [T + "inventory/p1"]: { stock, name: "A", price: 10 } });
        const body = { entity: "inventory", entityId: "p1", requestId: "m-" + n, deltas: { stock: delta }, floors: clamp ? {} : { stock: 0 }, clamps: clamp ? { stock: 0 } : {} };
        if (hint !== undefined) body.kindHint = hint;
        const v = G.validateDeltaRequest(body);
        assert.equal(v.ok, true, JSON.stringify(body));
        const r = await G.applyDelta(db, { tenantId: "t1", actorUid: "u", actorRole: "owner", entity: v.entity, entityId: v.entityId, requestId: v.requestId,
            deltas: v.deltas, floors: v.floors, clamps: v.clamps, movements: v.movements, kindHint: v.kindHint, clientTimestamp: 1, collection: v.collection, serverTimestamp: TS });
        const rows = rowList(db);
        if (r.ok === false) {                                  // a floor refusal: nothing written at all
            assert.equal(r.status, 409);
            assert.equal(db.writes.length, 0);
            continue;
        }
        const applied = r.after.stock - stock;
        assert.ok(r.after.stock >= 0 || !clamp, "a clamp never goes below 0");
        const sum = rows.reduce((a, x) => a + x.qty, 0);
        assert.ok(Math.abs(sum - applied) < 1e-9, "rows sum to what moved");
        if (Math.abs(applied) < 1e-9) { assert.equal(rows.length, 0); continue; }
        assert.equal(rows.length, 1);
        assert.equal(rows[0].derived, true);
        assert.equal(rows[0].reason, "");
        assert.equal(rows[0].valueAtCost, 0);
        const wanted = hint || "adjustment";
        const fits = M.KIND_DIRECTION[wanted] === 0 || Math.sign(applied) === M.KIND_DIRECTION[wanted];
        assert.equal(rows[0].kind, fits ? wanted : "adjustment");
    }
});

// ── review sweep 1 of PR #205 ───────────────────────────────────────────────
test("KH-21 sweep: a clamp on a NEGATIVE stock RAISES it to 0; a `sale` hint must not label that increase (row is `adjustment` +2)", async () => {
    // Legacy or hand-edited data can hold stock below 0. A clamped deduction of 3 from -2 lands on 0: the applied change is +2.
    const db = strictDb({ [T + "inventory/p1"]: { stock: -2, name: "A", price: 40 } });
    const r = await G.applyDelta(db, dParams());             // deltas -3, clamps stock>=0, kindHint sale
    assert.equal(r.ok, true, "the deduction is never refused");
    assert.equal(db.store[T + "inventory/p1"].stock, 0);
    const rows = rowList(db);
    assert.equal(rows.length, 1);
    assert.deepEqual([rows[0].kind, rows[0].qty, rows[0].derived, rows[0].valueAtCost], ["adjustment", 2, true, 0],
        "a `sale` of +2 would put a negative supply in the statutory register");
    assert.deepEqual(db.store[T + "audit_log/req-1"].before, { stock: -2 });
});

test("KH-22 sweep: `kindHint: null` means NO hint on a delta call and on a delta op (accepted); the mutation endpoints refuse it (KH-15)", () => {
    const v = G.validateDeltaRequest(deltaBody({ kindHint: null }));
    assert.equal(v.ok, true);
    assert.equal(v.kindHint, undefined);
    const op = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 }, kindHint: null };
    const o = O.validateOperationRequest({ requestId: "completeOrder:o1:1", opType: "completeOrder", clientTimestamp: "c", ops: [op] });
    assert.equal(o.ok, true, "a null hint is not a hint: the op must not be lost over it");
});
