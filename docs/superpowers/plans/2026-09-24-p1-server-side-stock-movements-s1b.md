# P1 Stock Movements, Slice S1b (server: whole-record inventory mutations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the ledger completeness gap: `recordMutation`, `recordMutationsBatch` and `recordOperation` mutation ops on `inventory` also write a server-derived `stock_movements` row whenever the stock changes (create -> `receipt`, update / delete -> `adjustment`), so product create, edit, bulk import and delete can no longer change stock without a ledger row.

**Depends on:** S1a merged, deployed to dev and on-device checklist passed (`plans/2026-09-24-p1-server-side-stock-movements-s1a.md`).

**Architecture:** `movementLogic.deriveForMutation(action, before, after)` computes the row from stock before/after (stock absent or non-numeric counts as 0; delete counts as 0). Each of the three mutation paths calls it inside its existing transaction for entity `inventory` only. Whole-record mutations still reject client `movements` (S1a). `MAX_BATCH_SIZE` drops 200 -> 150 (3 writes per inventory item: doc + audit + row = 450 < 500), mirrored in `Gateway.qml`. Design: spec D11 and D13.

**Tech Stack:** Node 20 / `node --test` (server, verified in the sandbox); QML constants and e2e indices (CI-only, cannot run in the sandbox).

## Global Constraints

- Same as S1a: branch off latest `main` (e.g. `feature/2026-09-26-p1-s1b-derived-mutations`), Taher's commit identity, PAT only from chat and `grep -c ghp_ .git/config` must print 0 after pushing, no app build/run, no Qt install, DEV only.
- Row fields as in S1a; derived rows have `derived: true`, `reason ""`, `valueAtCost 0`. `productId` is the doc id, never client-supplied. Batch row id = `{requestId}:{entityId}~m0`, single mutation = `{requestId}~m0`, operation = `{requestId}~{opIndex}~m0`.
- Only entity `inventory` derives. A stock change of 0 (or float noise) derives nothing.
- The conflict (`before`) check runs first: a rejected mutation/batch/operation writes NOTHING, including no row.
- Run the whole suite with `node --test` from `functions/`.

## How this plan was verified (2026-09-24 design session)

Applied on top of the replayed S1a plan on a fresh copy of `main` @ `6da373d`: full `functions/` suite 313/313 (232 existing, 4 of them re-expected on purpose across S1a+S1b, + 81 new).
New/changed `lib/` files 100% line coverage. 12 deliberate mutations (S1a + S1b logic) all caught. The replay caught one real bug in a first draft (batch row read the doc AFTER writing it in the fake; now reads `item.before`). NOT verified: the QML/e2e edits in Task 5 (CI only).

## File map

| File | Change | Responsibility |
|---|---|---|
| `functions/lib/movementLogic.js` | modify | `stockOf`, `deriveForMutation` |
| `functions/lib/gatewayLogic.js` | modify | `applyMutation` writes the derived row |
| `functions/lib/batchMutationLogic.js` | modify | derived rows per item; reject `movements`; cap 150 |
| `functions/lib/operationLogic.js` | modify | mutation ops on inventory derive rows |
| `functions/test/movementDerive.test.js` | create | all S1b server tests |
| `functions/test/batchMutationLogic.test.js` | modify (1 test) | cap pin 200 -> 150 |
| `qml/model/Gateway.qml`, `tests/tst_Gateway.qml`, `test/e2e/tst_BulkImportChunkingE2E.qml`, `test/e2e/tst_OrdersStoreE2E.qml` | modify | client mirror of the cap and its pins |
| docs | modify | AGENTS.md, README.md, test plan, CHECKPOINT.md |

---

### Task 1: derive helpers (pure)

**Files:**
- Modify: `functions/lib/movementLogic.js`
- Create: `functions/test/movementDerive.test.js` (part 1; Tasks 2-4 append parts)

**Interfaces:**
- Produces: `stockOf(doc) -> number`; `deriveForMutation(action, before, after) -> [] | [derivedRow]`.

