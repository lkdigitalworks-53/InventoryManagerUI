# P1 Stock Movements, Slice S1a (server: recordDelta + recordOperation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `recordDelta` and `recordOperation` write server-built `stock_movements` rows in the same transaction as every inventory stock change (client-supplied kinds when sent, a server-derived default otherwise), and no client-facing endpoint can write that collection directly.

**Architecture:** One new pure module `functions/lib/movementLogic.js` (validate, derive, sum-check, row-build). `gatewayLogic.validateDeltaRequest` validates optional `movements`; `applyDelta` and `operationLogic.applyOperation` verify the sum against the APPLIED delta, derive a default row when none was sent, and write rows inside their existing transaction. `stock_movement` leaves `ENTITY_COLLECTIONS`. `validateMutationRequest` rejects `movements` (S1b derives for whole-record mutations). Design: `docs/superpowers/specs/2026-09-24-p1-server-side-stock-movements-design.md` (D1-D13).

**Tech Stack:** Node 20 (CI) / `node --test`, `firebase-functions`, Firestore transactions. No Qt, no QML in this slice.

## Global Constraints

- Branch off latest `main` (e.g. `feature/2026-09-25-p1-s1a-server-movements`); never touch `feature/p1-stock-movement-taxonomy`. Commit as `Taher (via Claude session) <tsowner@lkdigitalworks.com>`. PAT from chat only; push with `git push <url> <branch>` (no `-u`), then `grep -c ghp_ .git/config` must print 0.
- Do not build or run the app. Do not install Qt. Only `functions/` is touched, plus docs. Environment is DEV only (no prod data, no backward-compat constraint on old clients).
- Kind enum (10): `receipt, sale, loss, theft, destroyed, write_off, free_sample, gift, adjustment, sales_return`. `qty` is signed; direction per kind in the spec (D4). Row fields: `id, productId, kind, qty, reason, valueAtCost, derived, actorUid, actorRole, serverTimestamp, clientTimestamp, requestId` (+ `operationId, opType, opIndex` inside an operation). There is NO `batchRef` (cut until S3, spec D9).
- Derived defaults (spec D11): `recordDelta` on inventory `stock` with no `movements` -> one `adjustment`; `recordOperation` delta op -> `sale` for `completeOrder` (falls back to `adjustment` if the change is an increase). Zero applied change derives nothing.
- Write budget (spec D8): per operation `2 x ops + 1 + rows <= 500`, where every op on entity `inventory` counts at least 1 row. Over budget = `400 operation-too-large`. `recordDelta` allows 50 explicit movements.
- Error strings are part of the contract (spec section 5); do not rename.
- Never write an `undefined` field to Firestore (Admin SDK rejects it): `buildRows` adds `operationId`/`opType`/`opIndex` only when given.
- Test counts: always count with `node --test` output, not from memory (LEARNINGS).
- Setup once: `cd functions && npm ci` (needed for `index.handlers` tests; the `lib/` tests need nothing installed). Run the whole suite with `node --test` (NOT `node --test test/`, which fails).

## How this plan was verified (2026-09-24 design session)

Every file and patch below was applied to a scratch copy of `functions/` from `main` @ `6da373d` and replayed step by step. Full `functions/` suite after S1a:
291/291 (232 existing, 3 of them re-expected on purpose, + 59 new). New/changed `lib/` files: 100% line coverage (`movementLogic.js` 100% branch). Mutation checks (deliberate bugs) all caught.
Red/green counts below are from that replay. NOT verified: nothing in QML (none touched); the Firebase emulator (no e2e in this slice).

**Base has since moved (2026-09-26 rebase note):** PR #80 (staff delete UI, unrelated to P1) merged to `main` after this plan was verified and
added `removed_staff` to `ENTITY_COLLECTIONS` in `functions/lib/gatewayLogic.js` — the same object Task 2's patch edits. The Task 2 diff below
**no longer applies with `git apply`** (`error: patch failed: functions/lib/gatewayLogic.js:9`); the other four patches (Tasks 1, 3, 4) are unaffected
and still apply cleanly to `main` as of `9be6303`. Before Task 2, re-check with `git apply --check`, and if it still fails, make the same edit by
hand against the current file (remove the `stock_movement` line, add the doc comment and the `MovementLogic` require) rather than trusting the diff verbatim.

