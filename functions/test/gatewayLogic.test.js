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

test("validateMutationRequest resolves staff to the staff collection", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ entity: "staff" }));
    assert.equal(result.ok, true);
    assert.equal(result.collection, "staff");
});

test("validateMutationRequest resolves removed_staff to the removed_staff collection", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ entity: "removed_staff", action: "create" }));
    assert.equal(result.ok, true);
    assert.equal(result.collection, "removed_staff");
});

test("ENTITY_COLLECTIONS keeps removed_staff distinct from staff (a tombstone must never overwrite a live record)", () => {
    assert.notEqual(GatewayLogic.ENTITY_COLLECTIONS.removed_staff, GatewayLogic.ENTITY_COLLECTIONS.staff);
});

test("validateMutationRequest resolves supplier to the suppliers collection", () => {
    const result = GatewayLogic.validateMutationRequest(validBody({ entity: "supplier" }));
    assert.equal(result.ok, true);
    assert.equal(result.collection, "suppliers");
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

// Like makeFakeDb, but tracks real document DATA per path (not just
// existence), so tests can assert on read-then-compute logic (CAS, delta)
// that needs to see what's actually stored at workingRef. `docs` is
// { path: data }. Matches the real Firestore DocumentSnapshot shape:
// `.exists` is a boolean, `.data()` is a method.
function makeFakeDbWithData(docs, existingAuditPaths) {
    const writes = [];
    const store = Object.assign({}, docs || {});
    // Convenience seeding for "this audit_log entry already exists" tests
    // that don't care about its contents — only fills in a path not
    // already given real data via `docs`.
    for (const path of (existingAuditPaths || [])) {
        if (!Object.prototype.hasOwnProperty.call(store, path)) store[path] = {};
    }
    return {
        writes,
        store,
        doc(path) {
            return { path };
        },
        async runTransaction(fn) {
            const txn = {
                async get(ref) {
                    const has = Object.prototype.hasOwnProperty.call(store, ref.path);
                    return { exists: has, data: () => (has ? store[ref.path] : undefined) };
                },
                set(ref, data, options) {
                    writes.push({ type: "set", path: ref.path, data, options });
                    store[ref.path] = data;
                },
                delete(ref) {
                    writes.push({ type: "delete", path: ref.path });
                    delete store[ref.path];
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

// PH3: an inventory DELETE needs the handler-validated sweep prefix (applyMutation throws without it).
function cascadeParams(overrides) {
    return baseParams(Object.assign({
        action: "delete",
        after: null,
        cleanupEnvPrefix: "dev1",
        cleanupPrefix: "dev1/tenants/tenant-1/products/sku-1/"
    }, overrides || {}));
}

test("applyMutation writes the working doc and an audit_log entry for an update", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
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
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
    await GatewayLogic.applyMutation(db, cascadeParams());

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

// ── applyDelta ───────────────────────────────────────────────────────────────
// Atomic server-side numeric field adjustments (Component 4 of the async-write-
// sequencing design). Unlike applyMutation, this never compares against a
// client-supplied `before` — it reads the current value inside the same
// transaction and computes current+delta, so it's safe regardless of what
// else may have changed the doc concurrently.

function deltaParams(overrides) {
    return Object.assign({
        tenantId: "tenant-1",
        actorUid: "uid-1",
        actorRole: "owner",
        entity: "stock_batch",
        entityId: "batch-1",
        requestId: "req-delta-1",
        deltas: { qtyRemaining: -3 },
        floors: {},
        clientTimestamp: 12345,
        collection: "stock_batches",
        serverTimestamp: "SERVER_TIMESTAMP_SENTINEL"
    }, overrides || {});
}

test("applyDelta applies a single-field delta to the current stored value", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/stock_batches/batch-1": { qtyRemaining: 10 } });
    await GatewayLogic.applyDelta(db, deltaParams());

    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/stock_batches/batch-1");
    assert.ok(workingWrite, "expected a write to the working-tier doc");
    assert.equal(workingWrite.data.qtyRemaining, 7);
});

test("applyDelta writes an audit_log entry with the server-observed before/after values", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/stock_batches/batch-1": { qtyRemaining: 10 } });
    await GatewayLogic.applyDelta(db, deltaParams());

    const auditWrite = db.writes.find((w) => w.path === "tenants/tenant-1/audit_log/req-delta-1");
    assert.ok(auditWrite, "expected a write to the audit_log doc");
    assert.deepEqual(auditWrite.data.before, { qtyRemaining: 10 });
    assert.deepEqual(auditWrite.data.after, { qtyRemaining: 7 });
    assert.equal(auditWrite.data.entryId, "req-delta-1");
    assert.equal(auditWrite.data.entity, "stock_batch");
    assert.equal(auditWrite.data.entityId, "batch-1");
});

test("applyDelta rejects when a floor would be violated, writing nothing at all", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/stock_batches/batch-1": { qtyRemaining: 2 } });
    const result = await GatewayLogic.applyDelta(
        db, deltaParams({ deltas: { qtyRemaining: -5 }, floors: { qtyRemaining: 0 } }));

    assert.equal(result.ok, false);
    assert.equal(result.status, 409);
    assert.equal(result.error, "insufficient-quantity");
    assert.equal(result.field, "qtyRemaining");
    assert.equal(result.current, 2);
    assert.equal(db.writes.length, 0, "a rejected delta must write nothing, not even a partial field");
});

test("applyDelta succeeds when a delta brings a field to exactly its floor", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/stock_batches/batch-1": { qtyRemaining: 5 } });
    const result = await GatewayLogic.applyDelta(
        db, deltaParams({ deltas: { qtyRemaining: -5 }, floors: { qtyRemaining: 0 } }));

    assert.equal(result.ok, true);
    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/stock_batches/batch-1");
    assert.equal(workingWrite.data.qtyRemaining, 0);
});

test("applyDelta rejects the whole call when ANY field would violate its floor, even if others wouldn't", async () => {
    const db = makeFakeDbWithData({
        "tenants/tenant-1/stock_batches/batch-1": { qtyRemaining: 1, qtyReceived: 100 }
    });
    const result = await GatewayLogic.applyDelta(db, deltaParams({
        deltas: { qtyRemaining: -5, qtyReceived: -1 },
        floors: { qtyRemaining: 0, qtyReceived: 0 }
    }));

    assert.equal(result.ok, false);
    assert.equal(result.field, "qtyRemaining");
    assert.equal(db.writes.length, 0, "qtyReceived must not be written either — all-or-nothing");
});

test("applyDelta returns not-found and writes nothing when the working doc doesn't exist", async () => {
    const db = makeFakeDbWithData({});
    const result = await GatewayLogic.applyDelta(db, deltaParams());

    assert.equal(result.ok, false);
    assert.equal(result.status, 404);
    assert.equal(result.error, "not-found");
    assert.equal(db.writes.length, 0);
});

test("applyDelta treats a missing field on the current doc as a zero baseline", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/stock_batches/batch-1": { note: "no qty field yet" } });
    await GatewayLogic.applyDelta(db, deltaParams({ deltas: { qtyRemaining: 4 } }));

    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/stock_batches/batch-1");
    assert.equal(workingWrite.data.qtyRemaining, 4);
});

test("applyDelta applies multiple fields atomically in one call", async () => {
    const db = makeFakeDbWithData({
        "tenants/tenant-1/stock_batches/batch-1": { qtyReceived: 20, qtyRemaining: 5 }
    });
    await GatewayLogic.applyDelta(db, deltaParams({ deltas: { qtyReceived: 8, qtyRemaining: 8 } }));

    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/stock_batches/batch-1");
    assert.equal(workingWrite.data.qtyReceived, 28);
    assert.equal(workingWrite.data.qtyRemaining, 13);
});

test("applyDelta is a no-op when the requestId was already applied (idempotent retry)", async () => {
    const db = makeFakeDbWithData(
        { "tenants/tenant-1/stock_batches/batch-1": { qtyRemaining: 10 } },
        ["tenants/tenant-1/audit_log/req-delta-1"]
    );
    await GatewayLogic.applyDelta(db, deltaParams());

    assert.equal(db.writes.length, 0, "a retried delta requestId must not write anything again");
});

// ── applyMutation: whole-record compare-and-swap backstop ─────────────────────
// Component 3 of the async-write-sequencing design. A defense-in-depth check,
// expected to fire rarely once locking (Component 2) is in place — but still
// required, since Firestore's own transaction retry only protects against
// truly simultaneous commits, not a client whose `before` went stale seconds
// ago because something else already committed since.

test("applyMutation rejects when 'before' doesn't match the current server state, writing nothing", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 99 } });
    const result = await GatewayLogic.applyMutation(db, baseParams({ before: { qty: 1 } }));

    assert.equal(result.ok, false);
    assert.equal(result.status, 409);
    assert.equal(result.conflict, true);
    assert.deepEqual(result.current, { qty: 99 });
    assert.equal(db.writes.length, 0, "a rejected mutation must not touch the working doc or write an audit entry");
});

