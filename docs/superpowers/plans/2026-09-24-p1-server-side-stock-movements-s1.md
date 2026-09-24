# P1 Stock Movements, Slice S1 (server) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `recordDelta` and `recordOperation` write server-built `stock_movements` rows in the same transaction as the stock change, and no client-facing endpoint can write that collection directly.

**Architecture:** One new pure module `functions/lib/movementLogic.js` (validate, sum-check, row-build). `gatewayLogic.validateDeltaRequest` validates optional `movements`; `applyDelta` and `operationLogic.applyOperation` verify the sum against the APPLIED delta and write the rows inside their existing transaction. `stock_movement` leaves `ENTITY_COLLECTIONS`. Design: `docs/superpowers/specs/2026-09-24-p1-server-side-stock-movements-design.md` (D1-D10).

**Tech Stack:** Node 20 (CI) / `node --test`, `firebase-functions`, Firestore transactions. No Qt, no QML in this slice.

## Global Constraints

- Branch off latest `main`; never touch `feature/p1-stock-movement-taxonomy`. Commit as `Taher (via Claude session) <tsowner@lkdigitalworks.com>`. PAT from chat only; push with `git push <url> <branch>` (no `-u`), then `grep -c ghp_ .git/config` must print 0.
- Do not build or run the app. Do not install Qt. Only `functions/` is touched, plus docs.
- `movements` is optional on every request; a request without it must behave exactly as before.
- Kind enum (10): `receipt, sale, loss, theft, destroyed, write_off, free_sample, gift, adjustment, sales_return`. `qty` is signed; direction per kind in the spec (D4).
- Caps: 50 movements per `recordDelta`, 90 per `recordOperation` (spec D8).
- Error strings are part of the contract (spec section 5); do not rename.
- Never write an `undefined` field to Firestore (Admin SDK rejects it): `buildRows` adds `operationId`/`opType`/`opIndex` only when given.
- Test counts: always count with `node --test` output, not from memory (LEARNINGS).
- Setup once: `cd functions && npm ci` (needed for `index.handlers` tests; the `lib/` tests need nothing installed).

## How this plan was verified (2026-09-24 design session)

Every file and patch below was applied to a scratch copy of `functions/` from `main` @ `2c1e5f6` and run: `lib/` + new tests
153/153, full `functions/` suite 281/281 (232 existing + 49 new). New/changed `lib/` files: 100% line coverage
(`movementLogic.js` 100% branch). 10 deliberate mutations, all caught after one added test. Each patch also passes
`git apply --check` against `main`. The whole plan was then replayed step by step on a fresh copy of `main` (red counts and green counts below are from that replay).
NOT verified: nothing in QML (none touched); the real Firebase emulator (no e2e in this slice).

## File map

| File | Change | Responsibility |
|---|---|---|
| `functions/lib/movementLogic.js` | create | kinds, direction rules, validation, sum check, row builder |
| `functions/lib/gatewayLogic.js` | modify | validate `movements` on delta requests; `applyDelta` writes rows; close `stock_movement` entity |
| `functions/lib/operationLogic.js` | modify | delta ops carry `movements`; cap; sum check; rows in the operation transaction |
| `functions/index.js` | modify (1 line) | pass `validated.movements` to `applyDelta` |
| `functions/test/testSupport/handlerHarness.js` | modify | capture `applyDelta` params for assertions |
| `functions/test/movementLogic.test.js` | create | pure unit tests |
| `functions/test/movementWiring.test.js` | create | `applyDelta` / operation integration tests over an in-memory transaction fake |
| `functions/test/index.handlers.test.js` | append | handler pass-through and contract |
| docs | modify | AGENTS.md, README.md, test plan status, CHECKPOINT.md |

---

### Task 1: movementLogic (pure)

**Files:**
- Create: `functions/lib/movementLogic.js`
- Test: `functions/test/movementLogic.test.js`

**Interfaces:**
- Produces: `validateMovements(raw) -> {ok:true, movements} | {ok:false,status:400,error}`; `totalsMatch(movements, appliedDelta) -> boolean`;
  `buildRows(movements, ctx) -> [{id, data}]`; constants `KIND_DIRECTION`, `MOVEMENT_KINDS`, `MAX_MOVEMENTS` (50), `MAX_OP_MOVEMENTS` (90).

