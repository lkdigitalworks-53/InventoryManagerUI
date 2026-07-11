"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const GatewayLogic = require("../lib/gatewayLogic");

// ── parseBearerToken ────────────────────────────────────────────────────────

test("parseBearerToken returns null when header is missing", () => {
    assert.equal(GatewayLogic.parseBearerToken(undefined), null);
    assert.equal(GatewayLogic.parseBearerToken(""), null);
});

test("parseBearerToken returns null for a malformed header", () => {
    assert.equal(GatewayLogic.parseBearerToken("Basic abc123"), null);
});

test("parseBearerToken extracts the token from a valid header", () => {
    assert.equal(GatewayLogic.parseBearerToken("Bearer abc.def.ghi"), "abc.def.ghi");
});

test("parseBearerToken is case-insensitive on the scheme", () => {
    assert.equal(GatewayLogic.parseBearerToken("bearer xyz"), "xyz");
});

// ── validateMutationRequest ─────────────────────────────────────────────────

function validBody(overrides) {
    return Object.assign({
        entity: "inventory",
        entityId: "sku-1",
        action: "update",
        requestId: "req-1",
        before: { qty: 1 },
        after: { qty: 2 },
        clientTimestamp: 12345
    }, overrides || {});
}

test("validateMutationRequest rejects an unknown entity", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ entity: "widget" }));
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "unsupported-entity");
});

test("validateMutationRequest rejects a disallowed action", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ action: "rename" }));
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "unsupported-action");
});

test("validateMutationRequest rejects a missing entityId", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ entityId: "" }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-fields");
});

test("validateMutationRequest rejects a missing requestId", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ requestId: "" }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-fields");
});

test("validateMutationRequest accepts a valid request and resolves the collection", () => {
    const result = GatewayLogic.validateMutationRequest(validBody());
    assert.equal(result.ok, true);
    assert.equal(result.collection, "inventory");
    assert.equal(result.entity, "inventory");
    assert.equal(result.entityId, "sku-1");
    assert.equal(result.action, "update");
    assert.equal(result.requestId, "req-1");
    assert.deepEqual(result.before, { qty: 1 });
    assert.deepEqual(result.after, { qty: 2 });
});

test("validateMutationRequest resolves stock_batch to the stock_batches collection", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ entity: "stock_batch" }));
    assert.equal(result.ok, true);
    assert.equal(result.collection, "stock_batches");
});

test("validateMutationRequest resolves order to the orders collection", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ entity: "order" }));
    assert.equal(result.ok, true);
    assert.equal(result.collection, "orders");
});

// ── applyMutation ────────────────────────────────────────────────────────────
// Fake Firestore double: minimal .doc()/.runTransaction() shape, records what
// the transaction writes so we can assert on real decision logic (delete vs
// set, idempotent no-op) without touching a real or emulated Firestore.

function makeFakeDb(existingAuditPaths) {
    const writes = []; // { type: "set"|"delete", path, data, options }
    const existing = new Set(existingAuditPaths || []);
    return {
        writes,
        doc(path) {
            return { path };
        },
        async runTransaction(fn) {
            const txn = {
                async get(ref) {
                    return { exists: existing.has(ref.path) };
                },
                set(ref, data, options) {
                    writes.push({ type: "set", path: ref.path, data, options });
                },
                delete(ref) {
                    writes.push({ type: "delete", path: ref.path });
                }
            };
            return fn(txn);
        }
    };
}

function baseParams(overrides) {
    return Object.assign({
        tenantId: "tenant-1",
        actorUid: "uid-1",
        actorRole: "owner",
        entity: "inventory",
        entityId: "sku-1",
        action: "update",
        requestId: "req-1",
        before: { qty: 1 },
        after: { qty: 2 },
        clientTimestamp: 12345,
        collection: "inventory",
        serverTimestamp: "SERVER_TIMESTAMP_SENTINEL"
    }, overrides || {});
}

test("applyMutation writes the working doc and an audit_log entry for an update", async () => {
    const db = makeFakeDb();
    await GatewayLogic.applyMutation(db, baseParams());

    assert.equal(db.writes.length, 2);
    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/inventory/sku-1");
    const auditWrite = db.writes.find((w) => w.path === "tenants/tenant-1/audit_log/req-1");

    assert.ok(workingWrite, "expected a write to the working-tier doc");
    assert.equal(workingWrite.type, "set");
    assert.deepEqual(workingWrite.data, { qty: 2 });
    assert.equal(workingWrite.options.merge, false);

    assert.ok(auditWrite, "expected a write to the audit_log doc");
    assert.equal(auditWrite.type, "set");
    assert.equal(auditWrite.data.entryId, "req-1");
    assert.equal(auditWrite.data.tenantId, "tenant-1");
    assert.equal(auditWrite.data.actorUid, "uid-1");
    assert.equal(auditWrite.data.actorRole, "owner");
    assert.equal(auditWrite.data.entity, "inventory");
    assert.equal(auditWrite.data.entityId, "sku-1");
    assert.deepEqual(auditWrite.data.before, { qty: 1 });
    assert.deepEqual(auditWrite.data.after, { qty: 2 });
    assert.equal(auditWrite.data.clientTimestamp, 12345);
    assert.equal(auditWrite.data.requestId, "req-1");
    assert.equal(auditWrite.data.serverTimestamp, "SERVER_TIMESTAMP_SENTINEL");
});

test("applyMutation deletes the working doc (not the audit entry) for a delete action", async () => {
    const db = makeFakeDb();
    await GatewayLogic.applyMutation(db, baseParams({ action: "delete", after: null }));

    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/inventory/sku-1");
    const auditWrite = db.writes.find((w) => w.path === "tenants/tenant-1/audit_log/req-1");

    assert.ok(workingWrite);
    assert.equal(workingWrite.type, "delete");
    assert.ok(auditWrite);
    assert.equal(auditWrite.type, "set");
    assert.equal(auditWrite.data.action, "delete");
});

test("applyMutation is a no-op when the requestId was already applied (idempotent retry)", async () => {
    const db = makeFakeDb(["tenants/tenant-1/audit_log/req-1"]);
    await GatewayLogic.applyMutation(db, baseParams());

    assert.equal(db.writes.length, 0, "a retried requestId must not write anything again");
});