test("applyMutation rejects a claimed 'create' (before: null) when the doc already exists", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 5 } });
    const result = await GatewayLogic.applyMutation(db, baseParams({ action: "create", before: null }));

    assert.equal(result.ok, false);
    assert.equal(result.conflict, true);
});

test("applyMutation rejects an 'update' with a non-null 'before' when the doc doesn't exist, without crashing", async () => {
    const db = makeFakeDbWithData({});
    const result = await GatewayLogic.applyMutation(db, baseParams({ before: { qty: 1 } }));

    assert.equal(result.ok, false);
    assert.equal(result.conflict, true);
    assert.equal(result.current, null);
});

test("applyMutation proceeds normally when 'before' matches the current server state", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
    const result = await GatewayLogic.applyMutation(db, baseParams());

    assert.equal(result.ok, true);
    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/inventory/sku-1");
    assert.deepEqual(workingWrite.data, { qty: 2 });
});

test("applyMutation's idempotency short-circuit runs before the CAS check — a retry is never rejected as a conflict against its own prior result", async () => {
    const db = makeFakeDbWithData(
        { "tenants/tenant-1/inventory/sku-1": { qty: 2 } }, // already the post-mutation state
        ["tenants/tenant-1/audit_log/req-1"]
    );
    // before:{qty:1} would mismatch current:{qty:2} if CAS ran — but this is a
    // retry of an already-applied request, so it must short-circuit first.
    const result = await GatewayLogic.applyMutation(db, baseParams());

    assert.equal(result.ok, true);
    assert.equal(result.idempotentReplay, true);
    assert.equal(db.writes.length, 0);
});