- [ ] **Step 1: Write the failing test** — create `functions/test/movementLogic.test.js`:

```js
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const M = require("../lib/movementLogic");

function mv(overrides) {
    return Object.assign({ kind: "loss", qty: -2, reason: "water damage", valueAtCost: 40, batchRef: "BAT-1" }, overrides || {});
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
    assert.deepEqual(r, { ok: true, movements: [{ kind: "loss", qty: -2, reason: "water damage", valueAtCost: 40, batchRef: "BAT-1" }] });
});

test("validateMovements: defaults reason '', valueAtCost 0, batchRef null", () => {
    const r = M.validateMovements([{ kind: "receipt", qty: 5 }]);
    assert.deepEqual(r.movements[0], { kind: "receipt", qty: 5, reason: "", valueAtCost: 0, batchRef: null });
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

test("validateMovements: rejects bad batchRef", () => {
    fail([mv({ batchRef: "" })], "invalid-movement-batch-ref");
    fail([mv({ batchRef: 7 })], "invalid-movement-batch-ref");
    fail([mv({ batchRef: "b".repeat(201) })], "invalid-movement-batch-ref");
});

test("validateMovements: does not trust client-supplied identity fields", () => {
    const r = M.validateMovements([mv({ id: "forged", productId: "other", actorUid: "boss", serverTimestamp: 1 })]);
    assert.deepEqual(Object.keys(r.movements[0]).sort(), ["batchRef", "kind", "qty", "reason", "valueAtCost"]);
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
    const rows = M.buildRows([{ kind: "loss", qty: -1, reason: "r", valueAtCost: 5, batchRef: null },
                              { kind: "loss", qty: -2, reason: "", valueAtCost: 0, batchRef: "B" }], CTX);
    assert.deepEqual(rows.map((r) => r.id), ["req-9~m0", "req-9~m1"]);
    assert.equal(rows[0].data.id, "req-9~m0");
    assert.equal(rows[0].data.productId, "p1");
    assert.equal(rows[0].data.actorUid, "u1");
    assert.equal(rows[0].data.actorRole, "owner");
    assert.equal(rows[0].data.serverTimestamp, "TS");
    assert.equal(rows[0].data.requestId, "req-9");
    assert.equal("operationId" in rows[0].data, false);
});

test("buildRows: operation context adds operationId/opType/opIndex; never an undefined field", () => {
    const rows = M.buildRows([{ kind: "sale", qty: -1, reason: "", valueAtCost: 1, batchRef: null }],
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

// ── monkey: random garbage never throws, never returns ok with junk ─────────
test("validateMovements monkey: random junk never throws", () => {
    const junk = [undefined, null, 0, 1, "s", [], {}, [[]], [{}], [{ kind: {} }], [{ kind: "loss", qty: {} }],
                  [{ kind: "loss", qty: -1, reason: {} }], [{ kind: "loss", qty: -1, batchRef: {} }],
                  [{ kind: "loss", qty: -1, valueAtCost: [] }], true, false, () => 1];
    for (const j of junk) {
        const r = M.validateMovements(j);
        assert.equal(typeof r.ok, "boolean");
        if (r.ok) for (const m of r.movements) assert.ok(M.MOVEMENT_KINDS.indexOf(m.kind) >= 0);
    }
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && node --test test/movementLogic.test.js`
Expected: FAIL, `Cannot find module '../lib/movementLogic'` (1 failed file).

- [ ] **Step 3: Write the implementation** — create `functions/lib/movementLogic.js`:

