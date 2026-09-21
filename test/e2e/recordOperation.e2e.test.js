"use strict";

// Real-Firestore check of the recordOperation endpoint, against the Firebase
// Local Emulator Suite (firestore + auth + functions). The unit tests in
// functions/test/ run the transaction logic against an in-memory double; this
// file is the one place the SAME logic meets Firestore's real transaction
// semantics (reads before writes, retry on contention, document id rules).
//
// Run inside the same `firebase emulators:exec` as the QML E2E tests, AFTER
// test/e2e/seed.js has written .fixture.json (see .github/workflows/checks.yml):
//   firebase emulators:exec --only firestore,auth,functions \
//     "node test/e2e/seed.js && node --test test/e2e/recordOperation.e2e.test.js"
//
// Uses its own ids (prefix "opE2E") and deletes what it creates, so it cannot
// disturb the QML E2E suites that share the seeded tenant.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");

const PROJECT_ID = "inventorymanager-48392";   // must match seed.js and FirebaseService.qml
const FUNCTIONS_BASE = "http://127.0.0.1:5001/" + PROJECT_ID + "/asia-south1";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
    console.error("recordOperation.e2e: FIRESTORE_EMULATOR_HOST is not set -- refusing to run " +
                  "against what might be real Firestore.");
    process.exit(1);
}

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, ".fixture.json"), "utf8"));
const T = "tenants/" + fixture.tenantId + "/";
const db = getFirestore(initializeApp({ projectId: PROJECT_ID }));   // "(default)", like seed.js

const createdPaths = new Set();

async function seed(relPath, data) {
    await db.doc(T + relPath).set(data);
    createdPaths.add(T + relPath);
}

async function read(relPath) {
    const snap = await db.doc(T + relPath).get();
    return snap.exists ? snap.data() : null;
}

// One POST. Retries only on a network-level failure (the first call to a
// function in the emulator can be slow while it loads); retrying is safe here
// because the endpoint is idempotent per requestId, which is what is under test.
async function post(body, token) {
    let lastError;
    for (let attempt = 0; attempt < 4; attempt++) {
        try {
            const res = await fetch(FUNCTIONS_BASE + "/recordOperation", {
                method: "POST",
                headers: { "Content-Type": "application/json", "Authorization": "Bearer " + (token || fixture.idToken) },
                body: JSON.stringify(body),
                signal: AbortSignal.timeout(60000)
            });
            let json = null;
            try { json = await res.json(); } catch (e) { json = null; }
            return { status: res.status, body: json };
        } catch (e) {
            lastError = e;
            await new Promise((resolve) => setTimeout(resolve, 2000));
        }
    }
    throw lastError;
}

// What the outbox does on a 5xx: send the same request again. Firestore can abort a
// transaction that loses too many contention retries, which surfaces as a 500; the
// stable request id is exactly what makes resending that safe.
async function postWithRetryOn5xx(body, token) {
    let r = await post(body, token);
    for (let i = 0; i < 3 && r.status >= 500; i++) r = await post(body, token);
    return r;
}

function op(requestId, ops) {
    return { requestId: requestId, opType: "completeOrder", clientTimestamp: "2026-09-21T10:00:00.000Z", ops: ops };
}

const batchDelta = (id, n, floors) => ({ kind: "delta", entity: "stock_batch", entityId: id,
    deltas: { qtyRemaining: n }, floors: floors === undefined ? { qtyRemaining: 0 } : floors, clamps: {} });
const stockDelta = (id, n, floors, clamps) => ({ kind: "delta", entity: "inventory", entityId: id,
    deltas: { stock: n }, floors: floors === undefined ? { stock: 0 } : floors, clamps: clamps || {} });

test.after(async () => {
    for (const p of createdPaths) await db.doc(p).delete();
    const audits = await db.collection(T + "audit_log").listDocuments();
    for (const ref of audits) if (ref.id.startsWith("completeOrder:opE2E")) await ref.delete();
});

test("warm-up: an empty body is a clean 400, not a hang or a 500", async () => {
    const r = await post({});
    assert.equal(r.status, 400);
    assert.equal(r.body.error, "missing-fields");
});