test("applyMutation's CAS compare is not sensitive to object key insertion order", async () => {
    const db = makeFakeDbWithData({
        "tenants/tenant-1/inventory/sku-1": { b: 2, a: 1 } // constructed key order: b, then a
    });
    const result = await GatewayLogic.applyMutation(db, baseParams({
        before: { a: 1, b: 2 }, // same object, keys written in the opposite order
        after: { a: 1, b: 3 }
    }));

    assert.equal(result.ok, true, "key order alone must never cause a spurious conflict");
});

test("applyDelta's success result includes the computed new field values, not just ok:true", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/stock_batches/batch-1": { qtyRemaining: 10 } });
    const result = await GatewayLogic.applyDelta(db, deltaParams());

    assert.equal(result.ok, true);
    assert.deepEqual(result.after, { qtyRemaining: 7 },
        "callers need the server-authoritative new value, not just success/failure, to avoid local drift");
});

test("applyDelta's idempotent-replay result also includes the original after values", async () => {
    const db = makeFakeDbWithData(
        { "tenants/tenant-1/stock_batches/batch-1": { qtyRemaining: 7 } },
        []
    );
    // Seed the audit_log entry as if a prior attempt already succeeded.
    db.store["tenants/tenant-1/audit_log/req-delta-1"] = { after: { qtyRemaining: 7 } };
    const result = await GatewayLogic.applyDelta(db, deltaParams());

    assert.equal(result.ok, true);
    assert.equal(result.idempotentReplay, true);
    assert.deepEqual(result.after, { qtyRemaining: 7 },
        "a retried request must still tell the caller the real outcome, not just that it was a replay");
});