```js
"use strict";

// P1 (CGST Rule 56(2)) stock-movement ledger rows. Rows are built HERE, on the
// server, inside the same transaction as the stock change. The client only says
// WHAT happened (kind, signed qty, reason, valueAtCost, batchRef); the row id,
// productId, actor, role and times are stamped by the server, so the ledger
// cannot be forged by a client. Pure module: no Firebase dependency.

// Direction of the stock change each kind may carry: +1 increases stock,
// -1 decreases it, 0 either way. `sales_return` is the one kind beyond the
// spec's nine (see specs/2026-09-24-p1-server-side-stock-movements-design.md).
const KIND_DIRECTION = {
    receipt: 1,
    sales_return: 1,
    sale: -1,
    loss: -1,
    theft: -1,
    destroyed: -1,
    write_off: -1,
    free_sample: -1,
    gift: -1,
    adjustment: 0
};
const MOVEMENT_KINDS = Object.keys(KIND_DIRECTION);

// Per recordDelta request.
const MAX_MOVEMENTS = 50;
// Per recordOperation, all ops together. operationLogic budgets 401 writes for
// 200 ops (200 docs + 200 audits + 1 marker); 401 + 90 = 491 stays under
// Firestore's 500-writes-per-transaction ceiling.
const MAX_OP_MOVEMENTS = 90;
const MAX_REASON = 500;
const MAX_BATCH_REF = 200;
// Quantities may be fractional; tolerate float noise, nothing more.
const EPSILON = 1e-9;

function _fail(error) {
    return { ok: false, status: 400, error: error };
}

// raw: undefined/null (no movements) or a non-empty array of
// { kind, qty, reason?, valueAtCost?, batchRef? }. Returns
// { ok: true, movements: [normalized...] } or { ok: false, status, error }.
function validateMovements(raw) {
    if (raw === undefined || raw === null) return { ok: true, movements: [] };
    if (!Array.isArray(raw) || raw.length === 0) return _fail("invalid-movements");
    if (raw.length > MAX_MOVEMENTS) return _fail("too-many-movements");

    const movements = [];
    for (const m of raw) {
        if (!m || typeof m !== "object") return _fail("invalid-movements");
        if (MOVEMENT_KINDS.indexOf(m.kind) < 0) return _fail("invalid-movement-kind");

        if (typeof m.qty !== "number" || !isFinite(m.qty) || m.qty === 0) return _fail("invalid-movement-qty");
        const direction = KIND_DIRECTION[m.kind];
        if (direction !== 0 && Math.sign(m.qty) !== direction) return _fail("invalid-movement-qty");

        const value = m.valueAtCost === undefined ? 0 : m.valueAtCost;
        if (typeof value !== "number" || !isFinite(value) || value < 0) return _fail("invalid-movement-value");

        const reason = (m.reason === undefined || m.reason === null) ? "" : m.reason;
        if (typeof reason !== "string" || reason.length > MAX_REASON) return _fail("invalid-movement-reason");

        const batchRef = (m.batchRef === undefined || m.batchRef === null) ? null : m.batchRef;
        if (batchRef !== null && (typeof batchRef !== "string" || batchRef.length === 0 || batchRef.length > MAX_BATCH_REF))
            return _fail("invalid-movement-batch-ref");

        movements.push({ kind: m.kind, qty: m.qty, reason: reason.trim(), valueAtCost: value, batchRef: batchRef });
    }
    return { ok: true, movements: movements };
}

// The ledger must agree with the stock change it explains: the movements'
// signed quantities sum to exactly the delta the server APPLIED (after floors
// and clamps), never the delta the client asked for.
function totalsMatch(movements, appliedDelta) {
    let sum = 0;
    for (const m of movements) sum += m.qty;
    return Math.abs(sum - appliedDelta) <= EPSILON;
}

// One { id, data } per movement. ctx: { baseId, productId, actorUid, actorRole,
// serverTimestamp, clientTimestamp, requestId, operationId?, opType?, opIndex? }.
// `baseId` is the audit_log id of the write that carries the movements, so a
// retried request (which replays from that audit entry) never writes a row twice.
function buildRows(movements, ctx) {
    return movements.map(function (m, j) {
        const id = ctx.baseId + "~m" + j;
        const data = {
            id: id,
            productId: ctx.productId,
            kind: m.kind,
            qty: m.qty,
            reason: m.reason,
            valueAtCost: m.valueAtCost,
            batchRef: m.batchRef,
            actorUid: ctx.actorUid,
            actorRole: ctx.actorRole,
            serverTimestamp: ctx.serverTimestamp,
            clientTimestamp: ctx.clientTimestamp,
            requestId: ctx.requestId
        };
        if (ctx.operationId !== undefined) {
            data.operationId = ctx.operationId;
            data.opType = ctx.opType;
            data.opIndex = ctx.opIndex;
        }
        return { id: id, data: data };
    });
}

module.exports = {
    KIND_DIRECTION, MOVEMENT_KINDS, MAX_MOVEMENTS, MAX_OP_MOVEMENTS,
    validateMovements, totalsMatch, buildRows
};
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd functions && node --test test/movementLogic.test.js`
Expected: `# tests 21`, `# pass 21`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/movementLogic.js functions/test/movementLogic.test.js
git commit -m "feat(p1): movementLogic - kinds, validation, sum check, server-built rows"
```

---

### Task 2: recordDelta writes rows; close the generic path

**Files:**
- Modify: `functions/lib/gatewayLogic.js`
- Create: `functions/test/movementWiring.test.js` (first half; Task 4 appends the second)

**Interfaces:**
- Consumes: Task 1's `MovementLogic.validateMovements`, `totalsMatch`, `buildRows`.
- Produces: `validateDeltaRequest(body)` result gains `movements` (always an array); `applyDelta(db, params)` accepts `params.movements` and returns
  `{ok:false,status:409,error:"movement-qty-mismatch",field:"stock",current}` on a sum mismatch; `ENTITY_COLLECTIONS.stock_movement` no longer exists.

- [ ] **Step 1: Write the failing tests** — create `functions/test/movementWiring.test.js`:

```js
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