## File map

| File | Change | Responsibility |
|---|---|---|
| `functions/lib/movementLogic.js` | create | kinds, direction rules, validation, derive, sum check, row builder, write ceiling constant |
| `functions/lib/gatewayLogic.js` | modify | validate `movements` on delta requests; reject them on mutations; `applyDelta` derives/writes rows; close `stock_movement` entity |
| `functions/lib/operationLogic.js` | modify | delta ops carry/derive movements; write budget; rows in the operation transaction |
| `functions/index.js` | modify (1 line) | pass `validated.movements` to `applyDelta` |
| `functions/test/testSupport/handlerHarness.js` | modify | capture `applyDelta` params for assertions |
| `functions/test/operationLogic.test.js` | modify (3 existing tests) | new write budget and the derived row change 3 old expectations |
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
- Produces: `validateMovements(raw)`, `totalsMatch(movements, appliedDelta)`, `deriveMovement(appliedDelta, defaultKind)`, `buildRows(movements, ctx)`; constants `KIND_DIRECTION`, `MOVEMENT_KINDS`, `DEFAULT_KIND_BY_OPTYPE`, `MAX_MOVEMENTS` (50), `MAX_TXN_WRITES` (500).

- [ ] **Step 1: Write the failing test** - create `functions/test/movementLogic.test.js`:

```js
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && node --test test/movementLogic.test.js`
Expected: FAIL, `Cannot find module '../lib/movementLogic'`.

- [ ] **Step 3: Write the implementation** - create `functions/lib/movementLogic.js`:

```js
"use strict";

// P1 (CGST Rule 56(2)) stock-movement ledger rows. Rows are built HERE, on the
// server, inside the same transaction as the stock change. The client may say
// WHAT happened (kind, signed qty, reason, valueAtCost); when it says nothing,
// the server derives a default row, so no stock change can leave the ledger.
// Row id, productId, actor, role and times are always stamped by the server, so
// the ledger cannot be forged by a client. Pure module: no Firebase dependency.

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

// Default kind for a stock change the client did not describe, by operation.
// Anything else defaults to "adjustment".
const DEFAULT_KIND_BY_OPTYPE = { completeOrder: "sale" };

// Explicit movements per recordDelta request.
const MAX_MOVEMENTS = 50;
// Firestore's per-transaction write ceiling. Every write path must keep
// (working docs + audit entries + movement rows [+ marker]) under it.
const MAX_TXN_WRITES = 500;
const MAX_REASON = 500;
// Quantities may be fractional; tolerate float noise, nothing more.
const EPSILON = 1e-9;

function _fail(error) {
    return { ok: false, status: 400, error: error };
}

// raw: undefined/null (no movements) or a non-empty array of
// { kind, qty, reason?, valueAtCost? }. Returns
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

        movements.push({ kind: m.kind, qty: m.qty, reason: reason.trim(), valueAtCost: value, derived: false });
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

// Server-derived row for a stock change the client did not describe. Zero
// change derives nothing. If defaultKind contradicts the direction of the
// change (e.g. "sale" on an increase) the row falls back to "adjustment".
function deriveMovement(appliedDelta, defaultKind) {
    if (!isFinite(appliedDelta) || Math.abs(appliedDelta) <= EPSILON) return [];
    const direction = KIND_DIRECTION[defaultKind];
    const kind = (direction === undefined || (direction !== 0 && Math.sign(appliedDelta) !== direction))
        ? "adjustment" : defaultKind;
    return [{ kind: kind, qty: appliedDelta, reason: "", valueAtCost: 0, derived: true }];
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
            derived: m.derived === true,
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
    KIND_DIRECTION, MOVEMENT_KINDS, DEFAULT_KIND_BY_OPTYPE, MAX_MOVEMENTS, MAX_TXN_WRITES,
    validateMovements, totalsMatch, deriveMovement, buildRows
};
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd functions && node --test test/movementLogic.test.js`
Expected: `# tests 24`, `# pass 24`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/movementLogic.js functions/test/movementLogic.test.js
git commit -m "feat(p1): movementLogic - kinds, validation, derive, sum check, server-built rows"
```

---

### Task 2: recordDelta writes rows; close the generic path

**Files:**
- Modify: `functions/lib/gatewayLogic.js`
- Create: `functions/test/movementWiring.test.js` (first half; Task 4 appends the second)

**Interfaces:**
- Consumes: Task 1.
- Produces: `validateDeltaRequest(body)` result gains `movements` (always an array); `validateMutationRequest` rejects `movements` with `400 movements-not-supported`;
  `applyDelta(db, params)` accepts `params.movements`, derives an `adjustment` row when none, returns `{ok:false,status:409,error:"movement-qty-mismatch",field:"stock",current}` on a sum mismatch; `ENTITY_COLLECTIONS.stock_movement` no longer exists.

- [ ] **Step 1: Write the failing tests** - create `functions/test/movementWiring.test.js`:

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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd functions && node --test test/movementWiring.test.js`
Expected: `# tests 17`, `# pass 6`, `# fail 11` (measured by replaying this plan on a fresh copy of `main`).

