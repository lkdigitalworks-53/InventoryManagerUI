"use strict";

// New in this session — NOT part of the original P0 spec, which only defines
// a single-item recordMutation contract. Needed because approveAllPending
// (OrdersStore.qml) previously did one Firestore putMany for potentially
// many orders; routing that through N individual recordMutation calls would
// trade that away for N round trips. This gives one atomic batch write
// instead — every item lands or none do — which is a stronger compliance
// property than N independent writes, at the cost of a batch-size cap.
//
// MAX_BATCH_SIZE=200 keeps the transaction's write count (2 per item: one
// working-doc write + one audit_log entry) at 400, safely under Firestore's
// ~500-writes-per-transaction ceiling. A caller needing more than 200 items
// in one shot must split into multiple recordMutations calls; atomicity
// then holds within each chunk, not across chunks - a documented trade-off,
// not a hidden one.
//
// Zero Firebase SDK dependency of its own — same dependency-injection
// pattern as gatewayLogic.js / cutoverLogic.js.

const { ENTITY_COLLECTIONS, ALLOWED_ACTIONS } = require("./gatewayLogic");

const MAX_BATCH_SIZE = 200;

// Validates + normalizes a recordMutationsBatch request body. Returns
// { ok: true, entity, collection, requestId, items: [...] } or
// { ok: false, status, error }.
function validateBatchMutationRequest(body) {
    const entity = String(body.entity || "");
    const requestId = String(body.requestId || "");
    const items = Array.isArray(body.items) ? body.items : [];

    const collection = ENTITY_COLLECTIONS[entity];
    if (!collection) {
        return { ok: false, status: 400, error: "unsupported-entity" };
    }
    if (!requestId) {
        return { ok: false, status: 400, error: "missing-fields" };
    }
    if (items.length === 0) {
        return { ok: false, status: 400, error: "empty-batch" };
    }
    if (items.length > MAX_BATCH_SIZE) {
        return { ok: false, status: 400, error: "batch-too-large" };
    }

    const normalized = [];
    for (const item of items) {
        const entityId = String((item && item.entityId) || "");
        const action = String((item && item.action) || "");
        if (ALLOWED_ACTIONS.indexOf(action) < 0) {
            return { ok: false, status: 400, error: "unsupported-action" };
        }
        if (!entityId) {
            return { ok: false, status: 400, error: "missing-fields" };
        }
        normalized.push({
            entityId: entityId,
            action: action,
            before: item.before === undefined ? null : item.before,
            after: item.after === undefined ? null : item.after,
            clientTimestamp: item.clientTimestamp || null
        });
    }

    return { ok: true, entity: entity, collection: collection, requestId: requestId, items: normalized };
}

// Applies every item in the batch atomically, in a single transaction.
// Per-item idempotency: the audit_log doc id for item N is
// `<batchRequestId>:<entityId>` — a retried batch (or a batch that partly
// overlaps a previous one) skips whatever was already applied and only
// writes what's new.
async function applyMutationsBatch(db, params) {
    const tenantRoot = "tenants/" + params.tenantId;

    await db.runTransaction(async (txn) => {
        const refs = params.items.map((item) => ({
            item: item,
            auditRef: db.doc(tenantRoot + "/audit_log/" + params.requestId + ":" + item.entityId),
            workingRef: db.doc(tenantRoot + "/" + params.collection + "/" + item.entityId)
        }));

        // Firestore transactions require all reads before any writes.
        const existingFlags = await Promise.all(refs.map((r) => txn.get(r.auditRef)));

        refs.forEach((r, i) => {
            if (existingFlags[i].exists) return; // idempotent retry — already applied

            if (r.item.action === "delete") {
                txn.delete(r.workingRef);
            } else {
                txn.set(r.workingRef, r.item.after || {}, { merge: false });
            }

            txn.set(r.auditRef, {
                entryId: params.requestId + ":" + r.item.entityId,
                tenantId: params.tenantId,
                actorUid: params.actorUid,
                actorRole: params.actorRole,
                action: r.item.action,
                entity: params.entity,
                entityId: r.item.entityId,
                before: r.item.before,
                after: r.item.after,
                serverTimestamp: params.serverTimestamp,
                clientTimestamp: r.item.clientTimestamp,
                requestId: params.requestId,
                batchEntityId: r.item.entityId
            });
        });
    });
}

module.exports = {
    MAX_BATCH_SIZE,
    validateBatchMutationRequest,
    applyMutationsBatch
};