test("applyDelta: no movements writes no movement rows (old behaviour)", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    await G.applyDelta(db, dParams({ movements: [] }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyDelta: several movements, one per FIFO portion, must sum to the applied delta", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const movements = [{ kind: "sale", qty: -1, reason: "", valueAtCost: 1, batchRef: "A" },
                       { kind: "sale", qty: -2, reason: "", valueAtCost: 4, batchRef: "B" }];
    const r = await G.applyDelta(db, dParams({ movements: movements }));
    assert.equal(r.ok, true);
    assert.deepEqual(rowsOf(db).map((w) => w.path), [T + "stock_movements/req-1~m0", T + "stock_movements/req-1~m1"]);
});

test("applyDelta: a sum that disagrees with the applied delta writes NOTHING and returns 409", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const r = await G.applyDelta(db, dParams({ movements: [{ kind: "loss", qty: -1, reason: "", valueAtCost: 0, batchRef: null }] }));
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
    const r = await G.applyDelta(db, dParams({ deltas: { stock: 5 }, movements: [{ kind: "receipt", qty: 5, reason: "", valueAtCost: 50, batchRef: "B1" }] }));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"].stock, 6);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd functions && node --test test/movementWiring.test.js`
Expected: `# tests 14`, `# pass 5`, `# fail 9` (measured by replaying this plan on a fresh copy of `main`).

- [ ] **Step 3: Apply the implementation** — save as `/tmp/gateway.patch` and run `git apply /tmp/gateway.patch` from the repo root
(or make the same edits by hand; the patch is the exact diff that was run):

```diff
--- a/functions/lib/gatewayLogic.js
+++ b/functions/lib/gatewayLogic.js
@@ -9,16 +9,19 @@
 // preserving refactor — see docs/superpowers/plans/2026-07-11-p0-gateway-fast-follow.md).
 
 // P0 scope. `entity` -> collection name under the tenant root.
+// `stock_movements` is deliberately absent: those rows are built server-side
+// by movementLogic (P1), so no client-facing endpoint can name that entity.
 const ENTITY_COLLECTIONS = {
     inventory: "inventory",
     stock_batch: "stock_batches",
-    stock_movement: "stock_movements",
     transaction: "transactions",
     order: "orders",
     staff: "staff",
     supplier: "suppliers"
 };
 
+const MovementLogic = require("./movementLogic");
+
 const ALLOWED_ACTIONS = ["create", "update", "delete", "opening_balance"];
 
 // Extracts the token from an "Authorization: Bearer <token>" header.
@@ -94,6 +97,14 @@
         }
     }
 
+    const mv = MovementLogic.validateMovements(body.movements);
+    if (!mv.ok) return mv;
+    if (mv.movements.length > 0) {
+        if (entity !== "inventory") return { ok: false, status: 400, error: "movements-require-inventory" };
+        if (!Object.prototype.hasOwnProperty.call(deltas, "stock"))
+            return { ok: false, status: 400, error: "movements-require-stock-delta" };
+    }
+
     return {
         ok: true,
         entity: entity,
@@ -102,6 +113,7 @@
         deltas: deltas,
         floors: floors,
         clamps: clamps,
+        movements: mv.movements,
         clientTimestamp: clientTimestamp,
         collection: collection
     };
@@ -214,7 +226,22 @@
             after[field] = nextVal;
         }
 
+        const movements = params.movements || [];
+        if (movements.length > 0 && !MovementLogic.totalsMatch(movements, after.stock - before.stock)) {
+            return { ok: false, status: 409, error: "movement-qty-mismatch", field: "stock", current: before.stock };
+        }
+
         txn.set(workingRef, Object.assign({}, current, after), { merge: false });
+        const rows = MovementLogic.buildRows(movements, {
+            baseId: params.requestId,
+            productId: params.entityId,
+            actorUid: params.actorUid,
+            actorRole: params.actorRole,
+            serverTimestamp: params.serverTimestamp,
+            clientTimestamp: params.clientTimestamp,
+            requestId: params.requestId
+        });
+        for (const row of rows) txn.set(db.doc("tenants/" + params.tenantId + "/stock_movements/" + row.id), row.data);
         txn.set(auditRef, {
             entryId: params.requestId,
             tenantId: params.tenantId,
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd functions && node --test test/movementWiring.test.js test/gatewayLogic.test.js test/lockLogic.test.js test/batchMutationLogic.test.js`
Expected: all pass, `# fail 0` (the existing gateway/lock/batch tests must be untouched and green).

- [ ] **Step 5: Commit**

```bash
git add functions/lib/gatewayLogic.js functions/test/movementWiring.test.js
git commit -m "feat(p1): recordDelta writes server-built stock_movements rows atomically; close stock_movement entity"
```

---

### Task 3: recordDelta handler pass-through

**Files:**
- Modify: `functions/index.js` (1 line, inside `exports.recordDelta`)
- Modify: `functions/test/testSupport/handlerHarness.js`
- Test: append to `functions/test/index.handlers.test.js`

**Interfaces:**
- Consumes: Task 2's `validated.movements`.
- Produces: `applyDelta` is called with `params.movements`; harness exposes `mockState.lastApplyDeltaParams`.

- [ ] **Step 1: Write the failing tests** — append to the end of `functions/test/index.handlers.test.js`:

```js
// ── recordDelta: P1 stock movements ─────────────────────────────────────

test("recordDelta: forwards validated movements to applyDelta", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyDeltaResult = { ok: true, after: { stock: 7 } };
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody({
        entity: "inventory", entityId: "p1", deltas: { stock: -3 },
        movements: [{ kind: "loss", qty: -3, reason: " spoiled ", valueAtCost: 9, id: "forged" }]
    }) }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(mockState.lastApplyDeltaParams.movements,
        [{ kind: "loss", qty: -3, reason: "spoiled", valueAtCost: 9, batchRef: null }]);
});

test("recordDelta: without movements forwards an empty list (old clients unaffected)", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyDeltaResult = { ok: true, after: { qtyOnHand: 4 } };
    await handlers.recordDelta(mockReq({ body: validDeltaBody() }), mockRes());
    assert.deepEqual(mockState.lastApplyDeltaParams.movements, []);
});

test("recordDelta: invalid movement -> 400 with the specific error, applyDelta never called", async () => {
    seedHappyPathAuth(mockState);
    mockState.lastApplyDeltaParams = null;
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody({
        entity: "inventory", entityId: "p1", deltas: { stock: -3 }, movements: [{ kind: "stolen", qty: -3 }]
    }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "invalid-movement-kind");
    assert.equal(mockState.lastApplyDeltaParams, null);
});

test("recordDelta: movement-qty-mismatch from applyDelta is forwarded as 409 with field/current", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyDeltaResult = { ok: false, status: 409, error: "movement-qty-mismatch", field: "stock", current: 0 };
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody({
        entity: "inventory", entityId: "p1", deltas: { stock: -3 }, movements: [{ kind: "loss", qty: -3 }]
    }) }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(jsonBody(res).error, "movement-qty-mismatch");
    assert.equal(jsonBody(res).current, 0);
});

test("recordDelta: the closed stock_movement entity -> 400 unsupported-entity", async () => {
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.recordDelta(mockReq({ body: validDeltaBody({ entity: "stock_movement", entityId: "m1", deltas: { qty: 1 } }) }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "unsupported-entity");
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd functions && npm ci && node --test test/index.handlers.test.js`
Expected: `# tests 30`, `# pass 28`, `# fail 2` (measured after Tasks 1-2: the harness cannot capture params yet, and `index.js` does not forward `movements`; the other 3 new tests already pass on Task 2's validation).

- [ ] **Step 3: Apply the implementation** — harness first, then `index.js`:

```diff
--- a/functions/test/testSupport/handlerHarness.js
+++ b/functions/test/testSupport/handlerHarness.js
@@ -76,6 +76,7 @@
         collectionGetError: null, // when set, every collection(...).get() throws this (computeAnalysis 500 path)
         applyMutationResult: null,
         applyDeltaResult: null,
+        lastApplyDeltaParams: null,
         applyMutationsBatchResult: null,
         applyOperationResult: null,
         acquireLockResult: null,
@@ -192,7 +193,7 @@
         id: gatewayLogicPath, filename: gatewayLogicPath, loaded: true,
         exports: Object.assign({}, realGatewayLogic, {
             applyMutation: async () => mockState.applyMutationResult,
-            applyDelta: async () => mockState.applyDeltaResult
+            applyDelta: async (db, params) => { mockState.lastApplyDeltaParams = params; return mockState.applyDeltaResult; }
         })
     };
     const realBatchMutationLogic = require(batchMutationLogicPath);
```

```diff
--- a/functions/index.js
+++ b/functions/index.js
@@ -224,6 +224,7 @@
                 deltas: validated.deltas,
                 floors: validated.floors,
                 clamps: validated.clamps,
+                movements: validated.movements,
                 clientTimestamp: validated.clientTimestamp,
                 collection: validated.collection,
                 serverTimestamp: FieldValue.serverTimestamp()
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd functions && node --test test/index.handlers.test.js`
Expected: `# tests 30`, `# pass 30`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add functions/index.js functions/test/testSupport/handlerHarness.js functions/test/index.handlers.test.js
git commit -m "feat(p1): recordDelta handler forwards movements; harness captures applyDelta params"
```

---

### Task 4: recordOperation writes rows

**Files:**
- Modify: `functions/lib/operationLogic.js`
- Test: append to `functions/test/movementWiring.test.js`

**Interfaces:**
- Consumes: Task 1 (`MAX_OP_MOVEMENTS`, `totalsMatch`, `buildRows`); Task 2's `validateDeltaRequest` already returns `movements` per delta op.
- Produces: `validateOperationRequest` errors `movements-require-delta-op` and `too-many-movements` (both with `opIndex`);
  `applyOperation` writes `stock_movements/{requestId}~{opIndex}~m{j}` and rejects the WHOLE operation with `409 movement-qty-mismatch` + `opIndex`.

- [ ] **Step 1: Write the failing tests** — append to `functions/test/movementWiring.test.js` (the file already imports `O` and `M`):

```js
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

test("validateOperationRequest: a mutation op may not carry movements", () => {
    const v = O.validateOperationRequest(opBody([{ kind: "mutation", entity: "order", entityId: "o1", action: "update",
        before: {}, after: {}, movements: [] }]));
    assert.equal(v.error, "movements-require-delta-op");
    assert.equal(v.opIndex, 0);
});

test("validateOperationRequest: total movements are capped so the transaction stays under 500 writes", () => {
    const fifty = Array.from({ length: 50 }, () => ({ kind: "sale", qty: -1 }));
    const ok = O.validateOperationRequest(opBody([deltaOp("p1", -50, fifty), deltaOp("p2", -40, fifty.slice(0, 40))]));
    assert.equal(ok.ok, true);
    const over = O.validateOperationRequest(opBody([deltaOp("p1", -50, fifty), deltaOp("p2", -41, fifty.slice(0, 41))]));
    assert.equal(over.error, "too-many-movements");
    assert.equal(over.opIndex, 1);
    assert.equal(M.MAX_OP_MOVEMENTS, 90);
});

test("validateOperationRequest: a bad movement reports the op index", () => {
    const v = O.validateOperationRequest(opBody([deltaOp("p1", -1, [{ kind: "sale", qty: -1 }]), deltaOp("p2", -1, [{ kind: "x", qty: -1 }])]));
    assert.equal(v.error, "invalid-movement-kind");
    assert.equal(v.opIndex, 1);
});

test("applyOperation: writes a movement row per op movement, carrying the operation context", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 }, [T + "inventory/p2"]: { stock: 5 } });
    const v = O.validateOperationRequest(opBody([
        deltaOp("p1", -3, [{ kind: "sale", qty: -1, valueAtCost: 2, batchRef: "A" }, { kind: "sale", qty: -2, valueAtCost: 6, batchRef: "B" }]),
        deltaOp("p2", -1, undefined)]));
    const r = await O.applyOperation(db, oParams(v));
    assert.equal(r.ok, true);
    assert.deepEqual(rowsOf(db).map((w) => w.path),
        [T + "stock_movements/completeOrder:o1:1~0~m0", T + "stock_movements/completeOrder:o1:1~0~m1"]);
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