test("applyDelta clamps at a floor instead of rejecting when the field is in 'clamps' not 'floors'", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { stock: 2 } });
    const result = await GatewayLogic.applyDelta(db, deltaParams({
        entity: "inventory", entityId: "sku-1", collection: "inventory",
        deltas: { stock: -5 }, floors: {}, clamps: { stock: 0 }
    }));

    assert.equal(result.ok, true, "clamp mode must succeed, not reject, unlike floors mode");
    assert.equal(result.after.stock, 0, "clamped at the floor, not driven negative");
    const workingWrite = db.writes.find((w) => w.path === "tenants/tenant-1/inventory/sku-1");
    assert.equal(workingWrite.data.stock, 0);
});

test("applyDelta clamp mode still succeeds normally (no clamping) when the delta doesn't cross the floor", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { stock: 10 } });
    const result = await GatewayLogic.applyDelta(db, deltaParams({
        entity: "inventory", entityId: "sku-1", collection: "inventory",
        deltas: { stock: -3 }, floors: {}, clamps: { stock: 0 }
    }));

    assert.equal(result.ok, true);
    assert.equal(result.after.stock, 7);
});

// ── validateDeltaRequest ────────────────────────────────────────────────────

function validDeltaBody(overrides) {
    return Object.assign({
        entity: "stock_batch",
        entityId: "batch-1",
        requestId: "req-delta-1",
        deltas: { qtyRemaining: -3 },
        floors: { qtyRemaining: 0 },
        clamps: {},
        clientTimestamp: 12345
    }, overrides || {});
}

test("validateDeltaRequest rejects an unknown entity", () => {
    const result = GatewayLogic.validateDeltaRequest(validDeltaBody({ entity: "widget" }));
    assert.equal(result.ok, false);
    assert.equal(result.status, 400);
    assert.equal(result.error, "unsupported-entity");
});

test("validateDeltaRequest rejects a missing entityId", () => {
    const result = GatewayLogic.validateDeltaRequest(validDeltaBody({ entityId: "" }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-fields");
});

test("validateDeltaRequest rejects a missing requestId", () => {
    const result = GatewayLogic.validateDeltaRequest(validDeltaBody({ requestId: "" }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-fields");
});

test("validateDeltaRequest rejects an empty deltas object", () => {
    const result = GatewayLogic.validateDeltaRequest(validDeltaBody({ deltas: {} }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "missing-deltas");
});

test("validateDeltaRequest rejects a non-numeric delta value", () => {
    const result = GatewayLogic.validateDeltaRequest(validDeltaBody({ deltas: { qtyRemaining: "3" } }));
    assert.equal(result.ok, false);
    assert.equal(result.error, "invalid-delta-value");
});

test("validateDeltaRequest accepts a valid request and resolves the collection", () => {
    const result = GatewayLogic.validateDeltaRequest(validDeltaBody());
    assert.equal(result.ok, true);
    assert.equal(result.collection, "stock_batches");
    assert.deepEqual(result.deltas, { qtyRemaining: -3 });
    assert.deepEqual(result.floors, { qtyRemaining: 0 });
});

// ── PH3 cleanup marker (design Q5/Q11; test plan F18-F25, F37) ─────────────────────────────────
const MARKER_PATH = "tenants/tenant-1/pending_cleanup/sku-1";

test("F18 inventory delete: marker written in the SAME txn (doc delete + marker + audit, one commit)", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
    const result = await GatewayLogic.applyMutation(db, cascadeParams());
    assert.deepEqual(result, { ok: true });
    assert.deepEqual(db.writes.map((w) => w.type + ":" + w.path), [
        "delete:tenants/tenant-1/inventory/sku-1",
        "set:" + MARKER_PATH,
        "set:tenants/tenant-1/audit_log/req-1"
    ]);
});

test("F19 inventory delete: marker carries prefix, envPrefix, createdAt, attempts 0, lastError null", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
    await GatewayLogic.applyMutation(db, cascadeParams());
    const marker = db.writes.find((w) => w.path === MARKER_PATH).data;
    assert.deepEqual(marker, {
        productId: "sku-1", envPrefix: "dev1", prefix: "dev1/tenants/tenant-1/products/sku-1/",
        createdAt: "SERVER_TIMESTAMP_SENTINEL", attempts: 0, lastError: null,
        actorUid: "uid-1", actorRole: "owner", requestId: "req-1"
    });
    const prd = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
    await GatewayLogic.applyMutation(prd, cascadeParams({
        cleanupEnvPrefix: "prd", cleanupPrefix: "prd/tenants/tenant-1/products/sku-1/" }));
    assert.equal(prd.writes.find((w) => w.path === MARKER_PATH).data.prefix, "prd/tenants/tenant-1/products/sku-1/");
});

test("BC-G01 inventory delete: marker carries the DELETE's actor and requestId (R2), whatever they are", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
    await GatewayLogic.applyMutation(db, cascadeParams({ actorUid: "uid-77", actorRole: "admin", requestId: "req-xyz" }));
    const marker = db.writes.find((w) => w.path === MARKER_PATH).data;
    assert.equal(marker.actorUid, "uid-77");
    assert.equal(marker.actorRole, "admin");
    assert.equal(marker.requestId, "req-xyz");
    const audit = db.writes.find((w) => w.path === "tenants/tenant-1/audit_log/req-xyz").data;
    assert.equal(marker.requestId, audit.requestId, "marker back-links to the product-delete audit entry");
});

test("F22 inventory delete: CAS conflict -> 409, NO marker, NO writes at all (destroy-before-ack regression)", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 99 } }); // server moved on
    const result = await GatewayLogic.applyMutation(db, cascadeParams()); // before = { qty: 1 }
    assert.equal(result.ok, false);
    assert.equal(result.status, 409);
    assert.equal(result.conflict, true);
    assert.equal(db.writes.length, 0);
    assert.equal(Object.prototype.hasOwnProperty.call(db.store, MARKER_PATH), false);
});

