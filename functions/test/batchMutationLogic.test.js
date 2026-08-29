"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const BatchMutationLogic = require("../lib/batchMutationLogic");

// ── validateBatchMutationRequest ─────────────────────────────────────────────

function validItem(overrides) {
    return Object.assign({
        entityId: "order-1",
        action: "update",
        before: { status: "pending" },
        after: { status: "approved" },
        clientTimestamp: 111
    }, overrides || {});
}

function validBody(overrides) {
    return Object.assign({
        entity: "inventory",
        requestId: "batch-1",
        items: [validItem()]
    }, overrides || {});
}

test("validateBatchMutationRequest rejects an unknown entity", () => {
    const result = BatchMutationLogic.validateBatchMutationRequest(validBody({ entity: "widget" }));
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "unsupported-entity");
});

test("validateBatchMutationRequest rejects a missing batch requestId", () => {
    const result = BatchMutationLogic.validateBatchMutationRequest(validBody({ requestId: "" }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-fields");
});

test("validateBatchMutationRequest rejects an empty items array", () => {
    const result = BatchMutationLogic.validateBatchMutationRequest(validBody({ items: [] }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "empty-batch");
});

test("validateBatchMutationRequest rejects a batch over the max size", () => {
    const items = [];
    for (let i = 0; i < BatchMutationLogic.MAX_BATCH_SIZE + 1; i++) {
        items.push(validItem({ entityId: "order-" + i }));
    }
    const result = BatchMutationLogic.validateBatchMutationRequest(validBody({ items: items }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "batch-too-large");
});

test("validateBatchMutationRequest accepts a batch exactly at the max size", () => {
    const items = [];
    for (let i = 0; i < BatchMutationLogic.MAX_BATCH_SIZE; i++) {
        items.push(validItem({ entityId: "order-" + i }));
    }
    const result = BatchMutationLogic.validateBatchMutationRequest(validBody({ items: items }));
    assert.equal(result.ok, true);
});

// Regression pin (2026-08-29 bulk-import chunking fix): Gateway.qml's
// `maxBatchSize` property mirrors this literal because there's no shared
// build-time constant between the Node and QML runtimes. The two tests
// above use BatchMutationLogic.MAX_BATCH_SIZE dynamically, so they'd still
// pass at any value and wouldn't catch a drift — this test hardcodes the
// literal deliberately so a future change to MAX_BATCH_SIZE without a
// matching change to Gateway.qml fails loudly here instead of silently
// reproducing the original bug (client sends an oversized batch again).
test("MAX_BATCH_SIZE stays in sync with Gateway.qml's mirrored maxBatchSize (200)", () => {
    assert.equal(BatchMutationLogic.MAX_BATCH_SIZE, 200);
});

test("validateBatchMutationRequest rejects a batch containing an item with a disallowed action", () => {
    const result = BatchMutationLogic.validateBatchMutationRequest(
        validBody({ items: [validItem(), validItem({ entityId: "order-2", action: "rename" })] })
    );
    assert.equal(result.ok, false);
    assert.equal(result.error, "unsupported-action");
});

test("validateBatchMutationRequest rejects a batch containing an item missing entityId", () => {
    const result = BatchMutationLogic.validateBatchMutationRequest(
        validBody({ items: [validItem({ entityId: "" })] })
    );
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-fields");
});

test("validateBatchMutationRequest accepts a valid batch and resolves the collection", () => {
    const result = BatchMutationLogic.validateBatchMutationRequest(validBody());
    assert.equal(result.ok, true);
    assert.equal(result.collection, "inventory");
    assert.equal(result.items.length, 1);
    assert.equal(result.items[0].entityId, "order-1");
});

// ── fake transactional Firestore double (multi-ref get/set/delete) ─────────

// workingDocs: optional map of workingRef path -> current server data (or
// omitted entirely = doc doesn't exist). Needed since review I1 added a CAS
// read of every item's workingRef, not just its auditRef.
function makeFakeDb(existingAuditPaths, workingDocs) {
    const writes = [];
    const existingAudit = new Set(existingAuditPaths || []);
    const docs = workingDocs || {};
    return {
        writes,
        doc(path) { return { path }; },
        async runTransaction(fn) {
            const txn = {
                async get(ref) {
                    if (existingAudit.has(ref.path)) return { exists: true, data: () => ({}) };
                    if (Object.prototype.hasOwnProperty.call(docs, ref.path)) {
                        return { exists: true, data: () => docs[ref.path] };
                    }
                    return { exists: false, data: () => undefined };
                },
                set(ref, data, options) { writes.push({ type: "set", path: ref.path, data, options }); },
                delete(ref) { writes.push({ type: "delete", path: ref.path }); }
            };
            return fn(txn);
        }
    };
}

// Working-doc path for a given entityId in the default test fixtures
// (collection "inventory", tenant "tenant-1") — used to build workingDocs
// maps that match validItem()'s `before`, i.e. the no-conflict happy path.
function workingPath(entityId) {
    return "tenants/tenant-1/inventory/" + entityId;
}

function baseBatchParams(overrides) {
    return Object.assign({
        tenantId: "tenant-1",
        actorUid: "uid-1",
        actorRole: "owner",
        entity: "inventory",
        collection: "inventory",
        requestId: "batch-1",
        serverTimestamp: "SERVER_TIMESTAMP_SENTINEL",
        items: [validItem()]
    }, overrides || {});
}

// ── applyMutationsBatch ──────────────────────────────────────────────────────

test("applyMutationsBatch writes one working-doc write + one audit entry per item", async () => {
    const db = makeFakeDb(null, {
        [workingPath("order-1")]: { status: "pending" },
        [workingPath("order-2")]: { status: "pending" }
    });
    await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1" }), validItem({ entityId: "order-2" })]
    }));

    const workingWrites = db.writes.filter((w) => w.path.startsWith("tenants/tenant-1/inventory/"));
    const auditWrites = db.writes.filter((w) => w.path.startsWith("tenants/tenant-1/audit_log/"));

    assert.equal(workingWrites.length, 2);
    assert.equal(auditWrites.length, 2);
    assert.ok(auditWrites.some((w) => w.path === "tenants/tenant-1/audit_log/batch-1:order-1"));
    assert.ok(auditWrites.some((w) => w.path === "tenants/tenant-1/audit_log/batch-1:order-2"));
});

test("applyMutationsBatch deletes the working doc for a delete-action item", async () => {
    const db = makeFakeDb(null, { [workingPath("order-1")]: { status: "pending" } });
    await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1", action: "delete", after: null })]
    }));

    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/inventory/order-1");
    assert.equal(workingWrite.type, "delete");
});

