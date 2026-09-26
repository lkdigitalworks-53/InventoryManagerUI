# Atomic multi-write operations through the outbox — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make order completion (C-3) exactly-once and atomic by sending it as one replay-safe operation through the outbox, with timeouts, retry jitter and a server-first-when-online option on the Gateway.

**Architecture:** The client plans the writes with a pure function and sends them as one outbox item under a deterministic key; a new generic Cloud Function applies them in one Firestore transaction (all-or-nothing, replay returns the first result). Gateway gains a shared send helper with a timeout, jitter, and an await mode; `StuckWrites` counts timeouts.

**Tech Stack:** Qt 6 / QML (Felgo), `.pragma library` JS helpers, Firebase Cloud Functions (Node 20, `node --test`), Firestore.

**Spec:** `docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md`
**Test plan:** `docs/superpowers/test-plans/2026-09-20-atomic-operation-outbox-test-plan.md`

## Global Constraints

- One branch per phase, cut from current `main`; never commit to `main`. Every commit carries `Taher (via Claude session) <tsowner@lkdigitalworks.com>` (repo convention; confirm with Taher).
- Push each branch and open a PR; Taher reviews in GitHub. Do not build or run the app until Taher says so. Do not install Qt tooling in the sandbox: QML tests are verified by the CI run only.
- Tests for every change: happy path, negative, edge cases, multiple scenarios, monkey. Update `SKILLS.md`, `AGENTS.md`, `README.md` and the tracker in the same PR that changes behaviour.
- Constants copied from the spec: `MAX_OPS = 200` (server `operationLogic.js`, client `Gateway.maxOperationOps` and `CompletionPlan.MAX_OPS`); `opType` allowlist `["completeOrder"]`; `TIMEOUT_BACKGROUND_MS = 30000`; `TIMEOUT_AWAIT_MS = 10000`; jitter +-20%; drift-repair note `Adjustment (drift repair)`; keys `completeOrder:{orderId}:{epoch}`, sale docs `tx-s-{orderId}-{epoch}-{line}`, repair batches `BAT-RPR-{orderId}-{epoch}-{line}`.
- Cloud Function deploy is Taher's job and must happen before the client phase ships (dev environment only).

## Status legend (be honest about what has actually been run)

