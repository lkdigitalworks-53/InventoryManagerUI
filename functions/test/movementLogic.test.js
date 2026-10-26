"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const M = require("../lib/movementLogic");

function mv(overrides) {
    return Object.assign({ kind: "loss", qty: -2, reason: "water damage", valueAtCost: 40 }, overrides || {});
}
function fail(raw, error) {
    const r = M.validateMovements(raw);
    assert.equal(r.ok, false);
    assert.equal(r.status, 400);
    assert.equal(r.error, error);
}

// ── validateMovements: happy path ───────────────────────────────────────────
test("validateMovements: absent movements is ok and empty", () => {
    assert.deepEqual(M.validateMovements(undefined), { ok: true, movements: [] });
    assert.deepEqual(M.validateMovements(null), { ok: true, movements: [] });
});

test("validateMovements: normalizes a full movement", () => {
    const r = M.validateMovements([mv({ reason: "  water damage  " })]);
    assert.deepEqual(r, { ok: true, movements: [{ kind: "loss", qty: -2, reason: "water damage", valueAtCost: 40, derived: false }] });
});

test("validateMovements: defaults reason '' and valueAtCost 0", () => {
    const r = M.validateMovements([{ kind: "receipt", qty: 5 }]);
    assert.deepEqual(r.movements[0], { kind: "receipt", qty: 5, reason: "", valueAtCost: 0, derived: false });
});

test("validateMovements: every kind accepts its own direction", () => {
    for (const kind of M.MOVEMENT_KINDS) {
        const dir = M.KIND_DIRECTION[kind] || 1;
        assert.equal(M.validateMovements([{ kind: kind, qty: 3 * dir }]).ok, true, kind);
    }
});

test("validateMovements: adjustment accepts both signs; fractional qty ok", () => {
    assert.equal(M.validateMovements([{ kind: "adjustment", qty: 2 }]).ok, true);
    assert.equal(M.validateMovements([{ kind: "adjustment", qty: -0.5 }]).ok, true);
});

test("validateMovements: exactly MAX_MOVEMENTS is ok", () => {
    const many = Array.from({ length: M.MAX_MOVEMENTS }, () => mv());
    assert.equal(M.validateMovements(many).ok, true);
});

// ── validateMovements: negative ─────────────────────────────────────────────
test("validateMovements: rejects non-array, empty array, non-object entries", () => {
    fail("x", "invalid-movements");
    fail({}, "invalid-movements");
    fail([], "invalid-movements");
    fail([null], "invalid-movements");
    fail([5], "invalid-movements");
});

test("validateMovements: rejects more than MAX_MOVEMENTS", () => {
    fail(Array.from({ length: M.MAX_MOVEMENTS + 1 }, () => mv()), "too-many-movements");
});

test("validateMovements: rejects unknown / missing / non-string kind", () => {
    fail([mv({ kind: "stolen" })], "invalid-movement-kind");
    fail([mv({ kind: undefined })], "invalid-movement-kind");
    fail([mv({ kind: 7 })], "invalid-movement-kind");
    fail([mv({ kind: "__proto__" })], "invalid-movement-kind");
    fail([mv({ kind: "toString" })], "invalid-movement-kind");
});

test("validateMovements: rejects zero, NaN, Infinity, string qty", () => {
    for (const qty of [0, NaN, Infinity, -Infinity, "2", null, undefined]) fail([mv({ qty: qty })], "invalid-movement-qty");
});

test("validateMovements: rejects a qty sign that contradicts the kind", () => {
    fail([mv({ kind: "receipt", qty: -1 })], "invalid-movement-qty");
    fail([mv({ kind: "sales_return", qty: -1 })], "invalid-movement-qty");
    for (const kind of ["sale", "loss", "theft", "destroyed", "write_off", "free_sample", "gift"])
        fail([mv({ kind: kind, qty: 1 })], "invalid-movement-qty");
});

test("validateMovements: rejects bad valueAtCost", () => {
    for (const v of [-1, NaN, Infinity, "5", null]) fail([mv({ valueAtCost: v })], "invalid-movement-value");
});

test("validateMovements: rejects bad reason (non-string, over 500 chars)", () => {
    fail([mv({ reason: 5 })], "invalid-movement-reason");
    fail([mv({ reason: "x".repeat(501) })], "invalid-movement-reason");
    assert.equal(M.validateMovements([mv({ reason: "x".repeat(500) })]).ok, true);
});

test("validateMovements: does not trust client-supplied identity fields", () => {
    const r = M.validateMovements([mv({ id: "forged", productId: "other", actorUid: "boss", serverTimestamp: 1, derived: true, batchRef: "x" })]);
    assert.deepEqual(Object.keys(r.movements[0]).sort(), ["derived", "kind", "qty", "reason", "valueAtCost"]);
    assert.equal(r.movements[0].derived, false);
});

