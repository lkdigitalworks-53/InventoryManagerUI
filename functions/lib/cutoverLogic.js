"use strict";

// Pure/dependency-injected core of the P0 compliance gateway's runCutover
// handler. Zero Firebase SDK dependency of its own — `db`, `serverTimestamp`
// are passed in by the caller (index.js), same pattern as gatewayLogic.js.
//
// Extracted from functions/index.js's exports.runCutover (behavior-
// preserving refactor — see docs/superpowers/plans/2026-07-11-p0-gateway-fast-follow.md).

const DEFAULT_BATCH_SIZE = 400;

// Owner-only + explicit-confirmation gate. `ctx` is the caller's derived
// tenant context (or null/undefined if they have none); `body` is the raw
// request body. Pure.
function validateCutoverRequest(ctx, body) {
    if (!ctx) {
        return { ok: false, status: 403, error: "no-tenant-context" };
    }
    if (ctx.role !== "owner") {
        return { ok: false, status: 403, error: "owner-only" };
    }
    if (String((body && body.confirm) || "") !== "CUTOVER") {
        return { ok: false, status: 400, error: "confirmation-required" };
    }
    return { ok: true };
}

// Shape of the single immutable audit_log marker a cutover leaves behind.
// Pure — serverTimestamp is passed in, not computed here.
function buildCutoverMarker(params) {
    return {
        entryId: params.markerId,
        tenantId: params.tenantId,
        actorUid: params.actorUid,
        actorRole: params.actorRole,
        action: "cutover",
        entity: "tenant",
        entityId: params.tenantId,
        before: null,
        after: { note: "Fresh-start cutover: ledger wiped, stock zeroed." },
        serverTimestamp: params.serverTimestamp,
        clientTimestamp: params.clientTimestamp,
        requestId: params.markerId
    };
}

// Deletes every doc under `path`, committing in chunks of `batchSize` writes
// (Firestore's batch-write limit is 500; this stays comfortably under it).
// Returns the number of docs deleted.
async function deleteCollection(db, path, batchSize) {
    const size = batchSize || DEFAULT_BATCH_SIZE;
    const snap = await db.collection(path).get();
    let batch = db.batch();
    let n = 0;
    for (const doc of snap.docs) {
        batch.delete(doc.ref);
        if (++n % size === 0) { await batch.commit(); batch = db.batch(); }
    }
    if (n % size !== 0) await batch.commit();
    return snap.size;
}

// Zeroes the `stock` field on every doc in the inventory collection under
// tenant root `root`, same batching discipline as deleteCollection. Returns
// the number of docs updated.
async function zeroInventoryStock(db, root, batchSize) {
    const size = batchSize || DEFAULT_BATCH_SIZE;
    const inv = await db.collection(root + "/inventory").get();
    let batch = db.batch();
    let n = 0;
    for (const doc of inv.docs) {
        batch.update(doc.ref, { stock: 0 });
        if (++n % size === 0) { await batch.commit(); batch = db.batch(); }
    }
    if (n % size !== 0) await batch.commit();
    return inv.docs.length;
}

module.exports = {
    DEFAULT_BATCH_SIZE,
    validateCutoverRequest,
    buildCutoverMarker,
    deleteCollection,
    zeroInventoryStock
};