- **Verified in the sandbox:** Task 1, Task 2 (Node: 228/228 functions tests pass with these files applied to a scratch copy; 14/14 deliberate mutations caught) and the *logic* of Tasks 3-5 (68 test bodies, 47 of them new and 21 being #75's existing `StuckWrites` tests, executed in Node through a shim; 21/21 deliberate mutations caught). Merged as #78/#79; the QML portion (Tasks 3-5) subsequently ran for real under `qmltestrunner` in CI and passed.
- **Verified in CI (2026-09-25, PR #83):** Tasks 6-8, implemented and merged as real `qmltestrunner` runs (28/28 new QML tests passing), NOT as drafted below. Task 7 in particular departs from this document's original design: no shared `_xhrPost` helper or injectable `xhrFactory` -- the real `_send`/`_sendBatch`/`_sendDelta` had grown far more elaborate than assumed here (a QTBUG-49896 workaround, CAS-conflict parsing, terminal-batch-error handling), so each sender instead got its own settled-flag `Timer` (the proven `AuthService._postJson` pattern), later deduplicated into a shared `_armSendTimeout`. No new test files were created (`tst_Gateway_send.qml`/`tst_Gateway_operation.qml` as drafted below do not exist); cases were appended to the existing `tst_Gateway.qml` instead. Treat Tasks 6-8's code below as historical design intent, not as what shipped -- read PR #83 (and the corresponding rows in the test plan) for the real implementation.
- **Not executed anywhere yet:** Tasks 9-11 (store hooks, `DataModel`, UI). Written without a Qt toolchain; CI is their first run. Treat their code as a careful draft, and re-read the live files fresh before implementing -- Task 7 already proved once that this document's draft code can be stale relative to how much the real files have grown since it was written.

## File structure

| File | Responsibility | Task |
|---|---|---|
| `functions/lib/operationLogic.js` (new) | validate + apply one atomic multi-op transaction | 1 |
| `functions/index.js` | `recordOperation` HTTPS handler | 2 |
| `functions/test/testSupport/handlerHarness.js` | mock `applyOperation` | 2 |
| `qml/helper/StuckWrites.js` | timeouts count while online | 3 |
| `qml/helper/SendPolicy.js` (new) | timeout values, jitter | 4 |
| `qml/helper/OperationKeys.js` (new) | deterministic keys and ids | 4 |
| `qml/helper/CompletionPlan.js` (new) | pure planner | 5 |
| `qml/model/OutboxStore.qml` | `op` items, per-key ordering, jitter | 6 |
| `qml/model/Gateway.qml` | send helper + timeout, `recordOperation`, await mode, signals | 7, 8 |
| `qml/model/{Inventory,StockBatch,Orders,Transaction}Store.qml` | local-only hooks, `buildOrderUpdate`, `buildSaleDocs` | 9 |
| `qml/model/DataModel.qml` | `_tryCompleteOrder` on the operation | 10 |
| `qml/pages/*` | "saved, syncing" state | 11 |
| docs | SKILLS/AGENTS/README/tracker/test plan | 12 |

---

# Phase 1 — Server (start now; independent of PR #75)

Branch: `feature/2026-09-21-record-operation-endpoint`

### Task 1: `operationLogic.js` — atomic multi-op transaction

**Files:**
- Create: `functions/lib/operationLogic.js`
- Test: `functions/test/operationLogic.test.js`

**Interfaces:**
- Consumes: `validateDeltaRequest`, `validateMutationRequest`, `_deepEqual` from `functions/lib/gatewayLogic.js` (already exported).
- Produces: `MAX_OPS`, `OP_TYPES`, `validateOperationRequest(body)`, `applyOperation(db, params)`, `opAuditId(requestId, index)`.

- [ ] **Step 1: Write the failing test**

Create `functions/test/operationLogic.test.js`:

```js
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && node --test test/operationLogic.test.js`
Expected: FAIL, `Cannot find module '../lib/operationLogic'`.

- [ ] **Step 3: Write the implementation**

Create `functions/lib/operationLogic.js`:

```js
"use strict";

// One atomic, idempotent multi-write operation. Design:
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// A "compound" business operation (order completion today) touches several
// working-tier docs at once. Sent as N separate recordDelta/recordMutation
// calls it is neither atomic nor replay-safe as a unit. This module applies the
// whole list in ONE Firestore transaction: every op lands or none does, and a
// retry of the same requestId is a no-op that returns the first result.
//
// Zero Firebase SDK dependency - same dependency-injection pattern as
// gatewayLogic.js / batchMutationLogic.js.

const {
    validateMutationRequest,
    validateDeltaRequest,
    _deepEqual
} = require("./gatewayLogic");

// 200 ops = up to 200 working-doc writes + 200 per-op audit entries + 1 marker
// = 401 writes, under Firestore's ~500-writes-per-transaction ceiling. Mirrored
// client-side as Gateway.qml's `maxOperationOps` (no shared build-time constant
// between this Node runtime and the QML client); both sides pin the value in a
// test so drift fails a test instead of failing in production.
const MAX_OPS = 200;

// Allowlist so the audit trail never carries a free-form client string.
// Adding an operation type is a server deploy on purpose.
const OP_TYPES = ["completeOrder"];

// Validates + normalizes a recordOperation request body. Reuses the single-item
// validators per op (with a derived per-op request id) so entity/action/delta
// rules stay defined in exactly one place. Returns
// { ok: true, requestId, opType, ops, clientTimestamp } or
// { ok: false, status, error, opIndex? }.
function validateOperationRequest(body) {
    const requestId = String((body && body.requestId) || "");
    const opType = String((body && body.opType) || "");
    const rawOps = (body && Array.isArray(body.ops)) ? body.ops : [];

    if (!requestId || !opType) return { ok: false, status: 400, error: "missing-fields" };
    if (OP_TYPES.indexOf(opType) < 0) return { ok: false, status: 400, error: "unsupported-op-type" };
    if (rawOps.length === 0) return { ok: false, status: 400, error: "empty-operation" };
    if (rawOps.length > MAX_OPS) return { ok: false, status: 400, error: "operation-too-large" };

    const ops = [];
    for (let i = 0; i < rawOps.length; i++) {
        const raw = rawOps[i] || {};
        const perOp = Object.assign({}, raw, { requestId: opAuditId(requestId, i) });
        let v;
        if (raw.kind === "delta") v = validateDeltaRequest(perOp);
        else if (raw.kind === "mutation") v = validateMutationRequest(perOp);
        else return { ok: false, status: 400, error: "unsupported-kind", opIndex: i };
        if (!v.ok) return Object.assign({}, v, { opIndex: i });
        ops.push(Object.assign({ kind: raw.kind }, v));
    }
    return { ok: true, requestId: requestId, opType: opType, ops: ops,
             clientTimestamp: (body && body.clientTimestamp) || null };
}

function opAuditId(requestId, index) { return requestId + ":" + index; }

// Applies every op in one transaction. Reads first (Firestore requires all
// reads before any write), computes the whole result in memory, and only if
// every op is acceptable writes anything. A rejection therefore leaves NO trace
// (no working-doc write, no audit entry, no marker), so the same requestId can
// safely be retried later with a re-planned payload.
//
// Returns { ok: true, results, idempotentReplay? } or
// { ok: false, status, error, opIndex, field?, current?, conflict? }.
async function applyOperation(db, params) {
    const tenantRoot = "tenants/" + params.tenantId;
    const markerRef = db.doc(tenantRoot + "/audit_log/" + params.requestId);

    return db.runTransaction(async (txn) => {
        const existing = await txn.get(markerRef);
        if (existing.exists) {
            return { ok: true, idempotentReplay: true, results: existing.data().results };
        }

        // One read per distinct working doc; later ops see earlier ops' effects.
        const state = {};   // path -> { ref, existed, exists, data }
        for (const op of params.ops) {
            const path = tenantRoot + "/" + op.collection + "/" + op.entityId;
            if (state[path]) continue;
            const ref = db.doc(path);
            const snap = await txn.get(ref);
            state[path] = { ref: ref, existed: snap.exists, exists: snap.exists,
                            data: snap.exists ? snap.data() : null };
        }

        const audits = [];
        const results = [];
        for (let i = 0; i < params.ops.length; i++) {
            const op = params.ops[i];
            const entry = state[tenantRoot + "/" + op.collection + "/" + op.entityId];

            if (op.kind === "delta") {
                if (!entry.exists) return { ok: false, status: 404, error: "not-found", opIndex: i };
                const before = {};
                const after = {};
                for (const field in op.deltas) {
                    const curVal = entry.data[field] || 0;
                    let nextVal = curVal + op.deltas[field];
                    if (Object.prototype.hasOwnProperty.call(op.floors, field) && nextVal < op.floors[field]) {
                        return { ok: false, status: 409, error: "insufficient-quantity",
                                 opIndex: i, field: field, current: curVal };
                    }
                    if (Object.prototype.hasOwnProperty.call(op.clamps, field) && nextVal < op.clamps[field]) {
                        nextVal = op.clamps[field];
                    }
                    before[field] = curVal;
                    after[field] = nextVal;
                }
                entry.data = Object.assign({}, entry.data, after);
                audits.push({ i: i, op: op, action: "delta", before: before, after: after });
                results.push({ entity: op.entity, entityId: op.entityId, kind: "delta", after: after });
            } else {
                if (!_deepEqual(entry.data, op.before)) {
                    return { ok: false, status: 409, error: "conflict", conflict: true,
                             opIndex: i, current: entry.data };
                }
                if (op.action === "delete") {
                    entry.exists = false;
                    entry.data = null;
                } else {
                    entry.exists = true;
                    entry.data = op.after || {};
                }
                audits.push({ i: i, op: op, action: op.action, before: op.before, after: op.after });
                results.push({ entity: op.entity, entityId: op.entityId, kind: "mutation",
                               after: op.action === "delete" ? null : (op.after || {}) });
            }
        }

        // Every op accepted: now (and only now) write.
        for (const path in state) {
            const entry = state[path];
            if (entry.exists) txn.set(entry.ref, entry.data, { merge: false });
            else if (entry.existed) txn.delete(entry.ref);
        }
        for (const a of audits) {
            txn.set(db.doc(tenantRoot + "/audit_log/" + opAuditId(params.requestId, a.i)), {
                entryId: opAuditId(params.requestId, a.i),
                tenantId: params.tenantId,
                actorUid: params.actorUid,
                actorRole: params.actorRole,
                action: a.action,
                entity: a.op.entity,
                entityId: a.op.entityId,
                before: a.before,
                after: a.after,
                serverTimestamp: params.serverTimestamp,
                clientTimestamp: params.clientTimestamp,
                requestId: opAuditId(params.requestId, a.i),
                operationId: params.requestId,
                opType: params.opType,
                opIndex: a.i
            });
        }
        // The marker is what makes a retry a no-op. Its id IS the requestId,
        // like every other audit_log entry.
        txn.set(markerRef, {
            entryId: params.requestId,
            tenantId: params.tenantId,
            actorUid: params.actorUid,
            actorRole: params.actorRole,
            action: "operation",
            opType: params.opType,
            opCount: params.ops.length,
            results: results,
            serverTimestamp: params.serverTimestamp,
            clientTimestamp: params.clientTimestamp,
            requestId: params.requestId
        });
        return { ok: true, results: results };
    });
}

module.exports = { MAX_OPS, OP_TYPES, validateOperationRequest, applyOperation, opAuditId };
```

- [ ] **Step 4: Run the tests**

Run: `cd functions && node --test test/operationLogic.test.js`
Expected: PASS, 20 tests, 0 failures. With `--experimental-test-coverage`, `operationLogic.js` shows 100% line, branch and function coverage.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/operationLogic.js functions/test/operationLogic.test.js
git commit -m "feat(functions): atomic multi-op transaction logic (operationLogic)"
```

### Task 2: `recordOperation` endpoint

**Files:**
- Modify: `functions/index.js` (require + new handler, placed just before the `// Component 2 (async-write-sequencing design). Pessimistic record locking` comment)
- Modify: `functions/test/testSupport/handlerHarness.js`
- Test: `functions/test/index.handlers.recordOperation.test.js` (new)

**Interfaces:**
- Consumes: `OperationLogic.validateOperationRequest`, `OperationLogic.applyOperation` (Task 1); `GatewayLogic.parseBearerToken`, `scopedDb`, `deriveContext`, `send`, `FieldValue` already in `index.js`.
- Produces: HTTPS `recordOperation`. Success `200 { ok: true, entryId, results, idempotentReplay }`. Rejections `409/404` with `{ ok: false, error, opIndex, field, current, conflict }`; `400` with `{ ok: false, error, opIndex }`; plus the standard 401/403/405/500 bodies.

- [ ] **Step 1: Write the failing handler tests**

Create `functions/test/index.handlers.recordOperation.test.js`:

```js
"use strict";

// Handler-level tests for functions/index.js's recordOperation endpoint, in the
// same shape as recordDelta's block in index.handlers.test.js: auth, request
// wiring, and - the seam that matters - whether the lib/ result is forwarded
// into the HTTP response without dropping or renaming a field (opIndex, field,
// current, conflict, results, idempotentReplay). The transaction logic itself is
// covered by operationLogic.test.js; applyOperation is mocked here.

const test = require("node:test");
const assert = require("node:assert/strict");
const { installMocks, seedHappyPathAuth, mockReq, mockRes, jsonBody } = require("./testSupport/handlerHarness");

const { handlers, mockState } = installMocks();

function validOperationBody(overrides) {
    return Object.assign({
        env: "test", requestId: "completeOrder:o1:1", opType: "completeOrder", clientTimestamp: 12345,
        ops: [{ kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 }, floors: { stock: 0 } }]
    }, overrides || {});
}

test("recordOperation: success returns 200 with ok, entryId, results and idempotentReplay:false", async () => {
    seedHappyPathAuth(mockState);
    const results = [{ entity: "inventory", entityId: "p1", kind: "delta", after: { stock: 4 } }];
    mockState.applyOperationResult = { ok: true, results: results };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(jsonBody(res), { ok: true, entryId: "completeOrder:o1:1", results: results, idempotentReplay: false });
});

test("recordOperation: a replay is forwarded as idempotentReplay:true with the stored results", async () => {
    seedHappyPathAuth(mockState);
    const results = [{ entity: "inventory", entityId: "p1", kind: "delta", after: { stock: 4 } }];
    mockState.applyOperationResult = { ok: true, idempotentReplay: true, results: results };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 200);
    assert.equal(jsonBody(res).idempotentReplay, true);
    assert.deepEqual(jsonBody(res).results, results);
});

test("recordOperation: a floor rejection forwards error/opIndex/field/current unmodified (0 survives)", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyOperationResult = { ok: false, status: 409, error: "insufficient-quantity", opIndex: 0, field: "stock", current: 0 };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 409);
    const body = jsonBody(res);
    assert.equal(body.ok, false);
    assert.equal(body.error, "insufficient-quantity");
    assert.equal(body.opIndex, 0);          // 0 is falsy - must survive
    assert.equal(body.field, "stock");
    assert.equal(body.current, 0);
});

test("recordOperation: a CAS conflict forwards conflict:true and the server's current doc", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyOperationResult = { ok: false, status: 409, error: "conflict", conflict: true, opIndex: 2, current: { status: "completed" } };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 409);
    assert.equal(jsonBody(res).conflict, true);
    assert.equal(jsonBody(res).opIndex, 2);
    assert.deepEqual(jsonBody(res).current, { status: "completed" });
});

test("recordOperation: a rejection without a status falls back to 409", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyOperationResult = { ok: false, error: "conflict" };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 409);
});

test("recordOperation: a 404 from applyOperation is forwarded with its op index", async () => {
    seedHappyPathAuth(mockState);
    mockState.applyOperationResult = { ok: false, status: 404, error: "not-found", opIndex: 3 };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 404);
    assert.equal(jsonBody(res).opIndex, 3);
});

test("recordOperation: missing Authorization header -> 401 missing-token", async () => {
    const res = mockRes();
    await handlers.recordOperation(mockReq({ headers: { origin: "http://localhost" }, body: validOperationBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "missing-token");
});

test("recordOperation: verifyIdToken throwing -> 401 invalid-token", async () => {
    mockState.verifyIdToken = async () => { throw new Error("bad token"); };
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 401);
    assert.equal(jsonBody(res).error, "invalid-token");
});

test("recordOperation: authenticated but no matching user/tenant doc -> 403 no-tenant-context", async () => {
    mockState.verifyIdToken = async () => ({ uid: "ghost-uid" });
    mockState.docs = {};
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
    assert.equal(res.statusCode, 403);
    assert.equal(jsonBody(res).error, "no-tenant-context");
});

test("recordOperation: invalid op -> 400 from validateOperationRequest with the failing opIndex", async () => {
    seedHappyPathAuth(mockState);
    const body = validOperationBody({
        ops: [
            { kind: "delta", entity: "inventory", entityId: "p1", deltas: { stock: -1 } },
            { kind: "delta", entity: "nope", entityId: "x", deltas: { a: 1 } }
        ]
    });
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: body }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "unsupported-entity");
    assert.equal(jsonBody(res).opIndex, 1);
});

test("recordOperation: empty envelope -> 400 missing-fields", async () => {
    seedHappyPathAuth(mockState);
    const res = mockRes();
    await handlers.recordOperation(mockReq({ body: {} }), res);
    assert.equal(res.statusCode, 400);
    assert.equal(jsonBody(res).error, "missing-fields");
});

test("recordOperation: GET request -> 405 method-not-allowed", async () => {
    const res = mockRes();
    await handlers.recordOperation(mockReq({ method: "GET" }), res);
    assert.equal(res.statusCode, 405);
    assert.equal(jsonBody(res).error, "method-not-allowed");
});

test("recordOperation: applyOperation throwing -> 500 write-failed, not an unhandled rejection", async () => {
    seedHappyPathAuth(mockState);
    const operationLogicPath = require.resolve("../lib/operationLogic");
    const cached = require.cache[operationLogicPath].exports;
    const original = cached.applyOperation;
    cached.applyOperation = async () => { throw new Error("simulated Firestore failure"); };
    try {
        const res = mockRes();
        await handlers.recordOperation(mockReq({ body: validOperationBody() }), res);
        assert.equal(res.statusCode, 500);
        assert.equal(jsonBody(res).error, "write-failed");
    } finally {
        cached.applyOperation = original;
    }
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd functions && node --test test/index.handlers.recordOperation.test.js`
Expected: FAIL (`handlers.recordOperation is not a function`).

- [ ] **Step 3: Apply the harness and handler edits**

Save as `harness.patch` and run `git apply harness.patch`:

```diff
--- a/functions/test/testSupport/handlerHarness.js
+++ b/functions/test/testSupport/handlerHarness.js
@@ -63,6 +63,7 @@
     const firestorePath = resolveFromFunctionsRoot("firebase-admin/firestore");
     const gatewayLogicPath = require.resolve("../../lib/gatewayLogic");
     const batchMutationLogicPath = require.resolve("../../lib/batchMutationLogic");
+    const operationLogicPath = require.resolve("../../lib/operationLogic");
     const lockLogicPath = require.resolve("../../lib/lockLogic");
     const cutoverLogicPath = require.resolve("../../lib/cutoverLogic");
 
@@ -76,6 +77,7 @@
         applyMutationResult: null,
         applyDeltaResult: null,
         applyMutationsBatchResult: null,
+        applyOperationResult: null,
         acquireLockResult: null,
         acquireLockError: null,
         acquireLockCalls: [],
@@ -200,6 +202,13 @@
             applyMutationsBatch: async () => mockState.applyMutationsBatchResult
         })
     };
+    const realOperationLogic = require(operationLogicPath);
+    require.cache[operationLogicPath] = {
+        id: operationLogicPath, filename: operationLogicPath, loaded: true,
+        exports: Object.assign({}, realOperationLogic, {
+            applyOperation: async () => mockState.applyOperationResult
+        })
+    };
     const realLockLogic = require(lockLogicPath);
     require.cache[lockLogicPath] = {
         id: lockLogicPath, filename: lockLogicPath, loaded: true,
```

Save as `index.patch` and run `git apply index.patch`:

```diff
--- a/functions/index.js
+++ b/functions/index.js
@@ -24,6 +24,7 @@
 const GatewayLogic = require("./lib/gatewayLogic");
 const CutoverLogic = require("./lib/cutoverLogic");
 const BatchMutationLogic = require("./lib/batchMutationLogic");
+const OperationLogic = require("./lib/operationLogic");
 const LockLogic = require("./lib/lockLogic");
 const { send } = require("./lib/httpResponse");
 
@@ -243,6 +244,82 @@
         send(res, 200, { ok: true, entryId: validated.requestId, after: result.after });
     });
 
+// Atomic multi-write operation (order completion today). One request carries a
+// list of delta/mutation ops for several working-tier docs; they are applied in
+// ONE Firestore transaction, all-or-nothing, keyed by a stable requestId so a
+// retry is a no-op. See lib/operationLogic.js and
+// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md.
+exports.recordOperation = functions.onRequest(
+    { region: "asia-south1", cors: true },
+    async (req, res) => {
+        if (req.method === "OPTIONS") { send(res, 204, {}); return; }
+        if (req.method !== "POST") {
+            send(res, 405, { ok: false, error: "method-not-allowed" });
+            return;
+        }
+
+        const token = GatewayLogic.parseBearerToken(req.get("Authorization"));
+        if (!token) {
+            send(res, 401, { ok: false, error: "missing-token" });
+            return;
+        }
+
+        let decoded;
+        try {
+            decoded = await admin.auth().verifyIdToken(token);
+        } catch (e) {
+            send(res, 401, { ok: false, error: "invalid-token" });
+            return;
+        }
+        const actorUid = decoded.uid;
+
+        const body = req.body || {};
+        const db = scopedDb(body.env);
+
+        const validated = OperationLogic.validateOperationRequest(body);
+        if (!validated.ok) {
+            send(res, validated.status, { ok: false, error: validated.error, opIndex: validated.opIndex });
+            return;
+        }
+
+        const ctx = await deriveContext(db, actorUid);
+        if (!ctx) {
+            send(res, 403, { ok: false, error: "no-tenant-context" });
+            return;
+        }
+
+        let result;
+        try {
+            result = await OperationLogic.applyOperation(db, {
+                tenantId: ctx.tenantId,
+                actorUid: actorUid,
+                actorRole: ctx.role,
+                requestId: validated.requestId,
+                opType: validated.opType,
+                ops: validated.ops,
+                clientTimestamp: validated.clientTimestamp,
+                serverTimestamp: FieldValue.serverTimestamp()
+            });
+        } catch (e) {
+            console.error("recordOperation write failed", e);
+            send(res, 500, { ok: false, error: "write-failed" });
+            return;
+        }
+
+        if (result && result.ok === false) {
+            send(res, result.status || 409, {
+                ok: false, error: result.error, opIndex: result.opIndex,
+                field: result.field, current: result.current, conflict: result.conflict
+            });
+            return;
+        }
+
+        send(res, 200, {
+            ok: true, entryId: validated.requestId, results: result.results,
+            idempotentReplay: result.idempotentReplay === true
+        });
+    });
+
 // Component 2 (async-write-sequencing design). Pessimistic record locking —
 // see functions/lib/lockLogic.js for the acquire/renew/reject semantics and
 // why this needs no cleanup job (TTL expiry is the safety net, not an
```

- [ ] **Step 4: Run the whole functions suite**

Run: `cd functions && node --test`
Expected: all pass (228 in the verification run: 195 existing + the 33 new), 0 failures. The `OPTIONS` early-return in the new handler is uncovered by design, exactly like its three siblings (the `cors` middleware answers preflight before handler code runs; see the note in `index.handlers.test.js`).

- [ ] **Step 5: Commit, push, PR**

```bash
git add functions/index.js functions/test/testSupport/handlerHarness.js functions/test/index.handlers.recordOperation.test.js
git commit -m "feat(functions): recordOperation endpoint (atomic, idempotent multi-write)"
git push -u origin feature/2026-09-21-record-operation-endpoint
```

Open the PR. **Taher deploys it to dev** (`firebase deploy --only functions:recordOperation`) before any Phase 3 work is tried on a device.

---

# Phase 2 — Pure client helpers (start now; independent of PR #75 except Task 3's base file)

Branch: `feature/2026-09-21-operation-helpers`. Task 3 edits `StuckWrites.js` from PR #75, so cut this branch after #75 merges (or stack it on #75's branch).

### Task 3: `StuckWrites` — timeouts count while online (D5)

**Files:**
- Modify: `qml/helper/StuckWrites.js`
- Test: `tests/tst_StuckWrites.qml` (append)

**Interfaces:**
- Produces: `StuckWrites.TIMEOUT` (`"timeout"`), `isStuckStatus(status, online)`, `noteFailure(state, requestId, status, online)`. Numeric statuses ignore `online`; `TIMEOUT` counts only when `online === true`.

- [ ] **Step 1: Append the failing tests** before the closing `}` of `tests/tst_StuckWrites.qml`:

```qml

    // -- timeouts (D5, 2026-09-20): a hang while online is a stuck write --------

    function test_isStuckStatus_timeout_counts_only_while_online() {
        compare(SW.isStuckStatus(SW.TIMEOUT, true), true)
        compare(SW.isStuckStatus(SW.TIMEOUT, false), false)
        compare(SW.isStuckStatus(SW.TIMEOUT), false, "unknown connectivity is not evidence of a hang")
        compare(SW.isStuckStatus(SW.TIMEOUT, "yes"), false, "only a real boolean true counts")
    }

    function test_isStuckStatus_numeric_statuses_ignore_the_online_flag() {
        compare(SW.isStuckStatus(500, true), true)
        compare(SW.isStuckStatus(500, false), true, "the server answered, so connectivity is irrelevant")
        compare(SW.isStuckStatus(0, true), false)
        compare(SW.isStuckStatus(409, true), false)
    }

    function test_noteFailure_timeouts_online_tip_at_the_threshold() {
        var s = SW.newState()
        var tipped = 0
        for (var i = 0; i < SW.THRESHOLD; ++i)
            if (SW.noteFailure(s, "r1", SW.TIMEOUT, true)) tipped++
        compare(tipped, 1)
        compare(SW.stuckCount(s), 1)
    }

    function test_noteFailure_timeouts_offline_never_tip() {
        var s = SW.newState()
        for (var i = 0; i < SW.THRESHOLD * 3; ++i)
            compare(SW.noteFailure(s, "r1", SW.TIMEOUT, false), false)
        compare(SW.stuckCount(s), 0)
    }

    function test_noteFailure_timeouts_and_server_errors_share_one_counter() {
        var s = SW.newState()
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, true), false)
        compare(SW.noteFailure(s, "r1", 503, true), false)
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, true), false)
        compare(SW.noteFailure(s, "r1", 500, true), false)
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, true), true, "the 5th failure of any counted kind tips it")
    }

    function test_noteFailure_a_timeout_while_offline_does_not_reset_earlier_online_failures() {
        var s = SW.newState()
        for (var i = 0; i < 4; ++i) SW.noteFailure(s, "r1", SW.TIMEOUT, true)
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, false), false)
        compare(SW.noteFailure(s, "r1", SW.TIMEOUT, true), true)
    }
```

- [ ] **Step 2: Push and confirm CI's QML job fails** on `SW.TIMEOUT` being undefined (no local runner).

- [ ] **Step 3: Apply the change** (`git apply`):

```diff
--- a/qml/helper/StuckWrites.js
+++ b/qml/helper/StuckWrites.js
@@ -8,9 +8,10 @@
 // (tests/tst_StuckWrites.qml).
 //
 // A queued write is "stuck" once it has failed THRESHOLD times with a
-// server-side status. Offline (status 0), 401 (token refresh) and 409 (CAS
-// conflict, dropped elsewhere) never count: they resolve on their own or the
-// write leaves the outbox. Retry, backoff and dropping are not decided here.
+// server-side status, or timed out while the device is online. Offline (status 0),
+// 401 (token refresh) and 409 (CAS conflict, dropped elsewhere) never count: they
+// resolve on their own or the write leaves the outbox. Retry, backoff and dropping
+// are not decided here.
 
 // 5 server-side failures is about 3 minutes with OutboxStore's backoff
 // ([2s, 8s, 30s, 2m, 10m]): long enough to ride out a deploy blip.
@@ -19,14 +20,20 @@
 // state = { failures: { requestId: count }, stuck: { requestId: true } }
 function newState() { return { failures: {}, stuck: {} } }
 
-function isStuckStatus(status) {
+// A request that timed out (Gateway aborted it) is reported as TIMEOUT, not as
+// status 0. It counts only while the device believes it is online: a hang with
+// a working network is a stuck write, a timeout while offline is expected.
+var TIMEOUT = "timeout"
+
+function isStuckStatus(status, online) {
+    if (status === TIMEOUT) return online === true
     return status >= 400 && status !== 401 && status !== 409
 }
 
 // Records one failed send. Returns true only for the failure that tips the item
 // over THRESHOLD, so the caller can react once per item.
-function noteFailure(state, requestId, status) {
-    if (!isStuckStatus(status)) return false
+function noteFailure(state, requestId, status, online) {
+    if (!isStuckStatus(status, online)) return false
     var n = (state.failures[requestId] || 0) + 1
     state.failures[requestId] = n
     if (n !== THRESHOLD) return false
```

- [ ] **Step 4: Push and confirm CI's QML job passes.** The 21 existing StuckWrites tests must still pass (they did in the Node shim run, together with the 6 new ones: 27/27).

- [ ] **Step 5: Commit**

```bash
git add qml/helper/StuckWrites.js tests/tst_StuckWrites.qml
git commit -m "feat: StuckWrites counts timeouts while online (D5)"
```

### Task 4: `SendPolicy` and `OperationKeys`

**Files:**
- Create: `qml/helper/SendPolicy.js`, `qml/helper/OperationKeys.js`
- Test: `tests/tst_SendPolicy.qml`, `tests/tst_OperationKeys.qml` (new)

**Interfaces:**
- Produces: `SendPolicy.TIMEOUT_BACKGROUND_MS`, `TIMEOUT_AWAIT_MS`, `JITTER_FRACTION`, `timeoutMs(awaiting)`, `jittered(delayMs, rand)`; `OperationKeys.nextEpoch(order)`, `completeOrderKey(orderId, epoch)`, `saleTxId(orderId, epoch, lineIndex)`, `repairBatchId(orderId, epoch, lineIndex)`.

- [ ] **Step 1: Write the failing tests**

`tests/tst_SendPolicy.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/SendPolicy.js" as SP

// Headless tests for Gateway's send-timeout and retry-jitter arithmetic. Pure JS,
// no singletons. Design: docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
TestCase {
    name: "SendPolicy"

    // Small deterministic PRNG (LCG) so a failing monkey run reproduces from its seed.
    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function test_timeoutMs_uses_the_short_value_while_a_person_is_waiting() {
        compare(SP.timeoutMs(true), SP.TIMEOUT_AWAIT_MS)
        compare(SP.timeoutMs(false), SP.TIMEOUT_BACKGROUND_MS)
    }

    function test_timeout_values_are_pinned_and_ordered() {
        compare(SP.TIMEOUT_AWAIT_MS, 10000)
        compare(SP.TIMEOUT_BACKGROUND_MS, 30000)
        verify(SP.TIMEOUT_AWAIT_MS < SP.TIMEOUT_BACKGROUND_MS, "the foreground wait must be the shorter one")
    }

    function test_jittered_bounds_and_midpoint() {
        compare(SP.jittered(1000, 0), 800)
        compare(SP.jittered(1000, 0.5), 1000)
        compare(SP.jittered(1000, 0.999999), 1200)
    }

    function test_jittered_is_monotonic_in_rand() {
        var prev = -1
        for (var i = 0; i < 100; ++i) {
            var v = SP.jittered(30000, i / 100)
            verify(v >= prev, "not monotonic at " + i)
            prev = v
        }
    }

    function test_jittered_invalid_rand_falls_back_to_no_jitter() {
        var bad = [undefined, null, NaN, -0.1, 1, 2, "0.3"]
        for (var i = 0; i < bad.length; ++i)
            compare(SP.jittered(2000, bad[i]), 2000, "rand " + bad[i])
    }

    function test_jittered_zero_delay_stays_zero() {
        compare(SP.jittered(0, 0.9), 0)
    }

    // Monkey: every delay of the real outbox schedule stays within +-20% and integral.
    function test_monkey_jitter_stays_inside_its_band_for_the_whole_backoff_schedule() {
        var schedule = [2000, 8000, 30000, 120000, 600000]
        var rand = _rng(20260920)
        for (var n = 0; n < 500; ++n) {
            var d = schedule[n % schedule.length]
            var j = SP.jittered(d, rand())
            verify(j >= Math.round(d * 0.8) && j <= Math.round(d * 1.2), "out of band: " + d + " -> " + j)
            compare(j, Math.round(j))
        }
    }
}
```

`tests/tst_OperationKeys.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/OperationKeys.js" as OK

// Headless tests for the deterministic ids behind the atomic order-completion
// operation. Pure JS, no singletons.
TestCase {
    name: "OperationKeys"

    function test_nextEpoch_first_completion_is_epoch_1() {
        compare(OK.nextEpoch(null), 1)
        compare(OK.nextEpoch(undefined), 1)
        compare(OK.nextEpoch({}), 1)
        compare(OK.nextEpoch({ completionEpoch: 0 }), 1)
    }

    function test_nextEpoch_increments_a_stored_epoch() {
        compare(OK.nextEpoch({ completionEpoch: 1 }), 2)
        compare(OK.nextEpoch({ completionEpoch: 7 }), 8)
    }

    function test_nextEpoch_ignores_a_non_numeric_epoch() {
        compare(OK.nextEpoch({ completionEpoch: "2" }), 1)
        compare(OK.nextEpoch({ completionEpoch: null }), 1)
    }

    function test_completeOrderKey_format_and_determinism() {
        compare(OK.completeOrderKey("ORD-1", 1), "completeOrder:ORD-1:1")
        compare(OK.completeOrderKey("ORD-1", 1), OK.completeOrderKey("ORD-1", 1))
    }

    function test_completeOrderKey_differs_per_order_and_per_epoch() {
        verify(OK.completeOrderKey("ORD-1", 1) !== OK.completeOrderKey("ORD-2", 1))
        verify(OK.completeOrderKey("ORD-1", 1) !== OK.completeOrderKey("ORD-1", 2))
    }

    function test_saleTxId_keeps_its_prefix_and_is_unique_per_line() {
        compare(OK.saleTxId("ORD-1", 2, 0), "tx-s-ORD-1-2-0")
        verify(OK.saleTxId("ORD-1", 2, 0) !== OK.saleTxId("ORD-1", 2, 1))
        verify(OK.saleTxId("ORD-1", 2, 0) !== OK.saleTxId("ORD-1", 3, 0))
    }

    function test_repairBatchId_is_deterministic_and_unique_per_line() {
        compare(OK.repairBatchId("ORD-1", 1, 3), "BAT-RPR-ORD-1-1-3")
        verify(OK.repairBatchId("ORD-1", 1, 3) !== OK.repairBatchId("ORD-1", 1, 4))
    }
}
```

- [ ] **Step 2: Push, confirm CI's QML job fails** (modules missing).

- [ ] **Step 3: Write the implementations**

`qml/helper/SendPolicy.js`:

```js
.pragma library

// Pure numbers and arithmetic behind Gateway's send timeouts and retry jitter.
// Design: docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// Gateway owns the Timer and the XHR; nothing here touches QML, the outbox or the
// network, so it has a headless test (tests/tst_SendPolicy.qml).
//
// Both timeouts are starting values, NOT measured: tune them on a device after the
// first real runs (Cloud Function cold starts in asia-south1 are the thing to watch).

// Background outbox drain: nobody is waiting, so be generous.
var TIMEOUT_BACKGROUND_MS = 30000

// Foreground "server first" wait: a person is looking at a spinner, so be short.
var TIMEOUT_AWAIT_MS = 10000

// +-20% around the outbox backoff delay, so two devices that reconnect together do
// not retry in lockstep.
var JITTER_FRACTION = 0.2

function timeoutMs(awaiting) {
    return awaiting ? TIMEOUT_AWAIT_MS : TIMEOUT_BACKGROUND_MS
}

// rand is Math.random() in production and a fixed value in tests, in [0, 1).
function jittered(delayMs, rand) {
    var r = (typeof rand === "number" && rand >= 0 && rand < 1) ? rand : 0.5
    return Math.round(delayMs * (1 - JITTER_FRACTION + 2 * JITTER_FRACTION * r))
}
```

`qml/helper/OperationKeys.js`:

```js
.pragma library

// Deterministic ids for the atomic order-completion operation. Design:
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// The same order at the same completion epoch always yields the same key, so a
// re-run after a hang, a restart or a sign-out/in resends the SAME requestId and
// the server replays the first result instead of applying it twice. The epoch is
// stored on the order and bumped by the operation itself, so re-completing a
// reopened order gets a fresh key.

// Number of the completion this attempt would be. Orders written before this
// field existed count as epoch 0, so their first completion is epoch 1.
function nextEpoch(order) {
    var n = order && typeof order.completionEpoch === "number" ? order.completionEpoch : 0
    return n + 1
}

function completeOrderKey(orderId, epoch) {
    return "completeOrder:" + orderId + ":" + epoch
}

// One sale transaction doc per order line. Keeps the "tx-s-" prefix the ids always had.
function saleTxId(orderId, epoch, lineIndex) {
    return "tx-s-" + orderId + "-" + epoch + "-" + lineIndex
}

// Drift-repair batch synthesised for a line whose batches cannot cover its quantity.
function repairBatchId(orderId, epoch, lineIndex) {
    return "BAT-RPR-" + orderId + "-" + epoch + "-" + lineIndex
}
```

- [ ] **Step 4: Push, confirm CI passes** (logic verified beforehand: 7 + 7 tests).

- [ ] **Step 5: Commit**

```bash
git add qml/helper/SendPolicy.js qml/helper/OperationKeys.js tests/tst_SendPolicy.qml tests/tst_OperationKeys.qml
git commit -m "feat: SendPolicy (timeouts, jitter) and OperationKeys (deterministic ids)"
```

### Task 5: `CompletionPlan` — the pure planner

**Files:**
- Create: `qml/helper/CompletionPlan.js`
- Test: `tests/tst_CompletionPlan.qml` (new)

**Interfaces:**
- Consumes: `OperationKeys` (Task 4).
- Produces: `CompletionPlan.MAX_OPS`, `REPAIR_NOTE`, `build(input, hooks)` returning `{ ok, key, opType, ops, lines, orderAfter, predicted }` or `{ ok: false, reason, errors }`. Input and hooks shapes are documented at the top of the file.

- [ ] **Step 1: Write the failing tests**

`tests/tst_CompletionPlan.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/CompletionPlan.js" as CP

// Headless tests for the pure planner behind the atomic order-completion
// operation. Pure JS, no singletons: nothing here can be polluted by another test.
// Design: docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
TestCase {
    name: "CompletionPlan"

    // Small deterministic PRNG (LCG) so a failing monkey run reproduces from its seed.
    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function _batch(id, remaining, cost, supplier) {
        return { batchId: id, supplierId: supplier || "", qtyRemaining: remaining, unitCost: cost || 0 }
    }

    // Records what the planner asked the hooks for, so tests can assert on it.
    function _hooks(calls) {
        return {
            orderUpdate: function(lines) {
                calls.orderUpdate.push(lines)
                return { before: { status: "pending" }, after: { status: "completed", products: lines } }
            },
            saleDocs: function(after) {
                calls.saleDocs.push(after)
                var out = []
                for (var i = 0; i < after.products.length; ++i)
                    out.push({ txId: "tx-s-o1-1-" + i, productId: after.products[i].productId })
                return out
            }
        }
    }

    function _calls() { return { orderUpdate: [], saleDocs: [] } }

    function _input(over) {
        var base = {
            orderId: "o1", epoch: 1, now: "2026-09-20T10:00:00.000Z", clampStock: false,
            lines: [{ line: { productId: "p1", name: "Widget", quantity: 3 }, productId: "p1", name: "Widget", qty: 3 }],
            stockByProduct: { p1: 10 },
            batchesByProduct: { p1: [_batch("b1", 10, 5, "s1")] }
        }
        for (var k in over) base[k] = over[k]
        return base
    }

    function _ops(plan, entity, kind) {
        var out = []
        for (var i = 0; i < plan.ops.length; ++i)
            if (plan.ops[i].entity === entity && (!kind || plan.ops[i].kind === kind)) out.push(plan.ops[i])
        return out
    }

    // -- happy path -------------------------------------------------------------

    function test_single_line_single_batch_builds_the_full_operation() {
        var c = _calls()
        var p = CP.build(_input(), _hooks(c))
        compare(p.ok, true)
        compare(p.key, "completeOrder:o1:1")
        compare(p.opType, "completeOrder")
        // batch delta, stock delta, order update, one sale doc
        compare(p.ops.length, 4)
        compare(JSON.stringify(p.ops[0]), JSON.stringify({ kind: "delta", entity: "stock_batch", entityId: "b1",
            deltas: { qtyRemaining: -3 }, floors: { qtyRemaining: 0 }, clamps: {} }))
        compare(JSON.stringify(p.ops[1]), JSON.stringify({ kind: "delta", entity: "inventory", entityId: "p1",
            deltas: { stock: -3 }, floors: { stock: 0 }, clamps: {} }))
        compare(p.ops[2].entity, "order")
        compare(p.ops[2].action, "update")
        compare(p.ops[3].entity, "transaction")
        compare(p.ops[3].action, "create")
        compare(p.ops[3].before, null)
        compare(p.ops[3].entityId, "tx-s-o1-1-0")
    }

    function test_consumption_lineage_is_stamped_on_the_returned_lines() {
        var p = CP.build(_input(), _hooks(_calls()))
        compare(JSON.stringify(p.lines[0].consumption),
                JSON.stringify([{ batchId: "b1", supplierId: "s1", qtyConsumed: 3, unitCost: 5 }]))
        compare(p.lines[0].name, "Widget", "the original line fields survive")
    }

    function test_the_input_line_object_is_never_mutated() {
        var input = _input()
        CP.build(input, _hooks(_calls()))
        compare(input.lines[0].line.consumption, undefined)
    }

    function test_predicted_state_matches_the_plan() {
        var p = CP.build(_input(), _hooks(_calls()))
        compare(p.predicted.batches.b1, 7)
        compare(p.predicted.stock.p1, 7)
        compare(p.predicted.created.length, 0)
    }

    function test_operation_order_is_batches_then_stock_then_order_then_sales() {
        var p = CP.build(_input(), _hooks(_calls()))
        var seq = []
        for (var i = 0; i < p.ops.length; ++i) seq.push(p.ops[i].entity)
        compare(seq.join(","), "stock_batch,inventory,order,transaction")
    }

    function test_orderAfter_is_returned_and_hooks_run_exactly_once_each() {
        var c = _calls()
        var p = CP.build(_input(), _hooks(c))
        compare(c.orderUpdate.length, 1)
        compare(c.saleDocs.length, 1)
        compare(p.orderAfter.status, "completed")
        compare(c.saleDocs[0], p.orderAfter, "sale docs are built from the order AFTER completion")
    }

    // -- FIFO -------------------------------------------------------------------

    function test_a_line_spanning_two_batches_consumes_oldest_first() {
        var p = CP.build(_input({
            lines: [{ line: { productId: "p1" }, productId: "p1", name: "Widget", qty: 8 }],
            batchesByProduct: { p1: [_batch("b1", 5, 2, "s1"), _batch("b2", 10, 3, "s2")] }
        }), _hooks(_calls()))
        var d = _ops(p, "stock_batch", "delta")
        compare(d.length, 2)
        compare(d[0].entityId, "b1"); compare(d[0].deltas.qtyRemaining, -5)
        compare(d[1].entityId, "b2"); compare(d[1].deltas.qtyRemaining, -3)
        compare(p.lines[0].consumption.length, 2)
        compare(p.lines[0].consumption[1].unitCost, 3)
    }

    function test_empty_and_zero_quantity_batches_are_skipped() {
        var p = CP.build(_input({
            batchesByProduct: { p1: [_batch("b0", 0, 1), _batch("bn", undefined, 1), _batch("b1", 10, 5)] }
        }), _hooks(_calls()))
        var d = _ops(p, "stock_batch", "delta")
        compare(d.length, 1)
        compare(d[0].entityId, "b1")
    }

    function test_a_batch_missing_cost_and_supplier_defaults_to_zero_and_empty() {
        var p = CP.build(_input({ batchesByProduct: { p1: [{ batchId: "b1", qtyRemaining: 10 }] } }), _hooks(_calls()))
        compare(JSON.stringify(p.lines[0].consumption[0]),
                JSON.stringify({ batchId: "b1", supplierId: "", qtyConsumed: 3, unitCost: 0 }))
    }

    function test_two_lines_of_the_same_product_share_batch_availability() {
        var p = CP.build(_input({
            lines: [
                { line: { productId: "p1" }, productId: "p1", name: "Widget", qty: 6 },
                { line: { productId: "p1" }, productId: "p1", name: "Widget", qty: 3 }
            ],
            batchesByProduct: { p1: [_batch("b1", 7, 1), _batch("b2", 10, 1)] }
        }), _hooks(_calls()))
        var d = _ops(p, "stock_batch", "delta")
        // line 1: 6 from b1. line 2: 1 left in b1, then 2 from b2.
        compare(d.length, 3)
        compare(d[1].entityId, "b1"); compare(d[1].deltas.qtyRemaining, -1)
        compare(d[2].entityId, "b2"); compare(d[2].deltas.qtyRemaining, -2)
        compare(p.predicted.batches.b1, 0)
        compare(p.predicted.batches.b2, 8)
        compare(p.predicted.stock.p1, 1)
    }

    // -- drift repair -----------------------------------------------------------

    function test_a_shortfall_is_booked_as_a_fully_consumed_repair_batch() {
        var p = CP.build(_input({
            lines: [{ line: { productId: "p1" }, productId: "p1", name: "Widget", qty: 8 }],
            batchesByProduct: { p1: [_batch("b1", 5, 2, "s1")] }
        }), _hooks(_calls()))
        compare(p.ok, true)
        var creates = _ops(p, "stock_batch", "mutation")
        compare(creates.length, 1)
        compare(creates[0].entityId, "BAT-RPR-o1-1-0")
        compare(creates[0].action, "create")
        compare(creates[0].before, null)
        compare(creates[0].after.qtyReceived, 3)
        compare(creates[0].after.qtyRemaining, 0)
        compare(creates[0].after.unitCost, 0)
        compare(creates[0].after.note, CP.REPAIR_NOTE)
        compare(creates[0].after.receivedDate, "2026-09-20T10:00:00.000Z")
        var last = p.lines[0].consumption[p.lines[0].consumption.length - 1]
        compare(JSON.stringify(last), JSON.stringify({ batchId: "BAT-RPR-o1-1-0", supplierId: "", qtyConsumed: 3, unitCost: 0 }))
        compare(p.predicted.created.length, 1)
    }

    function test_a_product_with_no_batches_at_all_is_repaired_in_full() {
        var p = CP.build(_input({ batchesByProduct: {} }), _hooks(_calls()))
        compare(p.ok, true)
        compare(_ops(p, "stock_batch", "delta").length, 0)
        compare(_ops(p, "stock_batch", "mutation")[0].after.qtyReceived, 3)
    }

    function test_repair_batch_ids_are_unique_per_line() {
        var p = CP.build(_input({
            lines: [
                { line: { productId: "p1" }, productId: "p1", name: "A", qty: 1 },
                { line: { productId: "p2" }, productId: "p2", name: "B", qty: 1 }
            ],
            stockByProduct: { p1: 5, p2: 5 }, batchesByProduct: {}
        }), _hooks(_calls()))
        var creates = _ops(p, "stock_batch", "mutation")
        compare(creates[0].entityId, "BAT-RPR-o1-1-0")
        compare(creates[1].entityId, "BAT-RPR-o1-1-1")
    }

    // -- stock validation and clamping (D3) -------------------------------------

    function test_insufficient_stock_is_rejected_before_any_hook_runs() {
        var c = _calls()
        var p = CP.build(_input({ stockByProduct: { p1: 2 } }), _hooks(c))
        compare(p.ok, false)
        compare(p.reason, "out-of-stock")
        compare(p.errors[0], "Widget: need 3, only 2 in stock")
        compare(c.orderUpdate.length, 0)
        compare(c.saleDocs.length, 0)
    }

    function test_demand_is_summed_across_lines_of_the_same_product() {
        var p = CP.build(_input({
            lines: [
                { line: {}, productId: "p1", name: "Widget", qty: 6 },
                { line: {}, productId: "p1", name: "Widget", qty: 6 }
            ],
            stockByProduct: { p1: 10 }
        }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.errors.length, 1, "the second line is what tips it over")
        compare(p.errors[0], "Widget: need 12, only 10 in stock")
    }

    function test_an_unknown_product_is_not_found_in_inventory() {
        var p = CP.build(_input({
            lines: [
                { line: {}, productId: "ghost", name: "Ghost", qty: 1 },
                { line: {}, productId: "", name: "Blank", qty: 1 }
            ]
        }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.errors.length, 2)
        compare(p.errors[0], "Ghost: not found in inventory")
        compare(p.errors[1], "Blank: not found in inventory")
    }

    function test_clampStock_accepts_the_sale_and_clamps_the_stock_delta() {
        var p = CP.build(_input({ clampStock: true, stockByProduct: { p1: 2 } }), _hooks(_calls()))
        compare(p.ok, true)
        var s = _ops(p, "inventory")[0]
        compare(JSON.stringify(s.floors), "{}")
        compare(JSON.stringify(s.clamps), JSON.stringify({ stock: 0 }))
        compare(p.predicted.stock.p1, 0, "predicted stock never goes below zero when clamping")
        // 2 in stock but 3 sold and only 10 in b1: batch covers it, no repair needed
        compare(_ops(p, "stock_batch", "mutation").length, 0)
    }

    function test_clampStock_still_reports_unknown_products() {
        var p = CP.build(_input({ clampStock: true, lines: [{ line: {}, productId: "ghost", name: "Ghost", qty: 1 }] }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.errors[0], "Ghost: not found in inventory")
    }

    // -- edge cases -------------------------------------------------------------

    function test_a_zero_quantity_line_passes_through_with_empty_consumption_and_no_ops() {
        var p = CP.build(_input({
            lines: [
                { line: { productId: "p1", name: "Widget" }, productId: "p1", name: "Widget", qty: 0 },
                { line: { productId: "p1", name: "Widget" }, productId: "p1", name: "Widget", qty: 2 }
            ]
        }), _hooks(_calls()))
        compare(p.ok, true)
        compare(p.lines.length, 2, "no hole where the zero line was")
        compare(JSON.stringify(p.lines[0].consumption), "[]")
        compare(_ops(p, "inventory").length, 1)
    }

    function test_an_order_with_no_lines_still_produces_the_order_update() {
        var p = CP.build(_input({ lines: [] }), _hooks(_calls()))
        compare(p.ok, true)
        compare(p.ops.length, 1)
        compare(p.ops[0].entity, "order")
    }

    function test_the_operation_cap_is_enforced_at_200() {
        compare(CP.MAX_OPS, 200)
        var lines = [], stock = {}, batches = {}
        // 100 lines x (1 batch delta + 1 stock delta) = 200 ops, + order + 100 sales = 301
        for (var i = 0; i < 100; ++i) {
            lines.push({ line: {}, productId: "p" + i, name: "P" + i, qty: 1 })
            stock["p" + i] = 5
            batches["p" + i] = [_batch("b" + i, 5, 1)]
        }
        var p = CP.build(_input({ lines: lines, stockByProduct: stock, batchesByProduct: batches }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.reason, "too-many-ops")
        verify(p.errors[0].indexOf("limit 200") >= 0)
    }

    function test_exactly_200_ops_is_allowed() {
        // 66 lines x 3 ops (batch, stock, sale) = 198, + order = 199, + 1 more line's stock-less
        // zero-qty line adds a sale doc only = 200.
        var lines = [], stock = {}, batches = {}
        for (var i = 0; i < 66; ++i) {
            lines.push({ line: {}, productId: "p" + i, name: "P" + i, qty: 1 })
            stock["p" + i] = 5
            batches["p" + i] = [_batch("b" + i, 5, 1)]
        }
        lines.push({ line: {}, productId: "p0", name: "P0", qty: 0 })
        var p = CP.build(_input({ lines: lines, stockByProduct: stock, batchesByProduct: batches }), _hooks(_calls()))
        compare(p.ok, true)
        compare(p.ops.length, 200)
    }

    function test_201_ops_is_rejected() {
        var lines = [], stock = {}, batches = {}
        for (var i = 0; i < 66; ++i) {
            lines.push({ line: {}, productId: "p" + i, name: "P" + i, qty: 1 })
            stock["p" + i] = 5
            batches["p" + i] = [_batch("b" + i, 5, 1)]
        }
        // two zero-quantity lines add a sale doc each: 198 + order + 2 = 201
        lines.push({ line: {}, productId: "p0", name: "P0", qty: 0 })
        lines.push({ line: {}, productId: "p0", name: "P0", qty: 0 })
        var p = CP.build(_input({ lines: lines, stockByProduct: stock, batchesByProduct: batches }), _hooks(_calls()))
        compare(p.ok, false)
        compare(p.reason, "too-many-ops")
    }

    // A reopened order's lines still carry the consumption booked by its earlier
    // completion; re-completing must replace it, not append to it.
    function test_stale_consumption_on_an_input_line_is_replaced_not_appended() {
        var stale = [{ batchId: "old", supplierId: "s0", qtyConsumed: 99, unitCost: 9 }]
        var p = CP.build(_input({
            lines: [{ line: { productId: "p1", consumption: stale }, productId: "p1", name: "Widget", qty: 3 }]
        }), _hooks(_calls()))
        compare(p.lines[0].consumption.length, 1)
        compare(p.lines[0].consumption[0].batchId, "b1")
        compare(stale.length, 1, "and the caller's own array is untouched")
    }

    // -- determinism (the whole point) ------------------------------------------

    function test_the_same_input_always_yields_the_same_plan_and_key() {
        var a = CP.build(_input(), _hooks(_calls()))
        var b = CP.build(_input(), _hooks(_calls()))
        compare(JSON.stringify(a), JSON.stringify(b))
        compare(a.key, b.key)
    }

    function test_a_different_epoch_yields_a_different_key_and_different_repair_ids() {
        var a = CP.build(_input({ epoch: 1, batchesByProduct: {} }), _hooks(_calls()))
        var b = CP.build(_input({ epoch: 2, batchesByProduct: {} }), _hooks(_calls()))
        verify(a.key !== b.key)
        verify(_ops(a, "stock_batch", "mutation")[0].entityId !== _ops(b, "stock_batch", "mutation")[0].entityId)
    }

    // -- monkey -----------------------------------------------------------------

    // Random orders against random batches: whatever the shape, the plan must
    // consume exactly what was sold, never touch a batch beyond what it holds, and
    // never plan more than the cap.
    function test_monkey_random_orders_consume_exactly_what_was_sold() {
        var rand = _rng(20260920)
        for (var run = 0; run < 300; ++run) {
            var nProducts = 1 + Math.floor(rand() * 4)
            var stock = {}, batches = {}, lines = [], sold = {}
            for (var p = 0; p < nProducts; ++p) {
                var pid = "p" + p
                var nb = Math.floor(rand() * 4)
                var bl = [], total = 0
                for (var b = 0; b < nb; ++b) {
                    var q = Math.floor(rand() * 6)
                    bl.push(_batch(pid + "b" + b, q, 1 + b))
                    total += q
                }
                batches[pid] = bl
                stock[pid] = 20
            }
            var nLines = 1 + Math.floor(rand() * 5)
            for (var l = 0; l < nLines; ++l) {
                var lpid = "p" + Math.floor(rand() * nProducts)
                var qty = Math.floor(rand() * 5)
                lines.push({ line: {}, productId: lpid, name: lpid, qty: qty })
                sold[lpid] = (sold[lpid] || 0) + qty
            }
            var plan = CP.build(_input({ lines: lines, stockByProduct: stock, batchesByProduct: batches }), _hooks(_calls()))
            if (!plan.ok) { compare(plan.reason === "out-of-stock" || plan.reason === "too-many-ops", true); continue }

            var consumed = {}
            for (var i = 0; i < plan.lines.length; ++i)
                for (var c = 0; c < plan.lines[i].consumption.length; ++c) {
                    var e = plan.lines[i].consumption[c]
                    consumed[lines[i].productId] = (consumed[lines[i].productId] || 0) + e.qtyConsumed
                }
            for (var sp in sold) compare(consumed[sp] || 0, sold[sp], "run " + run + " product " + sp)

            var taken = {}
            var d = _ops(plan, "stock_batch", "delta")
            for (var j = 0; j < d.length; ++j) taken[d[j].entityId] = (taken[d[j].entityId] || 0) - d[j].deltas.qtyRemaining
            for (var pid2 in batches)
                for (var bb = 0; bb < batches[pid2].length; ++bb) {
                    var bid = batches[pid2][bb].batchId
                    verify((taken[bid] || 0) <= batches[pid2][bb].qtyRemaining, "run " + run + " overdrew " + bid)
                }
            verify(plan.ops.length <= CP.MAX_OPS)
        }
    }
}
```

- [ ] **Step 2: Push, confirm CI's QML job fails** (module missing).

- [ ] **Step 3: Write the implementation**

`qml/helper/CompletionPlan.js`:

```js
.pragma library
.import "OperationKeys.js" as Keys

// Pure planner for the atomic order-completion operation. Design:
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
//
// Turns "complete this order" into the ordered list of writes the server applies in
// ONE transaction: FIFO batch deltas (and a drift-repair batch when the batches
// cannot cover a line), one stock delta per line, the order update, and one sale
// transaction doc per line. It reads no store and sends nothing; DataModel gathers
// the inputs and hands the result to Gateway.recordOperation.

// Mirrors MAX_OPS in functions/lib/operationLogic.js and Gateway.maxOperationOps.
var MAX_OPS = 200

// Same label StockBatchStore.topUpOldest has always used for drift-repair batches.
var REPAIR_NOTE = "Adjustment (drift repair)"

// input = {
//   orderId, epoch, now (ISO string), clampStock (bool),
//   lines: [ { line, productId, name, qty } ]          line = the order's own line object
//   stockByProduct: { productId: number }              local product.stock
//   batchesByProduct: { productId: [ { batchId, supplierId, qtyRemaining, unitCost } ] }  oldest first
// }
// hooks = {
//   orderUpdate(lines) -> { before, after }            the order doc before/after completion
//   saleDocs(orderAfter) -> [ doc ]                    sale docs, each with a deterministic txId
// }
// Returns { ok: true, key, opType, ops, lines, orderAfter, predicted }
//      or { ok: false, reason: "out-of-stock" | "too-many-ops", errors: [string] }
function build(input, hooks) {
    var errors = []
    var demand = {}
    var i

    // 1. Validate against local stock. Demand is summed per product, so two lines of
    // the same product cannot each pass on their own and then fail together.
    for (i = 0; i < input.lines.length; ++i) {
        var v = input.lines[i]
        if (!v.productId || !(v.productId in input.stockByProduct)) {
            errors.push(v.name + ": not found in inventory")
            continue
        }
        demand[v.productId] = (demand[v.productId] || 0) + v.qty
        if (!input.clampStock && demand[v.productId] > input.stockByProduct[v.productId])
            errors.push(v.name + ": need " + demand[v.productId] + ", only "
                        + input.stockByProduct[v.productId] + " in stock")
    }
    if (errors.length > 0) return { ok: false, reason: "out-of-stock", errors: errors }

    // 2. FIFO per line against a working copy of each batch's remaining quantity, so
    // a second line of the same product continues where the first stopped.
    var avail = {}
    var stockLeft = {}
    var ops = []
    var lines = []
    var predicted = { batches: {}, stock: {}, created: [] }

    for (i = 0; i < input.lines.length; ++i) {
        var L = input.lines[i]
        var out = {}
        for (var k in L.line) out[k] = L.line[k]
        out.consumption = []

        if (L.qty > 0) {
            var remaining = L.qty
            var batches = input.batchesByProduct[L.productId] || []
            for (var b = 0; b < batches.length && remaining > 0; ++b) {
                var batch = batches[b]
                var have = (batch.batchId in avail) ? avail[batch.batchId] : (batch.qtyRemaining || 0)
                avail[batch.batchId] = have
                if (have <= 0) continue
                var take = Math.min(have, remaining)
                ops.push({ kind: "delta", entity: "stock_batch", entityId: batch.batchId,
                           deltas: { qtyRemaining: -take }, floors: { qtyRemaining: 0 }, clamps: {} })
                avail[batch.batchId] = have - take
                predicted.batches[batch.batchId] = have - take
                out.consumption.push({ batchId: batch.batchId, supplierId: batch.supplierId || "",
                                       qtyConsumed: take, unitCost: batch.unitCost || 0 })
                remaining -= take
            }

            if (remaining > 0) {
                // Batches cannot cover this line although product.stock says they
                // should (or the sale is being force-applied): book the gap as an
                // explicit, clearly labelled batch that is already fully consumed.
                var rid = Keys.repairBatchId(input.orderId, input.epoch, i)
                var repair = { batchId: rid, productId: L.productId, supplierId: "",
                               qtyReceived: remaining, qtyRemaining: 0, unitCost: 0,
                               receivedDate: input.now, poId: "", note: REPAIR_NOTE,
                               createdAt: input.now, updatedAt: input.now }
                ops.push({ kind: "mutation", entity: "stock_batch", entityId: rid,
                           action: "create", before: null, after: repair })
                predicted.created.push(repair)
                out.consumption.push({ batchId: rid, supplierId: "", qtyConsumed: remaining, unitCost: 0 })
            }

            ops.push({ kind: "delta", entity: "inventory", entityId: L.productId,
                       deltas: { stock: -L.qty },
                       floors: input.clampStock ? {} : { stock: 0 },
                       clamps: input.clampStock ? { stock: 0 } : {} })
            var left = (L.productId in stockLeft ? stockLeft[L.productId] : input.stockByProduct[L.productId]) - L.qty
            stockLeft[L.productId] = input.clampStock ? Math.max(0, left) : left
            predicted.stock[L.productId] = stockLeft[L.productId]
        }
        lines.push(out)
    }

    // 3. The order itself, then its sale docs.
    var upd = hooks.orderUpdate(lines)
    ops.push({ kind: "mutation", entity: "order", entityId: input.orderId,
               action: "update", before: upd.before, after: upd.after })
    var sales = hooks.saleDocs(upd.after)
    for (i = 0; i < sales.length; ++i)
        ops.push({ kind: "mutation", entity: "transaction", entityId: sales[i].txId,
                   action: "create", before: null, after: sales[i] })

    if (ops.length > MAX_OPS)
        return { ok: false, reason: "too-many-ops",
                 errors: ["This order is too large to complete in one step (" + ops.length
                          + " changes, limit " + MAX_OPS + ")"] }

    return { ok: true, key: Keys.completeOrderKey(input.orderId, input.epoch), opType: "completeOrder",
             ops: ops, lines: lines, orderAfter: upd.after, predicted: predicted }
}
```

- [ ] **Step 4: Push, confirm CI passes** (logic verified beforehand: 27 tests including a 300-run seeded monkey test).

- [ ] **Step 5: Commit, push, PR**

```bash
git add qml/helper/CompletionPlan.js tests/tst_CompletionPlan.qml
git commit -m "feat: CompletionPlan, pure planner for the atomic order-completion operation"
git push -u origin feature/2026-09-21-operation-helpers
```

---

# Phase 3 — Wiring (starts only after PR #75 merges and Phases 1-2 are merged and the endpoint is deployed to dev)

Branch: `fix/2026-09-22-atomic-order-completion`. **Everything below is unexecuted code; CI is the first run.** Before each task, re-read the file it edits on current `main`: line numbers in the spec were taken before #75 merged.

### Task 6: `OutboxStore` — `op` items, per-key ordering, jitter

**Files:**
- Modify: `qml/model/OutboxStore.qml`
- Test: `tests/tst_OutboxStore.qml` (append)

**Interfaces:**
- Produces: `OutboxStore.enqueueOperation({ requestId, opType, ops, clientTimestamp })` returning the stored item (the existing one if that `requestId` is already queued); `_keysForItem(item)` covers `item.ops`; `dueItems()` never returns two items that share a key; `property var _rand: Math.random` used by `markFailed` for jitter.

- [ ] **Step 1: Write the failing tests** (append to `tests/tst_OutboxStore.qml`, inside its `TestCase`):

```qml
    // -- operation items (atomic order completion) -----------------------------

    function _op(id, entities) {
        var ops = []
        for (var i = 0; i < entities.length; ++i)
            ops.push({ kind: "delta", entity: entities[i][0], entityId: entities[i][1], deltas: { n: -1 }, floors: {}, clamps: {} })
        return { requestId: id, opType: "completeOrder", ops: ops }
    }

    function test_enqueueOperation_appends_a_durable_item() {
        OutboxStore.clear()
        var item = OutboxStore.enqueueOperation(_op("completeOrder:o1:1", [["inventory", "p1"], ["order", "o1"]]))
        compare(item.requestId, "completeOrder:o1:1")
        compare(item.opType, "completeOrder")
        compare(item.ops.length, 2)
        compare(item.attempts, 0)
        compare(OutboxStore.items.length, 1)
    }

    function test_enqueueOperation_with_a_queued_key_returns_the_existing_item_and_adds_nothing() {
        OutboxStore.clear()
        var a = OutboxStore.enqueueOperation(_op("k1", [["inventory", "p1"]]))
        var b = OutboxStore.enqueueOperation(_op("k1", [["inventory", "p1"], ["inventory", "p2"]]))
        compare(OutboxStore.items.length, 1)
        compare(b.requestId, a.requestId)
        compare(b.ops.length, 1, "the first payload wins; the same key never queues twice")
    }

    function test_keysForItem_lists_every_distinct_entity_the_operation_touches() {
        var item = _op("k1", [["inventory", "p1"], ["inventory", "p1"], ["order", "o1"]])
        var keys = OutboxStore._keysForItem(item)
        compare(keys.length, 2)
        verify(keys.indexOf("inventory/p1") >= 0)
        verify(keys.indexOf("order/o1") >= 0)
    }

    function test_operation_is_never_a_coalescing_target_for_plain_calls_or_deltas() {
        OutboxStore.clear()
        OutboxStore.enqueueOperation(_op("k1", [["inventory", "p1"]]))
        OutboxStore.enqueueDelta({ requestId: "d1", entity: "inventory", entityId: "p1", deltas: { stock: -1 } })
        OutboxStore.enqueue({ requestId: "m1", entity: "inventory", entityId: "p1", action: "update", before: null, after: {} })
        compare(OutboxStore.items.length, 3)
        compare(OutboxStore.items[0].ops.length, 1)
    }

    function test_an_in_flight_operation_blocks_every_item_touching_its_keys() {
        OutboxStore.clear()
        var op = OutboxStore.enqueueOperation(_op("k1", [["inventory", "p1"], ["order", "o1"]]))
        OutboxStore.enqueue({ requestId: "m1", entity: "order", entityId: "o1", action: "update", before: null, after: {} })
        OutboxStore.enqueue({ requestId: "m2", entity: "order", entityId: "o2", action: "update", before: null, after: {} })
        OutboxStore.markInFlight(op)
        var due = OutboxStore.dueItems()
        compare(due.length, 1)
        compare(due[0].requestId, "m2", "only the item on an unrelated key may go")
    }

    function test_dueItems_never_returns_two_items_that_share_a_key_in_one_pass() {
        OutboxStore.clear()
        OutboxStore.enqueueOperation(_op("k1", [["order", "o1"]]))
        OutboxStore.enqueue({ requestId: "m1", entity: "order", entityId: "o1", action: "update", before: null, after: {} })
        OutboxStore.enqueue({ requestId: "m2", entity: "order", entityId: "o9", action: "update", before: null, after: {} })
        var due = OutboxStore.dueItems()
        compare(due.length, 2)
        compare(due[0].requestId, "k1", "oldest first")
        compare(due[1].requestId, "m2", "the later item on the same key waits for the next drain")
    }

    function test_markFailed_jitters_the_backoff_within_the_band() {
        OutboxStore.clear()
        OutboxStore.enqueueOperation(_op("k1", [["order", "o1"]]))
        var saved = OutboxStore._rand
        OutboxStore._rand = function() { return 0 }
        var before = Date.now()
        OutboxStore.markFailed("k1")
        var low = OutboxStore.items[0].nextAttemptAt - before
        OutboxStore._rand = function() { return 0.999999 }
        OutboxStore.markFailed("k1")   // second attempt: 8000ms base
        var high = OutboxStore.items[0].nextAttemptAt - Date.now()
        OutboxStore._rand = saved
        verify(low >= 1600 - 50 && low <= 1600 + 50, "attempt 1 at rand 0 is ~2000*0.8, got " + low)
        verify(high >= 9600 - 50 && high <= 9600, "attempt 2 at rand ~1 is ~8000*1.2, got " + high)
    }
```

- [ ] **Step 2: Push, confirm CI's QML job fails** (`enqueueOperation` is not a function).

- [ ] **Step 3: Implement.** In `qml/model/OutboxStore.qml`:

Add near the top imports: `import "../helper/SendPolicy.js" as SendPolicy`.

Add beside `_backoffMs`:

```qml
    // Random source for retry jitter; tests swap it for a fixed value.
    property var _rand: Math.random
```

Replace `_keysForItem`:

```qml
    function _keysForItem(item) {
        if (item.ops) {
            var seen = {}
            var opKeys = []
            for (var o = 0; o < item.ops.length; ++o) {
                var k = _keyFor(item.ops[o].entity, item.ops[o].entityId)
                if (!seen[k]) { seen[k] = true; opKeys.push(k) }
            }
            return opKeys
        }
        if (item.items) {
            var out = []
            for (var i = 0; i < item.items.length; ++i)
                out.push(_keyFor(item.entity, item.items[i].entityId))
            return out
        }
        return [_keyFor(item.entity, item.entityId)]
    }
```

In `enqueue`, make the skip explicit: `if (candidate.items || candidate.deltas || candidate.ops) continue`.

Add after `enqueueDelta`:

```qml
    // Append one atomic multi-write operation. Never merged into anything. If the
    // same requestId (the operation key) is already queued, that item is returned
    // and nothing is added: the same key must never be queued twice.
    function enqueueOperation(call) {
        for (var i = 0; i < items.length; ++i)
            if (items[i].requestId === call.requestId) return items[i]
        var nowMs = Date.now()
        var item = {
            requestId: call.requestId,
            opType: call.opType,
            ops: call.ops,
            clientTimestamp: call.clientTimestamp || new Date().toISOString(),
            enqueuedAt: nowMs,
            attempts: 0,
            nextAttemptAt: nowMs
        }
        var arr = items.slice()
        arr.push(item)
        items = arr
        _save()
        return item
    }
```

Replace `dueItems`:

```qml
    function dueItems() {
        var nowMs = Date.now()
        var out = []
        var claimed = {}
        for (var i = 0; i < items.length; ++i) {
            if ((items[i].nextAttemptAt || 0) > nowMs) continue
            if (_isItemBlocked(items[i])) continue
            // Two due items that share a key must not go out together: the check
            // above only sees keys already in flight, not ones chosen in this pass.
            var keys = _keysForItem(items[i])
            var clash = false
            for (var k = 0; k < keys.length; ++k) if (claimed[keys[k]]) { clash = true; break }
            if (clash) continue
            for (var k2 = 0; k2 < keys.length; ++k2) claimed[keys[k2]] = true
            out.push(items[i])
        }
        return out
    }
```

In `markFailed`, replace `var delay = _backoffMs[idx]` with:

```qml
            var delay = SendPolicy.jittered(_backoffMs[idx], _rand())
```

- [ ] **Step 4: Push, confirm CI passes.** Existing `tst_OutboxStore` cases that assert an exact `nextAttemptAt` after `markFailed` must set `OutboxStore._rand = function() { return 0.5 }` in `init()` (jitter at 0.5 is exactly the base delay). Fix any that CI shows failing.

- [ ] **Step 5: Commit**

```bash
git add qml/model/OutboxStore.qml tests/tst_OutboxStore.qml
git commit -m "feat(outbox): operation items, per-key ordering in dueItems, retry jitter"
```

### Task 7: `Gateway` — shared send helper, timeout, XHR seam

**Files:**
- Modify: `qml/model/Gateway.qml`
- Test: `tests/tst_Gateway_send.qml` (new)

**Interfaces:**
- Consumes: `SendPolicy` (Task 4), `StuckWrites.TIMEOUT` (Task 3), `OutboxStore` (Task 6).
- Produces: `Gateway.xhrFactory`, `Gateway.backgroundTimeoutMs`, `Gateway.awaitTimeoutMs`, `_xhrPost(url, payload, timeoutMs, done)` calling `done({ status, responseText, timedOut })` exactly once. `_noteFailure(item, status)` passes `AuthService.isOnline` to `StuckWrites.noteFailure`.

- [ ] **Step 1: Write the failing tests.** `tests/tst_Gateway_send.qml` injects a fake XHR through `Gateway.xhrFactory`, which is what makes the send path testable headlessly for the first time:

```qml
import QtQuick
import QtTest
import "../qml/model"

// Gateway send path through an injected fake XHR. Design:
// docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md
// Safe to set AuthStore.idToken here ONLY because xhrFactory is faked: no real
// request can leave the process (unlike tst_Gateway.qml, which must not set it).
TestCase {
    name: "GatewaySend"

    property var made: []          // every fake XHR the Gateway created, in order

    function _fakeFactory() {
        return function() {
            var x = {
                readyState: 0, status: 0, responseText: "", aborted: false, sent: null, url: "",
                onreadystatechange: null,
                open: function(m, u) { x.url = u },
                setRequestHeader: function() {},
                getAllResponseHeaders: function() { return "" },
                send: function(body) { x.sent = body },
                abort: function() {
                    x.aborted = true; x.readyState = 4; x.status = 0
                    if (x.onreadystatechange) x.onreadystatechange()
                },
                respond: function(status, bodyObj) {
                    x.readyState = 4; x.status = status; x.responseText = JSON.stringify(bodyObj)
                    if (x.onreadystatechange) x.onreadystatechange()
                }
            }
            made.push(x)
            return x
        }
    }

    function init() {
        made = []
        OutboxStore.clear()
        Gateway.clear()
        Gateway.mode = "gateway"
        Gateway.xhrFactory = _fakeFactory()
        Gateway.backgroundTimeoutMs = 60
        AuthStore.idToken = "test-token"
    }

    function cleanup() {
        AuthStore.idToken = ""
        Gateway.mode = "direct"
        Gateway.backgroundTimeoutMs = 30000
        Gateway.xhrFactory = function() { return new XMLHttpRequest() }
        OutboxStore.clear()
    }

    function test_xhrPost_calls_done_once_with_the_real_status_and_body() {
        var results = []
        Gateway._xhrPost("https://x/y", "{}", 1000, function(r) { results.push(r) })
        compare(made.length, 1)
        made[0].respond(200, { ok: true })
        made[0].respond(500, { ok: false })      // a late duplicate event must be ignored
        compare(results.length, 1)
        compare(results[0].status, 200)
        compare(results[0].timedOut, false)
        compare(JSON.parse(results[0].responseText).ok, true)
    }

    function test_xhrPost_a_hung_request_is_aborted_and_reported_as_a_timeout_not_status_0() {
        var results = []
        Gateway._xhrPost("https://x/y", "{}", 40, function(r) { results.push(r) })
        tryVerify(function() { return results.length === 1 }, 1000)
        compare(made[0].aborted, true)
        compare(results[0].timedOut, true)
        compare(results[0].status, 0)
    }

    function test_xhrPost_a_response_after_the_timeout_is_ignored() {
        var results = []
        Gateway._xhrPost("https://x/y", "{}", 40, function(r) { results.push(r) })
        tryVerify(function() { return results.length === 1 }, 1000)
        made[0].respond(200, { ok: true })
        compare(results.length, 1)
    }

    function test_a_timed_out_delta_is_marked_failed_not_dropped_and_its_key_is_freed() {
        Gateway.recordDelta("inventory", "p1", { stock: -1 }, { stock: 0 }, {}, function() {})
        compare(made.length, 1)
        tryVerify(function() { return OutboxStore.items.length > 0 && OutboxStore.items[0].attempts === 1 }, 1000)
        compare(OutboxStore.items.length, 1, "still queued for retry")
        compare(OutboxStore._inFlightKeys["inventory/p1"], undefined, "the in-flight hold is released")
        compare(Gateway.inFlight, 0)
    }

    function test_a_delta_still_completes_normally_through_the_helper() {
        var got = null
        Gateway.recordDelta("inventory", "p1", { stock: -1 }, { stock: 0 }, {}, function(r) { got = r })
        made[0].respond(200, { ok: true, after: { stock: 4 } })
        compare(got.ok, true)
        compare(got.after.stock, 4)
        compare(OutboxStore.items.length, 0)
    }

    function test_timeouts_while_online_reach_the_stuck_indicator_after_five() {
        AuthService.isOnline = true
        Gateway.backgroundTimeoutMs = 20
        Gateway.recordDelta("inventory", "p1", { stock: -1 }, { stock: 0 }, {}, function() {})
        var requestId = OutboxStore.items[0].requestId
        for (var i = 0; i < 5; ++i) {
            var want = i + 1
            tryVerify(function() { return OutboxStore.items.length > 0 && OutboxStore.items[0].attempts === want }, 2000)
            OutboxStore.items[0].nextAttemptAt = 0     // skip the backoff wait
            Gateway.drainNow()
        }
        tryCompare(Gateway, "stuckCount", 1, 2000)
    }

    function test_timeouts_while_offline_never_reach_the_stuck_indicator() {
        AuthService.isOnline = false
        Gateway.backgroundTimeoutMs = 20
        Gateway.recordDelta("inventory", "p1", { stock: -1 }, { stock: 0 }, {}, function() {})
        for (var i = 0; i < 6; ++i) {
            var want2 = i + 1
            tryVerify(function() { return OutboxStore.items.length > 0 && OutboxStore.items[0].attempts === want2 }, 2000)
            OutboxStore.items[0].nextAttemptAt = 0
            Gateway.drainNow()
        }
        compare(Gateway.stuckCount, 0)
        AuthService.isOnline = true
    }
}
```

- [ ] **Step 2: Push, confirm CI's QML job fails** (`xhrFactory`, `_xhrPost` undefined).

- [ ] **Step 3: Implement the helper.** In `qml/model/Gateway.qml` add `import "../helper/SendPolicy.js" as SendPolicy` and, in the property area:

```qml
    // Injected in tests; production builds a real XMLHttpRequest.
    property var xhrFactory: function() { return new XMLHttpRequest() }

    // Transport timeout for outbox sends (nobody is waiting on these), and the
    // foreground wait a caller of recordOperation(awaitServer) will give the server.
    property int backgroundTimeoutMs: SendPolicy.timeoutMs(false)
    property int awaitTimeoutMs: SendPolicy.timeoutMs(true)
```

Add the helper (next to `_captureBeforeStatusIsLost`):

```qml
    // One POST, one outcome. Races a Timer against the XHR (the pattern
    // AuthService._postJson and StockBatchStore.nextBatchId already use). `done` gets
    // { status, responseText, timedOut } exactly once. A timeout is reported as
    // timedOut:true, never as status 0, so callers can tell "hung" from "offline".
    function _xhrPost(url, payload, timeoutMs, done) {
        var xhr = xhrFactory()
        var snap = { status: 0, responseText: "", headers: "" }
        var finished = false
        var timedOut = false
        var timer = Qt.createQmlObject('import QtQuick; Timer { repeat: false }', root, "GatewaySendTimeoutTimer")

        function finish() {
            if (finished) return
            finished = true
            timer.stop()
            timer.destroy()
            var eff = (xhr.status !== 0) ? xhr.status : snap.status
            var text = (xhr.status !== 0) ? xhr.responseText : snap.responseText
            done({ status: timedOut ? 0 : eff, responseText: timedOut ? "" : text, timedOut: timedOut })
        }

        timer.interval = timeoutMs
        timer.triggered.connect(function() {
            if (finished) return
            timedOut = true
            try { xhr.abort() } catch (e) {}
            finish()            // abort() fires onreadystatechange; finish() is idempotent
        })
        xhr.onreadystatechange = function() {
            _captureBeforeStatusIsLost(xhr, snap)
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            finish()
        }
        xhr.open("POST", url)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("Authorization", "Bearer " + AuthStore.idToken)
        timer.start()
        xhr.send(payload)
    }
```

Change `_noteFailure` (added by #75) to pass connectivity:

```qml
    function _noteFailure(item, status) {
        var online = (typeof AuthService !== "undefined" && AuthService) ? AuthService.isOnline === true : false
        if (!StuckWrites.noteFailure(_stuckState, item.requestId, status, online)) return
        var wasQuiet = stuckCount === 0
        stuckCount = StuckWrites.stuckCount(_stuckState)
        if (wasQuiet)
            Toast.show(qsTr("Some changes aren't syncing. The app keeps retrying."))
    }
```

Move the three senders onto the helper. The transformation is the same for each. Delete from `var xhr = new XMLHttpRequest()` through the closing `}))` of `xhr.send(...)` (this covers the `_snap` variable, `onreadystatechange`, `open`, `setRequestHeader` x2 and `send`), and replace it with `_xhrPost(<url>, JSON.stringify(<the object literal previously passed to xhr.send>), backgroundTimeoutMs, function(res) { ... })`. Inside the callback keep each sender's existing body unchanged apart from these substitutions: `inFlight--` stays first; `effStatus` becomes `res.status`; `effResponseText` becomes `res.responseText`; wherever the sender previously treated the outcome as non-terminal, a timeout (`res.timedOut`) takes that same non-terminal path (skip the classifier, `markFailed`, `_noteFailure(item, res.timedOut ? StuckWrites.TIMEOUT : res.status)`). The finished `_sendDelta`:

```qml
    function _sendDelta(item) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            OutboxStore.clearInFlight(item)
            return
        }
        inFlight++
        _xhrPost(deltaFunctionUrl, JSON.stringify({
            env: FirebaseService.environment,
            entity: item.entity,
            entityId: item.entityId,
            deltas: item.deltas,
            floors: item.floors,
            clamps: item.clamps,
            requestId: item.requestId,
            clientTimestamp: item.clientTimestamp
        }), backgroundTimeoutMs, function(res) {
            inFlight--
            var body = null
            try { body = JSON.parse(res.responseText) } catch (e) { body = null }
            var classified = res.timedOut ? { terminal: false, result: null }
                                          : _classifyDeltaResponse(res.status, body)

            if (classified.terminal) {
                OutboxStore.markSent(item.requestId)
            } else {
                console.warn("[Gateway] recordDelta failed", "timedOut:", res.timedOut, "status:", res.status,
                             item.entity, item.entityId, res.responseText)
                OutboxStore.markFailed(item.requestId)
                _noteFailure(item, res.timedOut ? StuckWrites.TIMEOUT : res.status)
            }
            OutboxStore.clearInFlight(item)

            if (classified.terminal) {
                var callbacks = _deltaCallbacks[item.requestId] || []
                var map = Object.assign({}, _deltaCallbacks)
                delete map[item.requestId]
                _deltaCallbacks = map
                for (var i = 0; i < callbacks.length; ++i)
                    callbacks[i](classified.result)
            }
            _reschedule()
        })
    }
```

In `_send` and `_sendBatch` the same substitution applies; keep their conflict parsing (`_parseMutationConflict`, `_classifyBatchMutationFailure`) exactly as it is, feeding it `res.status` and `res.responseText`.

- [ ] **Step 4: Push, confirm CI passes.** Also re-run `tst_Gateway.qml` (unchanged, must stay green).

- [ ] **Step 5: Commit**

```bash
git add qml/model/Gateway.qml tests/tst_Gateway_send.qml
git commit -m "feat(gateway): shared send helper with timeout, XHR seam, timeouts feed StuckWrites"
```

### Task 8: `Gateway.recordOperation`, `_sendOperation`, await mode, signals

**Files:**
- Modify: `qml/model/Gateway.qml`
- Test: `tests/tst_Gateway_operation.qml` (new)

**Interfaces:**
- Consumes: `OutboxStore.enqueueOperation` (Task 6), `_xhrPost` (Task 7), `_classifyDeltaResponse` (existing, reused unchanged: its semantics are exactly right for operations).
- Produces: `Gateway.operationFunctionUrl`, `Gateway.maxOperationOps` (200), `recordOperation(opType, ops, opKey, options, callback)`, signals `operationApplied(requestId, opType, results, replay)` and `operationRejected(requestId, opType, rejection)`. Callback shapes: `{ ok: true, results, idempotentReplay }` (server applied), `{ ok: true, queued: true, requestId }` (not awaiting, or offline), `{ ok: false, pending: true, error: "timeout", requestId }` (await window ended, still queued), `{ ok: false, error, opIndex, field, current, conflict }` (rejected), `{ ok: false, error: "bad-request" | "operation-requires-gateway-mode" }`.

- [ ] **Step 1: Write the failing tests.** `tests/tst_Gateway_operation.qml` (same fake-XHR setup as Task 7):

```qml
import QtQuick
import QtTest
import "../qml/model"

TestCase {
    name: "GatewayOperation"

    property var made: []
    property var applied: []
    property var rejected: []

    function _fakeFactory() {
        return function() {
            var x = {
                readyState: 0, status: 0, responseText: "", aborted: false, sent: null, url: "",
                onreadystatechange: null,
                open: function(m, u) { x.url = u },
                setRequestHeader: function() {},
                getAllResponseHeaders: function() { return "" },
                send: function(body) { x.sent = body },
                abort: function() { x.aborted = true; x.readyState = 4; x.status = 0; if (x.onreadystatechange) x.onreadystatechange() },
                respond: function(status, bodyObj) { x.readyState = 4; x.status = status; x.responseText = JSON.stringify(bodyObj); if (x.onreadystatechange) x.onreadystatechange() }
            }
            made.push(x)
            return x
        }
    }

    Connections {
        target: Gateway
        function onOperationApplied(requestId, opType, results, replay) { applied.push({ requestId: requestId, opType: opType, results: results, replay: replay }) }
        function onOperationRejected(requestId, opType, rejection) { rejected.push({ requestId: requestId, opType: opType, rejection: rejection }) }
    }

    function _ops(n) {
        var out = []
        for (var i = 0; i < n; ++i)
            out.push({ kind: "delta", entity: "inventory", entityId: "p" + i, deltas: { stock: -1 }, floors: { stock: 0 }, clamps: {} })
        return out
    }

    function init() {
        made = []; applied = []; rejected = []
        OutboxStore.clear(); Gateway.clear()
        Gateway.mode = "gateway"
        Gateway.xhrFactory = _fakeFactory()
        Gateway.backgroundTimeoutMs = 5000
        Gateway.awaitTimeoutMs = 60
        AuthStore.idToken = "test-token"
        AuthService.isOnline = true
    }

    function cleanup() {
        AuthStore.idToken = ""
        Gateway.mode = "direct"
        Gateway.awaitTimeoutMs = 10000
        Gateway.backgroundTimeoutMs = 30000
        Gateway.xhrFactory = function() { return new XMLHttpRequest() }
        OutboxStore.clear()
    }

    function test_maxOperationOps_mirrors_the_server_limit() {
        compare(Gateway.maxOperationOps, 200)
    }

    // -- validation ---------------------------------------------------------------

    function test_rejects_bad_requests_without_touching_the_outbox() {
        var got = []
        Gateway.recordOperation("completeOrder", [], "k1", {}, function(r) { got.push(r) })
        Gateway.recordOperation("completeOrder", _ops(1), "", {}, function(r) { got.push(r) })
        Gateway.recordOperation("completeOrder", _ops(201), "k2", {}, function(r) { got.push(r) })
        Gateway.recordOperation("completeOrder", "nope", "k3", {}, function(r) { got.push(r) })
        compare(got.length, 4)
        for (var i = 0; i < got.length; ++i) { compare(got[i].ok, false); compare(got[i].error, "bad-request") }
        compare(OutboxStore.items.length, 0)
    }

    function test_200_ops_is_accepted() {
        Gateway.recordOperation("completeOrder", _ops(200), "k200", {}, function() {})
        compare(OutboxStore.items.length, 1)
    }

    function test_requires_gateway_mode() {
        Gateway.mode = "direct"
        var got = null
        Gateway.recordOperation("completeOrder", _ops(1), "k1", {}, function(r) { got = r })
        compare(got.error, "operation-requires-gateway-mode")
        compare(OutboxStore.items.length, 0)
    }

    // -- queued / offline ---------------------------------------------------------

    function test_not_awaiting_returns_queued_immediately_and_still_sends() {
        var got = null
        Gateway.recordOperation("completeOrder", _ops(2), "k1", {}, function(r) { got = r })
        compare(got.ok, true); compare(got.queued, true); compare(got.requestId, "k1")
        compare(made.length, 1)
        compare(made[0].url, Gateway.operationFunctionUrl)
        var sent = JSON.parse(made[0].sent)
        compare(sent.requestId, "k1"); compare(sent.opType, "completeOrder"); compare(sent.ops.length, 2)
    }

    function test_offline_never_waits_even_when_asked_to() {
        AuthService.isOnline = false
        var got = null
        Gateway.recordOperation("completeOrder", _ops(1), "k1", { awaitServer: true }, function(r) { got = r })
        compare(got.queued, true)
        AuthService.isOnline = true
    }

    // -- awaiting -----------------------------------------------------------------

    function test_awaiting_gets_the_servers_answer_when_it_arrives_in_time() {
        var got = null
        Gateway.recordOperation("completeOrder", _ops(1), "k1", { awaitServer: true }, function(r) { got = r })
        compare(got, null, "nothing until the server answers")
        made[0].respond(200, { ok: true, entryId: "k1", results: [{ entity: "inventory", entityId: "p0", kind: "delta", after: { stock: 4 } }], idempotentReplay: false })
        compare(got.ok, true)
        compare(got.results[0].after.stock, 4)
        compare(OutboxStore.items.length, 0)
        compare(applied.length, 1); compare(applied[0].replay, false)
    }

    function test_awaiting_reports_a_replay() {
        var got = null
        Gateway.recordOperation("completeOrder", _ops(1), "k1", { awaitServer: true }, function(r) { got = r })
        made[0].respond(200, { ok: true, entryId: "k1", results: [], idempotentReplay: true })
        compare(got.idempotentReplay, true)
        compare(applied[0].replay, true)
    }

    function test_awaiting_that_runs_out_of_time_says_pending_and_the_item_stays_queued() {
        var got = []
        Gateway.recordOperation("completeOrder", _ops(1), "k1", { awaitServer: true }, function(r) { got.push(r) })
        tryVerify(function() { return got.length === 1 }, 1000)
        compare(got[0].ok, false); compare(got[0].pending, true); compare(got[0].error, "timeout")
        compare(OutboxStore.items.length, 1)
        // The request is still in flight (transport timeout is the longer one). When it
        // finally answers, the callback must NOT fire a second time; the signal does.
        made[0].respond(200, { ok: true, entryId: "k1", results: [], idempotentReplay: false })
        compare(got.length, 1)
        compare(applied.length, 1)
    }

    // -- rejection ----------------------------------------------------------------

    function test_a_floor_rejection_is_terminal_and_removed_from_the_outbox() {
        var got = null
        Gateway.recordOperation("completeOrder", _ops(2), "k1", { awaitServer: true }, function(r) { got = r })
        made[0].respond(409, { ok: false, error: "insufficient-quantity", opIndex: 1, field: "stock", current: 0 })
        compare(got.ok, false); compare(got.error, "insufficient-quantity")
        compare(got.opIndex, 1); compare(got.field, "stock"); compare(got.current, 0)
        compare(OutboxStore.items.length, 0)
        compare(rejected.length, 1); compare(rejected[0].rejection.opIndex, 1)
    }

    function test_a_5xx_is_retried_not_terminal() {
        var got = null
        Gateway.recordOperation("completeOrder", _ops(1), "k1", { awaitServer: true }, function(r) { got = r })
        made[0].respond(503, { ok: false, error: "unavailable" })
        compare(got, null)
        compare(OutboxStore.items.length, 1)
        compare(OutboxStore.items[0].attempts, 1)
        compare(rejected.length, 0)
    }

    function test_a_non_json_body_is_retried() {
        Gateway.recordOperation("completeOrder", _ops(1), "k1", {}, function() {})
        made[0].readyState = 4; made[0].status = 200; made[0].responseText = "<html>"
        made[0].onreadystatechange()
        compare(OutboxStore.items.length, 1)
        compare(OutboxStore.items[0].attempts, 1)
    }

    // -- identity -----------------------------------------------------------------

    function test_the_same_key_twice_queues_one_item_and_both_callers_get_the_answer() {
        var a = null, b = null
        Gateway.recordOperation("completeOrder", _ops(1), "k1", { awaitServer: true }, function(r) { a = r })
        Gateway.recordOperation("completeOrder", _ops(1), "k1", { awaitServer: true }, function(r) { b = r })
        compare(OutboxStore.items.length, 1)
        made[made.length - 1].respond(200, { ok: true, entryId: "k1", results: [], idempotentReplay: false })
        compare(a.ok, true); compare(b.ok, true)
    }

    function test_clear_drops_callbacks_and_the_queue() {
        var got = null
        Gateway.recordOperation("completeOrder", _ops(1), "k1", { awaitServer: true }, function(r) { got = r })
        Gateway.clear()
        compare(OutboxStore.items.length, 0)
        made[0].respond(200, { ok: true, entryId: "k1", results: [], idempotentReplay: false })
        compare(got, null, "a callback registered before sign-out must not fire after it")
    }

    // Monkey: whatever order the server's answers arrive in, every operation ends
    // either applied, rejected or still queued, and the outbox never holds a
    // terminal one.
    function test_monkey_random_outcomes_leave_a_consistent_outbox() {
        var s = 20260920
        function rnd() { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296 }
        var outcomes = [
            function(x) { x.respond(200, { ok: true, entryId: "x", results: [], idempotentReplay: false }) },
            function(x) { x.respond(409, { ok: false, error: "conflict", conflict: true, opIndex: 0, current: {} }) },
            function(x) { x.respond(503, { ok: false, error: "down" }) },
            function(x) { x.respond(200, { ok: true, entryId: "x", results: [], idempotentReplay: true }) }
        ]
        for (var n = 0; n < 40; ++n) {
            Gateway.recordOperation("completeOrder", _ops(1 + Math.floor(rnd() * 3)), "mk" + n, {}, function() {})
        }
        for (var i = 0; i < made.length; ++i) outcomes[Math.floor(rnd() * outcomes.length)](made[i])
        var terminal = applied.length + rejected.length
        var queued = OutboxStore.items.length
        verify(terminal + queued >= 1)
        for (var q = 0; q < OutboxStore.items.length; ++q) verify(OutboxStore.items[q].attempts >= 0)
        compare(Gateway.inFlight >= 0, true)
    }
}
```

- [ ] **Step 2: Push, confirm CI's QML job fails** (`recordOperation` undefined).

- [ ] **Step 3: Implement.** In `qml/model/Gateway.qml`:

```qml
    property string operationFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordOperation"

    // Mirrors MAX_OPS in functions/lib/operationLogic.js and CompletionPlan.MAX_OPS.
    readonly property int maxOperationOps: 200

    // Terminal outcomes of an operation, for callers whose callback died with a
    // relaunch (callbacks are in-memory, like _deltaCallbacks).
    signal operationApplied(string requestId, string opType, var results, bool replay)
    signal operationRejected(string requestId, string opType, var rejection)

    // requestId -> [ { fn, timer } ]: callers waiting on the server (awaitServer).
    property var _operationWaiters: ({})
```

```qml
    // Send one atomic multi-write operation through the outbox. `opKey` is the
    // requestId: the SAME key always means the SAME operation, so a re-run after a
    // hang, a relaunch or a sign-out/in is exactly-once on the server. See the spec.
    //   options.awaitServer: wait for the server's answer when online.
    // callback(result), see the plan for the five shapes.
    function recordOperation(opType, ops, opKey, options, callback) {
        if (mode !== "gateway") {
            if (callback) callback({ ok: false, error: "operation-requires-gateway-mode" })
            return ""
        }
        if (!opKey || !Array.isArray(ops) || ops.length === 0 || ops.length > maxOperationOps) {
            if (callback) callback({ ok: false, error: "bad-request" })
            return ""
        }
        var online = (typeof AuthService !== "undefined" && AuthService) ? AuthService.isOnline === true : false
        var awaiting = !!(options && options.awaitServer) && online
        var item = OutboxStore.enqueueOperation({
            requestId: opKey, opType: opType, ops: ops,
            clientTimestamp: new Date().toISOString()
        })
        if (callback) {
            if (awaiting) _addOperationWaiter(item.requestId, callback)
            else callback({ ok: true, queued: true, requestId: item.requestId })
        }
        drainNow()
        return item.requestId
    }

    function _addOperationWaiter(requestId, fn) {
        var timer = Qt.createQmlObject('import QtQuick; Timer { repeat: false }', root, "GatewayAwaitTimer")
        timer.interval = awaitTimeoutMs
        var waiter = { fn: fn, timer: timer }
        timer.triggered.connect(function() {
            // The UI stops waiting; the request itself keeps going (transport timeout is longer).
            var list = (_operationWaiters[requestId] || []).filter(function(w) { return w !== waiter })
            var map = Object.assign({}, _operationWaiters)
            if (list.length > 0) map[requestId] = list; else delete map[requestId]
            _operationWaiters = map
            timer.destroy()
            fn({ ok: false, pending: true, error: "timeout", requestId: requestId })
        })
        var all = Object.assign({}, _operationWaiters)
        all[requestId] = (all[requestId] || []).concat([waiter])
        _operationWaiters = all
        timer.start()
    }

    function _finishOperation(item, result) {
        var waiters = _operationWaiters[item.requestId] || []
        var map = Object.assign({}, _operationWaiters)
        delete map[item.requestId]
        _operationWaiters = map
        for (var i = 0; i < waiters.length; ++i) { waiters[i].timer.stop(); waiters[i].timer.destroy(); waiters[i].fn(result) }
        if (result.ok) operationApplied(item.requestId, item.opType, result.results || [], result.idempotentReplay === true)
        else operationRejected(item.requestId, item.opType, result)
    }

    function _sendOperation(item) {
        if (!AuthStore.idToken || AuthStore.idToken.length === 0) {
            OutboxStore.clearInFlight(item)
            return
        }
        inFlight++
        _xhrPost(operationFunctionUrl, JSON.stringify({
            env: FirebaseService.environment,
            requestId: item.requestId,
            opType: item.opType,
            ops: item.ops,
            clientTimestamp: item.clientTimestamp
        }), backgroundTimeoutMs, function(res) {
            inFlight--
            var body = null
            try { body = JSON.parse(res.responseText) } catch (e) { body = null }
            var classified = res.timedOut ? { terminal: false, result: null }
                                          : _classifyDeltaResponse(res.status, body)
            if (classified.terminal) {
                OutboxStore.markSent(item.requestId)
            } else {
                console.warn("[Gateway] recordOperation failed", "timedOut:", res.timedOut, "status:", res.status, item.requestId)
                OutboxStore.markFailed(item.requestId)
                _noteFailure(item, res.timedOut ? StuckWrites.TIMEOUT : res.status)
            }
            OutboxStore.clearInFlight(item)
            if (classified.terminal) _finishOperation(item, classified.result)
            _reschedule()
        })
    }
```

In `drainNow`, add the dispatch branch before the plain `_send`:

```qml
            else if (due[i].ops) _sendOperation(due[i])
```

In `clear()`, first stop and destroy any waiter timers, then reset the map:

```qml
        var keys = Object.keys(_operationWaiters)
        for (var w = 0; w < keys.length; ++w)
            for (var v = 0; v < _operationWaiters[keys[w]].length; ++v) {
                _operationWaiters[keys[w]][v].timer.stop()
                _operationWaiters[keys[w]][v].timer.destroy()
            }
        _operationWaiters = ({})
```

- [ ] **Step 4: Push, confirm CI passes.**

- [ ] **Step 5: Commit**

```bash
git add qml/model/Gateway.qml tests/tst_Gateway_operation.qml
git commit -m "feat(gateway): recordOperation with await mode, pending fallback and applied/rejected signals"
```

### Task 9: Store hooks — local-only entry points and the pure builders

**Files:**
- Modify: `qml/model/InventoryStore.qml`, `qml/model/StockBatchStore.qml`, `qml/model/OrdersStore.qml`, `qml/model/TransactionStore.qml`
- Test: `tests/tst_InventoryStore_applyRemote.qml`, `tests/tst_StockBatchStore_applyRemote.qml`, `tests/tst_OrdersStore_buildOrderUpdate.qml`, `tests/tst_TransactionStore_buildSaleDocs.qml` (new)

**Interfaces:**
- Produces (none of these send anything):
  - `InventoryStore.applyRemoteStock(productId, stock)` returns the previous stock, or `undefined` if the product is unknown.
  - `StockBatchStore.applyRemoteQty(batchId, qtyRemaining)` returns the previous quantity or `undefined`; `addLocalBatch(doc)` (no-op if the id exists, returns bool); `removeLocalBatch(batchId)` returns bool.
  - `OrdersStore.buildOrderUpdate(orderId, fields)` returns `{ before, after }` (the pure half of `updateOrder`; `fields` gains `completionEpoch`) or `null`; `updateOrder` is refactored to call it; `applyRemoteOrder(doc)` replaces the local order (bumps `revision`) and returns the previous one or `null`.
  - `TransactionStore.buildSaleDocs(order, epoch, legacyIds)` returns one doc per line. With `legacyIds` false the id is `OperationKeys.saleTxId(order.orderId, epoch, lineIndex)`; with `legacyIds` true it keeps today's random `_nextId("s")`, and `recordSaleFromOrder` (used by `_completeImportedOrder` and any other current caller) is refactored to call it that way, so those callers behave exactly as before. `addLocalEntries(docs)` (skips ids already present, returns how many were added) and `removeLocalEntries(txIds)`.

- [ ] **Step 1: Write the failing tests** (one file per store; each drives the real singleton's state directly, like the existing `tst_*Store_*.qml` files). Minimum cases per hook: unknown id returns `undefined`/`null`/`false`; happy path changes exactly the targeted record and returns the previous value; a second identical call is idempotent (`addLocalBatch`, `addLocalEntries`); `revision` bumps where the store's readers depend on it; `buildOrderUpdate` returns `null` for an unknown order, returns `before` equal to the untouched stored copy and `after` with recomputed totals when `products` changes, carries `completionEpoch`, and does NOT touch `OrdersStore.orders` or call the Gateway (assert `OutboxStore.items.length` unchanged); `buildSaleDocs` yields deterministic ids and identical output on two calls, skips zero-quantity lines, and matches `recordSaleFromOrder`'s previous doc shape field for field (compare against a fixture captured from the old function before refactoring it).

- [ ] **Step 2: Push, confirm CI fails on the missing functions.**

- [ ] **Step 3: Implement.** Reference implementations:

```qml
// InventoryStore.qml
    function applyRemoteStock(productId, stock) {
        var arr = _clone()
        for (var i = 0; i < arr.length; ++i) {
            if (arr[i].productId !== productId) continue
            var previous = arr[i].stock
            arr[i].stock = stock
            products = arr
            return previous
        }
        return undefined
    }
```

```qml
// StockBatchStore.qml
    function applyRemoteQty(batchId, qtyRemaining) {
        for (var i = 0; i < batches.length; ++i) {
            if (batches[i].batchId !== batchId) continue
            var previous = batches[i].qtyRemaining
            var arr = batches.slice()
            arr[i] = Object.assign({}, batches[i], { qtyRemaining: qtyRemaining })
            batches = arr
            return previous
        }
        return undefined
    }

    function addLocalBatch(doc) {
        for (var i = 0; i < batches.length; ++i) if (batches[i].batchId === doc.batchId) return false
        var arr = batches.slice()
        arr.push(doc)
        batches = arr
        return true
    }

    function removeLocalBatch(batchId) {
        var arr = []
        var removed = false
        for (var i = 0; i < batches.length; ++i) {
            if (batches[i].batchId === batchId) removed = true
            else arr.push(batches[i])
        }
        if (removed) batches = arr
        return removed
    }
```

```qml
// OrdersStore.qml — split updateOrder's body: everything up to (not including) _commit moves into
    function buildOrderUpdate(orderId, fields) {
        var idx = findIndexById(orderId)
        if (idx < 0) return null
        var arr = _clone()
        var o = arr[idx]
        var before = Object.assign({}, o)
        // ... the existing `if (fields.x !== undefined) o.x = fields.x` block, unchanged,
        //     plus:  if (fields.completionEpoch !== undefined) o.completionEpoch = fields.completionEpoch
        // ... the existing totals recomputation and `o.updatedAt = ...`, unchanged
        return { before: before, after: _normalizeOrder(o), arr: arr, idx: idx }
    }

    function updateOrder(orderId, fields) {
        var r = buildOrderUpdate(orderId, fields)
        if (!r) return
        _commit(r.arr, r.after, "update", r.before)
    }

    function applyRemoteOrder(doc) {
        var idx = findIndexById(doc.orderId)
        if (idx < 0) return null
        var arr = _clone()
        var previous = arr[idx]
        arr[idx] = _normalizeOrder(Object.assign({}, doc))
        orders = arr
        revision++
        _refreshCounts()
        return previous
    }
```

The planner reads `before`/`after` only; strip the helper fields when passing to hooks: DataModel's `orderUpdate` hook returns `{ before: r.before, after: r.after }`.

```qml
// TransactionStore.qml — extract the doc construction from recordSaleFromOrder
    function buildSaleDocs(order, epoch, legacyIds) {
        // ... the existing body up to and including `var doc = { ... }`, with
        //     txId: legacyIds ? _nextId("s") : OperationKeys.saleTxId(order.orderId, epoch, i)
        //     and each doc pushed to a returned array instead of _push(doc)
    }

    function recordSaleFromOrder(order) {
        var docs = buildSaleDocs(order, 0, true)
        for (var i = 0; i < docs.length; ++i) _push(docs[i])
    }

    function addLocalEntries(docs) {
        var have = {}
        for (var i = 0; i < entries.length; ++i) have[entries[i].txId] = true
        var arr = (entries || []).slice()
        var added = 0
        for (var j = 0; j < docs.length; ++j)
            if (!have[docs[j].txId]) { arr.unshift(docs[j]); added++ }
        if (added > 0) { entries = arr; revision++ }
        return added
    }

    function removeLocalEntries(txIds) {
        var drop = {}
        for (var i = 0; i < txIds.length; ++i) drop[txIds[i]] = true
        var arr = []
        for (var j = 0; j < entries.length; ++j) if (!drop[entries[j].txId]) arr.push(entries[j])
        if (arr.length !== entries.length) { entries = arr; revision++ }
    }
```

(`buildSaleDocs(order, epoch, legacyIds)`: when `legacyIds` is true it keeps `_nextId("s")`, so `_completeImportedOrder` and any other current caller behave exactly as before.)

- [ ] **Step 4: Push, confirm CI passes**, including every existing test in the four stores' files (the refactors must not change behaviour).

- [ ] **Step 5: Commit**

```bash
git add qml/model/InventoryStore.qml qml/model/StockBatchStore.qml qml/model/OrdersStore.qml qml/model/TransactionStore.qml tests/tst_InventoryStore_applyRemote.qml tests/tst_StockBatchStore_applyRemote.qml tests/tst_OrdersStore_buildOrderUpdate.qml tests/tst_TransactionStore_buildSaleDocs.qml
git commit -m "feat(stores): local-only hooks and pure builders for the atomic completion operation"
```

### Task 10: `DataModel._tryCompleteOrder` on the operation

**Files:**
- Modify: `qml/model/DataModel.qml`
- Test: `tests/tst_DataModel_completeOrderAtomic.qml` (new); existing `tst_DataModel_completeOrderReentrancy.qml` must stay green.

**Interfaces:**
- Consumes: Tasks 4-9.
- Produces: `_tryCompleteOrder(orderId, callback)` keeps its signature and its guard/`stockErrorMsg`/`out of stock` behaviour; `callback(true)` means the sale is booked (applied by the server, or queued and shown as completed), `callback(false)` means it failed and `stockErrorMsg` says why. Removes the `_afterAllDeltas` compensation (`restoreFifo` / `creditStockNoBatch`) because the transaction is atomic.

- [ ] **Step 1: Write the failing tests** using the fake XHR from Task 7/8 through the real singletons. Required cases (each is a test function; write them all before any implementation):
  1. Online, server applies: order becomes `completed`, stock and batch caches equal the response's `after` values, sale docs added, guard released, `callback(true)`, exactly one request whose `requestId` is `completeOrder:{id}:1`.
  2. Insufficient product stock (local validation): `out of stock` status, message `"{name}: need N, only M in stock"`, no request sent, guard released, `callback(false)`.
  3. Online, server rejects the `inventory` op with `insufficient-quantity`: message `"stock ran out before this order could complete"`, `out of stock`, `callback(false)`, no local stock change.
  4. Online, server rejects a `stock_batch` op with `current` (another device drained it): local batch quantity is reconciled to `current`, the plan is rebuilt and resent under the SAME key, then succeeds; exactly two requests, same `requestId`.
  5. Re-plan is bounded: four rejections in a row (the original plan plus `maxReplans` = 3 re-plans) end in `out of stock` and `callback(false)`; a fifth request is never sent.
  6. Await window ends (fake never answers, `awaitTimeoutMs` short): predicted state applied locally, order shows `completed`, `callback(true)`, guard still set; then the fake answers `200` and the local state is overwritten with the server's `after` and the guard is released.
  7. Offline (`AuthService.isOnline = false`): same as 6 without waiting.
  8. Queued, then rejected at sync (`operationRejected` with a floor failure): the predicted state is reverted, the plan is rebuilt with `clampStock: true`, resent under the same key, and on success the order stays `completed` with a repair batch present and product stock clamped at 0.
  9. Replay with different local state: the server answers `idempotentReplay: true`; local caches equal the response's `after`, not the plan's prediction.
  10. THE C-3 REGRESSION: run a completion whose request never answers; call `Gateway.clear()` (sign-out); reload the order as `pending`; complete it again. The second request's `requestId` equals the first's. Then answer the second with `idempotentReplay: true` and assert stock/batches changed once.
  11. Reopen then re-complete: after a completion with `completionEpoch: 1` is reversed to `pending`, the next completion's key ends `:2`.
  12. `too-many-ops` (an order that plans 201 ops): `out of stock` status is NOT set, `stockErrorMsg` carries the limit message, `callback(false)`.
  13. Already `completed` returns `callback(true)` without a request; in-flight guard returns `callback(false)` with `"This order is already being completed — please wait"`.
  14. Sale doc ids are `tx-s-{orderId}-{epoch}-{line}` and are not duplicated by a replay.
  15. Monkey (seeded, 200 runs): random orders and random server outcomes (apply, replay, floor rejection on a random op, 503, no answer) never leave the guard set after a terminal outcome, never leave `stock` negative (except via an explicit clamp), and never send a second distinct `requestId` for one order at one epoch.

- [ ] **Step 2: Push, confirm CI fails.**

- [ ] **Step 3: Implement.** Add imports `import "../helper/CompletionPlan.js" as CompletionPlan` and `import "../helper/OperationKeys.js" as OperationKeys`. Replace `_tryCompleteOrder` (keep its doc comment) with:

```qml
    readonly property int maxReplans: 3

    // key -> { orderId, attempt, clampStock, plan, undo, callback }: operations whose
    // outcome is still open. In-memory on purpose; the outbox is what is durable.
    property var _openCompletions: ({})

    function _tryCompleteOrder(orderId, callback) {
        var o = OrdersStore.getById(orderId)
        if (!o) { if (callback) callback(false); return }
        if (o.status === "completed") { if (callback) callback(true); return }
        if (dataModel._completingOrderIds[orderId]) {
            dataModel.stockErrorMsg = "This order is already being completed — please wait"
            if (callback) callback(false)
            return
        }
        dataModel._completingOrderIds[orderId] = true
        _completeAttempt(orderId, false, 0, callback)
    }

    function _completionInput(o, epoch, clampStock) {
        var lines = []
        var stockByProduct = {}
        var batchesByProduct = {}
        var products = o.products || []
        for (var i = 0; i < products.length; ++i) {
            var p = products[i]
            var inv = _resolveInventory(p)
            lines.push({ line: p, productId: inv ? inv.productId : "", name: p.name, qty: _lineQty(p) })
            if (!inv) continue
            stockByProduct[inv.productId] = inv.stock
            if (!(inv.productId in batchesByProduct))
                batchesByProduct[inv.productId] = StockBatchStore.forProduct(inv.productId)
        }
        return { orderId: o.orderId, epoch: epoch, now: new Date().toISOString(), clampStock: clampStock,
                 lines: lines, stockByProduct: stockByProduct, batchesByProduct: batchesByProduct }
    }

    function _completionHooks(orderId, epoch) {
        return {
            orderUpdate: function(lines) {
                var r = OrdersStore.buildOrderUpdate(orderId, { status: "completed", products: lines, completionEpoch: epoch })
                return { before: r.before, after: r.after }
            },
            saleDocs: function(orderAfter) { return TransactionStore.buildSaleDocs(orderAfter, epoch) }
        }
    }

    function _completeAttempt(orderId, clampStock, attempt, callback) {
        var o = OrdersStore.getById(orderId)
        var epoch = OperationKeys.nextEpoch(o)
        var plan = CompletionPlan.build(_completionInput(o, epoch, clampStock), _completionHooks(orderId, epoch))
        if (!plan.ok) {
            _failCompletion(orderId, plan.errors.join("\n"), plan.reason === "out-of-stock", callback)
            return
        }
        var open = { orderId: orderId, attempt: attempt, clampStock: clampStock, plan: plan, undo: null, callback: callback }
        _openCompletions[plan.key] = open
        var online = (typeof AuthService !== "undefined" && AuthService) ? AuthService.isOnline === true : false
        Gateway.recordOperation("completeOrder", plan.ops, plan.key, { awaitServer: online }, function(res) {
            _onCompletionResult(plan.key, res)
        })
    }

    function _failCompletion(orderId, message, markOutOfStock, callback) {
        delete dataModel._completingOrderIds[orderId]
        if (markOutOfStock) OrdersStore.updateOrder(orderId, { status: "out of stock" })
        dataModel.stockErrorMsg = message
        _updateOrderInModel(orderId)
        if (callback) callback(false)
    }

    function _onCompletionResult(key, res) {
        var open = _openCompletions[key]
        if (!open) return
        if (res.ok && !res.queued) { _settleApplied(key, res.results); return }
        if (res.ok || res.pending) {            // queued, offline, or the wait ran out: show it as done
            if (!open.undo) open.undo = _applyPredicted(open.plan)
            _updateOrderInModel(open.orderId)
            if (open.callback) { var cb = open.callback; open.callback = null; cb(true) }
            return
        }
        _onCompletionRejected(key, res)
    }

    // The server's answer is the truth: overwrite whatever was predicted.
    function _settleApplied(key, results) {
        var open = _openCompletions[key]
        if (!open) return
        _reflectResults(results)
        delete _openCompletions[key]
        delete dataModel._completingOrderIds[open.orderId]
        _updateOrderInModel(open.orderId)
        if (open.callback) { var cb = open.callback; open.callback = null; cb(true) }
    }

    function _onCompletionRejected(key, rejection) {
        var open = _openCompletions[key]
        if (!open) return
        var op = open.plan.ops[rejection.opIndex]
        if (open.undo) { _revertPredicted(open.undo); open.undo = null }
        // Someone else already completed it: the operation's job is done.
        if (rejection.conflict && op && op.entity === "order" && rejection.current && rejection.current.status === "completed") {
            OrdersStore.applyRemoteOrder(rejection.current)
            _settleApplied(key, [])
            return
        }
        var wasQueued = open.callback === null      // the caller was already told "done"
        var onStockOp = op && op.entity === "inventory"
        if (onStockOp && !wasQueued && rejection.error === "insufficient-quantity") {
            delete _openCompletions[key]
            _failCompletion(open.orderId, (_nameForProduct(op.entityId) + ": stock ran out before this order could complete"), true, open.callback)
            return
        }
        if (open.attempt >= maxReplans) {
            delete _openCompletions[key]
            _failCompletion(open.orderId, "Could not complete this order — please try again", true, open.callback)
            return
        }
        _reconcileFromRejection(op, rejection)
        delete _openCompletions[key]
        // D3: a sale that already happened is applied anyway (clamp + repair batch).
        _completeAttempt(open.orderId, open.clampStock || wasQueued, open.attempt + 1, open.callback)
    }

    function _reconcileFromRejection(op, rejection) {
        if (!op || rejection.current === undefined || rejection.current === null) return
        if (op.entity === "stock_batch") StockBatchStore.applyRemoteQty(op.entityId, rejection.current)
        else if (op.entity === "inventory") InventoryStore.applyRemoteStock(op.entityId, rejection.current)
        else if (op.entity === "order") OrdersStore.applyRemoteOrder(rejection.current)
    }

    function _nameForProduct(productId) {
        var inv = InventoryStore.getById(productId)
        return inv ? inv.name : productId
    }

    // Apply the plan's predicted post-state locally and remember how to undo it.
    function _applyPredicted(plan) {
        var undo = { batches: {}, stock: {}, createdBatches: [], order: null, txIds: [] }
        for (var b in plan.predicted.batches) undo.batches[b] = StockBatchStore.applyRemoteQty(b, plan.predicted.batches[b])
        for (var p in plan.predicted.stock) undo.stock[p] = InventoryStore.applyRemoteStock(p, plan.predicted.stock[p])
        for (var c = 0; c < plan.predicted.created.length; ++c) {
            if (StockBatchStore.addLocalBatch(plan.predicted.created[c])) undo.createdBatches.push(plan.predicted.created[c].batchId)
        }
        undo.order = OrdersStore.applyRemoteOrder(plan.orderAfter)
        var docs = []
        for (var o = 0; o < plan.ops.length; ++o)
            if (plan.ops[o].entity === "transaction") docs.push(plan.ops[o].after)
        TransactionStore.addLocalEntries(docs)
        for (var d = 0; d < docs.length; ++d) undo.txIds.push(docs[d].txId)
        return undo
    }

    function _revertPredicted(undo) {
        for (var b in undo.batches) if (undo.batches[b] !== undefined) StockBatchStore.applyRemoteQty(b, undo.batches[b])
        for (var p in undo.stock) if (undo.stock[p] !== undefined) InventoryStore.applyRemoteStock(p, undo.stock[p])
        for (var c = 0; c < undo.createdBatches.length; ++c) StockBatchStore.removeLocalBatch(undo.createdBatches[c])
        if (undo.order) OrdersStore.applyRemoteOrder(undo.order)
        TransactionStore.removeLocalEntries(undo.txIds)
    }

    // results: the server's [{ entity, entityId, kind, after }]
    function _reflectResults(results) {
        var docs = []
        for (var i = 0; i < results.length; ++i) {
            var r = results[i]
            if (r.entity === "stock_batch") {
                if (r.kind === "delta") StockBatchStore.applyRemoteQty(r.entityId, r.after.qtyRemaining)
                else StockBatchStore.addLocalBatch(r.after)
            } else if (r.entity === "inventory") {
                InventoryStore.applyRemoteStock(r.entityId, r.after.stock)
            } else if (r.entity === "order") {
                OrdersStore.applyRemoteOrder(r.after)
            } else if (r.entity === "transaction") {
                docs.push(r.after)
            }
        }
        if (docs.length > 0) TransactionStore.addLocalEntries(docs)
    }

    Connections {
        target: Gateway
        // Only for completions that were shown as done optimistically (undo set): a
        // caller still waiting gets its answer through its own callback, and handling the
        // same outcome here as well would run it twice (a re-plan reuses the same key).
        function onOperationApplied(requestId, opType, results, replay) {
            var open = dataModel._openCompletions[requestId]
            if (opType === "completeOrder" && open && open.undo) dataModel._settleApplied(requestId, results)
        }
        function onOperationRejected(requestId, opType, rejection) {
            var open = dataModel._openCompletions[requestId]
            if (opType === "completeOrder" && open && open.undo) dataModel._onCompletionRejected(requestId, rejection)
        }
    }
```

Notes for the implementer:
- `_settleApplied` after a callback already fired must not call the callback twice; the code above nulls `open.callback` when it fires. The `Connections` path and the callback path can both reach `_settleApplied`; the second sees no open record and returns.
- `_onCompletionResult(res.ok && !res.queued)` is the "server answered in time" case; `res.ok && res.queued` and `res.pending` both take the optimistic branch.
- Delete `_afterAllDeltas`, `succeededLines`, `pending`/`_oneResolved` and the per-line `consumeFifo`/`deductStock` chain from the old function. `StockBatchStore.consumeFifo`, `topUpOldest`, `InventoryStore.deductStock` and `restoreFifo` stay: the returns flow, imports and other callers still use them.
- `_completeImportedOrder` and `_reverseCompletedOrder` are unchanged in this task.

- [ ] **Step 4: Push, confirm CI passes**, including `tst_DataModel_completeOrderReentrancy.qml` and `tst_DataModel_adjustOrderSyncGuard.qml`. If the reentrancy tests assert on `consumeFifo` call shapes, update them to assert on the single `recordOperation` request instead, keeping every behavioural assertion.

- [ ] **Step 5: Commit**

```bash
git add qml/model/DataModel.qml tests/tst_DataModel_completeOrderAtomic.qml tests/tst_DataModel_completeOrderReentrancy.qml
git commit -m "fix: order completion is one atomic, replay-safe operation (C-3)"
```

### Task 11: "Saved, syncing" state for callers

**Files:**
- Modify: `qml/pages/OrderDetailDialog.qml`, `qml/pages/OrdersPage.qml` (approve-all loop), `qml/pages/NewOrderDialog.qml` (auto-approve path)
- Test: extend the existing headless dialog stand-in tests (see `tst_NewOrderDialogSubmit*.qml`); the rest is on-device.

**Interfaces:**
- Consumes: `_tryCompleteOrder`'s `callback(true)` now also means "queued, syncing". Add one read-only property `DataModel.completionsSyncing` (count of open completions with `undo !== null`) so screens can show a quiet "syncing" hint without new signals.

- [ ] **Step 1: Write the failing test** for `completionsSyncing` (0 initially, 1 after an offline completion, back to 0 after the server answers).
- [ ] **Step 2: Implement** `readonly property int completionsSyncing` as a binding over `_openCompletions` (recompute in `_applyPredicted`/`_settleApplied`), and show a one-line "Saved. Syncing…" caption in `OrderDetailDialog` while it is above 0 and the dialog's own order is open. No new blocking UI: the dialog closes as it does today; only the caption differs.
- [ ] **Step 3: Push, confirm CI; then on-device** (Task 13).
- [ ] **Step 4: Commit** `feat(ui): quiet "saved, syncing" hint while a completion is queued`.

### Task 12: Docs, tracker, coverage sweep

- [ ] **Step 1:** Update `docs/superpowers/ASYNC-REENTRANCY-BUGS.md`: mark C-3 fixed by this PR (root cause, fix, test names), and cross-link C-1 as the next consumer. Update `docs/superpowers/E2E-TESTING-ROADMAP.md`'s C-3 entry. Update `AGENTS.md`, `README.md`, `SKILLS.md` (one new Skill: "compound operations are one atomic outbox item with a deterministic key"; take the next free number at merge time).
- [ ] **Step 2:** Finalise `docs/superpowers/test-plans/2026-09-20-atomic-operation-outbox-test-plan.md`: replace every "planned" with the test file and count, and record which tests were genuinely run in CI.
- [ ] **Step 3:** Read the CI coverage output for `functions/` (line and branch) and confirm `operationLogic.js` is still 100%. For QML, list any branch in the new code without a test and either add the test or document it as unreachable in the test plan (repo convention). Do not claim QML coverage percentages: none are measured.
- [ ] **Step 4:** Commit `docs: C-3 fixed, skills/agents/readme, test plan finalised`.

### Task 13: Deploy and on-device verification (Taher)

- [ ] **Step 1 (Taher):** `firebase deploy --only functions:recordOperation` to the dev project; confirm `curl -i -X POST <url>` returns 401 `missing-token`.
- [ ] **Step 2:** Build the Phase 3 branch only when Taher asks, and run the on-device plan in the test plan (happy path, offline, kill-mid-flight, sign-out/in, two devices, reopen and re-complete, timeout tuning).
- [ ] **Step 3:** Record the measured cold-start and typical latency; adjust `SendPolicy` values in a follow-up if needed. Only then decide whether the circuit-breaker spec is worth starting.

---

## Self-review

- **Spec coverage:** server op (T1-2), keys/epochs (T4), planner + drift repair + D3 clamp (T5, T10), transport (T6-8), timeouts/jitter/await/fallback (T4, T7, T8), D5 (T3), local state (T9), rejection handling (T10), UX (T11), docs/tests/deploy (T12-13). Later items (breaker, `FirebaseService._request` timeouts, read fallbacks, C-1, server-first as default) are deliberately absent.
- **Placeholders:** none in Tasks 1-5 (code is verbatim from the verified run). Tasks 9 and 11 describe some test bodies by required cases rather than full code, and Task 7 gives the `_send`/`_sendBatch` change as a mechanical substitution because their exact text changes when #75 merges; each states this and what CI must show.
- **Type consistency:** `recordOperation(opType, ops, opKey, options, callback)`, `enqueueOperation({ requestId, opType, ops })`, `operationApplied(requestId, opType, results, replay)`, `operationRejected(requestId, opType, rejection)`, `CompletionPlan.build(input, hooks)` and the store hook names are used identically in every task that mentions them.
- **Known weak spot:** the optimistic apply / revert / re-plan logic in Task 10 is the most intricate part and has never run. Review it first, and expect CI plus the on-device plan to find problems.