- [ ] **Step 1: Write the failing test** - create `functions/test/movementDerive.test.js`:

```js
"use strict";

// P1 slice S1b: whole-record inventory mutations (recordMutation, recordMutationsBatch,
// recordOperation mutation ops) leave a server-derived ledger row, so no stock change
// can bypass the ledger.

const test = require("node:test");
const assert = require("node:assert/strict");
const G = require("../lib/gatewayLogic");
const B = require("../lib/batchMutationLogic");
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

// ── movementLogic: stockOf / deriveForMutation ──────────────────────────────
test("stockOf: number, or 0 for anything else", () => {
    assert.equal(M.stockOf({ stock: 7 }), 7);
    assert.equal(M.stockOf({ stock: -2 }), -2);
    for (const bad of [null, undefined, {}, { stock: "5" }, { stock: NaN }, { stock: Infinity }, { stock: null }, 5, "x"])
        assert.equal(M.stockOf(bad), 0);
});

test("deriveForMutation: create with stock is a receipt; create with 0 or no stock derives nothing", () => {
    assert.deepEqual(M.deriveForMutation("create", null, { stock: 5 }), [{ kind: "receipt", qty: 5, reason: "", valueAtCost: 0, derived: true }]);
    assert.deepEqual(M.deriveForMutation("create", null, { stock: 0 }), []);
    assert.deepEqual(M.deriveForMutation("create", null, { name: "x" }), []);
});

test("deriveForMutation: update is an adjustment by the difference; unchanged stock derives nothing", () => {
    assert.deepEqual(M.deriveForMutation("update", { stock: 5 }, { stock: 8 })[0], { kind: "adjustment", qty: 3, reason: "", valueAtCost: 0, derived: true });
    assert.equal(M.deriveForMutation("update", { stock: 5 }, { stock: 2 })[0].qty, -3);
    assert.deepEqual(M.deriveForMutation("update", { stock: 5, name: "a" }, { stock: 5, name: "b" }), []);
});

test("deriveForMutation: delete takes the whole stock out; opening_balance and unknown actions are adjustments", () => {
    assert.deepEqual(M.deriveForMutation("delete", { stock: 4 }, null)[0], { kind: "adjustment", qty: -4, reason: "", valueAtCost: 0, derived: true });
    assert.deepEqual(M.deriveForMutation("delete", { stock: 0 }, null), []);
    assert.equal(M.deriveForMutation("opening_balance", { stock: 1 }, { stock: 6 })[0].kind, "adjustment");
    // a delete whose `after` still carries stock must not count it
    assert.equal(M.deriveForMutation("delete", { stock: 4 }, { stock: 4 })[0].qty, -4);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd functions && node --test test/movementDerive.test.js`
Expected: `# tests 4`, `# pass 0`, `# fail 4` (`M.stockOf is not a function`).

- [ ] **Step 3: Apply the implementation**