- [ ] **Step 3: Apply the implementation** - save as `/tmp/gateway.patch` and run `git apply /tmp/gateway.patch` from the repo root
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
@@ -52,6 +55,11 @@
     if (!entityId || !requestId) {
         return { ok: false, status: 400, error: "missing-fields" };
     }
+    // Whole-record mutations never carry client movements: the server derives
+    // the row from the before/after stock (P1 spec D11). Movements come via recordDelta.
+    if (body.movements !== undefined) {
+        return { ok: false, status: 400, error: "movements-not-supported" };
+    }
 
     return {
         ok: true,
@@ -94,6 +102,14 @@
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
@@ -102,6 +118,7 @@
         deltas: deltas,
         floors: floors,
         clamps: clamps,
+        movements: mv.movements,
         clientTimestamp: clientTimestamp,
         collection: collection
     };
@@ -214,7 +231,26 @@
             after[field] = nextVal;
         }
 
+        // Every stock change on inventory leaves a ledger row: the client's
+        // movements if it sent any, else one server-derived "adjustment".
+        let movements = params.movements || [];
+        if (movements.length === 0 && params.entity === "inventory" && Object.prototype.hasOwnProperty.call(after, "stock"))
+            movements = MovementLogic.deriveMovement(after.stock - before.stock, "adjustment");
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
Expected: all pass, `# fail 0` (the existing gateway/lock/batch tests are untouched and green).

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

- [ ] **Step 1: Write the failing tests** - append to the end of `functions/test/index.handlers.test.js`:

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
        [{ kind: "loss", qty: -3, reason: "spoiled", valueAtCost: 9, derived: false }]);
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
Expected: `# tests 30`, `# pass 28`, `# fail 2` (harness cannot capture params yet, `index.js` does not forward `movements`).

- [ ] **Step 3: Apply the implementation** - harness first, then `index.js`:

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
- Modify: `functions/test/operationLogic.test.js` (3 existing tests, see Step 3)
- Test: append to `functions/test/movementWiring.test.js`

**Interfaces:**
- Consumes: Task 1 (`MAX_TXN_WRITES`, `DEFAULT_KIND_BY_OPTYPE`, `deriveMovement`, `totalsMatch`, `buildRows`); Task 2's `validateDeltaRequest` returns `movements` per delta op.
- Produces: `400 operation-too-large` when `2 x ops + 1 + rows > 500`; `applyOperation` writes `stock_movements/{requestId}~{opIndex}~m{j}` and rejects the WHOLE operation with `409 movement-qty-mismatch` + `opIndex`.

- [ ] **Step 1: Write the failing tests** - append to `functions/test/movementWiring.test.js` (the file already imports `O` and `M`):

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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd functions && node --test test/movementWiring.test.js`
Expected: `# tests 30`, `# pass 22`, `# fail 8` (rows are not written, budget does not exist yet; Task 2's tests still pass).

- [ ] **Step 3: Apply the implementation** - the exact diff that was run:

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
@@ -75,6 +76,16 @@
         if (!isSafeDocId(v.entityId)) return { ok: false, status: 400, error: "invalid-entity-id", opIndex: i };
         ops.push(Object.assign({ kind: raw.kind }, v));
     }