test("applyMutationsBatch skips items whose requestId was already applied (idempotent retry)", async () => {
    const db = makeFakeDb(["tenants/tenant-1/audit_log/batch-1:order-1"],
        { [workingPath("order-2")]: { status: "pending" } });
    await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1" }), validItem({ entityId: "order-2" })]
    }));

    // order-1 already applied -> no writes for it (also exempt from the CAS
    // check, same as applyMutation's own idempotent-replay short-circuit —
    // it's this same request landing twice, not a competing write); order-2
    // is new -> 2 writes for it.
    const order1Writes = db.writes.filter((w) => w.path.includes("order-1"));
    const order2Writes = db.writes.filter((w) => w.path.includes("order-2"));
    assert.equal(order1Writes.length, 0);
    assert.equal(order2Writes.length, 2);
});

test("applyMutationsBatch is entirely a no-op when every item was already applied", async () => {
    const db = makeFakeDb([
        "tenants/tenant-1/audit_log/batch-1:order-1",
        "tenants/tenant-1/audit_log/batch-1:order-2"
    ]);
    await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1" }), validItem({ entityId: "order-2" })]
    }));

    assert.equal(db.writes.length, 0);
});

test("applyMutationsBatch runs as a single transaction (one runTransaction call for the whole batch)", async () => {
    let transactionCalls = 0;
    const db = makeFakeDb(null, {
        [workingPath("order-1")]: { status: "pending" },
        [workingPath("order-2")]: { status: "pending" },
        [workingPath("order-3")]: { status: "pending" }
    });
    const originalRunTransaction = db.runTransaction.bind(db);
    db.runTransaction = async (fn) => {
        transactionCalls++;
        return originalRunTransaction(fn);
    };

    await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1" }), validItem({ entityId: "order-2" }), validItem({ entityId: "order-3" })]
    }));

    assert.equal(transactionCalls, 1, "the whole batch must be one atomic transaction, not N");
});

// ── CAS conflict handling (review I1) ───────────────────────────────────────

test("applyMutationsBatch accepts an item whose before matches the current server state", async () => {
    const db = makeFakeDb(null, { [workingPath("order-1")]: { status: "pending" } });
    const result = await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1", before: { status: "pending" } })]
    }));
    assert.equal(result.ok, true);
    assert.equal(db.writes.filter((w) => w.path.includes("order-1")).length, 2);
});

test("applyMutationsBatch accepts a create item whose before is null and no doc exists yet", async () => {
    const db = makeFakeDb(); // no working docs at all -> current is null for everything
    const result = await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1", action: "create", before: null, after: { status: "new" } })]
    }));
    assert.equal(result.ok, true);
});

test("applyMutationsBatch rejects the WHOLE batch when one item's before is stale, writing nothing", async () => {
    const db = makeFakeDb(null, {
        [workingPath("order-1")]: { status: "pending" },
        // order-2's actual server state has moved on since the client last
        // read it (claims before: {status:"pending"} but server says "shipped").
        [workingPath("order-2")]: { status: "shipped" }
    });
    const result = await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1" }), validItem({ entityId: "order-2" })]
    }));

    assert.equal(result.ok, false);
    assert.equal(result.status, 409);
    // all-or-nothing: order-1's own before matched fine, but it still must
    // not be written, matching this module's own stated design.
    assert.equal(db.writes.length, 0);
});

test("applyMutationsBatch's conflict report includes every conflicting item, not just the first", async () => {
    const db = makeFakeDb(null, {
        [workingPath("order-1")]: { status: "shipped" },
        [workingPath("order-2")]: { status: "cancelled" },
        [workingPath("order-3")]: { status: "pending" } // this one's fine
    });
    const result = await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1" }), validItem({ entityId: "order-2" }), validItem({ entityId: "order-3" })]
    }));

    assert.equal(result.ok, false);
    assert.equal(result.conflicts.length, 2);
    const ids = result.conflicts.map((c) => c.entityId).sort();
    assert.deepEqual(ids, ["order-1", "order-2"]);
    // caller isn't left guessing what the server actually has
    assert.equal(result.conflicts.find((c) => c.entityId === "order-1").current.status, "shipped");
});

test("applyMutationsBatch's conflict check exempts an idempotent-replay item even if its working doc has since moved on", async () => {
    // order-1 was already applied by this exact batch requestId (audit doc
    // exists) -> exempt from CAS, same reasoning as applyMutation's own
    // idempotent-replay short-circuit. order-2 is a genuine new conflict.
    const db = makeFakeDb(
        ["tenants/tenant-1/audit_log/batch-1:order-1"],
        { [workingPath("order-2")]: { status: "shipped" } }
    );
    const result = await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1" }), validItem({ entityId: "order-2" })]
    }));

    assert.equal(result.ok, false);
    assert.equal(result.conflicts.length, 1);
    assert.equal(result.conflicts[0].entityId, "order-2");
});