```diff
--- a/functions/lib/movementLogic.js
+++ b/functions/lib/movementLogic.js
@@ -89,6 +89,19 @@
     return [{ kind: kind, qty: appliedDelta, reason: "", valueAtCost: 0, derived: true }];
 }
 
+// The stock a working doc carries; anything absent or non-numeric counts as 0.
+function stockOf(doc) {
+    return (doc && typeof doc.stock === "number" && isFinite(doc.stock)) ? doc.stock : 0;
+}
+
+// Server-derived row for a whole-record inventory mutation, from the stock
+// before and after: create => receipt, update / delete / opening_balance =>
+// adjustment. Delete counts as stock going to 0.
+function deriveForMutation(action, before, after) {
+    const delta = (action === "delete" ? 0 : stockOf(after)) - stockOf(before);
+    return deriveMovement(delta, action === "create" ? "receipt" : "adjustment");
+}
+
 // One { id, data } per movement. ctx: { baseId, productId, actorUid, actorRole,
 // serverTimestamp, clientTimestamp, requestId, operationId?, opType?, opIndex? }.
 // `baseId` is the audit_log id of the write that carries the movements, so a
@@ -121,5 +134,5 @@
 
 module.exports = {
     KIND_DIRECTION, MOVEMENT_KINDS, DEFAULT_KIND_BY_OPTYPE, MAX_MOVEMENTS, MAX_TXN_WRITES,
-    validateMovements, totalsMatch, deriveMovement, buildRows
+    validateMovements, totalsMatch, deriveMovement, stockOf, deriveForMutation, buildRows
 };
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd functions && node --test test/movementDerive.test.js`
Expected: `# tests 4`, `# pass 4`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/movementLogic.js functions/test/movementDerive.test.js
git commit -m "feat(p1): stockOf and deriveForMutation"
```

---

### Task 2: recordMutation derives the row

**Files:**
- Modify: `functions/lib/gatewayLogic.js`
- Test: append to `functions/test/movementDerive.test.js`

- [ ] **Step 1: Write the failing tests** - append:

```js
// ── applyMutation ───────────────────────────────────────────────────────────
function mParams(overrides) {
    return Object.assign({ tenantId: "t1", actorUid: "u1", actorRole: "owner", entity: "inventory", entityId: "p1", action: "update",
        requestId: "req-m1", before: { stock: 5, name: "A" }, after: { stock: 8, name: "A" }, clientTimestamp: 9,
        collection: "inventory", serverTimestamp: "TS" }, overrides || {});
}

test("applyMutation: an inventory update that changes stock writes doc, audit and a derived adjustment row together", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 5, name: "A" } });
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
    assert.equal(row.serverTimestamp, "TS");
});

test("applyMutation: create with stock is a receipt row; create with stock 0 writes no row", async () => {
    let db = makeDb({});
    await G.applyMutation(db, mParams({ action: "create", before: null, after: { stock: 12 } }));
    assert.equal(db.store[T + "stock_movements/req-m1~m0"].kind, "receipt");
    assert.equal(db.store[T + "stock_movements/req-m1~m0"].qty, 12);
    db = makeDb({});
    await G.applyMutation(db, mParams({ action: "create", before: null, after: { stock: 0 } }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutation: deleting a product that still has stock writes a -stock adjustment row", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 5, name: "A" } });
    const r = await G.applyMutation(db, mParams({ action: "delete", after: null }));
    assert.equal(r.ok, true);
    assert.equal(db.store[T + "inventory/p1"], undefined);
    assert.equal(db.store[T + "stock_movements/req-m1~m0"].qty, -5);
});

test("applyMutation: an edit that does not touch stock writes no row", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 5, name: "A" } });
    await G.applyMutation(db, mParams({ after: { stock: 5, name: "B" } }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutation: other entities never derive rows, even if they carry a stock field", async () => {
    const db = makeDb({ [T + "orders/o1"]: { stock: 1 } });
    await G.applyMutation(db, mParams({ entity: "order", collection: "orders", entityId: "o1", before: { stock: 1 }, after: { stock: 9 } }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutation: a stale before (409 conflict) writes nothing, no row", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 6, name: "A" } });
    const r = await G.applyMutation(db, mParams());
    assert.equal(r.status, 409);
    assert.equal(db.writes.length, 0);
});

test("applyMutation: replay of the same requestId writes no second row", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 5, name: "A" } });
    await G.applyMutation(db, mParams());
    const n = db.writes.length;
    assert.equal((await G.applyMutation(db, mParams())).idempotentReplay, true);
    assert.equal(db.writes.length, n);
});

test("applyMutation: a non-numeric stock counts as 0 (string stock on the way in is a receipt of 0 only)", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: "5", name: "A" } });
    await G.applyMutation(db, mParams({ before: { stock: "5", name: "A" }, after: { stock: 5, name: "A" } }));
    assert.equal(db.store[T + "stock_movements/req-m1~m0"].qty, 5);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd functions && node --test test/movementDerive.test.js`
Expected: `# tests 12`, `# pass 8`, `# fail 4`.

