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

function makeFakeDb(existingAuditPaths) {
    const writes = [];
    const existing = new Set(existingAuditPaths || []);
    return {
        writes,
        doc(path) { return { path }; },
        async runTransaction(fn) {
            const txn = {
                async get(ref) { return { exists: existing.has(ref.path) }; },
                set(ref, data, options) { writes.push({ type: "set", path: ref.path, data, options }); },
                delete(ref) { writes.push({ type: "delete", path: ref.path }); }
            };
            return fn(txn);
        }
    };
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
    const db = makeFakeDb();
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
    const db = makeFakeDb();
    await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1", action: "delete", after: null })]
    }));

    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/inventory/order-1");
    assert.equal(workingWrite.type, "delete");
});

test("applyMutationsBatch skips items whose requestId was already applied (idempotent retry)", async () => {
    const db = makeFakeDb(["tenants/tenant-1/audit_log/batch-1:order-1"]);
    await BatchMutationLogic.applyMutationsBatch(db, baseBatchParams({
        items: [validItem({ entityId: "order-1" }), validItem({ entityId: "order-2" })]
    }));

    // order-1 already applied -> no writes for it; order-2 is new -> 2 writes for it.
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
    const db = makeFakeDb();
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