test("F23 inventory delete: idempotent replay -> early return, no second marker", async () => {
    const db = makeFakeDbWithData({}, ["tenants/tenant-1/audit_log/req-1"]);
    const result = await GatewayLogic.applyMutation(db, cascadeParams());
    assert.deepEqual(result, { ok: true, idempotentReplay: true });
    assert.equal(db.writes.length, 0);
});

test("F24 inventory update/create/opening_balance: no marker", async () => {
    for (const action of ["update", "create", "opening_balance"]) {
        const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
        await GatewayLogic.applyMutation(db, baseParams({ action: action }));
        assert.equal(db.writes.some((w) => w.path.indexOf("pending_cleanup") >= 0), false, action);
    }
});

test("F25 non-inventory deletes (stock_batch, order, staff, supplier): no marker", async () => {
    const cases = [["stock_batch", "stock_batches"], ["order", "orders"], ["staff", "staff"], ["supplier", "suppliers"]];
    for (const [entity, collection] of cases) {
        const path = "tenants/tenant-1/" + collection + "/sku-1";
        const db = makeFakeDbWithData({ [path]: { qty: 1 } });
        const result = await GatewayLogic.applyMutation(db, baseParams({ action: "delete", after: null, entity: entity, collection: collection }));
        assert.equal(result.ok, true, entity);
        assert.equal(db.writes.some((w) => w.path.indexOf("pending_cleanup") >= 0), false, entity);
        assert.equal(db.writes.filter((w) => w.type === "delete").length, 1, entity);
    }
});

test("inventory delete without a usable sweep prefix THROWS before any read or write", async () => {
    for (const bad of [{ cleanupPrefix: undefined }, { cleanupPrefix: "" }, { cleanupEnvPrefix: undefined },
                       { cleanupPrefix: "dev1/tenants/tenant-1/products/" },
                       { cleanupPrefix: "dev1/tenants/tenant-1/products/other/" }]) {
        const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
        await assert.rejects(() => GatewayLogic.applyMutation(db, cascadeParams(bad)), /missing-cleanup-prefix/);
        assert.equal(db.writes.length, 0, JSON.stringify(bad));
    }
});

test("inventory delete of a server-absent product with before=null: deletes nothing real, still leaves a marker", async () => {
    // Pins current behaviour (deepEqual(null, null) passes CAS): the marker is harmless, the sweep
    // re-checks the product doc and removes any stray objects.
    const db = makeFakeDbWithData({});
    const result = await GatewayLogic.applyMutation(db, cascadeParams({ before: null }));
    assert.equal(result.ok, true);
    assert.ok(db.writes.some((w) => w.path === MARKER_PATH));
});