- [ ] **Step 3: Apply the implementation**

```diff
--- a/functions/lib/gatewayLogic.js
+++ b/functions/lib/gatewayLogic.js
@@ -174,11 +174,26 @@
             return { ok: false, status: 409, conflict: true, current: current };
         }
 
+        // Inventory stock can only change through a transaction that also
+        // writes its ledger row (P1 spec D11): derive one from before/after.
+        const movements = params.entity === "inventory"
+            ? MovementLogic.deriveForMutation(params.action, current, params.after) : [];
+
         if (params.action === "delete") {
             txn.delete(workingRef);
         } else {
             txn.set(workingRef, params.after || {}, { merge: false });
         }
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd functions && node --test test/movementDerive.test.js test/gatewayLogic.test.js test/movementWiring.test.js`
Expected: `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/gatewayLogic.js functions/test/movementDerive.test.js
git commit -m "feat(p1): recordMutation writes a server-derived stock_movements row for inventory stock changes"
```

---

### Task 3: recordMutationsBatch derives rows; cap 150

**Files:**
- Modify: `functions/lib/batchMutationLogic.js`
- Modify: `functions/test/batchMutationLogic.test.js` (1 test: cap pin)
- Test: append to `functions/test/movementDerive.test.js`

- [ ] **Step 1: Write the failing tests** - append:

```js
// ── recordMutation / batch validation ───────────────────────────────────────
test("validateBatchMutationRequest: movements are not supported; the cap is 150", () => {
    const item = { entityId: "p1", action: "create", before: null, after: { stock: 1 } };
    const body = { entity: "inventory", requestId: "r", items: [item] };
    assert.equal(B.validateBatchMutationRequest(Object.assign({}, body, { movements: [] })).error, "movements-not-supported");
    assert.equal(B.MAX_BATCH_SIZE, 150);
    const items = (n) => Array.from({ length: n }, (_, i) => Object.assign({}, item, { entityId: "p" + i }));
    assert.equal(B.validateBatchMutationRequest(Object.assign({}, body, { items: items(150) })).ok, true);
    assert.equal(B.validateBatchMutationRequest(Object.assign({}, body, { items: items(151) })).error, "batch-too-large");
});

// ── applyMutationsBatch ─────────────────────────────────────────────────────
function bParams(items, overrides) {
    return Object.assign({ tenantId: "t1", actorUid: "u1", actorRole: "manager", entity: "inventory", collection: "inventory",
        requestId: "req-b1", items, serverTimestamp: "TS" }, overrides || {});
}

test("applyMutationsBatch: one derived row per stock-changing inventory item, id from the item's audit id", async () => {
    const db = makeDb({ [T + "inventory/p2"]: { stock: 4 } });
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
});

test("applyMutationsBatch: any conflict rejects the whole batch with zero writes", async () => {
    const db = makeDb({ [T + "inventory/p2"]: { stock: 99 } });
    const r = await B.applyMutationsBatch(db, bParams([
        { entityId: "p1", action: "create", before: null, after: { stock: 10 } },
        { entityId: "p2", action: "update", before: { stock: 4 }, after: { stock: 1 } }]));
    assert.equal(r.status, 409);
    assert.equal(db.writes.length, 0);
});

test("applyMutationsBatch: replay writes no second set of rows", async () => {
    const db = makeDb({});
    const items = [{ entityId: "p1", action: "create", before: null, after: { stock: 10 } }];
    await B.applyMutationsBatch(db, bParams(items));
    const n = db.writes.length;
    await B.applyMutationsBatch(db, bParams(items));
    assert.equal(db.writes.length, n);
});

test("applyMutationsBatch: non-inventory batches derive nothing", async () => {
    const db = makeDb({});
    await B.applyMutationsBatch(db, bParams([{ entityId: "o1", action: "create", before: null, after: { stock: 3 } }], { entity: "order", collection: "orders" }));
    assert.equal(rowsOf(db).length, 0);
});

test("applyMutationsBatch: a full 150-item inventory batch writes at most 450 docs (under the 500 ceiling)", async () => {
    const items = Array.from({ length: 150 }, (_, i) => ({ entityId: "p" + i, action: "create", before: null, after: { stock: 1 } }));
    const db = makeDb({});
    assert.equal((await B.applyMutationsBatch(db, bParams(items))).ok, true);
    assert.equal(db.writes.length, 450);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd functions && node --test test/movementDerive.test.js`