+
+    // Write budget: one working doc + one audit entry per op, one marker, and
+    // (conservatively) at least one movement row per op on inventory.
+    let rowBudget = 0;
+    for (const op of ops) {
+        if (op.entity === "inventory") rowBudget += Math.max(1, op.movements ? op.movements.length : 0);
+    }
+    if (2 * ops.length + 1 + rowBudget > MovementLogic.MAX_TXN_WRITES)
+        return { ok: false, status: 400, error: "operation-too-large" };
+
     return { ok: true, requestId: requestId, opType: opType, ops: ops,
              clientTimestamp: (body && body.clientTimestamp) || null };
 }
@@ -137,8 +148,16 @@
                     before[field] = curVal;
                     after[field] = nextVal;
                 }
+                let movements = op.movements || [];
+                if (movements.length === 0 && op.entity === "inventory" && Object.prototype.hasOwnProperty.call(after, "stock"))
+                    movements = MovementLogic.deriveMovement(after.stock - before.stock,
+                        MovementLogic.DEFAULT_KIND_BY_OPTYPE[params.opType] || "adjustment");
+                if (movements.length > 0 && !MovementLogic.totalsMatch(movements, after.stock - before.stock)) {
+                    return { ok: false, status: 409, error: "movement-qty-mismatch",
+                             opIndex: i, field: "stock", current: before.stock };
+                }
                 entry.data = Object.assign({}, entry.data, after);
-                audits.push({ i: i, op: op, action: "delta", before: before, after: after });
+                audits.push({ i: i, op: op, action: "delta", before: before, after: after, movements: movements });
                 results.push({ entity: op.entity, entityId: op.entityId, kind: "delta", after: after });
             } else {
                 if (!_deepEqual(entry.data, op.before)) {
@@ -152,7 +171,7 @@
                     entry.exists = true;
                     entry.data = op.after || {};
                 }
-                audits.push({ i: i, op: op, action: op.action, before: op.before, after: op.after });
+                audits.push({ i: i, op: op, action: op.action, before: op.before, after: op.after, movements: [] });
                 results.push({ entity: op.entity, entityId: op.entityId, kind: "mutation",
                                after: op.action === "delete" ? null : (op.after || {}) });
             }
@@ -182,6 +201,19 @@
                 opType: params.opType,
                 opIndex: a.i
             });
+            const rows = MovementLogic.buildRows(a.movements, {
+                baseId: opAuditId(params.requestId, a.i),
+                productId: a.op.entityId,
+                actorUid: params.actorUid,
+                actorRole: params.actorRole,
+                serverTimestamp: params.serverTimestamp,
+                clientTimestamp: params.clientTimestamp,
+                requestId: opAuditId(params.requestId, a.i),
+                operationId: params.requestId,
+                opType: params.opType,
+                opIndex: a.i
+            });
+            for (const row of rows) txn.set(db.doc(tenantRoot + "/stock_movements/" + row.id), row.data);
         }
         // The marker is what makes a retry a no-op. Its id IS the requestId,
         // like every other audit_log entry.
