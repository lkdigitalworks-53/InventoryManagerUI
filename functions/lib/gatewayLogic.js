"use strict";

// Pure, testable core of the P0 compliance gateway's recordMutation handler.
// Deliberately has zero Firebase SDK dependency of its own — `db` and
// `serverTimestamp` are passed in by the caller (index.js), so this module
// can be unit tested without a real or emulated Firestore.
//
// Extracted from functions/index.js's exports.recordMutation (behavior-
// preserving refactor — see docs/superpowers/plans/2026-07-11-p0-gateway-fast-follow.md).

// P0 scope. `entity` -> collection name under the tenant root.
const ENTITY_COLLECTIONS = {
    inventory: "inventory",
    stock_batch: "stock_batches",
    stock_movement: "stock_movements",
    transaction: "transactions"
};

const ALLOWED_ACTIONS = ["create", "update", "delete", "opening_balance"];

// Extracts the token from an "Authorization: Bearer <token>" header.
// Returns null if the header is missing or doesn't match the scheme.
function parseBearerToken(authHeader) {
    const header = authHeader || "";
    const match = header.match(/^Bearer\s+(.+)$/i);
    return match ? match[1] : null;
}

// Validates + normalizes a recordMutation request body against the known
// entity/action allowlists. Returns { ok: true, ...normalizedFields } or
// { ok: false, status, error }.
function validateMutationRequest(body, entityCollections) {
    const collections = entityCollections || ENTITY_COLLECTIONS;
    const entity = String(body.entity || "");
    const entityId = String(body.entityId || "");
    const action = String(body.action || "");
    const requestId = String(body.requestId || "");
    const before = body.before === undefined ? null : body.before;
    const after = body.after === undefined ? null : body.after;
    const clientTimestamp = body.clientTimestamp || null;

    const collection = collections[entity];
    if (!collection) {
        return { ok: false, status: 400, error: "unsupported-entity" };
    }
    if (ALLOWED_ACTIONS.indexOf(action) < 0) {
        return { ok: false, status: 400, error: "unsupported-action" };
    }
    if (!entityId || !requestId) {
        return { ok: false, status: 400, error: "missing-fields" };
    }

    return {
        ok: true,
        entity: entity,
        entityId: entityId,
        action: action,
        requestId: requestId,
        before: before,
        after: after,
        clientTimestamp: clientTimestamp,
        collection: collection
    };
}

// Applies one mutation atomically: writes (or deletes) the working-tier doc
// and appends exactly one audit_log entry, in a single transaction. The
// audit_log doc id IS the requestId, so a retried call with the same
// requestId is a no-op (idempotent retry protection for the outbox).
async function applyMutation(db, params) {
    const tenantRoot = "tenants/" + params.tenantId;
    const auditRef = db.doc(tenantRoot + "/audit_log/" + params.requestId);
    const workingRef = db.doc(tenantRoot + "/" + params.collection + "/" + params.entityId);

    await db.runTransaction(async (txn) => {
        const existing = await txn.get(auditRef);
        if (existing.exists) return; // idempotent retry — already applied

        if (params.action === "delete") {
            txn.delete(workingRef);
        } else {
            txn.set(workingRef, params.after || {}, { merge: false });
        }

        txn.set(auditRef, {
            entryId: params.requestId,
            tenantId: params.tenantId,
            actorUid: params.actorUid,
            actorRole: params.actorRole,
            action: params.action,
            entity: params.entity,
            entityId: params.entityId,
            before: params.before,
            after: params.after,
            serverTimestamp: params.serverTimestamp,
            clientTimestamp: params.clientTimestamp,
            requestId: params.requestId
        });
    });
}

module.exports = {
    ENTITY_COLLECTIONS,
    ALLOWED_ACTIONS,
    parseBearerToken,
    validateMutationRequest,
    applyMutation
};