Expected: `# tests 18`, `# pass 15`, `# fail 3`.

- [ ] **Step 3: Apply the implementation** (the cap pin test changes on purpose: the comment above it explains it must fail loudly when the cap moves):

```diff
--- a/functions/lib/batchMutationLogic.js
+++ b/functions/lib/batchMutationLogic.js
@@ -8,9 +8,9 @@
 // compliance property than N independent writes, at the cost of a
 // batch-size cap.
 //
-// MAX_BATCH_SIZE=200 keeps the transaction's write count (2 per item: one
-// working-doc write + one audit_log entry) at 400, safely under Firestore's
-// ~500-writes-per-transaction ceiling. A caller needing more than 200 items
+// MAX_BATCH_SIZE=150 keeps the transaction's write count (3 per item at most: one
+// working-doc write + one audit_log entry + one stock_movements row for inventory)
+// at 450, safely under Firestore's ~500-writes-per-transaction ceiling. A caller needing more than 150 items
 // in one shot must split into multiple recordMutations calls; atomicity
 // then holds within each chunk, not across chunks - a documented trade-off,
 // not a hidden one.
@@ -19,6 +19,7 @@
 // pattern as gatewayLogic.js / cutoverLogic.js.
 
 const { ENTITY_COLLECTIONS, ALLOWED_ACTIONS, _deepEqual } = require("./gatewayLogic");
+const MovementLogic = require("./movementLogic");
 
 // Mirrored client-side as Gateway.qml's `maxBatchSize` property (no shared
 // build-time constant between this Node runtime and the QML client — see
@@ -26,7 +27,7 @@
 // file's own test below and tests/tst_Gateway.qml both pin the value they
 // each hold so a drift fails a test on both sides instead of failing silently
 // in production the way the original bug did.
-const MAX_BATCH_SIZE = 200;
+const MAX_BATCH_SIZE = 150;
 
 // Validates + normalizes a recordMutationsBatch request body. Returns
 // { ok: true, entity, collection, requestId, items: [...] } or
@@ -46,6 +47,9 @@
     if (items.length === 0) {
         return { ok: false, status: 400, error: "empty-batch" };
     }
+    if (body.movements !== undefined) {
+        return { ok: false, status: 400, error: "movements-not-supported" };
+    }
     if (items.length > MAX_BATCH_SIZE) {
         return { ok: false, status: 400, error: "batch-too-large" };
     }
@@ -128,6 +132,21 @@
             } else {
                 txn.set(r.workingRef, r.item.after || {}, { merge: false });
             }
+            // Inventory stock changes leave a server-derived ledger row (P1 spec D11).
+            if (params.entity === "inventory") {
+                // The conflict check above proved the stored doc equals item.before.
+                const rows = MovementLogic.buildRows(
+                    MovementLogic.deriveForMutation(r.item.action, r.item.before, r.item.after), {
+                        baseId: params.requestId + ":" + r.item.entityId,
+                        productId: r.item.entityId,
+                        actorUid: params.actorUid,
+                        actorRole: params.actorRole,
+                        serverTimestamp: params.serverTimestamp,
+                        clientTimestamp: r.item.clientTimestamp,
+                        requestId: params.requestId
+                    });
+                for (const row of rows) txn.set(db.doc(tenantRoot + "/stock_movements/" + row.id), row.data);
+            }
 
             txn.set(r.auditRef, {
                 entryId: params.requestId + ":" + r.item.entityId,
```