```

Then the 3 existing `operationLogic.test.js` tests whose expectations change for a stated reason (a derived `sale` row adds one write; 200 inventory
ops no longer fit the write budget, so the two 200-op tests use `stock_batch` ops, which cost no movement row):

```diff
--- a/functions/test/operationLogic.test.js
+++ b/functions/test/operationLogic.test.js
@@ -90,7 +90,8 @@
 
 test("validateOperationRequest: MAX_OPS is exactly 200 (mirrored by Gateway.maxOperationOps)", () => {
     assert.equal(OperationLogic.MAX_OPS, 200);
-    const good = { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 } };
+    // stock_batch ops write no movement row, so 200 of them fit the write budget (P1 spec D8).
+    const good = { kind: "delta", entity: "stock_batch", entityId: "b1", deltas: { qtyRemaining: -1 } };
     const v = OperationLogic.validateOperationRequest({
         requestId: "completeOrder:t", opType: "completeOrder", ops: new Array(200).fill(good) });
     assert.equal(v.ok, true);
@@ -185,8 +186,8 @@
     assert.deepEqual(byPath[T + "transactions/tx1"].data, { kind: "sale" });
     assert.deepEqual(byPath[T + "stock_batches/b1"].options, { merge: false });
 
-    // 4 working docs + 4 per-op audit entries + 1 marker.
-    assert.equal(db.writes.length, 9);
+    // 4 working docs + 4 per-op audit entries + 1 marker + 1 server-derived "sale" movement row (P1).
+    assert.equal(db.writes.length, 10);
     const marker = byPath[T + "audit_log/completeOrder:o1:1"];
     assert.equal(marker.data.action, "operation");
     assert.equal(marker.data.opCount, 4);
@@ -359,8 +360,8 @@
     const docs = {};
     const ops = [];
     for (let i = 0; i < OperationLogic.MAX_OPS; i++) {
-        docs[T + "inventory/p" + i] = { stock: 5 };
-        ops.push(delta("inventory", "p" + i, { stock: -1 }, { stock: 0 }));
+        docs[T + "stock_batches/b" + i] = { qtyRemaining: 5 };
+        ops.push(delta("stock_batch", "b" + i, { qtyRemaining: -1 }, { qtyRemaining: 0 }));
     }
     const db = makeFakeDb(docs);
     const r = await OperationLogic.applyOperation(db, params(ops));
```

- [ ] **Step 4: Run to verify everything passes**

Run: `cd functions && node --test`
Expected: `# fail 0`; on `main` @ `6da373d` that is 232 existing + 59 new = 291 tests.
Coverage check (optional): `node --test --experimental-test-coverage` shows 100% line for the three `lib/` files.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/operationLogic.js functions/test/operationLogic.test.js functions/test/movementWiring.test.js
git commit -m "feat(p1): recordOperation writes/derives stock_movements rows in the operation transaction; write budget"
```

---

### Task 5: docs, test plan status, PR

**Files:**
- Modify: `AGENTS.md` (P1 bullet: mark S1a done), `README.md` (functions section: `movements` on `recordDelta`, derived rows on `recordOperation`, `stock_movement` closed), `docs/superpowers/test-plans/2026-09-24-p1-stock-movements-test-plan.md` (flip S1a rows to actual CI numbers), `CHECKPOINT.md`.
- Do NOT touch `SKILLS.md` unless a genuinely new lesson was learned (append-only, next free number).

- [ ] **Step 1: Mutation spot-check** (recommended): re-run the mutations listed in the test plan against the real files; each must make a test fail. Never leave a mutated file behind (`git diff` must show only the intended change).
- [ ] **Step 2: Update the docs above** with actual counts from `node --test` (count, do not copy).
- [ ] **Step 3: Confirm rules tests are untouched:** `git diff --stat main -- test/ firestore.rules` prints nothing.
- [ ] **Step 4: Push, open the PR, wait for the 5 CI checks, hand to Taher.** Taher deploys functions to dev (`firebase deploy --only functions`) and confirms with an unauthenticated POST to `recordDelta` returning `401 missing-token`, then runs the on-device checklist. S1b starts after that.
- [ ] **Step 5: Update `CHECKPOINT.md` step log** and end the session.

## Self-review (against the spec)

- D2 server-built row: Task 1 `buildRows` + "does not trust client-supplied identity fields"; Task 3 forged `id` test.
- D3 sum against the applied delta: Task 2 mismatch/clamp tests; Task 4 whole-operation rollback test.
- D4 kinds and direction: Task 1 (every kind, every wrong sign).
- D5 closed path: Task 2 (all three validators), Task 3 handler test.
- D6 movements only on inventory `stock` deltas via `recordDelta`; mutations reject them: Task 2 tests.
- D7 deterministic ids and replay: Task 2 and Task 4 replay tests.
- D8 write budget: Task 4 budget tests (166 ok / 167 rejected, explicit rows count, 200 stock_batch ops ok, largest operations at 499 and 401 writes).
- D9 fields: `valueAtCost` validation in Task 1; no `batchRef` anywhere.
- D11 derived defaults: Task 1 `deriveMovement` tests; Task 2 derived-adjustment, clamp and zero-change tests; Task 4 `sale` default and direction fallback.
- Placeholder scan: none. Names consistent across tasks.