test("an unsafe request id is a clean 400 (it would otherwise be a nested Firestore path)", async () => {
    const r = await post(op("completeOrder:opE2E/evil", [stockDelta("opE2E-none", -1)]));
    assert.equal(r.status, 400);
    assert.equal(r.body.error, "invalid-request-id");
});

test("a request without a token is a 401", async () => {
    const res = await fetch(FUNCTIONS_BASE + "/recordOperation", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    assert.equal(res.status, 401);
});

test("one operation applies every doc atomically, with a marker and one audit entry per op", async () => {
    await seed("inventory/opE2E-p1", { productId: "opE2E-p1", stock: 5, name: "Op E2E" });
    await seed("stock_batches/opE2E-b1", { batchId: "opE2E-b1", productId: "opE2E-p1", qtyRemaining: 5, unitCost: 2 });
    await seed("orders/opE2E-o1", { orderId: "opE2E-o1", status: "pending" });
    createdPaths.add(T + "transactions/opE2E-tx1");

    const r = await post(op("completeOrder:opE2E-1:1", [
        batchDelta("opE2E-b1", -2),
        stockDelta("opE2E-p1", -2),
        { kind: "mutation", entity: "order", entityId: "opE2E-o1", action: "update",
          before: { orderId: "opE2E-o1", status: "pending" }, after: { orderId: "opE2E-o1", status: "completed" } },
        { kind: "mutation", entity: "transaction", entityId: "opE2E-tx1", action: "create",
          before: null, after: { txId: "opE2E-tx1", kind: "sale" } }
    ]));

    assert.equal(r.status, 200);
    assert.equal(r.body.ok, true);
    assert.equal(r.body.idempotentReplay, false);
    assert.equal(r.body.results.length, 4);
    assert.deepEqual(r.body.results[0].after, { qtyRemaining: 3 });
    assert.deepEqual(r.body.results[1].after, { stock: 3 });

    assert.equal((await read("stock_batches/opE2E-b1")).qtyRemaining, 3);
    assert.equal((await read("inventory/opE2E-p1")).stock, 3);
    assert.equal((await read("orders/opE2E-o1")).status, "completed");
    assert.equal((await read("transactions/opE2E-tx1")).kind, "sale");

    const marker = await read("audit_log/completeOrder:opE2E-1:1");
    assert.equal(marker.action, "operation");
    assert.equal(marker.opCount, 4);
    assert.equal(marker.results.length, 4);
    const perOp = await read("audit_log/completeOrder:opE2E-1:1~1");
    assert.equal(perOp.action, "delta");
    assert.equal(perOp.operationId, "completeOrder:opE2E-1:1");
    assert.equal(perOp.opIndex, 1);
    assert.deepEqual(perOp.before, { stock: 5 });
    assert.deepEqual(perOp.after, { stock: 3 });
});

test("the same request id again is a replay: same results, nothing applied twice", async () => {
    const r = await post(op("completeOrder:opE2E-1:1", [batchDelta("opE2E-b1", -2), stockDelta("opE2E-p1", -2)]));
    assert.equal(r.status, 200);
    assert.equal(r.body.idempotentReplay, true);
    assert.equal(r.body.results.length, 4, "the FIRST operation's results, not this (different) payload's");
    assert.equal((await read("inventory/opE2E-p1")).stock, 3);
    assert.equal((await read("stock_batches/opE2E-b1")).qtyRemaining, 3);
});

test("a floor violation rejects the WHOLE operation: nothing written, no marker", async () => {
    const r = await post(op("completeOrder:opE2E-2:1", [
        batchDelta("opE2E-b1", -1),          // fine on its own
        stockDelta("opE2E-p1", -99)          // below the floor
    ]));
    assert.equal(r.status, 409);
    assert.equal(r.body.error, "insufficient-quantity");
    assert.equal(r.body.opIndex, 1);
    assert.equal(r.body.field, "stock");
    assert.equal(r.body.current, 3);

    assert.equal((await read("stock_batches/opE2E-b1")).qtyRemaining, 3, "the valid first op must NOT have applied");
    assert.equal(await read("audit_log/completeOrder:opE2E-2:1"), null, "a rejection leaves no marker");
    assert.equal(await read("audit_log/completeOrder:opE2E-2:1~0"), null);
});

test("the rejected request id can be re-planned and resent (here: clamp instead of floor)", async () => {
    const r = await post(op("completeOrder:opE2E-2:1", [
        batchDelta("opE2E-b1", -1),
        stockDelta("opE2E-p1", -99, {}, { stock: 0 })
    ]));
    assert.equal(r.status, 200);
    assert.equal(r.body.idempotentReplay, false);
    assert.equal((await read("inventory/opE2E-p1")).stock, 0);
    assert.equal((await read("stock_batches/opE2E-b1")).qtyRemaining, 2);
});

test("a stale order `before` is a CAS conflict carrying the server's doc, nothing written", async () => {
    const r = await post(op("completeOrder:opE2E-3:1", [
        batchDelta("opE2E-b1", -1),
        { kind: "mutation", entity: "order", entityId: "opE2E-o1", action: "update",
          before: { orderId: "opE2E-o1", status: "pending" }, after: { orderId: "opE2E-o1", status: "completed" } }
    ]));
    assert.equal(r.status, 409);
    assert.equal(r.body.conflict, true);
    assert.equal(r.body.opIndex, 1);
    assert.equal(r.body.current.status, "completed");
    assert.equal((await read("stock_batches/opE2E-b1")).qtyRemaining, 2, "the first op must NOT have applied");
});

test("a delta on a doc that does not exist is a 404 naming the op", async () => {
    const r = await post(op("completeOrder:opE2E-4:1", [stockDelta("opE2E-ghost", -1)]));
    assert.equal(r.status, 404);
    assert.equal(r.body.error, "not-found");
    assert.equal(r.body.opIndex, 0);
});

test("two devices completing at the same moment: Firestore serialises them, exactly one wins", async () => {
    await seed("inventory/opE2E-q1", { productId: "opE2E-q1", stock: 3, name: "Contended" });
    await seed("stock_batches/opE2E-bq1", { batchId: "opE2E-bq1", productId: "opE2E-q1", qtyRemaining: 3, unitCost: 1 });

    const both = await Promise.all([
        postWithRetryOn5xx(op("completeOrder:opE2E-c1:1", [batchDelta("opE2E-bq1", -2), stockDelta("opE2E-q1", -2)])),
        postWithRetryOn5xx(op("completeOrder:opE2E-c2:1", [batchDelta("opE2E-bq1", -2), stockDelta("opE2E-q1", -2)]), fixture.secondIdToken)
    ]);

    const statuses = both.map((r) => r.status).sort();
    assert.deepEqual(statuses, [200, 409], "one applied, one rejected on the floor: " + JSON.stringify(both.map((r) => r.body)));
    assert.equal((await read("inventory/opE2E-q1")).stock, 1, "applied exactly once");
    assert.equal((await read("stock_batches/opE2E-bq1")).qtyRemaining, 1, "applied exactly once");
    const markers = [await read("audit_log/completeOrder:opE2E-c1:1"), await read("audit_log/completeOrder:opE2E-c2:1")];
    assert.equal(markers.filter((m) => m !== null).length, 1, "exactly one marker");
});

test("many concurrent retries of ONE request id apply it exactly once (the C-3 double-apply, at the server)", async () => {
    await seed("inventory/opE2E-r1", { productId: "opE2E-r1", stock: 10, name: "Retried" });
    await seed("stock_batches/opE2E-br1", { batchId: "opE2E-br1", productId: "opE2E-r1", qtyRemaining: 10, unitCost: 1 });

    const body = op("completeOrder:opE2E-r1:1", [batchDelta("opE2E-br1", -1), stockDelta("opE2E-r1", -1)]);
    const results = await Promise.all([1, 2, 3, 4].map(() => postWithRetryOn5xx(body)));

    for (const r of results) assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(results.filter((r) => r.body.idempotentReplay === false).length, 1, "exactly one real application");
    assert.equal((await read("inventory/opE2E-r1")).stock, 9, "stock dropped once, not six times");
    assert.equal((await read("stock_batches/opE2E-br1")).qtyRemaining, 9);
});