```diff
--- a/functions/test/batchMutationLogic.test.js
+++ b/functions/test/batchMutationLogic.test.js
@@ -70,8 +70,8 @@
 // literal deliberately so a future change to MAX_BATCH_SIZE without a
 // matching change to Gateway.qml fails loudly here instead of silently
 // reproducing the original bug (client sends an oversized batch again).
-test("MAX_BATCH_SIZE stays in sync with Gateway.qml's mirrored maxBatchSize (200)", () => {
-    assert.equal(BatchMutationLogic.MAX_BATCH_SIZE, 200);
+test("MAX_BATCH_SIZE stays in sync with Gateway.qml's mirrored maxBatchSize (150)", () => {
+    assert.equal(BatchMutationLogic.MAX_BATCH_SIZE, 150);
 });
 
 test("validateBatchMutationRequest rejects a batch containing an item with a disallowed action", () => {
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd functions && node --test`
Expected: `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/batchMutationLogic.js functions/test/batchMutationLogic.test.js functions/test/movementDerive.test.js
git commit -m "feat(p1): recordMutationsBatch derives ledger rows for inventory; MAX_BATCH_SIZE 150"
```

---

### Task 4: recordOperation mutation ops derive rows

**Files:**
- Modify: `functions/lib/operationLogic.js`
- Test: append to `functions/test/movementDerive.test.js`

- [ ] **Step 1: Write the failing tests** - append:

```js
// ── recordOperation mutation ops ────────────────────────────────────────────
const RID = "completeOrder:o1:1";
const opBody = (ops) => ({ requestId: RID, opType: "completeOrder", ops: ops, clientTimestamp: 7 });
const oParams = (v) => ({ tenantId: "t1", actorUid: "u1", actorRole: "staff", requestId: v.requestId, opType: v.opType, ops: v.ops,
    clientTimestamp: v.clientTimestamp, serverTimestamp: "TS" });

test("applyOperation: an inventory mutation op that changes stock derives an adjustment row with the op context", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 5 } });
    const v = O.validateOperationRequest(opBody([{ kind: "mutation", entity: "inventory", entityId: "p1", action: "update",
        before: { stock: 5 }, after: { stock: 2 } }]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    const row = db.store[T + "stock_movements/completeOrder:o1:1~0~m0"];
    assert.equal(row.kind, "adjustment");
    assert.equal(row.qty, -3);
    assert.equal(row.derived, true);
    assert.equal(row.operationId, RID);
});

test("applyOperation: an inventory mutation op that does not change stock derives nothing", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 5, name: "a" } });
    const v = O.validateOperationRequest(opBody([{ kind: "mutation", entity: "inventory", entityId: "p1", action: "update",
        before: { stock: 5, name: "a" }, after: { stock: 5, name: "b" } }]));
    assert.equal((await O.applyOperation(db, oParams(v))).ok, true);
    assert.equal(rowsOf(db).length, 0);
});

test("applyOperation: a stale before on an inventory mutation op rejects the whole operation, no rows", async () => {
    const db = makeDb({ [T + "inventory/p1"]: { stock: 9 } });
    const v = O.validateOperationRequest(opBody([{ kind: "mutation", entity: "inventory", entityId: "p1", action: "update",
        before: { stock: 5 }, after: { stock: 2 } }]));
    const r = await O.applyOperation(db, oParams(v));
    assert.equal(r.status, 409);
    assert.equal(db.writes.length, 0);
});

test("applyOperation: 166 inventory mutation ops stay at 499 writes", async () => {
    const docs = {}; const ops = [];
    for (let i = 0; i < 166; i++) {
        docs[T + "inventory/p" + i] = { stock: 5 };
        ops.push({ kind: "mutation", entity: "inventory", entityId: "p" + i, action: "update", before: { stock: 5 }, after: { stock: 4 } });
    }
    const db = makeDb(docs);
    assert.equal((await O.applyOperation(db, oParams(O.validateOperationRequest(opBody(ops))))).ok, true);
    assert.equal(db.writes.length, 499);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd functions && node --test test/movementDerive.test.js`