test("applyOperation: ops without movements behave exactly as before (no rows)", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 10 } });
    const v = O.validateOperationRequest(opBody([deltaOp("p1", -3, undefined)]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.equal(rowsOf(db).length, 0);
});

test("applyOperation: max-size operation stays within the Firestore write ceiling", async () => {
    const docs = {};
    const ops = [];
    for (let i = 0; i < 90; i++) { docs[T + "inventory/p" + i] = { stock: 5 }; ops.push(deltaOp("p" + i, -1, [{ kind: "sale", qty: -1 }])); }
    for (let i = 90; i < 200; i++) { docs[T + "inventory/p" + i] = { stock: 5 }; ops.push(deltaOp("p" + i, -1, undefined)); }
    const v = O.validateOperationRequest(opBody(ops));
    assert.equal(v.ok, true);
    const db = makeDb(docs);
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.ok(db.writes.length <= 500, "writes: " + db.writes.length);
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd functions && node --test test/movementWiring.test.js`
Expected: `# tests 23`, `# pass 18`, `# fail 5` (measured: rows are not written, caps and errors do not exist yet; Task 2's tests still pass).

- [ ] **Step 3: Apply the implementation** — exact diff that was run:

```diff
--- a/functions/lib/operationLogic.js
+++ b/functions/lib/operationLogic.js
@@ -17,6 +17,7 @@
     validateDeltaRequest,
     _deepEqual
 } = require("./gatewayLogic");
+const MovementLogic = require("./movementLogic");
 
 // 200 ops = up to 200 working-doc writes + 200 per-op audit entries + 1 marker
 // = 401 writes, under Firestore's ~500-writes-per-transaction ceiling. Mirrored
@@ -64,15 +65,21 @@
     if (rawOps.length > MAX_OPS) return { ok: false, status: 400, error: "operation-too-large" };
 
     const ops = [];
+    let movementCount = 0;
     for (let i = 0; i < rawOps.length; i++) {
         const raw = rawOps[i] || {};
         const perOp = Object.assign({}, raw, { requestId: opAuditId(requestId, i) });
         let v;
         if (raw.kind === "delta") v = validateDeltaRequest(perOp);
-        else if (raw.kind === "mutation") v = validateMutationRequest(perOp);
+        else if (raw.kind === "mutation") {
+            if (raw.movements !== undefined) return { ok: false, status: 400, error: "movements-require-delta-op", opIndex: i };
+            v = validateMutationRequest(perOp);
+        }
         else return { ok: false, status: 400, error: "unsupported-kind", opIndex: i };
         if (!v.ok) return Object.assign({}, v, { opIndex: i });
         if (!isSafeDocId(v.entityId)) return { ok: false, status: 400, error: "invalid-entity-id", opIndex: i };
+        movementCount += v.movements ? v.movements.length : 0;
+        if (movementCount > MovementLogic.MAX_OP_MOVEMENTS) return { ok: false, status: 400, error: "too-many-movements", opIndex: i };
         ops.push(Object.assign({ kind: raw.kind }, v));
     }
     return { ok: true, requestId: requestId, opType: opType, ops: ops,
@@ -137,6 +144,11 @@
                     before[field] = curVal;
                     after[field] = nextVal;
                 }
+                if (op.movements && op.movements.length > 0
+                        && !MovementLogic.totalsMatch(op.movements, after.stock - before.stock)) {
+                    return { ok: false, status: 409, error: "movement-qty-mismatch",
+                             opIndex: i, field: "stock", current: before.stock };
+                }
                 entry.data = Object.assign({}, entry.data, after);
                 audits.push({ i: i, op: op, action: "delta", before: before, after: after });
                 results.push({ entity: op.entity, entityId: op.entityId, kind: "delta", after: after });
@@ -182,6 +194,21 @@
                 opType: params.opType,
                 opIndex: a.i
             });
+            if (a.op.movements && a.op.movements.length > 0) {
+                const rows = MovementLogic.buildRows(a.op.movements, {
+                    baseId: opAuditId(params.requestId, a.i),
+                    productId: a.op.entityId,
+                    actorUid: params.actorUid,
+                    actorRole: params.actorRole,
+                    serverTimestamp: params.serverTimestamp,
+                    clientTimestamp: params.clientTimestamp,
+                    requestId: opAuditId(params.requestId, a.i),
+                    operationId: params.requestId,
+                    opType: params.opType,
+                    opIndex: a.i
+                });
+                for (const row of rows) txn.set(db.doc(tenantRoot + "/stock_movements/" + row.id), row.data);
+            }
         }
         // The marker is what makes a retry a no-op. Its id IS the requestId,
         // like every other audit_log entry.
```

- [ ] **Step 4: Run to verify everything passes**

Run: `cd functions && npm test`
Expected: `# fail 0`; on `main` @ `2c1e5f6` that is 232 existing + 49 new = 281 tests.
Coverage check (optional): `node --test --experimental-test-coverage test/movementWiring.test.js test/movementLogic.test.js test/gatewayLogic.test.js test/operationLogic.test.js` shows 100% line for the three `lib/` files.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/operationLogic.js functions/test/movementWiring.test.js
git commit -m "feat(p1): recordOperation writes stock_movements rows in the operation transaction; cap total movements"
```

---

### Task 5: docs, test plan status, PR

**Files:**
- Modify: `AGENTS.md` (P1 bullet in the roadmap list, Compliance & Audit Agent scope line), `README.md` (functions section: `movements` on `recordDelta`/`recordOperation`, `stock_movement` closed), `docs/superpowers/test-plans/2026-09-24-p1-stock-movements-test-plan.md` (flip S1 rows from "planned" to "verified" with the real counts), `CHECKPOINT.md`.
- Do NOT touch `SKILLS.md` unless a genuinely new lesson was learned (append-only, next free number).

- [ ] **Step 1: Mutation spot-check** (recommended): re-run the 10 mutations listed in the test plan against the real files; each must make a test fail.
- [ ] **Step 2: Update the docs above** with actual counts from `npm test` (count, do not copy).
- [ ] **Step 3: Confirm rules tests are untouched:** `git diff --stat main -- test/ firestore.rules` prints nothing (ledger writes were already denied).
- [ ] **Step 4: Push and open the PR** (`feature/2026-09-25-p1-s1-server-movements` or similar), wait for the 5 CI checks, then hand to Taher. Taher deploys functions to dev
      (`firebase deploy --only functions`) and confirms with an unauthenticated POST to `recordDelta` returning `401 missing-token`. S2 must not start before that.
- [ ] **Step 5: Update `CHECKPOINT.md` step log** and end the session: S2 planning is the next session's job.

## Self-review (against the spec)

- D2 server-built row: Task 1 `buildRows`, Task 1 test "does not trust client-supplied identity fields", Task 3 forged `id` test.
- D3 sum invariant against the applied delta: Task 2 mismatch and clamp tests; Task 4 whole-operation rollback test.
- D4 kinds and direction: Task 1 tests (every kind, every wrong sign).
- D5 closed path: Task 2 `stock_movement is no longer a client-writable entity` (all three validators), Task 3 handler test.
- D6 inventory + stock delta + delta ops only: Task 2 and Task 4 validation tests.
- D7 deterministic ids and replay: Task 2 and Task 4 replay tests.
- D8 write budget: Task 4 cap test and max-size operation test.
- D9 `valueAtCost`: Task 1 value validation tests. D10 backward compatible: Task 2 "no movements", Task 3 "empty list", Task 4 "without movements".
- Placeholder scan: none. Names consistent across tasks (`validateMovements`, `totalsMatch`, `buildRows`, `MAX_OP_MOVEMENTS`, `movement-qty-mismatch`).