test("F37 F5 pin (single path): stale before.photoIds -> 409 conflict, nothing written", async () => {
    // A photo was confirmed on the server between the client's edit and the drain: strict compare
    // (incl. photoIds) stays on purpose (Q2 accepted). Do NOT relax without server-preserving photoIds.
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1, photoIds: ["photo-new"] } });
    const result = await GatewayLogic.applyMutation(db, baseParams({
        before: { qty: 1, photoIds: [] }, after: { qty: 2, photoIds: [] } }));
    assert.equal(result.ok, false);
    assert.equal(result.status, 409);
    assert.deepEqual(result.current, { qty: 1, photoIds: ["photo-new"] });
    assert.equal(db.writes.length, 0);
});

test("F41 real logic: delete of a server-absent product with a non-null before -> 409, current null, no marker (Q13 pin)", async () => {
    const db = makeFakeDbWithData({});
    const result = await GatewayLogic.applyMutation(db, cascadeParams()); // before = { qty: 1 }, server has nothing
    assert.equal(result.ok, false);
    assert.equal(result.status, 409);
    assert.equal(result.conflict, true);
    assert.equal(result.current, null);
    assert.equal(db.writes.length, 0);
});

// ── Review fix (PR #118): "cascade~" is a reserved audit_log id namespace ───────────────────────
test("RES-G1 validateMutationRequest rejects a requestId in the reserved cascade namespace", () => {
    for (const id of ["cascade~PRD-1~B1", "cascade~", "cascade~x"]) {
        const result = GatewayLogic.validateMutationRequest(validBody({ requestId: id }));
        assert.equal(result.ok, false, id);
        assert.equal(result.status, 400, id);
        assert.equal(result.error, "invalid-request-id", id);
    }
});

test("RES-G2 validateDeltaRequest rejects a requestId in the reserved cascade namespace", () => {
    for (const id of ["cascade~PRD-1~B1", "cascade~"]) {
        const result = GatewayLogic.validateDeltaRequest(validDeltaBody({ requestId: id }));
        assert.equal(result.ok, false, id);
        assert.equal(result.status, 400, id);
        assert.equal(result.error, "invalid-request-id", id);
    }
});

test("RES-G3 the reservation is an exact, case-sensitive PREFIX: lookalikes stay valid", () => {
    for (const id of ["req-cascade~1", "Cascade~1", "cascade-1", "cascade1~", " cascade~1", "xcascade~1"]) {
        assert.equal(GatewayLogic.validateMutationRequest(validBody({ requestId: id })).ok, true, id);
        assert.equal(GatewayLogic.validateDeltaRequest(validDeltaBody({ requestId: id })).ok, true, id);
    }
});

// ── PH5 F42: removing a field client-side is a CAS conflict for docs that still store it ─────────
// The server compares WHOLE documents (_deepEqual: identical key sets). Product docs written before
// PH5 carry photoUrl:"" and photoUpdatedAt:""; the PH5 client no longer sends them in `before`, so
// those docs 409 on every edit (accepted: fresh tenants only, Q-P5-3 a). This pins the consequence
// so nobody "fixes" the comparator, or re-adds the keys, without making that decision deliberately.
test("F42 applyMutation: before WITHOUT photoUrl/photoUpdatedAt vs a stored doc WITH them -> 409, nothing written", async () => {
    const stored = { qty: 1, photoUrl: "", photoUpdatedAt: "" };
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": stored });
    const result = await GatewayLogic.applyMutation(db, baseParams({ before: { qty: 1 } }));

    assert.equal(result.ok, false);
    assert.equal(result.status, 409);
    assert.equal(result.conflict, true);
    assert.deepEqual(result.current, stored);
    assert.equal(db.writes.length, 0);
});

test("F42b applyMutation: before and stored doc BOTH without the legacy keys (fresh tenant) commits", async () => {
    const db = makeFakeDbWithData({ "tenants/tenant-1/inventory/sku-1": { qty: 1 } });
    const result = await GatewayLogic.applyMutation(db, baseParams());
    assert.equal(result.ok, true);
});