Expected: `# tests 22`, `# pass 20`, `# fail 2`.

- [ ] **Step 3: Apply the implementation**

```diff
--- a/functions/lib/operationLogic.js
+++ b/functions/lib/operationLogic.js
@@ -171,7 +171,9 @@
                     entry.exists = true;
                     entry.data = op.after || {};
                 }
-                audits.push({ i: i, op: op, action: op.action, before: op.before, after: op.after, movements: [] });
+                const movements = op.entity === "inventory"
+                    ? MovementLogic.deriveForMutation(op.action, op.before, op.action === "delete" ? null : (op.after || {})) : [];
+                audits.push({ i: i, op: op, action: op.action, before: op.before, after: op.after, movements: movements });
                 results.push({ entity: op.entity, entityId: op.entityId, kind: "mutation",
                                after: op.action === "delete" ? null : (op.after || {}) });
             }
```

- [ ] **Step 4: Run to verify everything passes**

Run: `cd functions && node --test`
Expected: `# fail 0`; on `main` @ `6da373d` with S1a and S1b that is 232 existing + 81 new = 313 tests.
Optional: `node --test --experimental-test-coverage` shows 100% line for `movementLogic.js`, `gatewayLogic.js`, `operationLogic.js`, `batchMutationLogic.js`.

- [ ] **Step 5: Commit**

```bash
git add functions/lib/operationLogic.js functions/test/movementDerive.test.js
git commit -m "feat(p1): recordOperation mutation ops on inventory derive ledger rows"
```

---

### Task 5: client mirror of the batch cap (CI-verified only)

The server now rejects any batch over 150 items, so `Gateway.maxBatchSize` (the client mirror used to chunk bulk imports) must follow, and the tests that pin
or depend on 200 must move with it. Cannot run in the sandbox: push and read the CI result (do NOT install Qt).

**Files:**
- Modify: `qml/model/Gateway.qml` (one property + comment), `tests/tst_Gateway.qml` (one pin), `test/e2e/tst_BulkImportChunkingE2E.qml` (chunk boundary indices), `test/e2e/tst_OrdersStoreE2E.qml` (message text)

- [ ] **Step 1: Confirm nothing else pins 200:** `grep -rn "maxBatchSize" qml tests test` and `grep -rn "batch-too-large" qml tests test`; the patch below covers every hit found on `main` @ `6da373d` (the `_chunkItems(items, 200)` tests pass the size explicitly and are unaffected).
- [ ] **Step 2: Apply the patch** (`git apply --check` passed against `main`):