// ── totalsMatch ─────────────────────────────────────────────────────────────
test("totalsMatch: sums signed qty against the applied delta", () => {
    assert.equal(M.totalsMatch([{ qty: -2 }, { qty: -3 }], -5), true);
    assert.equal(M.totalsMatch([{ qty: -2 }, { qty: -3 }], -4), false);
    assert.equal(M.totalsMatch([{ qty: 5 }], -5), false);
});

test("totalsMatch: tolerates float noise only", () => {
    assert.equal(M.totalsMatch([{ qty: 0.1 }, { qty: 0.2 }], 0.3), true);
    assert.equal(M.totalsMatch([{ qty: 0.1 }, { qty: 0.2 }], 0.31), false);
});

// ── buildRows ───────────────────────────────────────────────────────────────
const CTX = { baseId: "req-9", productId: "p1", actorUid: "u1", actorRole: "owner",
              serverTimestamp: "TS", clientTimestamp: 123, requestId: "req-9" };

test("buildRows: stamps identity server-side and derives deterministic ids", () => {
    const rows = M.buildRows([{ kind: "loss", qty: -1, reason: "r", valueAtCost: 5, derived: false },
                              { kind: "loss", qty: -2, reason: "", valueAtCost: 0, derived: true }], CTX);
    assert.deepEqual(rows.map((r) => r.id), ["req-9~m0", "req-9~m1"]);
    assert.equal(rows[0].data.id, "req-9~m0");
    assert.equal(rows[0].data.productId, "p1");
    assert.equal(rows[0].data.actorUid, "u1");
    assert.equal(rows[0].data.actorRole, "owner");
    assert.equal(rows[0].data.serverTimestamp, "TS");
    assert.equal(rows[0].data.requestId, "req-9");
    assert.equal("operationId" in rows[0].data, false);
    assert.equal(rows[0].data.derived, false);
    assert.equal(rows[1].data.derived, true);
});

test("buildRows: operation context adds operationId/opType/opIndex; never an undefined field", () => {
    const rows = M.buildRows([{ kind: "sale", qty: -1, reason: "", valueAtCost: 1, derived: true }],
        Object.assign({}, CTX, { baseId: "op:1~2", operationId: "op:1", opType: "completeOrder", opIndex: 2 }));
    assert.equal(rows[0].id, "op:1~2~m0");
    assert.equal(rows[0].data.operationId, "op:1");
    assert.equal(rows[0].data.opType, "completeOrder");
    assert.equal(rows[0].data.opIndex, 2);
    for (const k in rows[0].data) assert.notEqual(rows[0].data[k], undefined, k);
});

test("buildRows: empty movements builds no rows", () => {
    assert.deepEqual(M.buildRows([], CTX), []);
});

// ── deriveMovement ──────────────────────────────────────────────────────────
test("deriveMovement: one derived row carrying the applied delta", () => {
    assert.deepEqual(M.deriveMovement(-3, "sale"), [{ kind: "sale", qty: -3, reason: "", valueAtCost: 0, derived: true }]);
    assert.deepEqual(M.deriveMovement(4, "adjustment"), [{ kind: "adjustment", qty: 4, reason: "", valueAtCost: 0, derived: true }]);
    assert.deepEqual(M.deriveMovement(0.5, "receipt")[0].qty, 0.5);
});

test("deriveMovement: zero, float noise and non-finite changes derive nothing", () => {
    assert.deepEqual(M.deriveMovement(0, "sale"), []);
    assert.deepEqual(M.deriveMovement(1e-12, "sale"), []);
    assert.deepEqual(M.deriveMovement(NaN, "sale"), []);
    assert.deepEqual(M.deriveMovement(Infinity, "sale"), []);
});

test("deriveMovement: a default kind that contradicts the direction (or is unknown) falls back to adjustment", () => {
    assert.equal(M.deriveMovement(3, "sale")[0].kind, "adjustment");
    assert.equal(M.deriveMovement(-3, "receipt")[0].kind, "adjustment");
    assert.equal(M.deriveMovement(-3, "nonsense")[0].kind, "adjustment");
    assert.equal(M.deriveMovement(-3, undefined)[0].kind, "adjustment");
});

test("constants: default kind by op type and the write ceiling", () => {
    assert.deepEqual(M.DEFAULT_KIND_BY_OPTYPE, { completeOrder: "sale" });
    assert.equal(M.MAX_TXN_WRITES, 500);
});

// ── monkey: random garbage never throws, never returns ok with junk ─────────
test("validateMovements monkey: random junk never throws", () => {
    const junk = [undefined, null, 0, 1, "s", [], {}, [[]], [{}], [{ kind: {} }], [{ kind: "loss", qty: {} }],
                  [{ kind: "loss", qty: -1, reason: {} }],
                  [{ kind: "loss", qty: -1, valueAtCost: [] }], true, false, () => 1];
    for (const j of junk) {
        const r = M.validateMovements(j);
        assert.equal(typeof r.ok, "boolean");
        if (r.ok) for (const m of r.movements) assert.ok(M.MOVEMENT_KINDS.indexOf(m.kind) >= 0);
    }
});