```diff
--- a/qml/model/Gateway.qml
+++ b/qml/model/Gateway.qml
@@ -246,8 +246,9 @@
     // retry an oversized batch forever. If the server's constant ever
     // changes, functions/test/batchMutationLogic.test.js pins its value and
     // tests/tst_Gateway.qml pins this one — a drift shows up as a test
-    // failure on both sides rather than silently.
-    readonly property int maxBatchSize: 200
+    // failure on both sides rather than silently. 150 (not 200) since P1:
+    // an inventory batch writes up to 3 docs per item (doc + audit + movement row).
+    readonly property int maxBatchSize: 150
 
     // Pure/testable: split items into chunks of at most `size`. No-op
     // wrapper (single chunk) when items already fits.
--- a/tests/tst_Gateway.qml
+++ b/tests/tst_Gateway.qml
@@ -474,9 +474,9 @@
     function test_maxBatchSize_matches_the_servers_MAX_BATCH_SIZE() {
         // Same literal pinned from the other side in
         // functions/test/batchMutationLogic.test.js — see that test's
-        // comment for why both sides hardcode 200 rather than each other's
+        // comment for why both sides hardcode 150 rather than each other's
         // dynamic constant.
-        compare(Gateway.maxBatchSize, 200)
+        compare(Gateway.maxBatchSize, 150)
     }
 
     // ── Regression: the exact reported bug — >200 rows must not be sent as
--- a/test/e2e/tst_BulkImportChunkingE2E.qml
+++ b/test/e2e/tst_BulkImportChunkingE2E.qml
@@ -14,7 +14,7 @@
 // initTestCase() comment for why that matters here).
 //
 // Test 1 reproduces the ACTUAL reported bug: 250 rows, one call, verified
-// against the real emulator that BOTH resulting chunks (200 + 50) actually
+// against the real emulator that BOTH resulting chunks (150 + 100) actually
 // landed — before this fix, the whole 250-item call was rejected outright
 // and the client never even noticed. Test 2 proves the other half: a
 // request the server permanently rejects (not a size issue this time — an
@@ -110,7 +110,7 @@
         // silently. Checking the two chunk boundaries (last of chunk 1,
         // first of chunk 2) plus the very first and very last row is enough
         // to prove BOTH chunks actually committed, not just one.
-        var checkIndices = [0, 199, 200, 249]
+        var checkIndices = [0, 149, 150, 249]
         for (var c = 0; c < checkIndices.length; ++c) {
             var idx = checkIndices[c]
             var entityId = "e2e-chunk-" + runId + "-" + idx
--- a/test/e2e/tst_OrdersStoreE2E.qml
+++ b/test/e2e/tst_OrdersStoreE2E.qml
@@ -233,7 +233,7 @@
 
         tryVerify(function() { return done }, 15000, "upsertMany callback never fired for 201 new orders")
         compare(received.added, 201)
-        compare(received.chunked, true, "201 new orders must be flagged as chunked (>Gateway.maxBatchSize=200)")
+        compare(received.chunked, true, "201 new orders must be flagged as chunked (>Gateway.maxBatchSize=150)")
     }
 
     function test_upsertMany_overwrite_policy_updates_envelope_fields_in_place() {
```

- [ ] **Step 3: Push and read CI.** Expected: QML unit tests, E2E (`tst_BulkImportChunkingE2E` now proves chunks of 150 + 100 land, and every product row the E2E creates also writes a derived movement row server-side without breaking the run) all green. If a QML test outside the patch failed on the 200 assumption, fix that test, not the constant.
- [ ] **Step 4: Commit**

```bash
git add qml/model/Gateway.qml tests/tst_Gateway.qml test/e2e/tst_BulkImportChunkingE2E.qml test/e2e/tst_OrdersStoreE2E.qml
git commit -m "feat(p1): Gateway.maxBatchSize 150 to match the server (3 writes per inventory item)"
```

---

### Task 6: docs, test plan, PR, deploy

- [ ] **Step 1:** Update `AGENTS.md` (P1 bullet: S1b done), `README.md` (derived rows on all inventory write paths, cap 150), the test plan (S1b rows to actual CI numbers), `CHECKPOINT.md`. Count tests from `node --test` output.
- [ ] **Step 2:** Mutation spot-check the S1b lines (list in the test plan); never leave a mutated file behind (`git diff` shows only the intended change).
- [ ] **Step 3:** Push, PR, wait for the 5 CI checks, hand to Taher. Taher deploys functions to dev, then runs the S1b on-device checklist (create product with stock, edit stock, bulk import 200 rows, delete product with stock: each must leave a derived row).
- [ ] **Step 4:** S2 (client kind pickers, delete `direct` mode and `runCutover`, lock `inventory` in the rules) is planned in its own session AFTER this checklist passes.

## Self-review (against the spec)

- D11 completeness on every inventory write path: S1a covers `recordDelta` and `recordOperation` delta ops; Tasks 2-4 cover `recordMutation`, batch and operation mutation ops.
- D13 batch cap: Task 3 (`150` ok, `151` rejected, 150 inventory items = 450 writes) and Task 5 (client mirror).
- Atomicity and rollback: conflict tests in Tasks 2, 3, 4 assert zero writes; replay tests assert no second row.
- Placeholder scan: none. Names consistent (`stockOf`, `deriveForMutation`, `MAX_BATCH_SIZE`).
